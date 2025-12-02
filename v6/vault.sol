// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Brokex Vault (avec owner + proxy autorisé)
/// @notice Le proxy (contrat principal Brokex) est seul autorisé à lock/unlock/settle.
///         L’owner (caisse du protocole) dépose la liquidité et reçoit les PnL négatifs.
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

contract Vault {
    IERC20 public immutable token;
    address public immutable owner;

    // NEW: proxy autorisé (contrat Brokex/Trades)
    address public proxy;

    // Solde total détenu par chaque utilisateur
    mapping(address => uint256) public balance;
    // Montant bloqué (marge active sur positions)
    mapping(address => uint256) public locked;

    // Événements
    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event Locked(address indexed user, uint256 amount);
    event OwnerDeposit(uint256 amount);
    event OwnerWithdraw(uint256 amount);
    event ProxyUpdated(address indexed newProxy);

    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }

    modifier onlyProxy() {
        require(msg.sender == proxy, "NOT_PROXY");
        _;
    }

    constructor(address _token) {
        require(_token != address(0), "ZERO_ADDRESS");
        token = IERC20(_token);
        owner = msg.sender; // le déployeur = caisse principale
    }

    // ----------------------------
    // Admin (owner)
    // ----------------------------

    /// @notice Définit le contrat principal autorisé (Brokex/Trades)
    function setProxy(address _proxy) external onlyOwner {
        require(_proxy != address(0), "ZERO_PROXY");
        proxy = _proxy;
        emit ProxyUpdated(_proxy);
    }

    /// @notice Dépôt de liquidité par l’owner (caisse)
    function ownerDeposit(uint256 amount) external onlyOwner {
        require(amount > 0, "ZERO_AMOUNT");
        require(token.transferFrom(msg.sender, address(this), amount), "TRANSFER_FAILED");
        balance[owner] += amount;
        emit OwnerDeposit(amount);
    }

    /// @notice Retrait de liquidité de la caisse (si disponible)
    function ownerWithdraw(uint256 amount) external onlyOwner {
        require(amount > 0, "ZERO_AMOUNT");
        uint256 ownerFree = balance[owner] - locked[owner];
        require(amount <= ownerFree, "INSUFFICIENT_AVAILABLE");
        balance[owner] -= amount;
        require(token.transfer(owner, amount), "TRANSFER_FAILED");
        emit OwnerWithdraw(amount);
    }

    // ----------------------------
    // Utilisateurs
    // ----------------------------

    function deposit(uint256 amount) external {
        require(amount > 0, "ZERO_AMOUNT");
        require(token.transferFrom(msg.sender, address(this), amount), "TRANSFER_FAILED");
        balance[msg.sender] += amount;
        emit Deposit(msg.sender, amount);
    }

    function withdraw(uint256 amount) external {
        require(amount > 0, "ZERO_AMOUNT");
        uint256 free = balance[msg.sender] - locked[msg.sender];
        require(amount <= free, "INSUFFICIENT_AVAILABLE");
        balance[msg.sender] -= amount;
        require(token.transfer(msg.sender, amount), "TRANSFER_FAILED");
        emit Withdraw(msg.sender, amount);
    }

    // ----------------------------
    // Logique de trading (réservée au proxy)
    // ----------------------------

    /// @notice Bloque une partie des fonds d’un trader
    function lock(address user, uint256 amount) external onlyProxy {
        require(user != address(0), "BAD_USER");
        require(amount > 0, "ZERO_AMOUNT");
        require(balance[user] >= locked[user] + amount, "NOT_ENOUGH_FREE");
        locked[user] += amount;
        emit Locked(user, amount);
    }

    /// @notice Libère une partie de la marge (quand position se ferme)
    function unlock(address user, uint256 amount) external onlyProxy {
        require(user != address(0), "BAD_USER");
        require(amount > 0, "ZERO_AMOUNT");
        require(locked[user] >= amount, "NOT_LOCKED");
        locked[user] -= amount;
    }

    /// @notice Règle un gain ou une perte après la fermeture d'une position
    /// @dev Les gains traders sont payés par le solde owner ; les pertes traders sont créditées au solde owner.
    function settle(address user, int256 pnl) external onlyProxy {
        require(user != address(0), "BAD_USER");

        if (pnl > 0) {
            uint256 profit = uint256(pnl);
            uint256 ownerFree = balance[owner] - locked[owner];
            require(ownerFree >= profit, "OWNER_LIQUIDITY_LOW");
            balance[owner] -= profit;
            balance[user]  += profit;
        } else if (pnl < 0) {
            uint256 loss = uint256(-pnl);
            uint256 userBal = balance[user];
            require(userBal >= loss, "USER_FUNDS_LOW");
            balance[user]  = userBal - loss;
            balance[owner] += loss;
        }
        // pnl == 0 -> rien à faire
    }

    // ----------------------------
    // Views
    // ----------------------------

    function available(address user) external view returns (uint256) {
        uint256 bal = balance[user];
        uint256 l = locked[user];
        return l > bal ? 0 : bal - l;
    }

    function total(address user) external view returns (uint256) {
        return balance[user];
    }

    function vaultBalance() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    function ownerBalance() external view returns (uint256) {
        return balance[owner];
    }
}
