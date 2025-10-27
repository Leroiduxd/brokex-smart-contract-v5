// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Calculator
/// @notice Gestion simple des actifs, marchés et spreads.
/// @dev Pas d'oracle, pas de commission : uniquement des infos de configuration.
import "@openzeppelin/contracts/access/Ownable.sol";

contract Calculator is Ownable {
    struct LotCfg {
        uint256 num;     // numérateur (taille de lot)
        uint256 den;     // dénominateur (taille de lot)
        bool    listed;  // actif listé ou non
        uint8   market;  // ID du marché auquel appartient l’actif
    }

    // ----------------------------
    // Storage
    // ----------------------------
    mapping(uint32 => LotCfg) public asset;      // assetId → lot config
    mapping(uint8 => bool) public marketOpen;    // marketId → ouvert/fermé
    mapping(uint8 => uint16) public spreadBps;   // marketId → spread (en bps)

    // ----------------------------
    // Event
    // ----------------------------
    event MarketStatus(uint8 indexed marketId, bool isOpen);

    constructor(address initialOwner) Ownable(initialOwner) {}

    // ----------------------------
    // Admin Functions
    // ----------------------------

    /// @notice Ajoute un actif et le relie à un marché
    function addAsset(uint32 assetId, uint8 marketId, uint256 num, uint256 den) external onlyOwner {
        require(num > 0 && den > 0, "BAD_LOT");
        asset[assetId] = LotCfg({ num: num, den: den, listed: true, market: marketId });
    }

    /// @notice Met à jour la taille du lot d’un actif
    function setLot(uint32 assetId, uint256 num, uint256 den) external onlyOwner {
        require(num > 0 && den > 0, "BAD_LOT");
        LotCfg storage a = asset[assetId];
        require(a.listed, "ASSET_UNKNOWN");
        a.num = num;
        a.den = den;
    }

    /// @notice Change le marché d’un actif
    function setMarket(uint32 assetId, uint8 marketId) external onlyOwner {
        LotCfg storage a = asset[assetId];
        require(a.listed, "ASSET_UNKNOWN");
        a.market = marketId;
    }

    /// @notice Active ou désactive un marché
    function setMarketOpen(uint8 marketId, bool isOpen) external onlyOwner {
        marketOpen[marketId] = isOpen;
        emit MarketStatus(marketId, isOpen);
    }

    /// @notice Définit le spread (en bps) pour un marché donné
    function setSpread(uint8 marketId, uint16 bps) external onlyOwner {
        spreadBps[marketId] = bps;
    }

    // ----------------------------
    // Views
    // ----------------------------

    /// @notice Retourne le numérateur et le dénominateur du lot d’un actif
    function getLot(uint32 assetId) external view returns (uint256 num, uint256 den) {
        LotCfg memory a = asset[assetId];
        require(a.listed, "ASSET_UNKNOWN");
        return (a.num, a.den);
    }

    /// @notice Retourne le marché associé à un actif
    function getMarket(uint32 assetId) external view returns (uint8) {
        LotCfg memory a = asset[assetId];
        require(a.listed, "ASSET_UNKNOWN");
        return a.market;
    }

    /// @notice Indique si le marché d’un actif est ouvert
    function isMarketOpen(uint32 assetId) external view returns (bool) {
        LotCfg memory a = asset[assetId];
        require(a.listed, "ASSET_UNKNOWN");
        return marketOpen[a.market];
    }

    /// @notice Retourne le spread (en bps) du marché d’un actif
    function getSpread(uint32 assetId) external view returns (uint16) {
        LotCfg memory a = asset[assetId];
        require(a.listed, "ASSET_UNKNOWN");
        return spreadBps[a.market];
    }
}
