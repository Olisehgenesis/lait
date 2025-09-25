// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title LaitV2
 * @dev Upgradeable escrow contract for crypto buy/sell orders with fee system
 * @notice Buy Orders: Users deposit crypto to buy fiat
 * @notice Sell Orders: Users sell crypto for fiat (admin pays fiat, gets crypto)
 */
contract LaitV2 is 
    Initializable,
    OwnableUpgradeable, 
    PausableUpgradeable, 
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    // Admin role structure
    struct Admin {
        address wallet;
        string name;
        bool isActive;
        uint256 addedTimestamp;
        address addedBy;
        uint256 ordersFilled;
        uint256 totalVolume;
    }

    // Order status enum
    enum OrderStatus { 
        PENDING,    // Order created
        FILLED,     // Order filled by admin
        REFUNDED,   // Order refunded
        EXPIRED     // Order expired (auto-refund)
    }

    // Order type enum
    enum OrderType {
        BUY,    // User buys fiat with crypto
        SELL    // User sells crypto for fiat
    }

    // Buy order structure
    struct BuyOrder {
        bytes32 orderId;
        address user;
        address paymentToken;      // Token user is paying with
        uint256 paymentAmount;     // Amount of payment token
        string targetCurrency;     // Fiat currency to receive
        uint256 targetAmount;      // Amount of fiat currency
        string orderMetadata;      // Payment method, contact info, etc.
        OrderStatus status;
        uint256 createdAt;
        uint256 minRefundTime;
        address filledBy;
        uint256 filledAt;
        string notes;
        bool metadataUpdated;      // Track if metadata has been updated
    }

    // Sell order structure
    struct SellOrder {
        bytes32 orderId;
        address user;
        address sellToken;         // Token user wants to sell
        uint256 sellAmount;        // Amount user wants to sell
        string sourceCurrency;     // Fiat currency user will pay
        uint256 sourceAmount;      // Amount of fiat user will pay
        string orderMetadata;      // Payment method, contact info, etc.
        OrderStatus status;
        uint256 createdAt;
        uint256 minRefundTime;
        address filledBy;
        uint256 filledAt;
        string notes;
        bool metadataUpdated;      // Track if metadata has been updated
    }

    // Exchange rate structure
    struct ExchangeRate {
        uint256 rate;              // Rate in smallest unit (e.g., 3700000 = 3700.000)
        uint256 decimals;          // Decimals for rate (e.g., 3 for 3 decimals)
        uint256 lastUpdated;
        bool isActive;
    }

    // Fee configuration
    struct FeeConfig {
        uint256 buyFeePercent;     // Basis points (100 = 1%)
        uint256 sellFeePercent;    // Basis points (100 = 1%)
        uint256 minFeeAmount;      // Minimum fee
        uint256 maxFeeAmount;      // Maximum fee
    }

    // State variables
    mapping(bytes32 => BuyOrder) public buyOrders;
    mapping(bytes32 => SellOrder) public sellOrders;
    mapping(address => bytes32[]) public userBuyOrders;
    mapping(address => bytes32[]) public userSellOrders;
    mapping(address => bool) public supportedTokens;
    
    // Admin management
    mapping(address => Admin) public admins;
    address[] public adminList;
    mapping(address => bool) public isAdmin;
    
    // Order tracking
    bytes32[] public allBuyOrderIds;
    bytes32[] public allSellOrderIds;
    bytes32[] public pendingBuyOrderIds;
    bytes32[] public pendingSellOrderIds;
    
    // Exchange rates: token => currency => rate
    mapping(address => mapping(string => ExchangeRate)) public exchangeRates;
    
    // Fee configuration per token
    mapping(address => FeeConfig) public tokenFees;
    
    // Treasury and fee tracking
    address public treasury;
    mapping(address => uint256) public collectedFees;
    
    // Order limits
    mapping(address => uint256) public minOrderAmount;
    mapping(address => uint256) public maxOrderAmount;
    
    address public constant ETH_ADDRESS = address(0);
    uint256 public constant MIN_REFUND_TIME = 2 hours;
    uint256 public constant BASIS_POINTS = 10000; // 100% = 10000 basis points
    
    // Escrow balances
    mapping(address => uint256) public escrowedBalances;
    uint256 public escrowedEthBalance;

    // Events
    event BuyOrderCreated(
        bytes32 indexed orderId,
        address indexed user,
        address paymentToken,
        uint256 paymentAmount,
        string targetCurrency,
        uint256 targetAmount
    );
    
    event SellOrderCreated(
        bytes32 indexed orderId,
        address indexed user,
        address sellToken,
        uint256 sellAmount,
        string sourceCurrency,
        uint256 sourceAmount
    );
    
    event BuyOrderFilled(bytes32 indexed orderId, address indexed admin, uint256 feeAmount);
    event SellOrderFilled(bytes32 indexed orderId, address indexed admin, uint256 feeAmount);
    event OrderRefunded(bytes32 indexed orderId, OrderType orderType, string reason);
    event OrderExpired(bytes32 indexed orderId, OrderType orderType);
    
    event ExchangeRateUpdated(address indexed token, string currency, uint256 rate);
    event FeeConfigUpdated(address indexed token, uint256 buyFee, uint256 sellFee);
    event FeesCollected(address indexed token, address indexed to, uint256 amount);
    
    event AdminAdded(address indexed admin, string name);
    event AdminRemoved(address indexed admin);
    event AdminUpdated(address indexed admin, string name);
    event TokenSupportUpdated(address indexed token, bool supported);

    // Modifiers
    modifier onlyActiveAdmin() {
        require(
            (isAdmin[msg.sender] && admins[msg.sender].isActive) || msg.sender == owner(), 
            "Only active admin"
        );
        _;
    }

    modifier validToken(address _token) {
        require(_token == ETH_ADDRESS || supportedTokens[_token], "Token not supported");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _treasury) public initializer {
        __Ownable_init(msg.sender);
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        treasury = _treasury;
        supportedTokens[ETH_ADDRESS] = true;
        
        // Add owner as first admin
        _addAdmin(msg.sender, "Contract Owner");
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // ===================
    // ADMIN MANAGEMENT
    // ===================

    function addAdmin(address _adminWallet, string calldata _name) external onlyOwner {
        require(_adminWallet != address(0), "Invalid address");
        require(!isAdmin[_adminWallet], "Already admin");
        require(bytes(_name).length > 0, "Name required");
        
        _addAdmin(_adminWallet, _name);
    }

    function _addAdmin(address _adminWallet, string memory _name) internal {
        admins[_adminWallet] = Admin({
            wallet: _adminWallet,
            name: _name,
            isActive: true,
            addedTimestamp: block.timestamp,
            addedBy: msg.sender,
            ordersFilled: 0,
            totalVolume: 0
        });
        
        isAdmin[_adminWallet] = true;
        adminList.push(_adminWallet);
        
        emit AdminAdded(_adminWallet, _name);
    }

    function removeAdmin(address _adminWallet) external onlyOwner {
        require(isAdmin[_adminWallet], "Not an admin");
        require(_adminWallet != owner(), "Cannot remove owner");
        
        admins[_adminWallet].isActive = false;
        isAdmin[_adminWallet] = false;
        
        for (uint256 i = 0; i < adminList.length; i++) {
            if (adminList[i] == _adminWallet) {
                adminList[i] = adminList[adminList.length - 1];
                adminList.pop();
                break;
            }
        }
        
        emit AdminRemoved(_adminWallet);
    }

    function updateAdmin(address _adminWallet, string calldata _name) external onlyOwner {
        require(isAdmin[_adminWallet], "Not an admin");
        admins[_adminWallet].name = _name;
        emit AdminUpdated(_adminWallet, _name);
    }

    function setAdminStatus(address _adminWallet, bool _isActive) external onlyOwner {
        require(isAdmin[_adminWallet], "Not an admin");
        admins[_adminWallet].isActive = _isActive;
    }

    // ===================
    // TOKEN & RATE MANAGEMENT
    // ===================

    function setSupportedToken(address _token, bool _supported) external onlyActiveAdmin {
        supportedTokens[_token] = _supported;
        emit TokenSupportUpdated(_token, _supported);
    }

    function setExchangeRate(
        address _token,
        string calldata _currency,
        uint256 _rate,
        uint256 _decimals
    ) external onlyActiveAdmin {
        require(_rate > 0, "Rate must be > 0");
        
        exchangeRates[_token][_currency] = ExchangeRate({
            rate: _rate,
            decimals: _decimals,
            lastUpdated: block.timestamp,
            isActive: true
        });
        
        emit ExchangeRateUpdated(_token, _currency, _rate);
    }

    function setFeeConfig(
        address _token,
        uint256 _buyFeePercent,
        uint256 _sellFeePercent,
        uint256 _minFee,
        uint256 _maxFee
    ) external onlyActiveAdmin {
        require(_buyFeePercent <= 1000, "Buy fee too high"); // Max 10%
        require(_sellFeePercent <= 1000, "Sell fee too high"); // Max 10%
        
        tokenFees[_token] = FeeConfig({
            buyFeePercent: _buyFeePercent,
            sellFeePercent: _sellFeePercent,
            minFeeAmount: _minFee,
            maxFeeAmount: _maxFee
        });
        
        emit FeeConfigUpdated(_token, _buyFeePercent, _sellFeePercent);
    }

    function setOrderLimits(
        address _token,
        uint256 _minAmount,
        uint256 _maxAmount
    ) external onlyActiveAdmin {
        require(_maxAmount > _minAmount, "Invalid limits");
        minOrderAmount[_token] = _minAmount;
        maxOrderAmount[_token] = _maxAmount;
    }

    // ===================
    // BUY ORDER SYSTEM
    // ===================

    function createBuyOrder(
        address _paymentToken,
        uint256 _paymentAmount,
        string calldata _targetCurrency,
        uint256 _targetAmount,
        string calldata _orderMetadata
    ) external payable whenNotPaused validToken(_paymentToken) nonReentrant returns (bytes32) {
        require(_paymentAmount > 0, "Amount must be > 0");
        require(_targetAmount > 0, "Target amount must be > 0");
        require(bytes(_targetCurrency).length > 0, "Currency required");
        
        // Check order limits
        if (minOrderAmount[_paymentToken] > 0) {
            require(_paymentAmount >= minOrderAmount[_paymentToken], "Below min amount");
        }
        if (maxOrderAmount[_paymentToken] > 0) {
            require(_paymentAmount <= maxOrderAmount[_paymentToken], "Above max amount");
        }
        
        bytes32 orderId = keccak256(abi.encodePacked(
            msg.sender,
            _paymentToken,
            _paymentAmount,
            block.timestamp,
            block.number,
            "BUY"
        ));
        
        // Transfer payment to escrow
        if (_paymentToken == ETH_ADDRESS) {
            require(msg.value == _paymentAmount, "ETH mismatch");
            escrowedEthBalance += _paymentAmount;
        } else {
            require(msg.value == 0, "No ETH expected");
            IERC20(_paymentToken).safeTransferFrom(msg.sender, address(this), _paymentAmount);
            escrowedBalances[_paymentToken] += _paymentAmount;
        }
        
        buyOrders[orderId] = BuyOrder({
            orderId: orderId,
            user: msg.sender,
            paymentToken: _paymentToken,
            paymentAmount: _paymentAmount,
            targetCurrency: _targetCurrency,
            targetAmount: _targetAmount,
            orderMetadata: _orderMetadata,
            status: OrderStatus.PENDING,
            createdAt: block.timestamp,
            minRefundTime: block.timestamp + MIN_REFUND_TIME,
            filledBy: address(0),
            filledAt: 0,
            notes: "",
            metadataUpdated: false
        });
        
        userBuyOrders[msg.sender].push(orderId);
        allBuyOrderIds.push(orderId);
        pendingBuyOrderIds.push(orderId);
        
        emit BuyOrderCreated(orderId, msg.sender, _paymentToken, _paymentAmount, _targetCurrency, _targetAmount);
        
        return orderId;
    }

    function fillBuyOrder(bytes32 _orderId, string calldata _notes) external onlyActiveAdmin nonReentrant {
        BuyOrder storage order = buyOrders[_orderId];
        require(order.orderId != bytes32(0), "Order not found");
        require(order.status == OrderStatus.PENDING, "Not pending");
        
        // Calculate fee
        uint256 feeAmount = _calculateFee(order.paymentToken, order.paymentAmount, true);
        uint256 amountToTreasury = order.paymentAmount - feeAmount;
        
        // Update order
        order.status = OrderStatus.FILLED;
        order.filledBy = msg.sender;
        order.filledAt = block.timestamp;
        order.notes = _notes;
        
        // Update admin stats
        admins[msg.sender].ordersFilled++;
        admins[msg.sender].totalVolume += order.paymentAmount;
        
        _removePendingBuyOrder(_orderId);
        
        // Transfer funds
        if (order.paymentToken == ETH_ADDRESS) {
            escrowedEthBalance -= order.paymentAmount;
            if (feeAmount > 0) collectedFees[ETH_ADDRESS] += feeAmount;
            
            (bool success, ) = payable(treasury).call{value: amountToTreasury}("");
            require(success, "ETH transfer failed");
        } else {
            escrowedBalances[order.paymentToken] -= order.paymentAmount;
            if (feeAmount > 0) collectedFees[order.paymentToken] += feeAmount;
            
            IERC20(order.paymentToken).safeTransfer(treasury, amountToTreasury);
        }
        
        emit BuyOrderFilled(_orderId, msg.sender, feeAmount);
    }

    // ===================
    // SELL ORDER SYSTEM
    // ===================

    function createSellOrder(
        address _sellToken,
        uint256 _sellAmount,
        string calldata _sourceCurrency,
        uint256 _sourceAmount,
        string calldata _orderMetadata
    ) external whenNotPaused validToken(_sellToken) nonReentrant returns (bytes32) {
        require(_sellAmount > 0, "Amount must be > 0");
        require(_sourceAmount > 0, "Source amount must be > 0");
        require(bytes(_sourceCurrency).length > 0, "Currency required");
        require(_sellToken != ETH_ADDRESS, "Cannot sell ETH"); // Users don't escrow for sell orders
        
        // Check order limits
        if (minOrderAmount[_sellToken] > 0) {
            require(_sellAmount >= minOrderAmount[_sellToken], "Below min amount");
        }
        if (maxOrderAmount[_sellToken] > 0) {
            require(_sellAmount <= maxOrderAmount[_sellToken], "Above max amount");
        }
        
        bytes32 orderId = keccak256(abi.encodePacked(
            msg.sender,
            _sellToken,
            _sellAmount,
            block.timestamp,
            block.number,
            "SELL"
        ));
        
        sellOrders[orderId] = SellOrder({
            orderId: orderId,
            user: msg.sender,
            sellToken: _sellToken,
            sellAmount: _sellAmount,
            sourceCurrency: _sourceCurrency,
            sourceAmount: _sourceAmount,
            orderMetadata: _orderMetadata,
            status: OrderStatus.PENDING,
            createdAt: block.timestamp,
            minRefundTime: block.timestamp + MIN_REFUND_TIME,
            filledBy: address(0),
            filledAt: 0,
            notes: "",
            metadataUpdated: false
        });
        
        userSellOrders[msg.sender].push(orderId);
        allSellOrderIds.push(orderId);
        pendingSellOrderIds.push(orderId);
        
        emit SellOrderCreated(orderId, msg.sender, _sellToken, _sellAmount, _sourceCurrency, _sourceAmount);
        
        return orderId;
    }

    function fillSellOrder(bytes32 _orderId, string calldata _notes) external onlyActiveAdmin nonReentrant {
        SellOrder storage order = sellOrders[_orderId];
        require(order.orderId != bytes32(0), "Order not found");
        require(order.status == OrderStatus.PENDING, "Not pending");
        
        // Calculate fee
        uint256 feeAmount = _calculateFee(order.sellToken, order.sellAmount, false);
        uint256 amountToTreasury = order.sellAmount - feeAmount;
        
        // Update order
        order.status = OrderStatus.FILLED;
        order.filledBy = msg.sender;
        order.filledAt = block.timestamp;
        order.notes = _notes;
        
        // Update admin stats
        admins[msg.sender].ordersFilled++;
        admins[msg.sender].totalVolume += order.sellAmount;
        
        _removePendingSellOrder(_orderId);
        
        // Transfer tokens from user to treasury (admin already paid fiat)
        if (feeAmount > 0) collectedFees[order.sellToken] += feeAmount;
        
        IERC20(order.sellToken).safeTransferFrom(order.user, treasury, amountToTreasury);
        if (feeAmount > 0) {
            IERC20(order.sellToken).safeTransferFrom(order.user, address(this), feeAmount);
        }
        
        emit SellOrderFilled(_orderId, msg.sender, feeAmount);
    }

    // ===================
    // REFUND SYSTEM
    // ===================

    function refundBuyOrder(bytes32 _orderId, string calldata _reason) external onlyActiveAdmin nonReentrant {
        BuyOrder storage order = buyOrders[_orderId];
        require(order.orderId != bytes32(0), "Order not found");
        require(order.status == OrderStatus.PENDING, "Not pending");
        require(block.timestamp >= order.minRefundTime, "Too early");
        
        order.status = OrderStatus.REFUNDED;
        order.notes = _reason;
        
        _removePendingBuyOrder(_orderId);
        
        // Refund escrow
        if (order.paymentToken == ETH_ADDRESS) {
            escrowedEthBalance -= order.paymentAmount;
            (bool success, ) = payable(order.user).call{value: order.paymentAmount}("");
            require(success, "Refund failed");
        } else {
            escrowedBalances[order.paymentToken] -= order.paymentAmount;
            IERC20(order.paymentToken).safeTransfer(order.user, order.paymentAmount);
        }
        
        emit OrderRefunded(_orderId, OrderType.BUY, _reason);
    }

    function cancelSellOrder(bytes32 _orderId) external nonReentrant {
        SellOrder storage order = sellOrders[_orderId];
        require(order.orderId != bytes32(0), "Order not found");
        require(order.user == msg.sender, "Not your order");
        require(order.status == OrderStatus.PENDING, "Not pending");
        
        order.status = OrderStatus.REFUNDED;
        order.notes = "User cancelled";
        
        _removePendingSellOrder(_orderId);
        
        emit OrderRefunded(_orderId, OrderType.SELL, "User cancelled");
    }

    function requestBuyRefund(bytes32 _orderId) external nonReentrant {
        BuyOrder storage order = buyOrders[_orderId];
        require(order.orderId != bytes32(0), "Order not found");
        require(order.user == msg.sender, "Not your order");
        require(order.status == OrderStatus.PENDING, "Not pending");
        require(block.timestamp >= order.minRefundTime, "Too early");
        
        order.status = OrderStatus.REFUNDED;
        order.notes = "User requested refund";
        
        _removePendingBuyOrder(_orderId);
        
        if (order.paymentToken == ETH_ADDRESS) {
            escrowedEthBalance -= order.paymentAmount;
            (bool success, ) = payable(msg.sender).call{value: order.paymentAmount}("");
            require(success, "Refund failed");
        } else {
            escrowedBalances[order.paymentToken] -= order.paymentAmount;
            IERC20(order.paymentToken).safeTransfer(msg.sender, order.paymentAmount);
        }
        
        emit OrderRefunded(_orderId, OrderType.BUY, "User requested refund");
    }

    // ===================
    // FEE MANAGEMENT
    // ===================

    function _calculateFee(address _token, uint256 _amount, bool _isBuyOrder) internal view returns (uint256) {
        FeeConfig memory config = tokenFees[_token];
        if (config.buyFeePercent == 0 && config.sellFeePercent == 0) return 0;
        
        uint256 feePercent = _isBuyOrder ? config.buyFeePercent : config.sellFeePercent;
        uint256 fee = (_amount * feePercent) / BASIS_POINTS;
        
        if (config.minFeeAmount > 0 && fee < config.minFeeAmount) {
            fee = config.minFeeAmount;
        }
        if (config.maxFeeAmount > 0 && fee > config.maxFeeAmount) {
            fee = config.maxFeeAmount;
        }
        
        return fee;
    }

    function withdrawFees(address _token, address _to) external onlyOwner nonReentrant {
        uint256 amount = collectedFees[_token];
        require(amount > 0, "No fees");
        
        collectedFees[_token] = 0;
        
        if (_token == ETH_ADDRESS) {
            (bool success, ) = payable(_to).call{value: amount}("");
            require(success, "Transfer failed");
        } else {
            IERC20(_token).safeTransfer(_to, amount);
        }
        
        emit FeesCollected(_token, _to, amount);
    }

    // ===================
    // INTERNAL HELPERS
    // ===================

    function _removePendingBuyOrder(bytes32 _orderId) internal {
        for (uint256 i = 0; i < pendingBuyOrderIds.length; i++) {
            if (pendingBuyOrderIds[i] == _orderId) {
                pendingBuyOrderIds[i] = pendingBuyOrderIds[pendingBuyOrderIds.length - 1];
                pendingBuyOrderIds.pop();
                break;
            }
        }
    }

    function _removePendingSellOrder(bytes32 _orderId) internal {
        for (uint256 i = 0; i < pendingSellOrderIds.length; i++) {
            if (pendingSellOrderIds[i] == _orderId) {
                pendingSellOrderIds[i] = pendingSellOrderIds[pendingSellOrderIds.length - 1];
                pendingSellOrderIds.pop();
                break;
            }
        }
    }

    // ===================
    // VIEW FUNCTIONS
    // ===================

    function getBuyOrder(bytes32 _orderId) external view returns (BuyOrder memory) {
        return buyOrders[_orderId];
    }

    function getSellOrder(bytes32 _orderId) external view returns (SellOrder memory) {
        return sellOrders[_orderId];
    }

    function getUserBuyOrders(address _user) external view returns (bytes32[] memory) {
        return userBuyOrders[_user];
    }

    function getUserSellOrders(address _user) external view returns (bytes32[] memory) {
        return userSellOrders[_user];
    }

    function getPendingBuyOrders() external view returns (bytes32[] memory) {
        return pendingBuyOrderIds;
    }

    function getPendingSellOrders() external view returns (bytes32[] memory) {
        return pendingSellOrderIds;
    }

    function getExchangeRate(address _token, string calldata _currency) external view returns (ExchangeRate memory) {
        return exchangeRates[_token][_currency];
    }

    function getAdmin(address _wallet) external view returns (Admin memory) {
        return admins[_wallet];
    }

    function getAllAdmins() external view returns (address[] memory) {
        return adminList;
    }

    function getCollectedFees(address _token) external view returns (uint256) {
        return collectedFees[_token];
    }

    // ===================
    // EMERGENCY FUNCTIONS
    // ===================

    function pause() external onlyActiveAdmin {
        _pause();
    }

    function unpause() external onlyActiveAdmin {
        _unpause();
    }

    function updateTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "Invalid treasury");
        treasury = _treasury;
    }

    function emergencyWithdraw(address _token) external onlyOwner {
        if (_token == ETH_ADDRESS) {
            uint256 balance = address(this).balance;
            (bool success, ) = payable(treasury).call{value: balance}("");
            require(success, "Transfer failed");
        } else {
            uint256 balance = IERC20(_token).balanceOf(address(this));
            IERC20(_token).safeTransfer(treasury, balance);
        }
    }

    receive() external payable {}

    /**
     * @dev Storage gap for future upgrades
     */
    uint256[50] private __gap;
}