// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* ────────────────────────── Interfaces ────────────────────────── */

interface ICalculator {
    function getLot(uint32 assetId) external view returns (uint256 num, uint256 den);
    function isMarketOpen(uint32 assetId) external view returns (bool);
}

/**
 * Supra Pull V2 interface
 * NOTE: verifySvalue is used here instead of verifyOracleProofV2 and is external view
 * to align with common Solidity integration patterns.
 */
interface ISupraOraclePullV2 {
    struct PriceInfo {
        uint256[] pairs;     // pair indexes
        uint256[] prices;    // raw prices
        uint256[] timestamp; // unix seconds (or milliseconds, will be normalized)
        uint256[] decimal;   // price decimals
        uint256[] round;     // round id
    }
    // Changed to 'view' for easier integration as the actual verification is off-chain/in the proof data.
    function verifySvalue(bytes calldata _proof) external view returns (PriceInfo memory);
}

interface IVault {
    function available(address user) external view returns (uint256);
    function lock(address user, uint256 amount) external;
    function unlock(address user, uint256 amount) external;
    function settle(address user, int256 pnl) external;
}

/* ────────────────────────── Contract ────────────────────────── */

contract Trades {
    uint256 private constant WAD = 1e18;              // Internal quantity scaling
    uint256 private constant LIQ_LOSS_OF_MARGIN_WAD = 8e17; // 0.8
    uint16  private constant TOL_BPS = 5;             // 0.05% tolerance
    uint256 private constant PROOF_MAX_AGE = 60;      // Max proof freshness (seconds)

    ICalculator public immutable calculator;
    ISupraOraclePullV2 public immutable supraPull;    // Proof-based oracle
    IVault public immutable vault;

    uint32 public nextId = 1;

    // States
    uint8 private constant STATE_ORDER    = 0; // LIMIT pending
    uint8 private constant STATE_OPEN     = 1; // active position
    uint8 private constant STATE_CLOSED   = 2; // closed
    uint8 private constant STATE_CANCELLED= 3; // cancelled

    // Close reasons (for Removed event)
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
        address owner;
        uint32  asset;
        uint16  lots;
        uint8   flags;       // bit0=longSide ; bits4..7=state
        uint8   _pad0;
        // slot 1 (price x1e6)
        int64   entryX6;     // 0 if ORDER
        int64   targetX6;    // 0 if MARKET
        int64   slX6;        // 0 if none
        int64   tpX6;        // 0 if none
        // slot 2
        int64   liqX6;       // Fixed at opening
        uint16  leverageX;   // 1..100
        uint16  _pad1;
        uint64  marginUsd6;  // USDC/USDT 1e6
    }

    mapping(uint32 => Trade) public trades;

    // ───────────────── EVENTS ─────────────────
    event Opened(
        uint32 indexed id,
        uint8  state,
        uint32 indexed asset,
        bool   longSide,
        uint16 lots,
        int64  entryOrTargetX6,
        int64  slX6,
        int64  tpX6,
        int64  liqX6,
        address indexed trader,
        uint16 leverageX
    );
    event Executed(uint32 indexed id, int64 entryX6);
    event StopsUpdated(uint32 indexed id, int64 slX6, int64 tpX6);
    event Removed(uint32 indexed id, uint8 reason, int64 execX6, int256 pnlUsd6);

    // CONSTRUCTOR: Simplified (Step 2 & 1)
    constructor(address _calc, address _vault, address _supraPull) {
        require(_calc != address(0) && _vault != address(0) && _supraPull != address(0), "ADDR_0");
        calculator = ICalculator(_calc);
        vault      = IVault(_vault);
        supraPull  = ISupraOraclePullV2(_supraPull);
    }

    /* ───────────────── helpers price & close ───────────────── */

    // Proof helper: Replaces _priceX6FromOracle (Step 3)
    function _priceX6FromProof(
        bytes calldata proof, uint32 assetId, uint256 maxAgeSec
    ) internal view returns (int64 pxX6) {
        ISupraOraclePullV2.PriceInfo memory info = supraPull.verifySvalue(proof);

        // Find assetId (pairId == assetId) in the proof
        uint256 idx = type(uint256).max;
        for (uint256 i = 0; i < info.pairs.length; ++i) {
            if (info.pairs[i] == uint256(assetId)) { idx = i; break; }
        }
        require(idx != type(uint256).max, "PROOF_NO_ASSET");

        uint256 raw = info.prices[idx];
        uint256 dec = info.decimal[idx];
        uint256 t   = info.timestamp[idx];

        // Normalize timestamp to seconds
        uint256 ts = (t > 1e12) ? (t / 1000) : t; 
        
        require(raw > 0, "PROOF_PRICE_0");
        require(ts <= block.timestamp + 180, "PROOF_BAD_TS"); 
        if (maxAgeSec > 0) require((block.timestamp - ts) <= maxAgeSec, "PROOF_TOO_OLD");

        // Scale to x1e6
        uint256 p6 = (dec == 6) ? raw : (dec > 6 ? raw / (10 ** (dec - 6)) : raw * (10 ** (6 - dec)));
        require(p6 > 0 && p6 <= type(uint64).max, "PROOF_PX6_RANGE");

        return int64(uint64(p6));
    }
    
    // Finalize Close Helper (Anti-Stack-Too-Deep Refactor)
    function _finalizeClose(
        Trade storage t,
        uint32 id_,
        uint8 rm,
        int64 px
    ) private {
        uint256 qty1e18 = _qty1e18(t.asset, t.lots);
        int256 pnlUsd6  = _pnlUsd6(t.entryX6, px, (t.flags & 0x01) != 0, qty1e18);

        // Cap PnL to margin (±100%)
        int256 cap = int256(uint256(t.marginUsd6));
        if (pnlUsd6 > cap) pnlUsd6 = cap;
        if (pnlUsd6 < -cap) pnlUsd6 = -cap;

        vault.unlock(t.owner, t.marginUsd6);
        vault.settle(t.owner, pnlUsd6);

        t.flags = _setState(t.flags, STATE_CLOSED);
        emit Removed(id_, rm, px, pnlUsd6);
    }
    
    // Finalize Execute Helper (Anti-Stack-Too-Deep Refactor)
    function _finalizeExec(Trade storage t, uint32 id_, int64 px) private {
        t.entryX6 = px;
        t.flags   = _setState(t.flags, STATE_OPEN);
        emit Executed(id_, px);
    }

    // Process one ID in CloseBatch (Anti-Stack-Too-Deep Refactor)
    function _processCloseOne(
        uint32 id_,
        uint32 assetId,
        uint8  reason,
        int64  px,
        uint16 tol
    ) private returns (bool closed) {
        Trade storage t = trades[id_];

        // Fast filters
        if (t.owner == address(0) || t.asset != assetId || _getState(t.flags) != STATE_OPEN) {
            return false;
        }

        // Compute trigger & mapped reason inline
        int64 triggerX6;
        uint8 rm;
        if (reason == REASON_SL) {
            if (t.slX6 == 0) return false; triggerX6 = t.slX6; rm = RM_SL;
        } else if (reason == REASON_TP) {
            if (t.tpX6 == 0) return false; triggerX6 = t.tpX6; rm = RM_TP;
        } else {
            if (reason != REASON_LIQ || t.liqX6 == 0) return false; triggerX6 = t.liqX6; rm = RM_LIQ;
        }

        // Acceptance (tol for SL/TP; tol OR beyond-liq for LIQ)
        bool accept;
        if (rm == RM_LIQ) {
            bool longSide = (t.flags & 0x01) != 0;
            accept = _withinTol(triggerX6, px, tol) || (longSide ? (px <= triggerX6) : (px >= triggerX6));
        } else {
            accept = _withinTol(triggerX6, px, tol);
        }
        if (!accept) return false;

        _finalizeClose(t, id_, rm, px);
        return true;
    }


    /* ───────────────── helpers math & flags (unchanged) ───────────────── */

    function _qty1e18(uint32 assetId, uint16 lots) internal view returns (uint256) {
        (uint256 num, uint256 den) = calculator.getLot(assetId);
        require(den > 0 && num > 0, "LOT_CFG");
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
        int64 entryX6, int64 execX6, bool longSide, uint256 qty1e18
    ) internal pure returns (int256) {
        int256 dX6 = int256(execX6) - int256(entryX6);
        if (!longSide) dX6 = -dX6;
        return (int256(qty1e18) * dX6) / int256(WAD);
    }

    function _validateStops(
        bool longSide, int64 baseX6, int64 liqX6, int64 slX6, int64 tpX6
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

    function _emitOpened(
        uint32 id, uint8 state, uint32 assetId, address trader
    ) internal {
        Trade storage t = trades[id];
        bool longSide_ = (t.flags & uint8(1)) == 1;
        int64 entryOrTargetX6_ = (state == STATE_OPEN) ? t.entryX6 : t.targetX6;
        emit Opened(id, state, assetId, longSide_, t.lots, entryOrTargetX6_, t.slX6, t.tpX6, t.liqX6, trader, t.leverageX);
    }

    /* ───────────────── open (MARKET/LIMIT) ───────────────── */

    // open: Replaces the old open/execute logic to use proof-based price reading
    function open(
        bytes calldata proof,
        uint32 assetId,
        uint256 pairIndex,
        bool   longSide,
        uint16 leverageX,
        uint16 lots,
        bool   isLimit,
        int64  priceX6,
        int64  slX6,
        int64  tpX6
    ) external returns (uint32 id) {
        if (isLimit) {
            id = _openLimit(assetId, longSide, leverageX, lots, priceX6, slX6, tpX6);
        } else {
            id = _openMarket(proof, assetId, pairIndex, longSide, leverageX, lots, slX6, tpX6);
        }
    }

    function _openLimit(
        uint32 assetId, bool longSide, uint16 leverageX, uint16 lots,
        int64 targetX6, int64 slX6, int64 tpX6
    ) internal returns (uint32 id) {
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
        uint8 flags = _setState((longSide ? uint8(1) : uint8(0)), STATE_ORDER);
        trades[id] = Trade({
            owner: msg.sender, asset: assetId, lots: lots, flags: flags, _pad0: 0,
            entryX6: 0, targetX6: targetX6, slX6: slX6, tpX6: tpX6, liqX6: liqX6,
            leverageX: leverageX, _pad1: 0, marginUsd6: marginUsd6
        });
        _emitOpened(id, STATE_ORDER, assetId, msg.sender);
    }

    function _openMarket(
        bytes calldata proof, uint32 assetId, uint256 pairIndex, bool longSide,
        uint16 leverageX, uint16 lots, int64 slX6, int64 tpX6
    ) internal returns (uint32 id) {
        require(calculator.isMarketOpen(assetId), "MARKET_CLOSED");

        // Use proof price (Step 3)
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
        uint8 flags = _setState((longSide ? uint8(1) : uint8(0)), STATE_OPEN);
        trades[id] = Trade({
            owner: msg.sender, asset: assetId, lots: lots, flags: flags, _pad0: 0,
            entryX6: entryX6, targetX6: 0, slX6: slX6, tpX6: tpX6, liqX6: liqX6,
            leverageX: leverageX, _pad1: 0, marginUsd6: marginUsd6
        });
        _emitOpened(id, STATE_OPEN, assetId, msg.sender);
    }

    /* ───────────────── cancel / execute ───────────────── */

    function cancel(uint32 id) external {
        Trade storage t = trades[id];
        require(t.owner == msg.sender, "NOT_OWNER");
        require(_getState(t.flags) == STATE_ORDER, "NOT_ORDER");
        vault.unlock(t.owner, t.marginUsd6);
        t.flags = _setState(t.flags, STATE_CANCELLED);
        emit Removed(id, RM_CANCELLED, 0, 0);
    }

    // executeLimit: Now requires proof (Step 3)
    function executeLimit(uint32 id, bytes calldata proof, uint256 pairIndex) external {
        Trade storage t = trades[id];
        require(_getState(t.flags) == STATE_ORDER, "NOT_ORDER");
        
        // Use proof price (Step 3)
        (int64 px, ) = _priceX6FromProof(proof, t.asset, PROOF_MAX_AGE);
        require(_withinTol(t.targetX6, px, TOL_BPS), "PRICE_NOT_NEAR");
        
        _finalizeExec(t, id, px);
    }

    /* ───────────────── close ───────────────── */

    // closeWithProof: Replaces close(uint32 id, uint8 reason)
    function closeWithProof(uint32 id, uint8 reason, bytes calldata proof, uint256 pairIndex) external {
        Trade storage t = trades[id];
        require(_getState(t.flags) == STATE_OPEN, "NOT_OPEN");

        // Logic to determine trigger and reason
        (int64 triggerX6, uint8 rm);
        if (reason == REASON_SL) { require(t.slX6 != 0, "NO_SL"); triggerX6 = t.slX6; rm = RM_SL; }
        else if (reason == REASON_TP) { require(t.tpX6 != 0, "NO_TP"); triggerX6 = t.tpX6; rm = RM_TP; }
        else { require(reason == REASON_LIQ && t.liqX6 != 0, "BAD_REASON"); triggerX6 = t.liqX6; rm = RM_LIQ; }

        // Use proof price (Step 3)
        (int64 px, ) = _priceX6FromProof(proof, t.asset, PROOF_MAX_AGE);

        bool accept;
        if (rm == RM_LIQ) {
            bool longSide = (t.flags & 0x01) != 0;
            accept = _withinTol(triggerX6, px, TOL_BPS) || (longSide ? (px <= triggerX6) : (px >= triggerX6));
        } else {
            accept = _withinTol(triggerX6, px, TOL_BPS);
        }
        require(accept, "PRICE_NOT_NEAR");

        _finalizeClose(t, id, rm, px);
    }

    // closeMarket: Now requires proof (Step 3)
    function closeMarket(uint32 id, bytes calldata proof, uint256 pairIndex) external {
        Trade storage t = trades[id];
        require(t.owner == msg.sender, "NOT_OWNER");
        require(_getState(t.flags) == STATE_OPEN, "NOT_OPEN");
        
        // Use proof price (Step 3)
        (int64 px, ) = _priceX6FromProof(proof, t.asset, PROOF_MAX_AGE);
        
        _finalizeClose(t, id, RM_MARKET, px);
    }

    /* ───────────────── update stops (unchanged) ───────────────── */

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
    function updateSL(uint32 id, int64 newSLx6) external {
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
    function updateTP(uint32 id, int64 newTPx6) external {
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

    /* ───────────────── views (unchanged) ───────────────── */

    function stateOf(uint32 id) external view returns (uint8) {
        return _getState(trades[id].flags);
    }
    function isLong(uint32 id) external view returns (bool) {
        return (trades[id].flags & 0x01) != 0;
    }
    function getTrade(uint32 id) external view returns (Trade memory) {
        return trades[id];
    }
    function debugProof(bytes calldata proof, uint256 pairIndex) external view
    returns (bool found, uint64 pxX6, uint64 ts, uint256 dec)
    {
        ISupraOraclePullV2.PriceInfo memory pi = supraPull.verifySvalue(proof);
        for (uint256 i = 0; i < pi.pairs.length; ++i) {
            if (pi.pairs[i] == pairIndex) {
                uint256 priceRaw = pi.prices[i];
                uint256 d        = pi.decimal[i];
                uint256 t        = pi.timestamp[i];
                uint256 p6 = (d == 6) ? priceRaw : (d > 6 ? priceRaw / (10 ** (d - 6)) : priceRaw * (10 ** (6 - d)));
                return (true, uint64(p6), uint64(t), d);
            }
        }
        return (false, 0, 0, 0);
    }


    /* ───────────────── batch utils ───────────────── */

    // execLimits: Now requires proof (Step 3)
    function execLimits(uint32 assetId, uint32[] calldata ids, bytes calldata proof, uint256 pairIndex)
        external
        returns (uint32 executed, uint32 skipped)
    {
        // Use proof price (Step 3)
        (int64 px, ) = _priceX6FromProof(proof, assetId, PROOF_MAX_AGE);

        for (uint256 i = 0; i < ids.length; ) {
            {
                uint32 id_ = ids[i];
                Trade storage t = trades[id_];

                if (
                    t.owner != address(0) && t.asset == assetId &&
                    _getState(t.flags) == STATE_ORDER && _withinTol(t.targetX6, px, TOL_BPS)
                ) {
                    _finalizeExec(t, id_, px);
                    unchecked { ++executed; }
                } else {
                    unchecked { ++skipped; }
                }
            }
            unchecked { ++i; }
        }
    }

    // closeBatch: Replaced to use _processCloseOne (Step 3)
    function closeBatch(
        uint32 assetId,
        uint8  reason,
        uint32[] calldata ids,
        bytes  calldata proof,
        uint256 pairIndex
    )
        external
        returns (uint32 closed, uint32 skipped)
    {
        require(
            reason == REASON_SL || reason == REASON_TP || reason == REASON_LIQ,
            "BAD_REASON"
        );

        // Use proof price (Step 3)
        (int64 px, ) = _priceX6FromProof(proof, assetId, PROOF_MAX_AGE);
        uint16 tol = TOL_BPS;

        for (uint256 i = 0; i < ids.length; ) {
            uint32 id_ = ids[i];
            if (_processCloseOne(id_, assetId, reason, px, tol)) {
                unchecked { ++closed; }
            } else {
                unchecked { ++skipped; }
            }
            unchecked { ++i; }
        }
    }
}
