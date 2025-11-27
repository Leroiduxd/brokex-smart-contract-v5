// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/* ────────────────────────── Interface vers Trades ────────────────────────── */

interface ITrades {
    // LIMIT
    function openLimitRelayer(
        address trader,
        uint32 assetId,
        bool longSide,
        uint16 leverageX,
        uint16 lots,
        int64 targetX6,
        int64 slX6,
        int64 tpX6
    ) external returns (uint32 id);

    function cancelRelayer(address trader, uint32 id) external;

    function updateStopsRelayer(
        address trader,
        uint32 id,
        int64 newSLx6,
        int64 newTPx6
    ) external;

    function setSLRelayer(
        address trader,
        uint32 id,
        int64 newSLx6
    ) external;

    function setTPRelayer(
        address trader,
        uint32 id,
        int64 newTPx6
    ) external;

    // MARKET
    function openMarketRelayer(
        address trader,
        bytes calldata proof,
        uint32 assetId,
        bool longSide,
        uint16 leverageX,
        uint16 lots,
        int64 slX6,
        int64 tpX6
    ) external returns (uint32 id);

    function closeMarketRelayer(
        address trader,
        uint32 id,
        bytes calldata proof
    ) external;
}

/* ────────────────────────── Meta-Relayer EIP-712 ────────────────────────── */

