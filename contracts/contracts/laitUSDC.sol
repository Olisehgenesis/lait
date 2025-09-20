// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title laitUSDC
 * @dev An upgradeable, mintable, burnable, pausable ERC20 token with access control
 * @notice This contract can be upgraded using UUPS (Universal Upgradeable Proxy Standard)
 */
contract laitUSDC is 
    Initializable,
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    ERC20PausableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    // Role definitions
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    
    // Token configuration
    uint256 public maxSupply;
    uint256 public mintingFee; // Fee in basis points (e.g., 100 = 1%)
    address public feeRecipient;
    
    // Events
    event MintingFeeUpdated(uint256 oldFee, uint256 newFee);
    event FeeRecipientUpdated(address oldRecipient, address newRecipient);
    event MaxSupplyUpdated(uint256 oldMaxSupply, uint256 newMaxSupply);
    event TokensMinted(address indexed to, uint256 amount, uint256 fee);
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    /**
     * @dev Initialize the contract
     * @param name Token name
     * @param symbol Token symbol
     * @param initialSupply Initial token supply
     * @param _maxSupply Maximum token supply
     * @param _mintingFee Minting fee in basis points
     * @param _feeRecipient Address to receive minting fees
     * @param admin Admin address for role management
     */
    function initialize(
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        uint256 _maxSupply,
        uint256 _mintingFee,
        address _feeRecipient,
        address admin
    ) public initializer {
        __ERC20_init(name, symbol);
        __ERC20Burnable_init();
        __ERC20Pausable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        
        maxSupply = _maxSupply;
        mintingFee = _mintingFee;
        feeRecipient = _feeRecipient;
        
        // Set up roles
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        
        // Mint initial supply
        if (initialSupply > 0) {
            _mint(admin, initialSupply);
        }
    }
    
    /**
     * @dev Mint tokens to a specified address
     * @param to Address to mint tokens to
     * @param amount Amount of tokens to mint
     */
    function mint(address to, uint256 amount) 
        public 
        onlyRole(MINTER_ROLE) 
        whenNotPaused 
        nonReentrant 
    {
        require(to != address(0), "laitUSDC: mint to zero address");
        require(amount > 0, "laitUSDC: amount must be greater than 0");
        require(totalSupply() + amount <= maxSupply, "laitUSDC: exceeds max supply");
        
        _mint(to, amount);
        emit TokensMinted(to, amount, 0);
    }
    
    /**
     * @dev Mint tokens with fee
     * @param to Address to mint tokens to
     * @param amount Amount of tokens to mint
     * @param feeAmount Fee amount to be paid
     */
    function mintWithFee(address to, uint256 amount, uint256 feeAmount) 
        public 
        onlyRole(MINTER_ROLE) 
        whenNotPaused 
        nonReentrant 
    {
        require(to != address(0), "laitUSDC: mint to zero address");
        require(amount > 0, "laitUSDC: amount must be greater than 0");
        require(totalSupply() + amount <= maxSupply, "laitUSDC: exceeds max supply");
        require(feeAmount <= amount, "laitUSDC: fee cannot exceed amount");
        
        _mint(to, amount);
        if (feeAmount > 0 && feeRecipient != address(0)) {
            _mint(feeRecipient, feeAmount);
        }
        
        emit TokensMinted(to, amount, feeAmount);
    }
    
    /**
     * @dev Batch mint tokens to multiple addresses
     * @param recipients Array of recipient addresses
     * @param amounts Array of amounts to mint
     */
    function batchMint(address[] calldata recipients, uint256[] calldata amounts) 
        external 
        onlyRole(MINTER_ROLE) 
        whenNotPaused 
        nonReentrant 
    {
        require(recipients.length == amounts.length, "laitUSDC: arrays length mismatch");
        require(recipients.length > 0, "laitUSDC: empty arrays");
        
        uint256 totalAmount = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            totalAmount += amounts[i];
        }
        
        require(totalSupply() + totalAmount <= maxSupply, "laitUSDC: exceeds max supply");
        
        for (uint256 i = 0; i < recipients.length; i++) {
            require(recipients[i] != address(0), "laitUSDC: mint to zero address");
            require(amounts[i] > 0, "laitUSDC: amount must be greater than 0");
            _mint(recipients[i], amounts[i]);
            emit TokensMinted(recipients[i], amounts[i], 0);
        }
    }
    
    /**
     * @dev Pause token transfers
     */
    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
    }
    
    /**
     * @dev Unpause token transfers
     */
    function unpause() public onlyRole(PAUSER_ROLE) {
        _unpause();
    }
    
    /**
     * @dev Update minting fee
     * @param newFee New minting fee in basis points
     */
    function updateMintingFee(uint256 newFee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newFee <= 10000, "laitUSDC: fee cannot exceed 100%");
        uint256 oldFee = mintingFee;
        mintingFee = newFee;
        emit MintingFeeUpdated(oldFee, newFee);
    }
    
    /**
     * @dev Update fee recipient
     * @param newRecipient New fee recipient address
     */
    function updateFeeRecipient(address newRecipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newRecipient != address(0), "laitUSDC: zero address");
        address oldRecipient = feeRecipient;
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(oldRecipient, newRecipient);
    }
    
    /**
     * @dev Update maximum supply
     * @param newMaxSupply New maximum supply
     */
    function updateMaxSupply(uint256 newMaxSupply) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newMaxSupply >= totalSupply(), "laitUSDC: max supply too low");
        uint256 oldMaxSupply = maxSupply;
        maxSupply = newMaxSupply;
        emit MaxSupplyUpdated(oldMaxSupply, newMaxSupply);
    }
    
    /**
     * @dev Calculate minting fee for a given amount
     * @param amount Amount to calculate fee for
     * @return Fee amount
     */
    function calculateMintingFee(uint256 amount) public view returns (uint256) {
        return (amount * mintingFee) / 10000;
    }
    
    /**
     * @dev Get token information
     * @return tokenName Token name
     * @return tokenSymbol Token symbol
     * @return tokenDecimals Token decimals
     * @return tokenTotalSupply Current total supply
     * @return tokenMaxSupply Maximum supply
     * @return tokenMintingFee Current minting fee in basis points
     * @return tokenFeeRecipient Current fee recipient
     */
    function getTokenInfo() external view returns (
        string memory tokenName,
        string memory tokenSymbol,
        uint8 tokenDecimals,
        uint256 tokenTotalSupply,
        uint256 tokenMaxSupply,
        uint256 tokenMintingFee,
        address tokenFeeRecipient
    ) {
        return (
            name(),
            symbol(),
            decimals(),
            totalSupply(),
            maxSupply,
            mintingFee,
            feeRecipient
        );
    }
    
    /**
     * @dev Required override for ERC20Pausable
     */
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20Upgradeable, ERC20PausableUpgradeable) {
        super._update(from, to, value);
    }
    
    /**
     * @dev Authorize upgrade (only UPGRADER_ROLE can upgrade)
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
    
    /**
     * @dev Get contract version
     */
    function version() public pure returns (string memory) {
        return "1.0.0";
    }
}
