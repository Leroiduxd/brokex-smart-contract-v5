// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* ────────────────────────── Interfaces ────────────────────────── */

interface ICalculator {
    function getLot(
        uint32 assetId
    ) external view returns (uint256 num, uint256 den);
    function isMarketOpen(uint32 assetId) external view returns (bool);
    function fee(uint32 assetId) external view returns (uint64);
    function fund(uint32 assetId) external view returns (int64);
    function costs(
        uint32 assetId
    ) external view returns (uint64 feeX6, int64 fundX6);
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
    function verifyOracleProofV2(
        bytes calldata _bytesProof
    ) external returns (PriceInfo memory);
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
    uint16 private constant TOL_BPS = 5; // 0.05 %
    uint256 private constant PROOF_MAX_AGE = 60; // fraîcheur max (s)

    ICalculator public immutable calculator;
    ISupraOraclePull public immutable supraPull;
    IVault public immutable vault;

    uint32 public nextId = 1;

    // ───────────── Admin & Relayer ─────────────
    address public owner;
    address public relayer;

    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }

    modifier onlyRelayer() {
        require(msg.sender == relayer, "NOT_RELAYER");
        _;
    }

    // States
    uint8 private constant STATE_ORDER = 0;
    uint8 private constant STATE_OPEN = 1;
    uint8 private constant STATE_CLOSED = 2;
    uint8 private constant STATE_CANCELLED = 3;

    // Removed reasons (event)
    uint8 private constant RM_CANCELLED = 0;
    uint8 private constant RM_MARKET = 1;
    uint8 private constant RM_SL = 2;
    uint8 private constant RM_TP = 3;
    uint8 private constant RM_LIQ = 4;

    // Close args
    uint8 private constant REASON_MARKET = 0;
    uint8 private constant REASON_SL = 1;
    uint8 private constant REASON_TP = 2;
    uint8 private constant REASON_LIQ = 3;

    struct Trade {
        // slot 0
        address owner; // 20B
        uint32 asset; // 4B
        uint16 lots; // 2B
        uint8 flags; // bit0=long ; bits4..7=state
        uint8 _pad0; // 1B
        // slot 1 (prix x1e6)
        int64 entryX6; // 0 si ORDER
        int64 targetX6; // 0 si MARKET
        int64 slX6; // 0 si absent
        int64 tpX6; // 0 si absent
        // slot 2
        int64 liqX6; // fixé à l’ouverture
        uint16 leverageX; // 1..100
        uint64 openedAt; // timestamp d'ouverture de la position
        uint64 marginUsd6; // stablecoin 1e6
    }

    // ───────────── Structs pour éviter Stack Too Deep ─────────────
    
    // Pour les ordres LIMIT
    struct LimitParams {
        address trader;
        uint32 assetId;
        bool longSide;
        uint16 leverageX;
        uint16 lots;
        int64 targetX6;
        int64 slX6;
        int64 tpX6;
    }

    // 🆕 Pour les ordres MARKET
    struct MarketParams {
        address trader;
        uint32 assetId;
        bool longSide;
        uint16 leverageX;
        uint16 lots;
        int64 entryX6;
        int64 slX6;
        int64 tpX6;
    }

    mapping(uint32 => Trade) public trades;

    // ───────────── Exposure (en lots) par asset ─────────────
    mapping(uint32 => uint256) public longLots;   // somme des lots en long
    mapping(uint32 => uint256) public shortLots;  // somme des lots en short

    /* ───────────────── Events ───────────────── */

    event Opened(
        uint32 indexed id,
        uint8 state, // 0=ORDER, 1=OPEN
        uint32 indexed asset,
        bool longSide,
        uint16 lots,
        int64 entryOrTargetX6, // entry si OPEN, target si ORDER
        int64 slX6,
        int64 tpX6,
        int64 liqX6,
        address indexed trader,
        uint16 leverageX
    );
    event Executed(uint32 indexed id, int64 entryX6);
    event StopsUpdated(uint32 indexed id, int64 slX6, int64 tpX6);
    event Removed(
        uint32 indexed id,
        uint8 reason,
        int64 execX6,
        int256 pnlUsd6
    );

    constructor(address _calc, address _vault, address _supraPull) {
        require(
            _calc != address(0) &&
                _vault != address(0) &&
                _supraPull != address(0),
            "ADDR_0"
        );
        calculator = ICalculator(_calc);
        supraPull = ISupraOraclePull(_supraPull);
        vault = IVault(_vault);

        owner = msg.sender;
    }

    /// @notice Définit l'adresse du relayer qui peut ouvrir des LIMIT/MARKET pour le compte des traders.
    function setRelayer(address _relayer) external onlyOwner {
        require(_relayer != address(0), "RELAYER_0");
        relayer = _relayer;
    }

    /* ───────────────── Price via PROOF only ───────────────── */

    function _priceX6FromProof(
        bytes calldata proof,
        uint32 assetId,
        uint256 maxAgeSec
    ) internal returns (int64 pxX6) {
        ISupraOraclePull.PriceInfo memory info = supraPull.verifyOracleProofV2(
            proof
        );

        // find pair == assetId
        uint256 idx = type(uint256).max;
        for (uint256 i = 0; i < info.pairs.length; ++i) {
            if (info.pairs[i] == uint256(assetId)) {
                idx = i;
                break;
            }
        }
        require(idx != type(uint256).max, "PROOF_NO_ASSET");

        uint256 raw = info.prices[idx];
        uint256 dec = info.decimal[idx];
        uint256 t = info.timestamp[idx];

        // ms -> s if needed
        uint256 ts = (t > 1e12) ? (t / 1000) : t;
        require(ts <= block.timestamp + 180, "PROOF_BAD_TS");
        require(
            block.timestamp >= ts && (block.timestamp - ts) <= maxAgeSec,
            "PROOF_TOO_OLD"
        );
        require(raw > 0, "PROOF_PRICE_0");

        uint256 p6 = (dec == 6)
            ? raw
            : (dec > 6 ? raw / (10 ** (dec - 6)) : raw * (10 ** (6 - dec)));
        require(p6 > 0 && p6 <= type(uint64).max, "PROOF_PX6_RANGE");

        return int64(uint64(p6));
    }

    /* ───────────────── Math & flags ───────────────── */

    function _qty1e18(
        uint32 assetId,
        uint16 lots
    ) internal view returns (uint256) {
        (uint256 num, uint256 den) = calculator.getLot(assetId);
        return (lots == 0) ? 0 : (uint256(lots) * WAD * num) / den;
    }

    function _notionalUsd6(
        uint256 qty1e18,
        int64 priceX6
    ) internal pure returns (uint64) {
        uint256 n6 = (qty1e18 * uint256(uint64(priceX6))) / WAD;
        require(n6 <= type(uint64).max, "NOTIONAL_64");
        return uint64(n6);
    }

    function _marginUsd6(
        uint64 notionalUsd6,
        uint16 lev
    ) internal pure returns (uint64) {
        uint256 m = (uint256(notionalUsd6) + lev - 1) / lev;
        require(m <= type(uint64).max, "MARGIN_64");
        return uint64(m);
    }

    function _liqPriceX6(
        int64 entryX6,
        uint16 lev,
        bool longSide
    ) internal pure returns (int64) {
        require(entryX6 > 0 && lev > 0, "BAD_LIQ_ARGS");
        uint256 entry1e6 = uint256(uint64(entryX6));
        uint256 liq1e6 = longSide
            ? (entry1e6 * (1e18 - (LIQ_LOSS_OF_MARGIN_WAD / lev))) / 1e18
            : (entry1e6 * (1e18 + (LIQ_LOSS_OF_MARGIN_WAD / lev))) / 1e18;
        require(liq1e6 <= type(uint64).max, "LIQ_RANGE");
        return int64(uint64(liq1e6));
    }

    function _setState(
        uint8 flags,
        uint8 newState
    ) internal pure returns (uint8) {
        return (flags & 0x0F) | (newState << 4);
    }

    function _getState(uint8 flags) internal pure returns (uint8) {
        return (flags >> 4) & 0x0F;
    }

    function _withinTol(
        int64 aX6,
        int64 bX6,
        uint16 bps
    ) internal pure returns (bool) {
        uint256 A = uint256(uint64(aX6));
        uint256 B = uint256(uint64(bX6));
        uint256 diff = A > B ? A - B : B - A;
        return diff * 10000 <= A * bps;
    }

    function _pnlUsd6(
        int64 entryX6,
        int64 execX6,
        bool longSide,
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
            if (longSide) {
                require(tpX6 >= baseX6, "TP_SIDE");
            } else {
                require(tpX6 <= baseX6, "TP_SIDE");
            }
        }
        if (slX6 != 0) {
            if (longSide) {
                require(slX6 >= liqX6 && slX6 <= baseX6, "SL_RANGE");
            } else {
                require(slX6 >= baseX6 && slX6 <= liqX6, "SL_RANGE");
            }
        }
    }

    /// @dev Incrémente l'exposition en lots pour un asset donné.
    function _incExposure(
        uint32 assetId,
        bool longSide,
        uint16 lots
    ) internal {
        if (lots == 0) return;
        if (longSide) {
            longLots[assetId] += lots;
        } else {
            shortLots[assetId] += lots;
        }
    }

    /// @dev Décrémente l'exposition en lots pour un asset donné.
    function _decExposure(
        uint32 assetId,
        bool longSide,
        uint16 lots
    ) internal {
        if (lots == 0) return;
        if (longSide) {
            uint256 cur = longLots[assetId];
            require(cur >= lots, "EXPO_LONG_UNDERFLOW");
            longLots[assetId] = cur - lots;
        } else {
            uint256 cur = shortLots[assetId];
            require(cur >= lots, "EXPO_SHORT_UNDERFLOW");
            shortLots[assetId] = cur - lots;
        }
    }

    function _emitOpened(
        uint32 id,
        uint8 state,
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

    /* ───────────────── OPEN (both use PROOF) ───────────────── */

    /// @notice Ouvre un LIMIT (target déjà x1e6) — ne lit PAS l’oracle.
    function openLimit(
        uint32 assetId,
        bool longSide,
        uint16 leverageX,
        uint16 lots,
        int64 targetX6,
        int64 slX6,
        int64 tpX6
    ) external returns (uint32 id) {
        require(targetX6 > 0, "BAD_LIMIT_PRICE");

        uint256 qty1e18 = _qty1e18(assetId, lots);
        require(qty1e18 > 0, "QTY_0");

        uint64 notionalUsd6 = _notionalUsd6(qty1e18, targetX6);
        uint64 marginUsd6 = _marginUsd6(notionalUsd6, leverageX);

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
            lots: lots,
            flags: flags,
            _pad0: 0,
            entryX6: 0,
            targetX6: targetX6,
            slX6: slX6,
            tpX6: tpX6,
            liqX6: liqX6,
            leverageX: leverageX,
            openedAt: 0, // ORDER n'est pas encore exécuté
            marginUsd6: marginUsd6
        });

        _emitOpened(id, STATE_ORDER, assetId, msg.sender);
    }

    /// @dev Logique interne pour le relayer afin de contourner la limite de stack (Stack too deep).
    function _openLimitRelayerCore(LimitParams memory p) internal returns (uint32 id) {
        require(p.targetX6 > 0, "BAD_LIMIT_PRICE");

        uint256 qty1e18 = _qty1e18(p.assetId, p.lots);
        require(qty1e18 > 0, "QTY_0");

        uint64 notionalUsd6 = _notionalUsd6(qty1e18, p.targetX6);
        uint64 marginUsd6 = _marginUsd6(notionalUsd6, p.leverageX);

        // 🔐 On vérifie la marge du trader, pas du relayer
        require(vault.available(p.trader) >= marginUsd6, "NO_MONEY");
        vault.lock(p.trader, marginUsd6);

        int64 liqX6 = _liqPriceX6(p.targetX6, p.leverageX, p.longSide);
        _validateStops(p.longSide, p.targetX6, liqX6, p.slX6, p.tpX6);

        id = nextId++;
        uint8 flags = (p.longSide ? uint8(1) : uint8(0));
        flags = _setState(flags, STATE_ORDER);

        trades[id] = Trade({
            owner: p.trader,
            asset: p.assetId,
            lots: p.lots,
            flags: flags,
            _pad0: 0,
            entryX6: 0,
            targetX6: p.targetX6,
            slX6: p.slX6,
            tpX6: p.tpX6,
            liqX6: liqX6,
            leverageX: p.leverageX,
            openedAt: 0, // ORDER pas encore exécuté
            marginUsd6: marginUsd6
        });

        _emitOpened(id, STATE_ORDER, p.assetId, p.trader);
    }

    /// @notice Ouvre un LIMIT pour le compte de `trader` (meta-tx / relayer).
    function openLimitRelayer(
        address trader,
        uint32 assetId,
        bool longSide,
        uint16 leverageX,
        uint16 lots,
        int64 targetX6,
        int64 slX6,
        int64 tpX6
    ) external onlyRelayer returns (uint32 id) {
        LimitParams memory params = LimitParams({
            trader: trader,
            assetId: assetId,
            longSide: longSide,
            leverageX: leverageX,
            lots: lots,
            targetX6: targetX6,
            slX6: slX6,
            tpX6: tpX6
        });
        return _openLimitRelayerCore(params);
    }

    /// @dev Helper pour ouvrir une position MARKET (utilisé par normal et relayer).
    ///      Emballe les paramètres dans MarketParams pour éviter "Stack too deep".
    function _createMarketTradeCore(MarketParams memory p) internal returns (uint32 id) {
        // 1) Taille et notional
        uint256 qty1e18 = _qty1e18(p.assetId, p.lots);
        require(qty1e18 > 0, "QTY_0");

        uint64 notionalUsd6 = _notionalUsd6(qty1e18, p.entryX6);
        uint64 marginUsd6 = _marginUsd6(notionalUsd6, p.leverageX);

        // 2) Vérifier la marge dispo & locker pour le TRADER
        require(vault.available(p.trader) >= marginUsd6, "NO_MONEY");
        vault.lock(p.trader, marginUsd6);

        // 3) Prix de liquidation + validation SL/TP
        int64 liqX6 = _liqPriceX6(p.entryX6, p.leverageX, p.longSide);
        _validateStops(p.longSide, p.entryX6, liqX6, p.slX6, p.tpX6);

        // 4) Enregistrement de la position
        id = nextId++;
        uint8 flags = (p.longSide ? uint8(1) : uint8(0));
        flags = _setState(flags, STATE_OPEN);

        trades[id] = Trade({
            owner: p.trader,
            asset: p.assetId,
            lots: p.lots,
            flags: flags,
            _pad0: 0,
            entryX6: p.entryX6, // prix oracle ± spread
            targetX6: 0,
            slX6: p.slX6,
            tpX6: p.tpX6,
            liqX6: liqX6,
            leverageX: p.leverageX,
            openedAt: uint64(block.timestamp), // heure d'ouverture
            marginUsd6: marginUsd6
        });

        // Expo
        _incExposure(p.assetId, p.longSide, p.lots);

        _emitOpened(id, STATE_OPEN, p.assetId, p.trader);
    }

    /// @dev Wrapper pour `msg.sender`
    function _createMarketTrade(
        uint32 assetId,
        bool longSide,
        uint16 leverageX,
        uint16 lots,
        int64 entryX6,
        int64 slX6,
        int64 tpX6
    ) internal returns (uint32 id) {
        MarketParams memory params = MarketParams({
            trader: msg.sender,
            assetId: assetId,
            longSide: longSide,
            leverageX: leverageX,
            lots: lots,
            entryX6: entryX6,
            slX6: slX6,
            tpX6: tpX6
        });
        return _createMarketTradeCore(params);
    }

    /// @dev Applique le spread au prix oracle:
    ///      LONG  : oracle + spread
    ///      SHORT : oracle - spread
    function _applySpread(
        int64 oracleX6,
        uint64 feeX6,
        bool longSide
    ) internal pure returns (int64) {
        require(feeX6 <= uint64(type(int64).max), "FEE_RANGE");

        if (longSide) {
            // LONG : payer plus cher -> oracle + spread
            uint256 sum = uint256(uint64(oracleX6)) + uint256(feeX6);
            require(sum <= type(uint64).max, "PX_RANGE");
            return int64(uint64(sum));
        } else {
            // SHORT : oracle - spread
            uint64 midU = uint64(oracleX6);
            require(midU > feeX6, "FEE_GT_PX");
            uint256 diff = uint256(midU) - uint256(feeX6);
            return int64(uint64(diff));
        }
    }

    /// @notice Ouverture MARKET normale (user paye lui-même le gas).
    function openMarket(
        bytes calldata proof,
        uint32 assetId,
        bool longSide,
        uint16 leverageX,
        uint16 lots,
        int64 slX6,
        int64 tpX6
    ) external returns (uint32 id) {
        require(calculator.isMarketOpen(assetId), "MARKET_CLOSED");

        // Prix "mid" depuis l'oracle
        int64 oracleX6 = _priceX6FromProof(proof, assetId, PROOF_MAX_AGE);

        // Spread / fee en x1e6
        uint64 feeX6 = calculator.fee(assetId);

        // Prix d'exécution = oracle ± spread
        int64 entryX6 = _applySpread(oracleX6, feeX6, longSide);

        // Création de la position
        id = _createMarketTrade(
            assetId,
            longSide,
            leverageX,
            lots,
            entryX6,
            slX6,
            tpX6
        );
    }

    /// 🆕 @notice Ouverture MARKET via relayer/paymaster (appelé uniquement par le relayer EIP-712).
    /// Le relayer passe le `trader` + la preuve oracle (non signée).
    function openMarketRelayer(
        address trader,
        bytes calldata proof,
        uint32 assetId,
        bool longSide,
        uint16 leverageX,
        uint16 lots,
        int64 slX6,
        int64 tpX6
    ) external onlyRelayer returns (uint32 id) {
        require(calculator.isMarketOpen(assetId), "MARKET_CLOSED");

        // Prix "mid" depuis l'oracle
        int64 oracleX6 = _priceX6FromProof(proof, assetId, PROOF_MAX_AGE);

        // Spread / fee en x1e6
        uint64 feeX6 = calculator.fee(assetId);

        // Prix d'exécution = oracle ± spread
        int64 entryX6 = _applySpread(oracleX6, feeX6, longSide);

        // Création de la position pour `trader` via la Struct pour éviter Stack Too Deep
        MarketParams memory params = MarketParams({
            trader: trader,
            assetId: assetId,
            longSide: longSide,
            leverageX: leverageX,
            lots: lots,
            entryX6: entryX6,
            slX6: slX6,
            tpX6: tpX6
        });

        id = _createMarketTradeCore(params);
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

    /// @notice Annule un LIMIT ORDER pour le compte de `trader` (meta-tx / relayer).
    function cancelRelayer(address trader, uint32 id) external onlyRelayer {
        Trade storage t = trades[id];
        require(t.owner == trader, "WRONG_TRADER");
        require(_getState(t.flags) == STATE_ORDER, "NOT_ORDER");

        vault.unlock(trader, t.marginUsd6);
        t.flags = _setState(t.flags, STATE_CANCELLED);

        emit Removed(id, RM_CANCELLED, 0, 0);
    }

    /// @notice Exécute un LIMIT -> OPEN avec prix issu de la PREUVE.
    ///         Comparaison sur le prix oracle "mid",
    ///         enregistrement à oracle ± spread.
    function executeLimit(uint32 id, bytes calldata proof) external {
        Trade storage t = trades[id];
        require(_getState(t.flags) == STATE_ORDER, "NOT_ORDER");

        // 1) Prix oracle "mid"
        int64 oracleX6 = _priceX6FromProof(proof, t.asset, PROOF_MAX_AGE);

        // 2) Vérification de la règle d'acceptation sur le mid
        uint256 tgt = uint256(uint64(t.targetX6));
        uint256 upper = (tgt * (10000 + TOL_BPS)) / 10000; // target*(1+tol)
        uint256 lower = (tgt * (10000 - TOL_BPS)) / 10000; // target*(1-tol)

        uint256 midU = uint256(uint64(oracleX6));
        bool longSide = (t.flags & 0x01) != 0;
        if (longSide) {
            require(midU <= upper, "PRICE_NOT_BETTER_LONG");
        } else {
            require(midU >= lower, "PRICE_NOT_BETTER_SHORT");
        }

        // 3) Application du spread pour le prix réel d'exécution
        uint64 feeX6 = calculator.fee(t.asset);
        int64 execX6 = _applySpread(oracleX6, feeX6, longSide);

        // 4) On enregistre le prix exec (avec spread)
        t.entryX6 = execX6;
        t.flags = _setState(t.flags, STATE_OPEN);
        t.openedAt = uint64(block.timestamp);

        // Expo : LIMIT devient une position ouverte
        _incExposure(t.asset, longSide, t.lots);

        emit Executed(id, execX6);
    }

    /* ───────────────── close (all use PROOF) ───────────────── */

    /// @notice Ferme la position par SL / TP / LIQ au prix issu de la PREUVE.
    function close(uint32 id, uint8 reason, bytes calldata proof) external {
        require(
            reason == REASON_SL || reason == REASON_TP || reason == REASON_LIQ,
            "BAD_REASON"
        );
        Trade storage t = trades[id];
        require(_getState(t.flags) == STATE_OPEN, "NOT_OPEN");

        // Prix oracle "mid" via preuve
        int64 oracleX6 = _priceX6FromProof(proof, t.asset, PROOF_MAX_AGE);

        _closeWithReason(t, id, reason, oracleX6);
    }

    /// @dev Calcule le prix de fermeture ajusté funding + spread.
    function _closePxWithFundingAndSpread(
        Trade storage t,
        int64 oracleX6
    ) internal view returns (int64) {
        // 1) Durée écoulée depuis l'ouverture
        uint64 openedAt = t.openedAt;
        uint256 dt = block.timestamp > openedAt
            ? (block.timestamp - openedAt)
            : 0;

        // 45 minutes = 2700 secondes
        uint256 intervals = dt / 2700;

        // 2) Funding par intervalle (peut être négatif)
        int64 fundPerIntervalX6 = calculator.fund(t.asset);
        int256 fundingTotal = int256(fundPerIntervalX6) * int256(intervals);

        // 3) Spread (toujours positif)
        uint64 feeX6 = calculator.fee(t.asset);
        int256 spread = int256(uint256(feeX6));

        // 4) Ajustement total = spread + fundingTotal (peut être + ou -)
        int256 combined = spread + fundingTotal;
        require(
            combined >= int256(type(int64).min) &&
                combined <= int256(type(int64).max),
            "ADJ_RANGE"
        );

        bool longSide = (t.flags & 0x01) != 0;

        // 5) Application de l'ajustement au prix oracle
        int256 pxInt = int256(oracleX6);
        if (longSide) {
            // LONG : on ferme "en short" => oracle - (spread + funding)
            pxInt = pxInt - combined;
        } else {
            // SHORT : on ferme "en long" => oracle + (spread + funding)
            pxInt = pxInt + combined;
        }

        require(
            pxInt > 0 && pxInt <= int256(type(int64).max),
            "CLOSE_PX_RANGE"
        );

        return int64(pxInt);
    }

    /// @notice Ferme la position au prix issu de la PREUVE,
    ///         ajusté par funding + spread (antagoniste).
    function closeMarket(uint32 id, bytes calldata proof) external {
        Trade storage t = trades[id];
        require(t.owner == msg.sender, "NOT_OWNER");
        require(_getState(t.flags) == STATE_OPEN, "NOT_OPEN");

        // 1) Prix oracle "mid" via la preuve
        int64 oracleX6 = _priceX6FromProof(proof, t.asset, PROOF_MAX_AGE);

        // 2) Prix de fermeture ajusté funding + spread
        int64 px = _closePxWithFundingAndSpread(t, oracleX6);

        bool longSide = (t.flags & 0x01) != 0;

        // 3) Finalisation
        _finalizeClose(t, id, px, longSide, RM_MARKET);
    }

    /// 🆕 @notice Fermeture MARKET via relayer/paymaster (EIP-712).
    /// Le relayer passe `trader`, `id` + la preuve oracle (non signée).
    function closeMarketRelayer(
        address trader,
        uint32 id,
        bytes calldata proof
    ) external onlyRelayer {
        Trade storage t = trades[id];
        require(t.owner == trader, "WRONG_TRADER");
        require(_getState(t.flags) == STATE_OPEN, "NOT_OPEN");

        // 1) Prix oracle "mid"
        int64 oracleX6 = _priceX6FromProof(proof, t.asset, PROOF_MAX_AGE);

        // 2) Prix de fermeture ajusté funding + spread
        int64 px = _closePxWithFundingAndSpread(t, oracleX6);

        bool longSide = (t.flags & 0x01) != 0;

        // 3) Finalisation
        _finalizeClose(t, id, px, longSide, RM_MARKET);
    }

    /* ───────────────── update stops ───────────────── */

    function updateStops(uint32 id, int64 newSLx6, int64 newTPx6) external {
        Trade storage t = trades[id];
        require(t.owner == msg.sender, "NOT_OWNER");
        uint8 st = _getState(t.flags);
        require(st == STATE_ORDER || st == STATE_OPEN, "IMMUTABLE");

        bool longSide = (t.flags & 0x01) != 0;
        int64 baseX6 = (st == STATE_OPEN) ? t.entryX6 : t.targetX6;

        _validateStops(longSide, baseX6, t.liqX6, newSLx6, newTPx6);

        t.slX6 = newSLx6;
        t.tpX6 = newTPx6;
        emit StopsUpdated(id, newSLx6, newTPx6);
    }

    /// @notice Met à jour SL et TP pour le compte de `trader` (meta-tx / relayer).
    function updateStopsRelayer(
        address trader,
        uint32 id,
        int64 newSLx6,
        int64 newTPx6
    ) external onlyRelayer {
        Trade storage t = trades[id];
        require(t.owner == trader, "WRONG_TRADER");

        uint8 st = _getState(t.flags);
        require(st == STATE_ORDER || st == STATE_OPEN, "IMMUTABLE");

        bool longSide = (t.flags & 0x01) != 0;
        int64 baseX6 = (st == STATE_OPEN) ? t.entryX6 : t.targetX6;

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
        int64 baseX6 = (st == STATE_OPEN) ? t.entryX6 : t.targetX6;
        _validateStops(longSide, baseX6, t.liqX6, newSLx6, t.tpX6);
        t.slX6 = newSLx6;
        emit StopsUpdated(id, t.slX6, t.tpX6);
    }

    /// @notice Met à jour uniquement le SL pour le compte de `trader` (meta-tx / relayer).
    function setSLRelayer(
        address trader,
        uint32 id,
        int64 newSLx6
    ) external onlyRelayer {
        Trade storage t = trades[id];
        require(t.owner == trader, "WRONG_TRADER");

        uint8 st = _getState(t.flags);
        require(st == STATE_ORDER || st == STATE_OPEN, "IMMUTABLE");

        bool longSide = (t.flags & 0x01) != 0;
        int64 baseX6 = (st == STATE_OPEN) ? t.entryX6 : t.targetX6;

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
        int64 baseX6 = (st == STATE_OPEN) ? t.entryX6 : t.targetX6;
        _validateStops(longSide, baseX6, t.liqX6, t.slX6, newTPx6);
        t.tpX6 = newTPx6;
        emit StopsUpdated(id, t.slX6, t.tpX6);
    }

    /// @notice Met à jour uniquement le TP pour le compte de `trader` (meta-tx / relayer).
    function setTPRelayer(
        address trader,
        uint32 id,
        int64 newTPx6
    ) external onlyRelayer {
        Trade storage t = trades[id];
        require(t.owner == trader, "WRONG_TRADER");

        uint8 st = _getState(t.flags);
        require(st == STATE_ORDER || st == STATE_OPEN, "IMMUTABLE");

        bool longSide = (t.flags & 0x01) != 0;
        int64 baseX6 = (st == STATE_OPEN) ? t.entryX6 : t.targetX6;

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

    /// @notice Expo en lots pour un asset : long et short.
    function getExposure(uint32 assetId)
        external
        view
        returns (uint256 longLots_, uint256 shortLots_)
    {
        longLots_ = longLots[assetId];
        shortLots_ = shortLots[assetId];
    }

    function longExposure(uint32 assetId) external view returns (uint256) {
        return longLots[assetId];
    }

    function shortExposure(uint32 assetId) external view returns (uint256) {
        return shortLots[assetId];
    }

    /* ───────────────── batch utils (proof) ───────────────── */

    function _execSingleLimitBatch(
        uint32 assetId,
        uint32 id,
        int64 oracleX6,
        uint64 feeX6
    ) internal returns (bool) {
        Trade storage t = trades[id];

        if (
            t.owner == address(0) ||
            t.asset != assetId ||
            _getState(t.flags) != STATE_ORDER
        ) {
            return false;
        }

        uint256 tgt = uint256(uint64(t.targetX6));
        uint256 upper = (tgt * (10000 + TOL_BPS)) / 10000;
        uint256 lower = (tgt * (10000 - TOL_BPS)) / 10000;

        bool longSide = (t.flags & 0x01) != 0;
        uint256 midU = uint256(uint64(oracleX6));
        bool ok = longSide ? (midU <= upper) : (midU >= lower);

        if (!ok) {
            return false;
        }

        // Prix exec = oracle ± spread
        int64 execX6 = _applySpread(oracleX6, feeX6, longSide);

        t.entryX6 = execX6;
        t.flags = _setState(t.flags, STATE_OPEN);
        t.openedAt = uint64(block.timestamp);

        _incExposure(t.asset, longSide, t.lots);

        emit Executed(id, execX6);
        return true;
    }

    function execLimits(
        uint32 assetId,
        uint32[] calldata ids,
        bytes calldata proof
    ) external returns (uint32 executed, uint32 skipped) {
        int64 oracleX6 = _priceX6FromProof(proof, assetId, PROOF_MAX_AGE);
        uint64 feeX6 = calculator.fee(assetId);

        for (uint256 i = 0; i < ids.length; ) {
            bool ok = _execSingleLimitBatch(assetId, ids[i], oracleX6, feeX6);

            if (ok) {
                unchecked {
                    ++executed;
                }
            } else {
                unchecked {
                    ++skipped;
                }
            }

            unchecked {
                ++i;
            }
        }
    }

    // ───────────────── helpers internes (close batch) ─────────────────

    function _okTP(
        bool longSide,
        int64 triggerX6,
        int64 px
    ) internal pure returns (bool) {
        uint256 trig = uint256(uint64(triggerX6));
        uint256 pxU = uint256(uint64(px));
        uint256 upper = (trig * (10000 + TOL_BPS)) / 10000;
        uint256 lower = (trig * (10000 - TOL_BPS)) / 10000;
        return longSide ? (pxU >= lower) : (pxU <= upper);
    }

    function _okSLorLIQ(
        bool longSide,
        int64 triggerX6,
        int64 px
    ) internal pure returns (bool) {
        uint256 trig = uint256(uint64(triggerX6));
        uint256 pxU = uint256(uint64(px));
        uint256 upper = (trig * (10000 + TOL_BPS)) / 10000;
        uint256 lower = (trig * (10000 - TOL_BPS)) / 10000;
        return longSide ? (pxU <= upper) : (pxU >= lower);
    }

    function _finalizeClose(
        Trade storage t,
        uint32 id,
        int64 px,
        bool longSide,
        uint8 rm
    ) internal {
        uint16 lots = t.lots;

        _decExposure(t.asset, longSide, lots);

        uint256 qty1e18 = _qty1e18(t.asset, lots);
        int256 pnlUsd6 = _pnlUsd6(t.entryX6, px, longSide, qty1e18);

        vault.unlock(t.owner, t.marginUsd6);
        vault.settle(t.owner, pnlUsd6);

        t.flags = _setState(t.flags, STATE_CLOSED);
        emit Removed(id, rm, px, pnlUsd6);
    }

    function _closeWithReason(
        Trade storage t,
        uint32 id,
        uint8 reason,
        int64 oracleX6
    ) internal {
        int64 triggerX6;
        uint8 rm;
        if (reason == REASON_SL) {
            triggerX6 = t.slX6;
            require(triggerX6 != 0, "NO_SL");
            rm = RM_SL;
        } else if (reason == REASON_TP) {
            triggerX6 = t.tpX6;
            require(triggerX6 != 0, "NO_TP");
            rm = RM_TP;
        } else {
            triggerX6 = t.liqX6;
            require(triggerX6 != 0, "NO_LIQ");
            rm = RM_LIQ;
        }

        bool longSide = (t.flags & 0x01) != 0;

        bool ok = (reason == REASON_TP)
            ? _okTP(longSide, triggerX6, oracleX6)
            : _okSLorLIQ(longSide, triggerX6, oracleX6);

        require(ok, "PRICE_NOT_MATCH");

        int64 pxClose = _closePxWithFundingAndSpread(t, oracleX6);

        _finalizeClose(t, id, pxClose, longSide, rm);
    }

    function closeBatch(
        uint32 assetId,
        uint8 reason,
        uint32[] calldata ids,
        bytes calldata proof
    ) external returns (uint32 closed, uint32 skipped) {
        require(
            reason == REASON_SL || reason == REASON_TP || reason == REASON_LIQ,
            "BAD_REASON"
        );

        int64 oracleX6 = _priceX6FromProof(proof, assetId, PROOF_MAX_AGE);

        for (uint256 i = 0; i < ids.length; ) {
            Trade storage t = trades[ids[i]];
            if (
                t.owner == address(0) ||
                t.asset != assetId ||
                _getState(t.flags) != STATE_OPEN
            ) {
                unchecked {
                    ++skipped;
                    ++i;
                }
                continue;
            }

            bool longSide = (t.flags & 0x01) != 0;

            int64 triggerX6;
            uint8 rm;
            if (reason == REASON_TP) {
                triggerX6 = t.tpX6;
                rm = RM_TP;
            } else if (reason == REASON_SL) {
                triggerX6 = t.slX6;
                rm = RM_SL;
            } else {
                triggerX6 = t.liqX6;
                rm = RM_LIQ;
            }

            if (triggerX6 == 0) {
                unchecked {
                    ++skipped;
                    ++i;
                }
                continue;
            }

            bool ok = (reason == REASON_TP)
                ? _okTP(longSide, triggerX6, oracleX6)
                : _okSLorLIQ(longSide, triggerX6, oracleX6);

            if (!ok) {
                unchecked {
                    ++skipped;
                    ++i;
                }
                continue;
            }

            int64 pxClose = _closePxWithFundingAndSpread(t, oracleX6);

            _finalizeClose(t, ids[i], pxClose, longSide, rm);
            unchecked {
                ++closed;
                ++i;
            }
        }
    }
}
