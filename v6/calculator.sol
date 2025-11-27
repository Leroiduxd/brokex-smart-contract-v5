// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";

contract Calculator is Ownable {
    struct LotCfg {
        uint256 num;
        uint256 den;
        bool    listed;
        uint8   market;
    }

    // ---------------------------------
    // Storage
    // ---------------------------------
    mapping(uint32 => LotCfg) public asset;
    mapping(uint8 => bool)    public marketOpen;

    // Spread + commission (prix x1e6)
    mapping(uint32 => uint64) public feeX6;

    // Funding rate (prix x1e6)
    mapping(uint32 => int64)  public fundX6;

    // Events
    event MarketStatus(uint8 indexed marketId, bool open);
    event FeeSet(uint32 indexed assetId, uint64 valueX6);
    event FundSet(uint32 indexed assetId, int64 valueX6);

    constructor(address initialOwner) Ownable(initialOwner) {}

    // ---------------------------------
    // Admin
    // ---------------------------------

    function addAsset(
        uint32 assetId,
        uint8 marketId,
        uint256 num,
        uint256 den
    ) external onlyOwner {
        require(num > 0 && den > 0, "BAD_LOT");
        asset[assetId] = LotCfg(num, den, true, marketId);
    }

    function setLot(uint32 assetId, uint256 num, uint256 den) external onlyOwner {
        require(num > 0 && den > 0, "BAD_LOT");
        LotCfg storage a = asset[assetId];
        require(a.listed, "ASSET_UNKNOWN");
        a.num = num;
        a.den = den;
    }

    function setMarket(uint32 assetId, uint8 marketId) external onlyOwner {
        LotCfg storage a = asset[assetId];
        require(a.listed, "ASSET_UNKNOWN");
        a.market = marketId;
    }

    function setMarketOpen(uint8 marketId, bool open) external onlyOwner {
        marketOpen[marketId] = open;
        emit MarketStatus(marketId, open);
    }

    // ---------------------------------
    // New Fee System (short names)
    // ---------------------------------

    /// @notice spread + commission (en x1e6)
    function setFee(uint32 assetId, uint64 valueX6) external onlyOwner {
        require(asset[assetId].listed, "ASSET_UNKNOWN");
        feeX6[assetId] = valueX6;
        emit FeeSet(assetId, valueX6);
    }

    /// @notice funding rate (en x1e6)
    function setFund(uint32 assetId, int64 valueX6) external onlyOwner {
        require(asset[assetId].listed, "ASSET_UNKNOWN");
        fundX6[assetId] = valueX6;
        emit FundSet(assetId, valueX6);
    }

    // ---------------------------------
    // Views
    // ---------------------------------

    function getLot(uint32 assetId) external view returns (uint256, uint256) {
        LotCfg memory a = asset[assetId];
        require(a.listed, "ASSET_UNKNOWN");
        return (a.num, a.den);
    }

    function getMarket(uint32 assetId) external view returns (uint8) {
        LotCfg memory a = asset[assetId];
        require(a.listed, "ASSET_UNKNOWN");
        return a.market;
    }

    function isMarketOpen(uint32 assetId) external view returns (bool) {
        LotCfg memory a = asset[assetId];
        require(a.listed, "ASSET_UNKNOWN");
        return marketOpen[a.market];
    }

    /// @notice getter court pour fee
    function fee(uint32 assetId) external view returns (uint64) {
        require(asset[assetId].listed, "ASSET_UNKNOWN");
        return feeX6[assetId];
    }

    /// @notice getter court pour funding
    function fund(uint32 assetId) external view returns (int64) {
        require(asset[assetId].listed, "ASSET_UNKNOWN");
        return fundX6[assetId];
    }

    /// @notice fee + funding en une fois
    function costs(uint32 assetId)
        external
        view
        returns (uint64, int64)
    {
        require(asset[assetId].listed, "ASSET_UNKNOWN");
        return (feeX6[assetId], fundX6[assetId]);
    }
}

