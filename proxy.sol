// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* ────────────────────────── Interfaces ────────────────────────── */

interface ICalculator {
    function getLot(uint32 assetId) external view returns (uint256 num, uint256 den);
    function isMarketOpen(uint32 assetId) external view returns (bool);
}

/**
 * Supra Pull V2 (preuve)
 * NOTE: verifyOracleProofV2 n’est PAS view (comportement normal côté Supra).
 */
interface ISupraOraclePull {
    struct PriceInfo {
        uint256[] pairs;
        uint256[] prices;
        uint256[] timestamp; // parfois en millisecondes
        uint256[] decimal;
        uint256[] round;
    }
    function verifyOracleProofV2(bytes calldata _bytesProof) external returns (PriceInfo memory);
}

interface IVault {
    function available(address user) external view returns (uint256);
    function lock(address user, uint256 amount) external;
    function unlock(address user, uint256 amount) external;
    function settle(address user, int256 pnl) external;
}

/* ────────────────────────── Contract ────────────────────────── */

contract Trades {
    uint256 private constant WAD = 1e18;
    uint256 private constant LIQ_LOSS_OF_MARGIN_WAD = 8e17; // 0.8
    uint16  private constant TOL_BPS = 5;                   // 0.05 %
    uint256 private constant PROOF_MAX_AGE = 60;            // fraîcheur max (s)

    ICalculator     public immutable calculator;
    ISupraOraclePull public immutable supraPull;
    IVault          public immutable vault;

    uint32 public nextId = 1;

    // States
    uint8 private constant STATE_ORDER     = 0;
    uint8 private constant STATE_OPEN      = 1;
    uint8 private constant STATE_CLOSED    = 2;
    uint8 private constant STATE_CANCELLED = 3;

    // Removed reasons (event)
    uint8 private constant RM_CANCELLED = 0;
    uint8 private constant RM_MARKET    = 1;
    uint8 private constant RM_SL        = 2;
    uint8 private constant RM_TP        = 3;
    uint8 private constant RM_LIQ       = 4;

    // Close args
    uint8 private constant REASON_MARKET = 0;
    uint8 private constant REASON_SL     = 1;
    uint8 private constant REASON_TP     = 2;
    uint8 private constant REASON_LIQ    = 3;

    struct Trade {
        // slot 0
        address owner;       // 20B
        uint32  asset;       // 4B
        uint16  lots;        // 2B
        uint8   flags;       // bit0=long ; bits4..7=state
        uint8   _pad0;       // 1B
        // slot 1 (prix x1e6)
        int64   entryX6;     // 0 si ORDER
        int64   targetX6;    // 0 si MARKET
        int64   slX6;        // 0 si absent
        int64   tpX6;        // 0 si absent
        // slot 2
        int64   liqX6;       // fixé à l’ouverture
        uint16  leverageX;   // 1..100
        uint16  _pad1;
        uint64  marginUsd6;  // stablecoin 1e6
    }

    mapping(uint32 => Trade) public trades;

    /* ───────────────── Events ───────────────── */

    event Opened(
        uint32 indexed id,
        uint8  state,            // 0=ORDER, 1=OPEN
        uint32 indexed asset,
        bool   longSide,
        uint16 lots,
        int64  entryOrTargetX6,  // entry si OPEN, target si ORDER
        int64  slX6,
        int64  tpX6,
        int64  liqX6,
        address indexed trader,
        uint16 leverageX
    );
    event Executed(uint32 indexed id, int64 entryX6);
    event StopsUpdated(uint32 indexed id, int64 slX6, int64 tpX6);
    event Removed(uint32 indexed id, uint8 reason, int64 execX6, int256 pnlUsd6);

    constructor(address _calc, address _vault, address _supraPull) {
        require(_calc != address(0) && _vault != address(0) && _supraPull != address(0), "ADDR_0");
        calculator = ICalculator(_calc);
        supraPull  = ISupraOraclePull(_supraPull);
        vault      = IVault(_vault);
    }

    /* ───────────────── Price via PROOF only ───────────────── */

    function _priceX6FromProof(bytes calldata proof, uint32 assetId, uint256 maxAgeSec)
        internal
        returns (int64 pxX6)
    {
        ISupraOraclePull.PriceInfo memory info = supraPull.verifyOracleProofV2(proof);

        // find pair == assetId
        uint256 idx = type(uint256).max;
        for (uint256 i = 0; i < info.pairs.length; ++i) {
            if (info.pairs[i] == uint256(assetId)) { idx = i; break; }
        }
        require(idx != type(uint256).max, "PROOF_NO_ASSET");

        uint256 raw = info.prices[idx];
        uint256 dec = info.decimal[idx];
        uint256 t   = info.timestamp[idx];

        // ms -> s if needed
        uint256 ts = (t > 1e12) ? (t / 1000) : t;
        require(ts <= block.timestamp + 180, "PROOF_BAD_TS");
        require(block.timestamp >= ts && (block.timestamp - ts) <= maxAgeSec, "PROOF_TOO_OLD");
        require(raw > 0, "PROOF_PRICE_0");

        uint256 p6 = (dec == 6) ? raw : (dec > 6 ? raw / (10 ** (dec - 6)) : raw * (10 ** (6 - dec)));
        require(p6 > 0 && p6 <= type(uint64).max, "PROOF_PX6_RANGE");

        return int64(uint64(p6));
    }

    /* ───────────────── Math & flags ───────────────── */

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

    function _validateStops(
        bool longSide,
        int64 baseX6,
        int64 liqX6,
        int64 slX6,
        int64 tpX6
    ) internal pure {
        if (tpX6 != 0) {
            if (longSide) { require(tpX6 >= baseX6, "TP_SIDE"); }
            else { require(tpX6 <= baseX6, "TP_SIDE"); }
        }
        if (slX6 != 0) {
            if (longSide) { require(slX6 >= liqX6 && slX6 <= baseX6, "SL_RANGE"); }
            else { require(slX6 >= baseX6 && slX6 <= liqX6, "SL_RANGE"); }
        }
    }

    function _emitOpened(uint32 id, uint8 state, uint32 assetId, address trader) internal {
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

    /* ───────────────── OPEN (both use PROOF) ───────────────── */

    /// @notice Ouvre un LIMIT (target déjà x1e6) — ne lit PAS l’oracle.
    function openLimit(
        uint32 assetId,
        bool   longSide,
        uint16 leverageX,
        uint16 lots,
        int64  targetX6,
        int64  slX6,
        int64  tpX6
    ) external returns (uint32 id) {
        require(targetX6 > 0, "BAD_LIMIT_PRICE");

        uint256 qty1e18 = _qty1e18(assetId, lots);
        require(qty1e18 > 0, "QTY_0");

        uint64 notionalUsd6 = _notionalUsd6(qty1e18, targetX6);
        uint64 marginUsd6   = _marginUsd6(notionalUsd6, leverageX);

        require(vault.available(msg.sender) >= marginUsd6, "NO_MONEY");
        vault.lock(msg.sender, marginUsd6);

        int64 liqX6 = _liqPriceX6(targetX6, leverageX, longSide);
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
            liqX6:    liqX6,
            leverageX: leverageX,
            _pad1: 0,
            marginUsd6: marginUsd6
        });

        _emitOpened(id, STATE_ORDER, assetId, msg.sender);
    }

    /// @notice Ouvre un MARKET en utilisant le prix extrait de la PREUVE.
    function openMarket(
        bytes calldata proof,
        uint32 assetId,
        bool   longSide,
        uint16 leverageX,
        uint16 lots,
        int64  slX6,
        int64  tpX6
    ) external returns (uint32 id) {
        require(calculator.isMarketOpen(assetId), "MARKET_CLOSED");

        int64 entryX6 = _priceX6FromProof(proof, assetId, PROOF_MAX_AGE);

        uint256 qty1e18 = _qty1e18(assetId, lots);
        require(qty1e18 > 0, "QTY_0");

        uint64 notionalUsd6 = _notionalUsd6(qty1e18, entryX6);
        uint64 marginUsd6   = _marginUsd6(notionalUsd6, leverageX);

        require(vault.available(msg.sender) >= marginUsd6, "NO_MONEY");
        vault.lock(msg.sender, marginUsd6);

        int64 liqX6 = _liqPriceX6(entryX6, leverageX, longSide);
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
            liqX6:    liqX6,
            leverageX: leverageX,
            _pad1: 0,
            marginUsd6: marginUsd6
        });

        _emitOpened(id, STATE_OPEN, assetId, msg.sender);
    }

    /* ───────────────── cancel / execute (LIMIT exec via PROOF) ───────────────── */

    function cancel(uint32 id) external {
        Trade storage t = trades[id];
        require(t.owner == msg.sender, "NOT_OWNER");
        require(_getState(t.flags) == STATE_ORDER, "NOT_ORDER");

        vault.unlock(t.owner, t.marginUsd6);
        t.flags = _setState(t.flags, STATE_CANCELLED);
        emit Removed(id, RM_CANCELLED, 0, 0);
    }

    /// @notice Exécute un LIMIT -> OPEN avec prix issu de la PREUVE.
    function executeLimit(uint32 id, bytes calldata proof) external {
        Trade storage t = trades[id];
        require(_getState(t.flags) == STATE_ORDER, "NOT_ORDER");

        int64 px = _priceX6FromProof(proof, t.asset, PROOF_MAX_AGE);
        require(_withinTol(t.targetX6, px, TOL_BPS), "PRICE_NOT_NEAR");

        t.entryX6 = px;
        t.flags   = _setState(t.flags, STATE_OPEN);

        emit Executed(id, px);
    }

    /* ───────────────── close (all use PROOF) ───────────────── */

    /// @param reason 1=SL, 2=TP, 3=LIQ  (0=MARKET non utilisé ici)
    function close(uint32 id, uint8 reason, bytes calldata proof) external {
        require(reason == REASON_SL || reason == REASON_TP || reason == REASON_LIQ, "BAD_REASON");
        Trade storage t = trades[id];
        require(_getState(t.flags) == STATE_OPEN, "NOT_OPEN");

        int64 triggerX6;
        uint8 rm;
        if (reason == REASON_SL) { triggerX6 = t.slX6; require(triggerX6 != 0, "NO_SL"); rm = RM_SL; }
        else if (reason == REASON_TP) { triggerX6 = t.tpX6; require(triggerX6 != 0, "NO_TP"); rm = RM_TP; }
        else { triggerX6 = t.liqX6; require(triggerX6 != 0, "NO_LIQ"); rm = RM_LIQ; }

        int64 px = _priceX6FromProof(proof, t.asset, PROOF_MAX_AGE);
        require(_withinTol(triggerX6, px, TOL_BPS), "PRICE_NOT_NEAR");

        uint256 qty1e18 = _qty1e18(t.asset, t.lots);
        int256 pnlUsd6  = _pnlUsd6(t.entryX6, px, (t.flags & 0x01) != 0, qty1e18);

        vault.unlock(t.owner, t.marginUsd6);
        vault.settle(t.owner, pnlUsd6);

        t.flags = _setState(t.flags, STATE_CLOSED);
        emit Removed(id, rm, px, pnlUsd6);
    }

    /// @notice Ferme la position au prix issu de la PREUVE (close market).
    function closeMarket(uint32 id, bytes calldata proof) external {
        Trade storage t = trades[id];
        require(t.owner == msg.sender, "NOT_OWNER");
        require(_getState(t.flags) == STATE_OPEN, "NOT_OPEN");

        int64 px = _priceX6FromProof(proof, t.asset, PROOF_MAX_AGE);

        uint256 qty1e18 = _qty1e18(t.asset, t.lots);
        int256 pnlUsd6  = _pnlUsd6(t.entryX6, px, (t.flags & 0x01) != 0, qty1e18);

        vault.unlock(t.owner, t.marginUsd6);
        vault.settle(t.owner, pnlUsd6);

        t.flags = _setState(t.flags, STATE_CLOSED);
        emit Removed(id, RM_MARKET, px, pnlUsd6);
    }

    /* ───────────────── update stops ───────────────── */

    function updateStops(uint32 id, int64 newSLx6, int64 newTPx6) external {
        Trade storage t = trades[id];
        require(t.owner == msg.sender, "NOT_OWNER");
        uint8 st = _getState(t.flags);
        require(st == STATE_ORDER || st == STATE_OPEN, "IMMUTABLE");

        bool longSide = (t.flags & 0x01) != 0;
        int64 baseX6  = (st == STATE_OPEN) ? t.entryX6 : t.targetX6;

        _validateStops(longSide, baseX6, t.liqX6, newSLx6, newTPx6);

        t.slX6 = newSLx6;
        t.tpX6 = newTPx6;
        emit StopsUpdated(id, newSLx6, newTPx6);
    }

    /// SL only
    function setSL(uint32 id, int64 newSLx6) external {
        Trade storage t = trades[id];
        require(t.owner == msg.sender, "NOT_OWNER");
        uint8 st = _getState(t.flags);
        require(st == STATE_ORDER || st == STATE_OPEN, "IMMUTABLE");
        bool longSide = (t.flags & 0x01) != 0;
        int64 baseX6  = (st == STATE_OPEN) ? t.entryX6 : t.targetX6;
        _validateStops(longSide, baseX6, t.liqX6, newSLx6, t.tpX6);
        t.slX6 = newSLx6;
        emit StopsUpdated(id, t.slX6, t.tpX6);
    }

    /// TP only
    function setTP(uint32 id, int64 newTPx6) external {
        Trade storage t = trades[id];
        require(t.owner == msg.sender, "NOT_OWNER");
        uint8 st = _getState(t.flags);
        require(st == STATE_ORDER || st == STATE_OPEN, "IMMUTABLE");
        bool longSide = (t.flags & 0x01) != 0;
        int64 baseX6  = (st == STATE_OPEN) ? t.entryX6 : t.targetX6;
        _validateStops(longSide, baseX6, t.liqX6, t.slX6, newTPx6);
        t.tpX6 = newTPx6;
        emit StopsUpdated(id, t.slX6, t.tpX6);
    }

    /* ───────────────── views ───────────────── */

    function stateOf(uint32 id) external view returns (uint8) {
        return _getState(trades[id].flags);
    }

    function isLong(uint32 id) external view returns (bool) {
        return (trades[id].flags & 0x01) != 0;
    }

    function getTrade(uint32 id) external view returns (Trade memory) {
        return trades[id];
    }

    /* ───────────────── batch utils (proof) ───────────────── */

    /// @notice Exécute en lot des LIMIT pour un actif avec un prix PROOF (≤ 60s).
    function execLimits(uint32 assetId, uint32[] calldata ids, bytes calldata proof)
        external
        returns (uint32 executed, uint32 skipped)
    {
        int64 px = _priceX6FromProof(proof, assetId, PROOF_MAX_AGE);

        for (uint256 i = 0; i < ids.length; ) {
            Trade storage t = trades[ids[i]];
            if (
                t.owner != address(0) &&
                t.asset == assetId &&
                _getState(t.flags) == STATE_ORDER &&
                _withinTol(t.targetX6, px, TOL_BPS)
            ) {
                t.entryX6 = px;
                t.flags   = _setState(t.flags, STATE_OPEN);
                emit Executed(ids[i], px);
                unchecked { ++executed; }
            } else {
                unchecked { ++skipped; }
            }
            unchecked { ++i; }
        }
    }

    /// @notice Ferme en lot (1=SL,2=TP,3=LIQ) avec prix PROOF (≤ 60s).
    function closeBatch(
        uint32 assetId,
        uint8  reason,
        uint32[] calldata ids,
        bytes  calldata proof
    )
        external
        returns (uint32 closed, uint32 skipped)
    {
        require(reason == REASON_SL || reason == REASON_TP || reason == REASON_LIQ, "BAD_REASON");

        int64 px = _priceX6FromProof(proof, assetId, PROOF_MAX_AGE);
        uint16 tol = TOL_BPS;

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

            t.flags = _setState(t.flags, STATE_CLOSED);
            emit Removed(ids[i], rm, px, pnlUsd6);

            unchecked { ++closed; ++i; }
        }
    }
}
