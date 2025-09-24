// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title LightV2
 * @dev Contract for crypto buy orders with escrow system
 * @notice Users create buy orders by depositing crypto, admins fill orders or process refunds
 */
contract LightV2 is 
    Ownable, 
    Pausable, 
    ReentrancyGuard 
{
    using SafeERC20 for IERC20;

    // Admin role structure
    struct Admin {
        address wallet;
        string name;
        bool isActive;
        uint256 addedTimestamp;
        address addedBy;
    }

    // Order status enum
    enum OrderStatus { 
        PENDING,    // Order created, crypto escrowed
        FILLED,     // Order filled by admin
        REFUNDED,   // Order refunded by admin
        EXPIRED     // Order expired (auto-refund after minimum time)
    }

    // Buy order structure
    struct BuyOrder {
        bytes32 orderId;
        address user;
        address paymentToken;      // Token user is paying with (USDT, ETH, etc.)
        uint256 paymentAmount;     // Amount of payment token
        string targetCurrency;     // What they want to buy ("UGX", "KES", etc.)
        uint256 targetAmount;      // Amount of target currency
        string orderMetadata;      // JSON metadata: payment method, contact info, service type, etc.
        OrderStatus status;
        uint256 createdAt;
        uint256 minRefundTime;     // Minimum time before refund allowed (2 hours)
        address filledBy;          // Admin who filled the order
        uint256 filledAt;
        string notes;              // Admin notes or transaction reference
    }

    // State variables
    mapping(bytes32 => BuyOrder) public orders;
    mapping(address => bytes32[]) public userOrders;
    mapping(address => bool) public supportedTokens;
    
    // Admin management
    mapping(address => Admin) public admins;
    address[] public adminList;
    mapping(address => bool) public isAdmin;
    
    bytes32[] public allOrderIds;
    bytes32[] public pendingOrderIds;
    address public treasury;
    uint256 public constant MIN_REFUND_TIME = 2 hours;
    
    // ETH support
    address public constant ETH_ADDRESS = address(0);
    
    // Token balances for tracking
    mapping(address => uint256) public escrrowedBalances;
    uint256 public escrrowedEthBalance;

    // Events
    event BuyOrderCreated(
        bytes32 indexed orderId,
        address indexed user,
        address paymentToken,
        uint256 paymentAmount,
        string targetCurrency,
        uint256 targetAmount,
        string orderMetadata
    );
    
    event OrderMetadataUpdated(
        bytes32 indexed orderId,
        address indexed user,
        string newMetadata
    );
    
    event OrderFilled(
        bytes32 indexed orderId,
        address indexed admin,
        string notes
    );
    
    event OrderRefunded(
        bytes32 indexed orderId,
        address indexed admin,
        string reason
    );
    
    event OrderExpired(bytes32 indexed orderId);
    
    event TokenSupportUpdated(address indexed token, bool supported);
    event AdminAdded(address indexed admin, string name, address indexed addedBy);
    event AdminRemoved(address indexed admin, address indexed removedBy);
    event AdminUpdated(address indexed admin, string name);
    
    // Modifiers
    modifier validOrder(bytes32 _orderId) {
        require(orders[_orderId].orderId != bytes32(0), "Order does not exist");
        _;
    }

    modifier onlyValidToken(address _token) {
        require(_token == ETH_ADDRESS || supportedTokens[_token], "Token not supported");
        _;
    }

    modifier onlyActiveAdmin() {
        require(
            (isAdmin[msg.sender] && admins[msg.sender].isActive) || msg.sender == owner(), 
            "Only active admin or owner"
        );
        _;
    }

    constructor(address _treasury) Ownable(msg.sender) {
        treasury = _treasury;
        supportedTokens[ETH_ADDRESS] = true; // ETH supported by default
        
        // Add owner as first admin
        _addAdmin(msg.sender, "Contract Owner");
    }

    // ===================
    // ADMIN MANAGEMENT
    // ===================

    function addAdmin(
        address _adminWallet, 
        string calldata _name
    ) external onlyOwner {
        require(_adminWallet != address(0), "Invalid admin address");
        require(!isAdmin[_adminWallet], "Already an admin");
        require(bytes(_name).length > 0, "Name cannot be empty");
        
        _addAdmin(_adminWallet, _name);
    }

    function _addAdmin(address _adminWallet, string memory _name) internal {
        admins[_adminWallet] = Admin({
            wallet: _adminWallet,
            name: _name,
            isActive: true,
            addedTimestamp: block.timestamp,
            addedBy: msg.sender
        });
        
        isAdmin[_adminWallet] = true;
        adminList.push(_adminWallet);
        
        emit AdminAdded(_adminWallet, _name, msg.sender);
    }

    function removeAdmin(address _adminWallet) external onlyOwner {
        require(isAdmin[_adminWallet], "Not an admin");
        require(_adminWallet != owner(), "Cannot remove contract owner");
        
        admins[_adminWallet].isActive = false;
        isAdmin[_adminWallet] = false;
        
        // Remove from adminList array
        for (uint256 i = 0; i < adminList.length; i++) {
            if (adminList[i] == _adminWallet) {
                adminList[i] = adminList[adminList.length - 1];
                adminList.pop();
                break;
            }
        }
        
        emit AdminRemoved(_adminWallet, msg.sender);
    }

    function updateAdmin(
        address _adminWallet,
        string calldata _name
    ) external onlyOwner {
        require(isAdmin[_adminWallet], "Not an admin");
        require(bytes(_name).length > 0, "Name cannot be empty");
        
        admins[_adminWallet].name = _name;
        emit AdminUpdated(_adminWallet, _name);
    }

    function setAdminStatus(address _adminWallet, bool _isActive) external onlyOwner {
        require(isAdmin[_adminWallet], "Not an admin");
        require(_adminWallet != owner(), "Cannot deactivate contract owner");
        admins[_adminWallet].isActive = _isActive;
    }

    // ===================
    // TOKEN MANAGEMENT
    // ===================

    function setSupportedToken(address _token, bool _supported) external onlyActiveAdmin {
        supportedTokens[_token] = _supported;
        emit TokenSupportUpdated(_token, _supported);
    }

    // ===================
    // BUY ORDER SYSTEM
    // ===================

    /**
     * @dev Create a buy order - user deposits crypto to buy fiat currency
     */
    function createBuyOrder(
        address _paymentToken,
        uint256 _paymentAmount,
        string calldata _targetCurrency,
        uint256 _targetAmount,
        string calldata _orderMetadata
    ) external payable whenNotPaused onlyValidToken(_paymentToken) nonReentrant returns (bytes32) {
        require(_paymentAmount > 0, "Payment amount must be greater than 0");
        require(_targetAmount > 0, "Target amount must be greater than 0");
        require(bytes(_targetCurrency).length > 0, "Target currency required");
        require(bytes(_orderMetadata).length > 0, "Order metadata required");
        
        // Generate unique order ID
        bytes32 orderId = keccak256(abi.encodePacked(
            msg.sender,
            _paymentToken,
            _paymentAmount,
            block.timestamp,
            block.number
        ));
        
        // Transfer payment token to contract (escrow)
        if (_paymentToken == ETH_ADDRESS) {
            require(msg.value == _paymentAmount, "ETH amount mismatch");
            escrrowedEthBalance += _paymentAmount;
        } else {
            require(msg.value == 0, "ETH not expected for token transfer");
            IERC20(_paymentToken).safeTransferFrom(msg.sender, address(this), _paymentAmount);
            escrrowedBalances[_paymentToken] += _paymentAmount;
        }
        
        // Create order
        orders[orderId] = BuyOrder({
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
            notes: ""
        });
        
        userOrders[msg.sender].push(orderId);
        allOrderIds.push(orderId);
        pendingOrderIds.push(orderId);
        
        emit BuyOrderCreated(
            orderId, 
            msg.sender, 
            _paymentToken, 
            _paymentAmount, 
            _targetCurrency, 
            _targetAmount, 
            _orderMetadata
        );
        
        return orderId;
    }

    /**
     * @dev Update order metadata (only by user, only before order is filled)
     */
    function updateOrderMetadata(
        bytes32 _orderId, 
        string calldata _newMetadata
    ) external validOrder(_orderId) {
        BuyOrder storage order = orders[_orderId];
        require(order.user == msg.sender, "Not your order");
        require(order.status == OrderStatus.PENDING, "Order not pending - cannot edit");
        require(bytes(_newMetadata).length > 0, "Metadata cannot be empty");
        
        order.orderMetadata = _newMetadata;
        
        emit OrderMetadataUpdated(_orderId, msg.sender, _newMetadata);
    }

    /**
     * @dev Admin fills a buy order (after sending fiat to user)
     */
    function fillOrder(
        bytes32 _orderId, 
        string calldata _notes
    ) external onlyActiveAdmin validOrder(_orderId) {
        BuyOrder storage order = orders[_orderId];
        require(order.status == OrderStatus.PENDING, "Order not pending");
        
        // Update order status
        order.status = OrderStatus.FILLED;
        order.filledBy = msg.sender;
        order.filledAt = block.timestamp;
        order.notes = _notes;
        
        // Remove from pending orders
        _removePendingOrder(_orderId);
        
        // Transfer escrowed funds to treasury
        if (order.paymentToken == ETH_ADDRESS) {
            escrrowedEthBalance -= order.paymentAmount;
            (bool success, ) = payable(treasury).call{value: order.paymentAmount}("");
            require(success, "ETH transfer to treasury failed");
        } else {
            escrrowedBalances[order.paymentToken] -= order.paymentAmount;
            IERC20(order.paymentToken).safeTransfer(treasury, order.paymentAmount);
        }
        
        emit OrderFilled(_orderId, msg.sender, _notes);
    }

    /**
     * @dev Admin refunds a buy order (returns crypto to user)
     */
    function refundOrder(
        bytes32 _orderId, 
        string calldata _reason
    ) external onlyActiveAdmin validOrder(_orderId) {
        BuyOrder storage order = orders[_orderId];
        require(order.status == OrderStatus.PENDING, "Order not pending");
        require(block.timestamp >= order.minRefundTime, "Minimum refund time not reached");
        
        // Update order status
        order.status = OrderStatus.REFUNDED;
        order.notes = _reason;
        
        // Remove from pending orders
        _removePendingOrder(_orderId);
        
        // Refund escrowed crypto to user
        if (order.paymentToken == ETH_ADDRESS) {
            escrrowedEthBalance -= order.paymentAmount;
            (bool success, ) = payable(order.user).call{value: order.paymentAmount}("");
            require(success, "ETH refund failed");
        } else {
            escrrowedBalances[order.paymentToken] -= order.paymentAmount;
            IERC20(order.paymentToken).safeTransfer(order.user, order.paymentAmount);
        }
        
        emit OrderRefunded(_orderId, msg.sender, _reason);
    }

    /**
     * @dev User can request refund for their own order (after minimum time)
     */
    function requestRefund(bytes32 _orderId) external validOrder(_orderId) {
        BuyOrder storage order = orders[_orderId];
        require(order.user == msg.sender, "Not your order");
        require(order.status == OrderStatus.PENDING, "Order not pending");
        require(block.timestamp >= order.minRefundTime, "Minimum refund time not reached");
        
        // Update order status
        order.status = OrderStatus.REFUNDED;
        order.notes = "User requested refund";
        
        // Remove from pending orders
        _removePendingOrder(_orderId);
        
        // Refund escrowed crypto to user
        if (order.paymentToken == ETH_ADDRESS) {
            escrrowedEthBalance -= order.paymentAmount;
            (bool success, ) = payable(msg.sender).call{value: order.paymentAmount}("");
            require(success, "ETH refund failed");
        } else {
            escrrowedBalances[order.paymentToken] -= order.paymentAmount;
            IERC20(order.paymentToken).safeTransfer(msg.sender, order.paymentAmount);
        }
        
        emit OrderRefunded(_orderId, msg.sender, "User requested refund");
    }

    /**
     * @dev Expire old orders automatically
     */
    function expireOrder(bytes32 _orderId) external validOrder(_orderId) {
        BuyOrder storage order = orders[_orderId];
        require(order.status == OrderStatus.PENDING, "Order not pending");
        require(block.timestamp >= order.minRefundTime + 24 hours, "Order not expired"); // 26 hours total
        
        // Update order status
        order.status = OrderStatus.EXPIRED;
        order.notes = "Order expired";
        
        // Remove from pending orders
        _removePendingOrder(_orderId);
        
        // Refund escrowed crypto to user
        if (order.paymentToken == ETH_ADDRESS) {
            escrrowedEthBalance -= order.paymentAmount;
            (bool success, ) = payable(order.user).call{value: order.paymentAmount}("");
            require(success, "ETH refund failed");
        } else {
            escrrowedBalances[order.paymentToken] -= order.paymentAmount;
            IERC20(order.paymentToken).safeTransfer(order.user, order.paymentAmount);
        }
        
        emit OrderExpired(_orderId);
    }

    // ===================
    // INTERNAL HELPERS
    // ===================

    function _removePendingOrder(bytes32 _orderId) internal {
        for (uint256 i = 0; i < pendingOrderIds.length; i++) {
            if (pendingOrderIds[i] == _orderId) {
                pendingOrderIds[i] = pendingOrderIds[pendingOrderIds.length - 1];
                pendingOrderIds.pop();
                break;
            }
        }
    }

    // ===================
    // VIEW FUNCTIONS
    // ===================

    function getOrder(bytes32 _orderId) external view returns (BuyOrder memory) {
        return orders[_orderId];
    }

    function getUserOrders(address _user) external view returns (bytes32[] memory) {
        return userOrders[_user];
    }

    function getAllOrderIds() external view returns (bytes32[] memory) {
        return allOrderIds;
    }

    function getPendingOrderIds() external view returns (bytes32[] memory) {
        return pendingOrderIds;
    }

    function getPendingOrdersCount() external view returns (uint256) {
        return pendingOrderIds.length;
    }

    function getEscrrowedBalance(address _token) external view returns (uint256) {
        if (_token == ETH_ADDRESS) {
            return escrrowedEthBalance;
        }
        return escrrowedBalances[_token];
    }

    function getAdmin(address _adminWallet) external view returns (Admin memory) {
        require(isAdmin[_adminWallet], "Not an admin");
        return admins[_adminWallet];
    }

    function getAllAdmins() external view returns (address[] memory) {
        return adminList;
    }

    function getActiveAdmins() external view returns (address[] memory) {
        uint256 activeCount = 0;
        
        for (uint256 i = 0; i < adminList.length; i++) {
            if (admins[adminList[i]].isActive) {
                activeCount++;
            }
        }
        
        address[] memory activeAdmins = new address[](activeCount);
        uint256 index = 0;
        
        for (uint256 i = 0; i < adminList.length; i++) {
            if (admins[adminList[i]].isActive) {
                activeAdmins[index] = adminList[i];
                index++;
            }
        }
        
        return activeAdmins;
    }

    function isActiveAdmin(address _wallet) external view returns (bool) {
        return isAdmin[_wallet] && admins[_wallet].isActive;
    }

    // ===================
    // EMERGENCY FUNCTIONS
    // ===================

    /**
     * @dev Emergency withdrawal (only owner)
     */
    function emergencyWithdraw(address _token) external onlyOwner {
        if (_token == ETH_ADDRESS) {
            uint256 balance = address(this).balance;
            (bool success, ) = payable(treasury).call{value: balance}("");
            require(success, "Emergency ETH withdrawal failed");
        } else {
            uint256 balance = IERC20(_token).balanceOf(address(this));
            IERC20(_token).safeTransfer(treasury, balance);
        }
    }

    function pause() external onlyActiveAdmin {
        _pause();
    }

    function unpause() external onlyActiveAdmin {
        _unpause();
    }

    function updateTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
    }

    /**
     * @dev Accept ETH deposits for gas or emergencies
     */
    receive() external payable {
        // Allow contract to receive ETH
    }
}