// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @title  MockStablecoin
/// @notice Minimal ERC-20 used for Unichain Sepolia testnet deployments.
///         Anyone can mint (test only — never use in production).
contract MockStablecoin is ERC20 {
    constructor(string memory name_, string memory symbol_, uint8 decimals_)
        ERC20(name_, symbol_, decimals_)
    {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
