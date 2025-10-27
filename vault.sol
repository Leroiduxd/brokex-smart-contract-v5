// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

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

    // Solde total détenu par chaque utilisateur (marge traders)
    mapping(address => uint256) public balance;
    // Montant bloqué (marge active sur positions)
    mapping(address => uint256) public locked;

    // =========================
    // LP non-transférable
    // =========================
    // Total des parts LP en circulation (même unité que "shares", pas d’échelle 1e18)
    uint256 public lpTotalSupply;
    // Parts par investisseur
    mapping(address => uint256) private _lpBalances;
    // Actifs LP (NAV en tokens)
    uint256 public lpAssets;

    // Prix scale léger (1e6)
    uint256 private constant PRICE_SCALE = 1e6;

    // =========================
    // Owner fees (skim 30% sur pnl < 0)
    // =========================
    uint256 public ownerFees; // tokens “hors LP”, ne bouge pas le prix du LP

    // Événements existants
    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event Locked(address indexed user, uint256 amount);
    event OwnerDeposit(uint256 amount);
    event OwnerWithdraw(uint256 amount);
    event ProxyUpdated(address indexed newProxy);

    // Nouveaux événements LP
    event LpDeposit(address indexed investor, uint256 amountIn, uint256 sharesMinted, uint256 priceE6);
    event LpWithdraw(address indexed investor, uint256 sharesBurned, uint256 amountOut, uint256 priceE6);
    event LpPriceChange(uint256 oldPriceE6, uint256 newPriceE6);

    // Nouveaux événements Owner fees
    event OwnerFeesAccrued(uint256 amount);
    event OwnerFeesWithdrawn(uint256 amount);

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
        owner = msg.sender; // le déployeur = propriétaire du contrat (peut retirer les fees)
    }

    // ----------------------------
    // Admin (owner)
    // ----------------------------

    function setProxy(address _proxy) external onlyOwner {
        require(_proxy != address(0), "ZERO_PROXY");
        proxy = _proxy;
        emit ProxyUpdated(_proxy);
    }

    // ----------------------------
    // Utilisateurs (TRADERS) — inchangé
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
    // Logique de trading (réservée au proxy) — inchangé sauf settle()
    // ----------------------------

    function lock(address user, uint256 amount) external onlyProxy {
        require(user != address(0), "BAD_USER");
        require(amount > 0, "ZERO_AMOUNT");
        require(balance[user] >= locked[user] + amount, "NOT_ENOUGH_FREE");
        locked[user] += amount;
        emit Locked(user, amount);
    }

    function unlock(address user, uint256 amount) external onlyProxy {
        require(user != address(0), "BAD_USER");
        require(amount > 0, "ZERO_AMOUNT");
        require(locked[user] >= amount, "NOT_LOCKED");
        locked[user] -= amount;
    }

    /// @notice Règle un gain ou une perte après la fermeture d'une position
    /// @dev Seule fonction qui peut faire varier le prix du LP.
    ///      - pnl > 0 (trader gagne): payé **par le LP** (baisse du prix). AUCUN fee.
    ///      - pnl < 0 (trader perd): la perte est “gain LP”, on skim **30% vers ownerFees**,
    ///        et **70%** va réellement dans le LP (hausse du prix).
    function settle(address user, int256 pnl) external onlyProxy {
        require(user != address(0), "BAD_USER");

        uint256 oldPrice = _lpPriceE6();

        if (pnl > 0) {
            // Trader gagne → payer depuis LP
            uint256 profit = uint256(pnl);
            require(lpAssets >= profit, "LP_LIQUIDITY_LOW");

            lpAssets      -= profit;     // NAV LP baisse
            balance[user] += profit;     // crédite le trader (il pourra withdraw)
        } else if (pnl < 0) {
            // Trader perd → LP “gagne”
            uint256 loss = uint256(-pnl);

            // On retire la perte au trader (sur sa marge dispo)
            uint256 userBal = balance[user];
            require(userBal >= loss, "USER_FUNDS_LOW");
            balance[user] = userBal - loss;

            // Split 30% fees / 70% LP
            uint256 fee = (loss * 3000) / 10000;    // 30%
            uint256 lpGain = loss - fee;            // 70%

            ownerFees += fee;                       // pot propriétaire (hors NAV LP)
            emit OwnerFeesAccrued(fee);

            lpAssets  += lpGain;                    // NAV LP monte
        }
        // pnl == 0 → no-op

        uint256 newPrice = _lpPriceE6();
        if (newPrice != oldPrice) {
            emit LpPriceChange(oldPrice, newPrice);
        }
    }

    // ----------------------------
    // LP (investisseurs) — parts non transférables
    // ----------------------------

    /// @notice Dépôt dans le LP : mint de parts au prix courant. Ne bouge pas le prix.
    function depositLP(uint256 amount) external {
        require(amount > 0, "ZERO_AMOUNT");
        require(token.transferFrom(msg.sender, address(this), amount), "TRANSFER_FAILED");

        uint256 price = _lpPriceE6();
        if (lpTotalSupply == 0) {
            // Premier dépôt: on fixe le prix initial à 1.00
            price = PRICE_SCALE;
        }

        // shares = amount / price
        // price = assets * 1e6 / supply  → rearrange:
        // shares = amount * supply / assets  (mais on veut stabilité: mint pro-rata au prix courant)
        // Avec l'échelle 1e6: shares = amount * 1e6 / price
        uint256 shares = (amount * PRICE_SCALE) / price;
        require(shares > 0, "SHARES_ZERO");

        _lpBalances[msg.sender] += shares;
        lpTotalSupply           += shares;
        lpAssets                += amount;

        emit LpDeposit(msg.sender, amount, shares, price);
        // prix inchangé par construction
        emit LpPriceChange(price, price);
    }

    /// @notice Retrait du LP : burn de parts au prix courant. Ne bouge pas le prix.
    function redeemLP(uint256 shares) external {
        require(shares > 0, "ZERO_SHARES");
        require(_lpBalances[msg.sender] >= shares, "INSUFFICIENT_SHARES");
        require(lpTotalSupply > 0, "NO_LP_SUPPLY");

        uint256 price = _lpPriceE6();
        // amountOut = shares * price / 1e6
        uint256 amountOut = (shares * price) / PRICE_SCALE;
        require(amountOut > 0, "AMOUNT_ZERO");
        require(lpAssets >= amountOut, "LP_ASSETS_LOW");

        _lpBalances[msg.sender] -= shares;
        lpTotalSupply           -= shares;
        lpAssets                -= amountOut;

        require(token.transfer(msg.sender, amountOut), "TRANSFER_FAILED");

        emit LpWithdraw(msg.sender, shares, amountOut, price);
        // prix inchangé par construction
        emit LpPriceChange(price, price);
    }

    function lpBalanceOf(address investor) external view returns (uint256) {
        return _lpBalances[investor];
    }

    /// @notice Prix LP en 1e6 (1_000_000 = 1.00)
    function lpPriceE6() external view returns (uint256) {
        return _lpPriceE6();
    }

    function lpTotalAssets() external view returns (uint256) {
        return lpAssets;
    }

    // ----------------------------
    // Owner fees (hors LP)
    // ----------------------------

    function ownerFeesBalance() external view returns (uint256) {
        return ownerFees;
    }

    function withdrawOwnerFees(uint256 amount) external onlyOwner {
        require(amount > 0, "ZERO_AMOUNT");
        require(ownerFees >= amount, "INSUFFICIENT_FEES");
        ownerFees -= amount;
        require(token.transfer(owner, amount), "TRANSFER_FAILED");
        emit OwnerFeesWithdrawn(amount);
    }

    // ----------------------------
    // Views existants
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

    // ----------------------------
    // Internes
    // ----------------------------

    function _lpPriceE6() internal view returns (uint256) {
        if (lpTotalSupply == 0) return PRICE_SCALE; // 1.00 par défaut
        // price = assets * 1e6 / supply
        return (lpAssets * PRICE_SCALE) / lpTotalSupply;
    }
}
