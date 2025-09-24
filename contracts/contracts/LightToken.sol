// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title LightToken
 * @dev Main Light token with 18 decimals and owner-only minting
 */
contract LightToken is ERC20, Ownable {
    constructor(address initialOwner) ERC20("Light Token", "LIGHT") Ownable(initialOwner) {}

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}


