// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolConfig, InvalidConfiguration} from "../types/SPTypes.sol";

/// @title  SPConfig
/// @notice Validation library for PoolConfig parameters.
///         All checks are pure; call validate() once at pool initialization.
library SPConfig {
    uint256 internal constant MIN_A   = 1;
    uint256 internal constant MAX_A   = 1000;
    /// @dev 10000 ppm = 100 bps = 1%; hard ceiling on any fee the hook can set.
    uint24  internal constant MAX_FEE = 10_000;

    /// @notice Validate a PoolConfig.  Reverts with InvalidConfiguration on
    ///         the first violated invariant.
    ///
    ///         Rules:
    ///           1. amplification  ∈ [1, 1000]
    ///           2. baseFee        ≤  maxFee
    ///           3. maxFee         ≤  10000 ppm  (100 bps)
    ///           4. decimals0, decimals1 ∈ [1, 18]
    function validate(PoolConfig memory cfg) internal pure {
        if (cfg.amplification < MIN_A || cfg.amplification > MAX_A) {
            revert InvalidConfiguration("amplification must be 1-1000");
        }
        if (cfg.baseFee > cfg.maxFee) {
            revert InvalidConfiguration("baseFee exceeds maxFee");
        }
        if (cfg.maxFee > MAX_FEE) {
            revert InvalidConfiguration("maxFee exceeds 100 bps");
        }
        if (cfg.decimals0 == 0 || cfg.decimals0 > 18) {
            revert InvalidConfiguration("decimals0 must be 1-18");
        }
        if (cfg.decimals1 == 0 || cfg.decimals1 > 18) {
            revert InvalidConfiguration("decimals1 must be 1-18");
        }
    }

    /// @notice Decode a PoolConfig from raw bytes (passed as hookData at init).
    ///         Reverts if decoding produces an invalid config.
    function decode(bytes calldata data) internal pure returns (PoolConfig memory cfg) {
        cfg = abi.decode(data, (PoolConfig));
        validate(cfg);
    }
}
