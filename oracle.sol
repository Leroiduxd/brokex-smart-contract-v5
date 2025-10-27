// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";

/// -----------------------------------------------------------------------
/// Supra Pull interface (DORA1/DORA2) – inchangée
/// -----------------------------------------------------------------------
interface ISupraOraclePull {
    struct PriceData {
        uint256[] pairs;
        uint256[] prices;
        uint256[] decimals;
    }

    struct PriceInfo {
        uint256[] pairs;
        uint256[] prices;
        uint256[] timestamp;
        uint256[] decimal;
        uint256[] round;
    }

    function verifyOracleProof(bytes calldata _bytesproof)
        external
        returns (PriceData memory);

    function verifyOracleProofV2(bytes calldata _bytesproof)
        external
        returns (PriceInfo memory);
}

/// -----------------------------------------------------------------------
/// Supra Push interface (getters) – doit correspondre à la doc
///  - priceFeed, derivedData
///  - getSvalue / getSvalues / getDerivedSvalue / getTimestamp
/// -----------------------------------------------------------------------
interface ISupraSValueFeed {
    struct priceFeed {
        uint256 round;
        uint256 decimals;
        uint256 time;
        uint256 price;
    }

    struct derivedData {
        int256  roundDifference;
        uint256 derivedPrice;
        uint256 decimals;
    }

    function getSvalue(uint256 _pairIndex)
        external
        view
        returns (priceFeed memory);

    function getSvalues(uint256[] memory _pairIndexes)
        external
        view
        returns (priceFeed[] memory);

    /// operation: 0 = multiplication, 1 = division
    function getDerivedSvalue(
        uint256 pair_id_1,
        uint256 pair_id_2,
        uint256 operation
    )
        external
        view
        returns (derivedData memory);

    function getTimestamp(uint256 _tradingPair)
        external
        view
        returns (uint256);
}

/// -----------------------------------------------------------------------
/// BrokexSupraPushMirror
/// - Ingestion des preuves Pull
/// - Stockage local par pair
/// - Expose EXACTEMENT les getters Push de Supra
/// -----------------------------------------------------------------------
contract BrokexSupraPushMirror is ISupraSValueFeed, Ownable {
    ISupraOraclePull public pull;

    /// stockage "push-like"
    mapping(uint256 => priceFeed) private feeds; // pairId => priceFeed

    event PullAddressUpdated(address indexed oldAddr, address indexed newAddr);
    event FeedUpdated(uint256 indexed pair, uint256 price, uint256 decimals, uint256 timestamp, uint256 round);

    constructor(address pullAddress) Ownable(msg.sender) {
        require(pullAddress != address(0), "pull=0");
        pull = ISupraOraclePull(pullAddress);
        emit PullAddressUpdated(address(0), pullAddress);
    }

    // ----------------------------------------------------------
    // Admin
    // ----------------------------------------------------------
    function updatePullAddress(address newPull) external onlyOwner {
        require(newPull != address(0), "pull=0");
        emit PullAddressUpdated(address(pull), newPull);
        pull = ISupraOraclePull(newPull);
    }

    // ----------------------------------------------------------
    // Ingestion depuis le PULL (DORA1) – pas de timestamp/round
    // -> on écrase sans condition (la preuve "Last Updated" de Supra)
    // ----------------------------------------------------------
    function ingestProof(bytes calldata _bytesProof) external returns (uint256 updated) {
        ISupraOraclePull.PriceData memory d = pull.verifyOracleProof(_bytesProof);
        for (uint256 i = 0; i < d.pairs.length; i++) {
            uint256 pair = d.pairs[i];
            priceFeed storage pf = feeds[pair];
            pf.price    = d.prices[i];
            pf.decimals = d.decimals[i];
            // pas fourni dans DORA1 : on met à jour "time" à now pour signaler l’ingestion,
            // et round=0 (inconnu).
            pf.time     = block.timestamp;
            pf.round    = 0;
            emit FeedUpdated(pair, pf.price, pf.decimals, pf.time, pf.round);
            updated++;
        }
    }

    // ----------------------------------------------------------
    // Ingestion depuis le PULL (DORA2) – avec timestamp & round
    // -> on met à jour UNIQUEMENT si plus récent:
    //    - timestamp strictement supérieur, OU
    //    - timestamp égal MAIS round strictement supérieur
    // ----------------------------------------------------------
    function ingestProofV2(bytes calldata _bytesProof) external returns (uint256 updated) {
        ISupraOraclePull.PriceInfo memory d = pull.verifyOracleProofV2(_bytesProof);
        for (uint256 i = 0; i < d.pairs.length; i++) {
            uint256 pair   = d.pairs[i];
            uint256 price  = d.prices[i];
            uint256 ts     = d.timestamp[i];
            uint256 dec    = d.decimal[i];
            uint256 round  = d.round[i];

            priceFeed storage cur = feeds[pair];

            bool isNewer = (ts > cur.time) || (ts == cur.time && round > cur.round);
            if (isNewer) {
                cur.price    = price;
                cur.decimals = dec;
                cur.time     = ts;
                cur.round    = round;
                emit FeedUpdated(pair, cur.price, cur.decimals, cur.time, cur.round);
                updated++;
            }
        }
    }

    // ----------------------------------------------------------
    // GETTERS "push" – ABI identique à Supra
    // ----------------------------------------------------------
    function getSvalue(uint256 _pairIndex)
        external
        view
        override
        returns (priceFeed memory)
    {
        return feeds[_pairIndex];
    }

    function getSvalues(uint256[] memory _pairIndexes)
        external
        view
        override
        returns (priceFeed[] memory out)
    {
        out = new priceFeed[](_pairIndexes.length);
        for (uint256 i = 0; i < _pairIndexes.length; i++) {
            out[i] = feeds[_pairIndexes[i]];
        }
    }

    /// operation: 0 = multiplication, 1 = division
    function getDerivedSvalue(
        uint256 pair_id_1,
        uint256 pair_id_2,
        uint256 operation
    )
        external
        view
        override
        returns (derivedData memory dd)
    {
        priceFeed memory a = feeds[pair_id_1];
        priceFeed memory b = feeds[pair_id_2];

        // roundDifference = roundA - roundB (peut être négatif)
        dd.roundDifference = int256(a.round) - int256(b.round);

        if (operation == 0) {
            // multiplication
            // décimales résultantes = decA + decB
            dd.derivedPrice = a.price * b.price;
            dd.decimals     = a.decimals + b.decimals;
        } else {
            // division
            // prix = a * 10^decB / b ; décimales résultantes = decA
            require(b.price != 0, "divide by zero");
            dd.derivedPrice = a.price * (10 ** b.decimals) / b.price;
            dd.decimals     = a.decimals;
        }
    }

    function getTimestamp(uint256 _tradingPair)
        external
        view
        override
        returns (uint256)
    {
        return feeds[_tradingPair].time;
    }
}
