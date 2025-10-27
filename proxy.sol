// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ICalculator {
    function getLot(uint32 assetId) external view returns (uint256 num, uint256 den);
    function isMarketOpen(uint32 assetId) external view returns (bool);
}

interface ISupraSValueFeedMinimal {
    struct priceFeed { uint256 round; uint256 decimals; uint256 time; uint256 price; }
    function getSvalue(uint256 _pairIndex) external view returns (priceFeed memory);
}

interface IVault {
    function available(address user) external view returns (uint256);
    function lock(address user, uint256 amount) external;
    function unlock(address user, uint256 amount) external;
    function settle(address user, int256 pnl) external;
}

contract Trades {
    uint256 private constant WAD = 1e18;              // qty interne
    uint256 private constant USD_SCALE = 1e12;        // (qty1e18 * price1e6) / 1e18 => USD6
    uint256 private constant LIQ_LOSS_OF_MARGIN_WAD = 8e17; // 0.8
    uint16  private constant TOL_BPS = 5;             // 0.05% tolérance

    ICalculator public immutable calculator;
    ISupraSValueFeedMinimal public immutable supraOracle;
    IVault public immutable vault;

    uint32 public nextId = 1;

    // States
    uint8 private constant STATE_ORDER     = 0; // LIMIT en attente
    uint8 private constant STATE_OPEN      = 1; // position active
    uint8 private constant STATE_CLOSED    = 2; // fermée
    uint8 private constant STATE_CANCELLED = 3; // annulée

    // Close reasons (pour Removed)
    uint8 private constant RM_CANCELLED = 0;
    uint8 private constant RM_MARKET    = 1;
    uint8 private constant RM_SL        = 2;
    uint8 private constant RM_TP        = 3;
    uint8 private constant RM_LIQ       = 4;

    // Close args (API close)
    uint8 private constant REASON_MARKET = 0;
    uint8 private constant REASON_SL     = 1;
    uint8 private constant REASON_TP     = 2;
    uint8 private constant REASON_LIQ    = 3;

    struct Trade {
        // slot 0
        address owner;      // 20B
        uint32  asset;      // 4B
        uint16  lots;       // 2B
        uint8   flags;      // bit0=longSide ; bits4..7=state
        uint8   _pad0;      // 1B

        // slot 1 (prix x1e6)
        int64   entryX6;    // 0 si ORDER
        int64   targetX6;   // 0 si MARKET
        int64   slX6;       // 0 si absent
        int64   tpX6;       // 0 si absent

        // slot 2
        int64   liqX6;      // fixé à l’ouverture (MARKET: entry ; LIMIT: target)
        uint16  leverageX;  // 1..100
        uint16  _pad1;
        uint64  marginUsd6; // USDC/USDT 1e6
    }

    mapping(uint32 => Trade) public trades;

    // ───── Exposition agrégée ULTRA-LÉGÈRE (par actif, par side) ─────
    struct SideAgg {
        uint128 totalLots;            // ∑ lots ouverts (>=0)
        int256  sumEntryX6TimesLots;  // ∑ (entryX6 * lots) en x1e6
    }
    struct AssetAgg {
        SideAgg longAgg;
        SideAgg shortAgg;
    }
    mapping(uint32 => AssetAgg) public exposureAgg;

    // ───────────────── EVENTS ─────────────────

    // Création d’une position (MARKET ou LIMIT), snapshot utile pour l’indexer
    event Opened(
        uint32 indexed id,
        uint8  state,            // 0=ORDER, 1=OPEN
        uint32 indexed asset,
        bool   longSide,
        uint16 lots,
        int64  entryOrTargetX6,  // entry si OPEN, target si ORDER
        int64  slX6,
        int64  tpX6,
        int64  liqX6,            // fixé à l’ouverture (MARKET: entry ; LIMIT: target)
        address indexed trader,  // append
        uint16 leverageX         // append (effet de levier)
    );

    // LIMIT exécuté -> OPEN (idempotent)
    event Executed(uint32 indexed id, int64 entryX6);

    // Mise à jour des stops
    event StopsUpdated(uint32 indexed id, int64 slX6, int64 tpX6);

    // Sortie du carnet: fermeture OU annulation
    // reason: 0=CANCELLED, 1=MARKET, 2=SL, 3=TP, 4=LIQ
    event Removed(uint32 indexed id, uint8 reason, int64 execX6, int256 pnlUsd6);

    constructor(address _calc, address _supra, address _vault) {
        require(_calc != address(0) && _supra != address(0) && _vault != address(0), "ADDR_0");
        calculator = ICalculator(_calc);
        supraOracle = ISupraSValueFeedMinimal(_supra);
        vault = IVault(_vault);
    }

    // ───────────────── helpers ─────────────────

    function _priceX6FromOracle(uint32 assetId) internal view returns (int64 pX6) {
        ISupraSValueFeedMinimal.priceFeed memory pf = supraOracle.getSvalue(assetId);
        require(pf.price > 0, "NO_PRICE");
        uint256 p;
        if (pf.decimals == 6) {
            p = pf.price;
        } else if (pf.decimals > 6) {
            p = pf.price / (10 ** (pf.decimals - 6));
        } else {
            p = pf.price * (10 ** (6 - pf.decimals));
        }
        require(p > 0 && p <= type(uint64).max, "PX6_RANGE");
        return int64(uint64(p));
    }

    function _qty1e18(uint32 assetId, uint16 lots) internal view returns (uint256) {
        (uint256 num, uint256 den) = calculator.getLot(assetId);
        return (lots == 0) ? 0 : (uint256(lots) * WAD * num) / den;
    }

    function _notionalUsd6(uint256 qty1e18, int64 priceX6) internal pure returns (uint64) {
        uint256 n6 = (qty1e18 * uint256(uint64(priceX6))) / WAD;
        require(n6 <= type(uint64).max, "NOTIONAL_64");
        return uint64(n6);
    }

    function _marginUsd6(uint64 notionalUsd6, uint16 lev) internal pure returns (uint64) {
        uint256 m = (uint256(notionalUsd6) + lev - 1) / lev;
        require(m <= type(uint64).max, "MARGIN_64");
        return uint64(m);
    }

    function _liqPriceX6(int64 entryX6, uint16 lev, bool longSide) internal pure returns (int64) {
        require(entryX6 > 0 && lev > 0, "BAD_LIQ_ARGS");
        uint256 entry1e6 = uint256(uint64(entryX6));
        uint256 liq1e6 = longSide
            ? (entry1e6 * (1e18 - (LIQ_LOSS_OF_MARGIN_WAD / lev))) / 1e18
            : (entry1e6 * (1e18 + (LIQ_LOSS_OF_MARGIN_WAD / lev))) / 1e18;
        require(liq1e6 <= type(uint64).max, "LIQ_RANGE");
        return int64(uint64(liq1e6));
    }

    function _setState(uint8 flags, uint8 newState) internal pure returns (uint8) {
        return (flags & 0x0F) | (newState << 4);
    }

    function _getState(uint8 flags) internal pure returns (uint8) {
        return (flags >> 4) & 0x0F;
    }

    function _withinTol(int64 aX6, int64 bX6, uint16 bps) internal pure returns (bool) {
        uint256 A = uint256(uint64(aX6));
        uint256 B = uint256(uint64(bX6));
        uint256 diff = A > B ? A - B : B - A;
        return diff * 10000 <= A * bps;
    }

    function _pnlUsd6(
        int64 entryX6,
        int64 execX6,
        bool  longSide,
        uint256 qty1e18
    ) internal pure returns (int256) {
        int256 dX6 = int256(execX6) - int256(entryX6);
        if (!longSide) dX6 = -dX6;
        return (int256(qty1e18) * dX6) / int256(WAD);
    }

    // Validation générique des stops selon le sens & le prix de référence (entry/target)
    function _validateStops(
        bool longSide,
        int64 baseX6,   // entry si OPEN/MARKET, target si ORDER/LIMIT
        int64 liqX6,
        int64 slX6,
        int64 tpX6
    ) internal pure {
        // TP facultatif (0 = pas de TP)
        if (tpX6 != 0) {
            if (longSide) {
                require(tpX6 >= baseX6, "TP_SIDE");
            } else {
                require(tpX6 <= baseX6, "TP_SIDE");
            }
        }
        // SL facultatif (0 = pas de SL) ; doit être entre base et liq selon sens
        if (slX6 != 0) {
            if (longSide) {
                // liq ≤ SL ≤ base (liq < base)
                require(slX6 >= liqX6 && slX6 <= baseX6, "SL_RANGE");
            } else {
                // base ≤ SL ≤ liq (liq > base)
                require(slX6 >= baseX6 && slX6 <= liqX6, "SL_RANGE");
            }
        }
    }

    // Helper pour émettre l'event (réduit la pression de stack, aucune logique modifiée)
    function _emitOpened(
        uint32 id,
        uint8  state,
        uint32 assetId,
        address trader
    ) internal {
        Trade storage t = trades[id];
        bool longSide_ = (t.flags & uint8(1)) == 1;
        int64 entryOrTargetX6_ = (state == STATE_OPEN) ? t.entryX6 : t.targetX6;

        emit Opened(
            id,
            state,
            assetId,
            longSide_,
            t.lots,
            entryOrTargetX6_,
            t.slX6,
            t.tpX6,
            t.liqX6,
            trader,
            t.leverageX
        );
    }

    // ─────────────────── Exposition: views & helpers ───────────────────

    function longLots(uint32 assetId) external view returns (uint128) {
        return exposureAgg[assetId].longAgg.totalLots;
    }
    function shortLots(uint32 assetId) external view returns (uint128) {
        return exposureAgg[assetId].shortAgg.totalLots;
    }
    function avgEntryLongX6(uint32 assetId) external view returns (int64) {
        SideAgg storage s = exposureAgg[assetId].longAgg;
        if (s.totalLots == 0) return 0;
        int256 avg = s.sumEntryX6TimesLots / int256(uint256(s.totalLots));
        if (avg <= 0 || avg > int256(uint256(type(uint64).max))) return 0;
        return int64(uint64(uint256(avg)));
    }
    function avgEntryShortX6(uint32 assetId) external view returns (int64) {
        SideAgg storage s = exposureAgg[assetId].shortAgg;
        if (s.totalLots == 0) return 0;
        int256 avg = s.sumEntryX6TimesLots / int256(uint256(s.totalLots));
        if (avg <= 0 || avg > int256(uint256(type(uint64).max))) return 0;
        return int64(uint64(uint256(avg)));
    }

    // applique un delta sur une side (clamp à 0 et reset de la somme si plus de lots)
    function _applySideDelta(
        SideAgg storage a,
        int128 dLots,
        int256 dSumEntryX6TimesLots
    ) internal {
        if (dLots != 0) {
            if (dLots > 0) {
                a.totalLots += uint128(uint256(int256(dLots)));
            } else {
                uint128 sub = uint128(uint256(int256(-dLots)));
                a.totalLots = (a.totalLots >= sub) ? a.totalLots - sub : 0;
            }
        }
        if (dSumEntryX6TimesLots != 0) {
            a.sumEntryX6TimesLots += dSumEntryX6TimesLots;
        }
        if (a.totalLots == 0) {
            a.sumEntryX6TimesLots = 0; // nettoyage quand plus aucun lot
        }
    }

    function _applyAggDelta(
        uint32 assetId,
        bool   longSide,
        int128 dLots,
        int256 dSumEntryX6TimesLots
    ) internal {
        AssetAgg storage A = exposureAgg[assetId];
        _applySideDelta(longSide ? A.longAgg : A.shortAgg, dLots, dSumEntryX6TimesLots);
    }

    // pratique pour commit une fois par batch (long & short d’un asset)
    function _applyAggDeltaPair(
        uint32 assetId,
        int128 dLotsLong,  int256 dSumLong,
        int128 dLotsShort, int256 dSumShort
    ) internal {
        AssetAgg storage A = exposureAgg[assetId];
        if (dLotsLong  != 0 || dSumLong  != 0) _applySideDelta(A.longAgg,  dLotsLong,  dSumLong);
        if (dLotsShort != 0 || dSumShort != 0) _applySideDelta(A.shortAgg, dLotsShort, dSumShort);
    }

    // ───────────────── open (MARKET/LIMIT) ─────────────────

    function open(
        uint32 assetId,
        bool   longSide,
        uint16 leverageX,  // 1..100
        uint16 lots,       // entier (ex: 1 => 0.01 BTC si den=100)
        bool   isLimit,
        int64  priceX6,    // LIMIT: target x1e6 ; MARKET: ignoré (0)
        int64  slX6,       // 0 si absent
        int64  tpX6        // 0 si absent
    ) external returns (uint32 id) {
        if (isLimit) {
            id = _openLimit(assetId, longSide, leverageX, lots, priceX6, slX6, tpX6);
        } else {
            id = _openMarket(assetId, longSide, leverageX, lots, slX6, tpX6);
        }
    }

    function _openLimit(
        uint32 assetId,
        bool   longSide,
        uint16 leverageX,
        uint16 lots,
        int64  targetX6,
        int64  slX6,
        int64  tpX6
    ) internal returns (uint32 id) {
        require(targetX6 > 0, "BAD_LIMIT_PRICE");

        uint256 qty1e18 = _qty1e18(assetId, lots);
        require(qty1e18 > 0, "QTY_0");

        uint64 notionalUsd6 = _notionalUsd6(qty1e18, targetX6);
        uint64 marginUsd6   = _marginUsd6(notionalUsd6, leverageX);

        require(vault.available(msg.sender) >= marginUsd6, "NO_MONEY");
        vault.lock(msg.sender, marginUsd6);

        // Liquidation FIXÉE À L’OUVERTURE sur la target
        int64 liqX6 = _liqPriceX6(targetX6, leverageX, longSide);

        // Valider SL/TP par rapport à la target et à liq
        _validateStops(longSide, targetX6, liqX6, slX6, tpX6);

        id = nextId++;
        uint8 flags = (longSide ? uint8(1) : uint8(0));
        flags = _setState(flags, STATE_ORDER);

        trades[id] = Trade({
            owner: msg.sender,
            asset: assetId,
            lots:  lots,
            flags: flags,
            _pad0: 0,
            entryX6:  0,
            targetX6: targetX6,
            slX6:     slX6,
            tpX6:     tpX6,
            liqX6:    liqX6,      // fixé et NE SERA PAS recalculé
            leverageX: leverageX,
            _pad1: 0,
            marginUsd6: marginUsd6
        });

        _emitOpened(id, STATE_ORDER, assetId, msg.sender);
    }

    function _openMarket(
        uint32 assetId,
        bool   longSide,
        uint16 leverageX,
        uint16 lots,
        int64  slX6,
        int64  tpX6
    ) internal returns (uint32 id) {
        require(calculator.isMarketOpen(assetId), "MARKET_CLOSED");

        int64 entryX6 = _priceX6FromOracle(assetId);
        uint256 qty1e18 = _qty1e18(assetId, lots);
        require(qty1e18 > 0, "QTY_0");

        uint64 notionalUsd6 = _notionalUsd6(qty1e18, entryX6);
        uint64 marginUsd6   = _marginUsd6(notionalUsd6, leverageX);

        require(vault.available(msg.sender) >= marginUsd6, "NO_MONEY");
        vault.lock(msg.sender, marginUsd6);

        // Liquidation FIXÉE À L’OUVERTURE sur l’entry
        int64 liqX6 = _liqPriceX6(entryX6, leverageX, longSide);

        // Valider SL/TP par rapport à l’entry et à liq
        _validateStops(longSide, entryX6, liqX6, slX6, tpX6);

        id = nextId++;
        uint8 flags = (longSide ? uint8(1) : uint8(0));
        flags = _setState(flags, STATE_OPEN);

        trades[id] = Trade({
            owner: msg.sender,
            asset: assetId,
            lots:  lots,
            flags: flags,
            _pad0: 0,
            entryX6:  entryX6,
            targetX6: 0,
            slX6:     slX6,
            tpX6:     tpX6,
            liqX6:    liqX6,      // fixé à l’ouverture
            leverageX: leverageX,
            _pad1: 0,
            marginUsd6: marginUsd6
        });

        // ── Expo: commit direct (unitaire)
        {
            int128 lots_i = int128(int256(uint256(lots)));
            int256 sum_i  = int256(int64(entryX6)) * int256(lots_i); // 1e6 * lots
            _applyAggDelta(assetId, longSide, lots_i, sum_i);
        }

        _emitOpened(id, STATE_OPEN, assetId, msg.sender);
    }

    // ───────────────── cancel ORDER ─────────────────

    function cancel(uint32 id) external {
        Trade storage t = trades[id];
        require(t.owner == msg.sender, "NOT_OWNER");
        require(_getState(t.flags) == STATE_ORDER, "NOT_ORDER");

        vault.unlock(t.owner, t.marginUsd6);
        t.flags = _setState(t.flags, STATE_CANCELLED);
        emit Removed(id, RM_CANCELLED, 0, 0);
    }

    // ───────────────── execute LIMIT -> OPEN (± tolérance) ─────────────────

    function executeLimit(uint32 id) external {
        Trade storage t = trades[id];
        require(_getState(t.flags) == STATE_ORDER, "NOT_ORDER");

        int64 px = _priceX6FromOracle(t.asset);
        require(_withinTol(t.targetX6, px, TOL_BPS), "PRICE_NOT_NEAR");

        t.entryX6 = px;
        // ⚠️ NE PAS recalculer t.liqX6 : il est FIXÉ à l’ouverture LIMIT
        t.flags   = _setState(t.flags, STATE_OPEN);

        emit Executed(id, px);
    }

    // ───────────────── close OPEN (SL/TP/LIQ) (± tolérance) ─────────────────

    /// @param reason 1=SL, 2=TP, 3=LIQ
    function close(uint32 id, uint8 reason) external {
        require(reason == REASON_SL || reason == REASON_TP || reason == REASON_LIQ, "BAD_REASON");
        Trade storage t = trades[id];
        require(_getState(t.flags) == STATE_OPEN, "NOT_OPEN");

        int64 triggerX6;
        uint8 rm;
        if (reason == REASON_SL) { triggerX6 = t.slX6; require(triggerX6 != 0, "NO_SL"); rm = RM_SL; }
        else if (reason == REASON_TP) { triggerX6 = t.tpX6; require(triggerX6 != 0, "NO_TP"); rm = RM_TP; }
        else { triggerX6 = t.liqX6; require(triggerX6 != 0, "NO_LIQ"); rm = RM_LIQ; }

        int64 px = _priceX6FromOracle(t.asset);
        require(_withinTol(triggerX6, px, TOL_BPS), "PRICE_NOT_NEAR");

        uint256 qty1e18 = _qty1e18(t.asset, t.lots);
        int256 pnlUsd6  = _pnlUsd6(t.entryX6, px, (t.flags & 0x01) != 0, qty1e18);

        vault.unlock(t.owner, t.marginUsd6);
        vault.settle(t.owner, pnlUsd6);

        t.flags = _setState(t.flags, STATE_CLOSED);
        emit Removed(id, rm, px, pnlUsd6);
    }

    /// @notice Ferme la position au prix oracle courant (pas de tolérance), reason=MARKET
    function closeMarket(uint32 id) external {
        Trade storage t = trades[id];
        require(t.owner == msg.sender, "NOT_OWNER");
        require(_getState(t.flags) == STATE_OPEN, "NOT_OPEN");

        int64 px = _priceX6FromOracle(t.asset);

        uint256 qty1e18 = _qty1e18(t.asset, t.lots);
        int256 pnlUsd6  = _pnlUsd6(t.entryX6, px, (t.flags & 0x01) != 0, qty1e18);

        vault.unlock(t.owner, t.marginUsd6);
        vault.settle(t.owner, pnlUsd6);

        // ── Expo: retrait direct (unitaire)
        {
            bool   longSide_ = (t.flags & 0x01) != 0;
            int128 lots_i    = int128(int256(uint256(t.lots)));
            int256 sum_i     = int256(int64(t.entryX6)) * int256(lots_i);
            _applyAggDelta(t.asset, longSide_, -lots_i, -sum_i);
        }

        t.flags = _setState(t.flags, STATE_CLOSED);
        emit Removed(id, RM_MARKET, px, pnlUsd6);
    }

    // ───────────────── update stops (avec validations) ─────────────────

    function updateStops(uint32 id, int64 newSLx6, int64 newTPx6) external {
        Trade storage t = trades[id];
        require(t.owner == msg.sender, "NOT_OWNER");
        uint8 st = _getState(t.flags);
        require(st == STATE_ORDER || st == STATE_OPEN, "IMMUTABLE");

        bool longSide = (t.flags & 0x01) != 0;
        int64 baseX6  = (st == STATE_OPEN) ? t.entryX6 : t.targetX6;

        // Valider vis-à-vis du baseX6 et de la liquidation (fixée)
        _validateStops(longSide, baseX6, t.liqX6, newSLx6, newTPx6);

        t.slX6 = newSLx6;
        t.tpX6 = newTPx6;
        emit StopsUpdated(id, newSLx6, newTPx6);
    }

    // ───────────────── views ─────────────────

    function stateOf(uint32 id) external view returns (uint8) {
        return _getState(trades[id].flags);
    }

    function isLong(uint32 id) external view returns (bool) {
        return (trades[id].flags & 0x01) != 0;
    }

    // ───────────────── batch utils (sans events de “skip”) ─────────────────

    /// @notice Exécute en lot des LIMIT pour un même actif (lecture oracle unique).
    function execLimits(uint32 assetId, uint32[] calldata ids)
        external
        returns (uint32 executed, uint32 skipped)
    {
        int64 px = _priceX6FromOracle(assetId);

        // ── Accumulateurs expo (commit 1x en fin)
        int128 dLotsLong  = 0;  int256 dSumLong  = 0;
        int128 dLotsShort = 0;  int256 dSumShort = 0;

        for (uint256 i = 0; i < ids.length; ) {
            Trade storage t = trades[ids[i]];
            if (
                t.owner != address(0) &&
                t.asset == assetId &&
                _getState(t.flags) == STATE_ORDER &&
                _withinTol(t.targetX6, px, TOL_BPS)
            ) {
                t.entryX6 = px;
                // ⚠️ NE PAS recalculer liqX6
                t.flags   = _setState(t.flags, STATE_OPEN);

                // Accumuler expo (lots et sum(entry*lots))
                bool   longSide_ = (t.flags & 0x01) != 0;
                int128 lots_i    = int128(int256(uint256(t.lots)));
                int256 sum_i     = int256(int64(px)) * int256(lots_i);
                if (longSide_) { dLotsLong  += lots_i; dSumLong  += sum_i; }
                else           { dLotsShort += lots_i; dSumShort += sum_i; }

                emit Executed(ids[i], px);
                unchecked { ++executed; }
            } else {
                unchecked { ++skipped; }
            }
            unchecked { ++i; }
        }

        // Commit unique
        _applyAggDeltaPair(assetId, dLotsLong, dSumLong, dLotsShort, dSumShort);
    }

    /// @notice Ferme en lot des positions d'un même actif pour un type donné (1=SL, 2=TP, 3=LIQ).
    /// @dev Tolérance fixe: TOL_BPS (non modifiable via l'ABI).
    function closeBatch(
        uint32 assetId,
        uint8  reason,          // 1=SL, 2=TP, 3=LIQ
        uint32[] calldata ids
    )
        external
        returns (uint32 closed, uint32 skipped)
    {
        require(reason == REASON_SL || reason == REASON_TP || reason == REASON_LIQ, "BAD_REASON");

        int64 px = _priceX6FromOracle(assetId);
        uint16 tol = TOL_BPS; // tolérance verrouillée

        // ── Accumulateurs expo (commit 1x en fin)
        int128 dLotsLong  = 0;  int256 dSumLong  = 0;
        int128 dLotsShort = 0;  int256 dSumShort = 0;

        for (uint256 i = 0; i < ids.length; ) {
            Trade storage t = trades[ids[i]];
            if (t.owner == address(0) || t.asset != assetId || _getState(t.flags) != STATE_OPEN) {
                unchecked { ++skipped; ++i; }
                continue;
            }

            int64 triggerX6;
            uint8 rm;
            if (reason == REASON_SL) { triggerX6 = t.slX6; rm = RM_SL; }
            else if (reason == REASON_TP) { triggerX6 = t.tpX6; rm = RM_TP; }
            else { triggerX6 = t.liqX6; rm = RM_LIQ; }

            if (triggerX6 == 0 || !_withinTol(triggerX6, px, tol)) {
                unchecked { ++skipped; ++i; }
                continue;
            }

            uint256 qty1e18 = _qty1e18(t.asset, t.lots);
            int256 pnlUsd6  = _pnlUsd6(t.entryX6, px, (t.flags & 0x01) != 0, qty1e18);

            vault.unlock(t.owner, t.marginUsd6);
            vault.settle(t.owner, pnlUsd6);

            // Accumuler expo à retirer
            bool   longSide_ = (t.flags & 0x01) != 0;
            int128 lots_i    = int128(int256(uint256(t.lots)));
            int256 sum_i     = int256(int64(t.entryX6)) * int256(lots_i);
            if (longSide_) { dLotsLong  -= lots_i; dSumLong  -= sum_i; }
            else           { dLotsShort -= lots_i; dSumShort -= sum_i; }

            t.flags = _setState(t.flags, STATE_CLOSED);
            emit Removed(ids[i], rm, px, pnlUsd6);

            unchecked { ++closed; ++i; }
        }

        // Commit unique
        _applyAggDeltaPair(assetId, dLotsLong, dSumLong, dLotsShort, dSumShort);
    }
}