contract BrokexMetaRelayer is EIP712 {
    using ECDSA for bytes32;

    ITrades public immutable trades;
    address public owner;

    mapping(address => uint256) public nonces;

    // ───────────── Structs ─────────────

    struct LimitOpenCall {
        address trader;
        uint32 assetId;
        bool longSide;
        uint16 leverageX;
        uint16 lots;
        int64 targetX6;
        int64 slX6;
        int64 tpX6;
        uint256 nonce;
        uint256 deadline;
    }

    struct MarketOpenCall {
        address trader;
        uint32 assetId;
        bool longSide;
        uint16 leverageX;
        uint16 lots;
        int64 slX6;
        int64 tpX6;
        uint256 nonce;
        uint256 deadline;
    }

    struct MarketCloseCall {
        address trader;
        uint32 id;
        uint256 nonce;
        uint256 deadline;
    }

    // EIP-712 types
    bytes32 private constant LIMIT_OPEN_TYPEHASH = keccak256(
        "LimitOpen(address trader,uint32 assetId,bool longSide,uint16 leverageX,uint16 lots,int64 targetX6,int64 slX6,int64 tpX6,uint256 nonce,uint256 deadline)"
    );

    bytes32 private constant LIMIT_CANCEL_TYPEHASH = keccak256(
        "LimitCancel(address trader,uint32 id,uint256 nonce,uint256 deadline)"
    );

    bytes32 private constant LIMIT_UPDATE_STOPS_TYPEHASH = keccak256(
        "LimitUpdateStops(address trader,uint32 id,int64 newSLx6,int64 newTPx6,uint256 nonce,uint256 deadline)"
    );

    bytes32 private constant LIMIT_SET_SL_TYPEHASH = keccak256(
        "LimitSetSL(address trader,uint32 id,int64 newSLx6,uint256 nonce,uint256 deadline)"
    );

    bytes32 private constant LIMIT_SET_TP_TYPEHASH = keccak256(
        "LimitSetTP(address trader,uint32 id,int64 newTPx6,uint256 nonce,uint256 deadline)"
    );

    bytes32 private constant MARKET_OPEN_TYPEHASH = keccak256(
        "MarketOpen(address trader,uint32 assetId,bool longSide,uint16 leverageX,uint16 lots,int64 slX6,int64 tpX6,uint256 nonce,uint256 deadline)"
    );

    bytes32 private constant MARKET_CLOSE_TYPEHASH = keccak256(
        "MarketClose(address trader,uint32 id,uint256 nonce,uint256 deadline)"
    );

    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }

    constructor(address _trades)
        EIP712("BrokexMetaRelayer", "1")
    {
        require(_trades != address(0), "TRADES_0");
        trades = ITrades(_trades);
        owner = msg.sender;
    }

    function setOwner(address newOwner) external onlyOwner {
        require(newOwner != address(0), "OWNER_0");
        owner = newOwner;
    }

    /* ─────────────────── Internes : nonce + deadline ─────────────────── */

    function _useNonce(address trader) internal returns (uint256 current) {
        current = nonces[trader];
        nonces[trader] = current + 1;
    }

    function _checkDeadline(uint256 deadline) internal view {
        require(block.timestamp <= deadline, "DEADLINE_EXPIRED");
    }

    /* ─────────────────── Helpers Hashing (Stack Fix) ─────────────────── */
    
    function _hashMarketOpen(MarketOpenCall memory c) private pure returns (bytes32) {
        return keccak256(bytes.concat(
            abi.encode(MARKET_OPEN_TYPEHASH),
            abi.encode(c.trader, c.assetId),
            abi.encode(c.longSide, c.leverageX),
            abi.encode(c.lots, c.slX6),
            abi.encode(c.tpX6, c.nonce, c.deadline)
        ));
    }

    function _hashLimitOpen(LimitOpenCall memory c) private pure returns (bytes32) {
        return keccak256(bytes.concat(
            abi.encode(LIMIT_OPEN_TYPEHASH),
            abi.encode(c.trader, c.assetId),
            abi.encode(c.longSide, c.leverageX),
            abi.encode(c.lots, c.targetX6),
            abi.encode(c.slX6, c.tpX6),
            abi.encode(c.nonce, c.deadline)
        ));
    }

    /* ─────────────────── Helpers Call (Stack Fix #2) ─────────────────── */
    
    function _doOpenMarketCall(MarketOpenCall memory c, bytes calldata proof) private {
        trades.openMarketRelayer(
            c.trader,
            proof,
            c.assetId,
            c.longSide,
            c.leverageX,
            c.lots,
            c.slX6,
            c.tpX6
        );
    }

    /* ─────────────────── LIMIT : open / cancel / stops ─────────────────── */

    function executeOpenLimit(
        address trader,
        uint32 assetId,
        bool longSide,
        uint16 leverageX,
        uint16 lots,
        int64 targetX6,
        int64 slX6,
        int64 tpX6,
        uint256 deadline,
        bytes calldata signature
    ) external {
        _checkDeadline(deadline);
        uint256 nonce = _useNonce(trader);

        LimitOpenCall memory c = LimitOpenCall({
            trader: trader,
            assetId: assetId,
            longSide: longSide,
            leverageX: leverageX,
            lots: lots,
            targetX6: targetX6,
            slX6: slX6,
            tpX6: tpX6,
            nonce: nonce,
            deadline: deadline
        });

        bytes32 structHash = _hashLimitOpen(c);
        _verify(trader, structHash, signature);

        trades.openLimitRelayer(
            c.trader,
            c.assetId,
            c.longSide,
            c.leverageX,
            c.lots,
            c.targetX6,
            c.slX6,
            c.tpX6
        );
    }

    function executeCancelLimit(
        address trader,
        uint32 id,
        uint256 deadline,
        bytes calldata signature
    ) external {
        _checkDeadline(deadline);
        uint256 nonce = _useNonce(trader);

        bytes32 structHash = keccak256(
            abi.encode(
                LIMIT_CANCEL_TYPEHASH,
                trader,
                id,
                nonce,
                deadline
            )
        );

        _verify(trader, structHash, signature);

        trades.cancelRelayer(trader, id);
    }

    function executeUpdateStops(
        address trader,
        uint32 id,
        int64 newSLx6,
        int64 newTPx6,
        uint256 deadline,
        bytes calldata signature
    ) external {
        _checkDeadline(deadline);
        uint256 nonce = _useNonce(trader);

        bytes32 structHash = keccak256(
            abi.encode(
                LIMIT_UPDATE_STOPS_TYPEHASH,
                trader,
                id,
                newSLx6,
                newTPx6,
                nonce,
                deadline
            )
        );

        _verify(trader, structHash, signature);

        trades.updateStopsRelayer(trader, id, newSLx6, newTPx6);
    }

    function executeSetSL(
        address trader,
        uint32 id,
        int64 newSLx6,
        uint256 deadline,
        bytes calldata signature
    ) external {
        _checkDeadline(deadline);
        uint256 nonce = _useNonce(trader);

        bytes32 structHash = keccak256(
            abi.encode(
                LIMIT_SET_SL_TYPEHASH,
                trader,
                id,
                newSLx6,
                nonce,
                deadline
            )
        );

        _verify(trader, structHash, signature);

        trades.setSLRelayer(trader, id, newSLx6);
    }

    function executeSetTP(
        address trader,
        uint32 id,
        int64 newTPx6,
        uint256 deadline,
        bytes calldata signature
    ) external {
        _checkDeadline(deadline);
        uint256 nonce = _useNonce(trader);

        bytes32 structHash = keccak256(
            abi.encode(
                LIMIT_SET_TP_TYPEHASH,
                trader,
                id,
                newTPx6,
                nonce,
                deadline
            )
        );

        _verify(trader, structHash, signature);

        trades.setTPRelayer(trader, id, newTPx6);
    }

    /* ─────────────────── MARKET : open / close ─────────────────── */

    function executeOpenMarket(
        address trader,
        bytes calldata proof,
        uint32 assetId,
        bool longSide,
        uint16 leverageX,
        uint16 lots,
        int64 slX6,
        int64 tpX6,
        uint256 deadline,
        bytes calldata signature
    ) external {
        _checkDeadline(deadline);
        uint256 nonce = _useNonce(trader);

        MarketOpenCall memory c = MarketOpenCall({
            trader: trader,
            assetId: assetId,
            longSide: longSide,
            leverageX: leverageX,
            lots: lots,
            slX6: slX6,
            tpX6: tpX6,
            nonce: nonce,
            deadline: deadline
        });

        // 1. Verif signature (stack clean)
        {
            bytes32 structHash = _hashMarketOpen(c);
            _verify(trader, structHash, signature);
        }

        // 2. Execution isolée (stack clean)
        _doOpenMarketCall(c, proof);
    }

    function executeCloseMarket(
        address trader,
        uint32 id,
        bytes calldata proof,
        uint256 deadline,
        bytes calldata signature
    ) external {
        _checkDeadline(deadline);
        uint256 nonce = _useNonce(trader);

        MarketCloseCall memory c = MarketCloseCall({
            trader: trader,
            id: id,
            nonce: nonce,
            deadline: deadline
        });

        _executeCloseMarket(c, proof, signature);
    }

    function _executeCloseMarket(
        MarketCloseCall memory c,
        bytes calldata proof,
        bytes calldata signature
    ) internal {
        bytes32 structHash = keccak256(
            abi.encode(
                MARKET_CLOSE_TYPEHASH,
                c.trader,
                c.id,
                c.nonce,
                c.deadline
            )
        );

        _verify(c.trader, structHash, signature);

        trades.closeMarketRelayer(c.trader, c.id, proof);
    }

    /* ─────────────────── interne : vérif signature ─────────────────── */

    function _verify(
        address trader,
        bytes32 structHash,
        bytes calldata signature
    ) internal view {
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, signature);
        require(signer == trader, "BAD_SIG");
    }
}
