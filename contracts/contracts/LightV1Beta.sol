// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title LightV1Beta
 * @dev Upgradeable proxy contract for crypto on/off-ramping with manual admin approval
 * @notice This contract handles escrow for off-ramping and minting/transfer for on-ramping
 */
contract LightV1Beta is 
    Initializable, 
    UUPSUpgradeable, 
    OwnableUpgradeable, 
    PausableUpgradeable, 
    ReentrancyGuardUpgradeable 
{
    using SafeERC20 for IERC20;

    // Admin role structure
    struct Admin {
        address wallet;
        string name;
        string description;
        bool isActive;
        bool canUpgrade; // New: Permission to upgrade contract
        uint256 addedTimestamp;
        address addedBy;
    }

    // Transaction status enum
    enum TransactionStatus { 
        PENDING, 
        APPROVED, 
        COMPLETED, 
        CANCELLED, 
        EXPIRED 
    }

    // Transaction type enum
    enum TransactionType { 
        ON_RAMP,    // Fiat to Crypto
        OFF_RAMP    // Crypto to Fiat
    }

    // Transaction structure
    struct Transaction {
        bytes32 txId;
        address user;
        address token;
        uint256 amount;
        uint256 fiatAmount;
        string currency; // "UGX", "KES", etc.
        TransactionType txType;
        TransactionStatus status;
        uint256 timestamp;
        uint256 expiryTime;
        string referenceId; // External payment reference
    }

    // State variables
    mapping(bytes32 => Transaction) public transactions;
    mapping(address => bytes32[]) public userTransactions;
    mapping(address => bool) public supportedTokens;
    mapping(address => uint256) public tokenBalances; // Contract's token reserves
    
    // Admin management
    mapping(address => Admin) public admins;
    address[] public adminList;
    mapping(address => bool) public isAdmin;
    bool public allowAdminUpgrades; // Global setting to allow/disallow admin upgrades
    
    bytes32[] public allTransactionIds;
    address public treasury; // Where fees are collected
    uint256 public transactionExpiry; // Default 30 minutes
    uint256 public minAmount; // Minimum transaction amount
    uint256 public maxAmount; // Maximum transaction amount per transaction
    uint256 public dailyLimit; // Daily limit per user
    mapping(address => mapping(uint256 => uint256)) public dailySpent; // user => day => amount
    
    // ETH support
    address public constant ETH_ADDRESS = address(0); // Use address(0) to represent ETH
    uint256 public ethBalance; // Contract's ETH reserves

    // Events
    event TransactionCreated(
        bytes32 indexed txId,
        address indexed user,
        TransactionType txType,
        address token,
        uint256 amount,
        uint256 fiatAmount,
        string currency
    );
    
    event TransactionApproved(bytes32 indexed txId, address indexed admin);
    event TransactionCompleted(bytes32 indexed txId);
    event TransactionCancelled(bytes32 indexed txId, string reason);
    event FundsDeposited(address indexed token, uint256 amount, address indexed depositor);
    event FundsWithdrawn(address indexed token, uint256 amount, address indexed recipient);
    event TokenSupportUpdated(address indexed token, bool supported);
    event AdminAdded(address indexed admin, string name, address indexed addedBy);
    event AdminRemoved(address indexed admin, address indexed removedBy);
    event AdminUpdated(address indexed admin, string name, string description);
    event UpgradePermissionChanged(address indexed admin, bool canUpgrade, address indexed changedBy);
    event AdminUpgradeSettingChanged(bool allowAdminUpgrades, address indexed changedBy);
    
    // Modifiers
    modifier validTransaction(bytes32 _txId) {
        require(transactions[_txId].txId != bytes32(0), "Transaction does not exist");
        require(transactions[_txId].status == TransactionStatus.PENDING, "Transaction not pending");
        require(block.timestamp <= transactions[_txId].expiryTime, "Transaction expired");
        _;
    }

    modifier onlyValidToken(address _token) {
        require(_token == ETH_ADDRESS || supportedTokens[_token], "Token not supported");
        _;
    }

    modifier onlyAdmin() {
        require(isAdmin[msg.sender] || msg.sender == owner(), "Only admin or owner");
        _;
    }

    modifier onlyActiveAdmin() {
        require(
            (isAdmin[msg.sender] && admins[msg.sender].isActive) || msg.sender == owner(), 
            "Only active admin or owner"
        );
        _;
    }

    modifier onlyUpgradeAuthorized() {
        require(
            msg.sender == owner() || 
            (allowAdminUpgrades && isAdmin[msg.sender] && admins[msg.sender].isActive && admins[msg.sender].canUpgrade),
            "Not authorized to upgrade contract"
        );
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initialize the contract (replaces constructor for upgradeable contracts)
     */
    function initialize(
        address _treasury,
        uint256 _transactionExpiry,
        uint256 _minAmount,
        uint256 _maxAmount,
        uint256 _dailyLimit,
        bool _allowAdminUpgrades
    ) public initializer {
        __Ownable_init(msg.sender);
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        treasury = _treasury;
        transactionExpiry = _transactionExpiry;
        minAmount = _minAmount;
        maxAmount = _maxAmount;
        dailyLimit = _dailyLimit;
        supportedTokens[ETH_ADDRESS] = true; // ETH supported by default
        allowAdminUpgrades = _allowAdminUpgrades;
        
        // Add owner as first admin with upgrade permissions
        _addAdmin(msg.sender, "Contract Owner", "Initial contract deployer with full permissions", true);
    }

    /**
     * @dev Required by UUPSUpgradeable - only authorized users can upgrade
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyUpgradeAuthorized {}

    /**
     * @dev Add a new admin (only owner can add admins)
     */
    function addAdmin(
        address _adminWallet, 
        string calldata _name, 
        string calldata _description,
        bool _canUpgrade
    ) external onlyOwner {
        require(_adminWallet != address(0), "Invalid admin address");
        require(!isAdmin[_adminWallet], "Already an admin");
        require(bytes(_name).length > 0, "Name cannot be empty");
        
        _addAdmin(_adminWallet, _name, _description, _canUpgrade);
    }

    /**
     * @dev Internal function to add admin
     */
    function _addAdmin(
        address _adminWallet, 
        string memory _name, 
        string memory _description, 
        bool _canUpgrade
    ) internal {
        admins[_adminWallet] = Admin({
            wallet: _adminWallet,
            name: _name,
            description: _description,
            isActive: true,
            canUpgrade: _canUpgrade,
            addedTimestamp: block.timestamp,
            addedBy: msg.sender
        });
        
        isAdmin[_adminWallet] = true;
        adminList.push(_adminWallet);
        
        emit AdminAdded(_adminWallet, _name, msg.sender);
    }

    /**
     * @dev Remove an admin (only owner can remove)
     */
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

    /**
     * @dev Update admin details (only owner or the admin themselves)
     */
    function updateAdmin(
        address _adminWallet,
        string calldata _name,
        string calldata _description
    ) external {
        require(isAdmin[_adminWallet], "Not an admin");
        require(
            msg.sender == owner() || msg.sender == _adminWallet,
            "Only owner or admin themselves can update"
        );
        require(bytes(_name).length > 0, "Name cannot be empty");
        
        admins[_adminWallet].name = _name;
        admins[_adminWallet].description = _description;
        
        emit AdminUpdated(_adminWallet, _name, _description);
    }

    /**
     * @dev Set admin upgrade permission (only owner)
     */
    function setAdminUpgradePermission(address _adminWallet, bool _canUpgrade) external onlyOwner {
        require(isAdmin[_adminWallet], "Not an admin");
        
        admins[_adminWallet].canUpgrade = _canUpgrade;
        
        emit UpgradePermissionChanged(_adminWallet, _canUpgrade, msg.sender);
    }

    /**
     * @dev Enable/disable admin upgrades globally (only owner)
     */
    function setAllowAdminUpgrades(bool _allowAdminUpgrades) external onlyOwner {
        allowAdminUpgrades = _allowAdminUpgrades;
        
        emit AdminUpgradeSettingChanged(_allowAdminUpgrades, msg.sender);
    }

    /**
     * @dev Deactivate/reactivate admin (only owner)
     */
    function setAdminStatus(address _adminWallet, bool _isActive) external onlyOwner {
        require(isAdmin[_adminWallet], "Not an admin");
        require(_adminWallet != owner(), "Cannot deactivate contract owner");
        
        admins[_adminWallet].isActive = _isActive;
    }

    /**
     * @dev Add or remove token support (admin function)
     */
    function setSupportedToken(address _token, bool _supported) external onlyActiveAdmin {
        supportedTokens[_token] = _supported;
        emit TokenSupportUpdated(_token, _supported);
    }

    /**
     * @dev Update transaction limits and parameters (admin function)
     */
    function updateLimits(
        uint256 _minAmount,
        uint256 _maxAmount,
        uint256 _dailyLimit,
        uint256 _transactionExpiry
    ) external onlyActiveAdmin {
        minAmount = _minAmount;
        maxAmount = _maxAmount;
        dailyLimit = _dailyLimit;
        transactionExpiry = _transactionExpiry;
    }

    /**
     * @dev Create off-ramp transaction (Crypto to Fiat)
     * User sends crypto to contract, admin releases fiat via MoMo
     * Currency and reference ID stored on-chain, mobile money numbers off-chain
     */
    function createOffRampTransaction(
        address _token,
        uint256 _amount,
        uint256 _fiatAmount,
        string calldata _currency
    ) external payable whenNotPaused onlyValidToken(_token) nonReentrant returns (bytes32) {
        require(_amount >= minAmount && _amount <= maxAmount, "Amount out of limits");
        require(_checkDailyLimit(msg.sender, _fiatAmount), "Daily limit exceeded");
        
        // Generate unique transaction ID
        bytes32 txId = keccak256(abi.encodePacked(
            msg.sender, 
            _token, 
            _amount, 
            block.timestamp, 
            block.number
        ));
        
        // Transfer tokens from user to contract (escrow)
        if (_token == ETH_ADDRESS) {
            require(msg.value == _amount, "ETH amount mismatch");
            ethBalance += _amount;
        } else {
            require(msg.value == 0, "ETH not expected for token transfer");
            IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
        }
        
        // Create transaction record
        transactions[txId] = Transaction({
            txId: txId,
            user: msg.sender,
            token: _token,
            amount: _amount,
            fiatAmount: _fiatAmount,
            currency: _currency,
            txType: TransactionType.OFF_RAMP,
            status: TransactionStatus.PENDING,
            timestamp: block.timestamp,
            expiryTime: block.timestamp + transactionExpiry,
            referenceId: ""
        });
        
        userTransactions[msg.sender].push(txId);
        allTransactionIds.push(txId);
        _updateDailySpent(msg.sender, _fiatAmount);
        
        emit TransactionCreated(txId, msg.sender, TransactionType.OFF_RAMP, _token, _amount, _fiatAmount, _currency);
        
        return txId;
    }

    /**
     * @dev Create on-ramp transaction (Fiat to Crypto)
     * User pays fiat via MoMo, admin releases crypto from contract
     * Currency and reference ID stored on-chain, mobile money numbers off-chain
     */
    function createOnRampTransaction(
        address _token,
        uint256 _amount,
        uint256 _fiatAmount,
        string calldata _currency,
        string calldata _referenceId
    ) external whenNotPaused onlyValidToken(_token) nonReentrant returns (bytes32) {
        require(_amount >= minAmount && _amount <= maxAmount, "Amount out of limits");
        require(_checkDailyLimit(msg.sender, _fiatAmount), "Daily limit exceeded");
        require(_token == ETH_ADDRESS || tokenBalances[_token] >= _amount, "Insufficient contract balance");
        require(_token != ETH_ADDRESS || ethBalance >= _amount, "Insufficient ETH balance");
        
        bytes32 txId = keccak256(abi.encodePacked(
            msg.sender, 
            _token, 
            _amount, 
            _referenceId,
            block.timestamp
        ));
        
        transactions[txId] = Transaction({
            txId: txId,
            user: msg.sender,
            token: _token,
            amount: _amount,
            fiatAmount: _fiatAmount,
            currency: _currency,
            txType: TransactionType.ON_RAMP,
            status: TransactionStatus.PENDING,
            timestamp: block.timestamp,
            expiryTime: block.timestamp + transactionExpiry,
            referenceId: _referenceId
        });
        
        userTransactions[msg.sender].push(txId);
        allTransactionIds.push(txId);
        _updateDailySpent(msg.sender, _fiatAmount);
        
        emit TransactionCreated(txId, msg.sender, TransactionType.ON_RAMP, _token, _amount, _fiatAmount, _currency);
        
        return txId;
    }

    /**
     * @dev Admin approves transaction after confirming fiat payment (admin function)
     */
    function approveTransaction(bytes32 _txId) external onlyActiveAdmin validTransaction(_txId) {
        transactions[_txId].status = TransactionStatus.APPROVED;
        emit TransactionApproved(_txId, msg.sender);
    }

    /**
     * @dev Complete approved transaction and transfer funds (admin function)
     */
    function completeTransaction(bytes32 _txId) external onlyActiveAdmin nonReentrant {
        Transaction storage txn = transactions[_txId];
        require(txn.txId != bytes32(0), "Transaction does not exist");
        require(txn.status == TransactionStatus.APPROVED, "Transaction not approved");
        
        if (txn.txType == TransactionType.ON_RAMP) {
            // Release crypto to user
            if (txn.token == ETH_ADDRESS) {
                ethBalance -= txn.amount;
                (bool success, ) = payable(txn.user).call{value: txn.amount}("");
                require(success, "ETH transfer failed");
            } else {
                tokenBalances[txn.token] -= txn.amount;
                IERC20(txn.token).safeTransfer(txn.user, txn.amount);
            }
        }
        // For OFF_RAMP, crypto is already in escrow, admin handles fiat transfer externally
        
        txn.status = TransactionStatus.COMPLETED;
        emit TransactionCompleted(_txId);
    }

    /**
     * @dev Cancel transaction and refund if applicable (admin function)
     */
    function cancelTransaction(bytes32 _txId, string calldata _reason) external onlyActiveAdmin {
        Transaction storage txn = transactions[_txId];
        require(txn.txId != bytes32(0), "Transaction does not exist");
        require(txn.status == TransactionStatus.PENDING || txn.status == TransactionStatus.APPROVED, "Cannot cancel");
        
        if (txn.txType == TransactionType.OFF_RAMP && txn.status == TransactionStatus.PENDING) {
            // Refund escrowed crypto to user
            if (txn.token == ETH_ADDRESS) {
                ethBalance -= txn.amount;
                (bool success, ) = payable(txn.user).call{value: txn.amount}("");
                require(success, "ETH refund failed");
            } else {
                IERC20(txn.token).safeTransfer(txn.user, txn.amount);
            }
        }
        
        txn.status = TransactionStatus.CANCELLED;
        emit TransactionCancelled(_txId, _reason);
    }

    /**
     * @dev User can cancel their own pending transaction
     */
    function userCancelTransaction(bytes32 _txId) external validTransaction(_txId) {
        Transaction storage txn = transactions[_txId];
        require(txn.user == msg.sender, "Not your transaction");
        
        if (txn.txType == TransactionType.OFF_RAMP) {
            // Refund escrowed crypto
            if (txn.token == ETH_ADDRESS) {
                ethBalance -= txn.amount;
                (bool success, ) = payable(msg.sender).call{value: txn.amount}("");
                require(success, "ETH refund failed");
            } else {
                IERC20(txn.token).safeTransfer(msg.sender, txn.amount);
            }
        }
        
        txn.status = TransactionStatus.CANCELLED;
        emit TransactionCancelled(_txId, "User cancelled");
    }

    /**
     * @dev Admin deposits tokens for on-ramp liquidity (admin function)
     */
    function depositTokens(address _token, uint256 _amount) external payable onlyActiveAdmin onlyValidToken(_token) {
        if (_token == ETH_ADDRESS) {
            require(msg.value == _amount, "ETH amount mismatch");
            ethBalance += _amount;
        } else {
            require(msg.value == 0, "ETH not expected for token deposit");
            IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
            tokenBalances[_token] += _amount;
        }
        emit FundsDeposited(_token, _amount, msg.sender);
    }

    /**
     * @dev Admin withdraws tokens (for liquidity management) (admin function)
     */
    function withdrawTokens(address _token, uint256 _amount, address _recipient) external onlyActiveAdmin {
        if (_token == ETH_ADDRESS) {
            require(ethBalance >= _amount, "Insufficient ETH balance");
            ethBalance -= _amount;
            (bool success, ) = payable(_recipient).call{value: _amount}("");
            require(success, "ETH withdrawal failed");
        } else {
            require(tokenBalances[_token] >= _amount, "Insufficient balance");
            tokenBalances[_token] -= _amount;
            IERC20(_token).safeTransfer(_recipient, _amount);
        }
        emit FundsWithdrawn(_token, _amount, _recipient);
    }

    /**
     * @dev Emergency withdrawal of all funds (only owner for security)
     */
    function emergencyWithdraw(address _token) external onlyOwner {
        if (_token == ETH_ADDRESS) {
            uint256 balance = ethBalance;
            ethBalance = 0;
            (bool success, ) = payable(treasury).call{value: balance}("");
            require(success, "Emergency ETH withdrawal failed");
            emit FundsWithdrawn(_token, balance, treasury);
        } else {
            uint256 balance = IERC20(_token).balanceOf(address(this));
            IERC20(_token).safeTransfer(treasury, balance);
            tokenBalances[_token] = 0;
            emit FundsWithdrawn(_token, balance, treasury);
        }
    }

    /**
     * @dev Clean up expired transactions
     */
    function expireTransaction(bytes32 _txId) external {
        Transaction storage txn = transactions[_txId];
        require(txn.txId != bytes32(0), "Transaction does not exist");
        require(txn.status == TransactionStatus.PENDING, "Transaction not pending");
        require(block.timestamp > txn.expiryTime, "Transaction not expired");
        
        if (txn.txType == TransactionType.OFF_RAMP) {
            // Refund escrowed crypto
            if (txn.token == ETH_ADDRESS) {
                ethBalance -= txn.amount;
                (bool success, ) = payable(txn.user).call{value: txn.amount}("");
                require(success, "ETH refund failed");
            } else {
                IERC20(txn.token).safeTransfer(txn.user, txn.amount);
            }
        }
        
        txn.status = TransactionStatus.EXPIRED;
        emit TransactionCancelled(_txId, "Expired");
    }

    // Internal helper functions
    function _checkDailyLimit(address _user, uint256 _amount) internal view returns (bool) {
        uint256 today = block.timestamp / 86400; // Current day
        return dailySpent[_user][today] + _amount <= dailyLimit;
    }

    function _updateDailySpent(address _user, uint256 _amount) internal {
        uint256 today = block.timestamp / 86400;
        dailySpent[_user][today] += _amount;
    }

    // View functions
    function getTransaction(bytes32 _txId) external view returns (Transaction memory) {
        return transactions[_txId];
    }

    function getUserTransactions(address _user) external view returns (bytes32[] memory) {
        return userTransactions[_user];
    }

    function getAllTransactionIds() external view returns (bytes32[] memory) {
        return allTransactionIds;
    }

    function getUserDailySpent(address _user) external view returns (uint256) {
        uint256 today = block.timestamp / 86400;
        return dailySpent[_user][today];
    }

    function getContractBalance(address _token) external view returns (uint256) {
        if (_token == ETH_ADDRESS) {
            return ethBalance;
        }
        return tokenBalances[_token];
    }

    /**
     * @dev Get admin details
     */
    function getAdmin(address _adminWallet) external view returns (Admin memory) {
        require(isAdmin[_adminWallet], "Not an admin");
        return admins[_adminWallet];
    }

    /**
     * @dev Get all admin addresses
     */
    function getAllAdmins() external view returns (address[] memory) {
        return adminList;
    }

    /**
     * @dev Get all active admin addresses
     */
    function getActiveAdmins() external view returns (address[] memory) {
        uint256 activeCount = 0;
        
        // Count active admins
        for (uint256 i = 0; i < adminList.length; i++) {
            if (admins[adminList[i]].isActive) {
                activeCount++;
            }
        }
        
        // Create array of active admins
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

    /**
     * @dev Check if address is an active admin
     */
    function isActiveAdmin(address _wallet) external view returns (bool) {
        return isAdmin[_wallet] && admins[_wallet].isActive;
    }

    /**
     * @dev Check if address can upgrade contract
     */
    function canUpgradeContract(address _wallet) external view returns (bool) {
        return _wallet == owner() || 
               (allowAdminUpgrades && isAdmin[_wallet] && admins[_wallet].isActive && admins[_wallet].canUpgrade);
    }

    /**
     * @dev Get all admin addresses with upgrade permissions
     */
    function getUpgradeAuthorizedAdmins() external view returns (address[] memory) {
        uint256 upgradeCount = 0;
        
        // Count admins with upgrade permissions
        for (uint256 i = 0; i < adminList.length; i++) {
            if (admins[adminList[i]].isActive && admins[adminList[i]].canUpgrade) {
                upgradeCount++;
            }
        }
        
        // Create array of upgrade-authorized admins
        address[] memory upgradeAdmins = new address[](upgradeCount);
        uint256 index = 0;
        
        for (uint256 i = 0; i < adminList.length; i++) {
            if (admins[adminList[i]].isActive && admins[adminList[i]].canUpgrade) {
                upgradeAdmins[index] = adminList[i];
                index++;
            }
        }
        
        return upgradeAdmins;
    }

    // Admin functions
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
     * @dev Get contract version
     */
    function version() external pure returns (string memory) {
        return "1.0.0";
    }
}