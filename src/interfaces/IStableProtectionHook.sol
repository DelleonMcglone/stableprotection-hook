// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolConfig} from "../types/SPTypes.sol";
import {PegZone} from "../types/SPTypes.sol";

/// @title  IStableProtectionHook
/// @notice External view interface for the StableProtectionHook contract.
///         Consumers (frontends, monitoring dashboards, partner integrations)
///         use these getters to inspect per-pool peg health without needing
///         to parse raw storage slots.
interface IStableProtectionHook {
    // ─── Pool configuration ─────────────────────────────────────────────────────

    /// @notice Returns the configuration stored for a pool at initialization.
    /// @param poolId The keccak256 hash of the PoolKey.
    /// @return cfg   The PoolConfig (amplification, fees, decimals).
    function getPoolConfig(PoolId poolId) external view returns (PoolConfig memory cfg);

    // ─── Zone / peg health ──────────────────────────────────────────────────────

    /// @notice Returns the last recorded peg-health state for a pool.
    /// @dev    Updated in afterSwap after every trade. May be stale between swaps.
    /// @param poolId     The keccak256 hash of the PoolKey.
    /// @return zone      Current peg zone.
    /// @return reserve0  Raw token0 virtual reserve at last update.
    /// @return reserve1  Raw token1 virtual reserve at last update.
    /// @return updateBlock Block number of the last zone update.
    function getZoneState(PoolId poolId)
        external
        view
        returns (PegZone zone, uint256 reserve0, uint256 reserve1, uint256 updateBlock);

    /// @notice Compute the current peg deviation (in basis points) live from
    ///         on-chain pool state.  Does NOT write to storage.
    /// @param poolId The keccak256 hash of the PoolKey.
    /// @return deviationBps Live peg deviation in basis points.
    function currentDeviationBps(PoolId poolId) external view returns (uint256 deviationBps);
}
