// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title LaitUSD
 * @dev Mock USD stablecoin with 6 decimals and owner-only minting
 */
contract LaitUSD is ERC20, Ownable {
    constructor(address initialOwner) ERC20("Lait USD", "lUSD") Ownable(initialOwner) {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}


