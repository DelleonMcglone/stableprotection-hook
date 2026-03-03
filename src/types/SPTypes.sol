// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// ─── Enums ─────────────────────────────────────────────────────────────────────

/// @notice Graduated peg health classification.
///         Thresholds are measured as |r0 - r1| * 10000 / avg in basis points.
enum PegZone {
    HEALTHY,   // deviation ≤ 0.10%  (≤  10 bps) → 1 bps base fee
    MINOR,     // deviation ≤ 0.50%  (≤  50 bps) → 5 bps base fee
    MODERATE,  // deviation ≤ 2.00%  (≤ 200 bps) → 15 bps base fee
    SEVERE,    // deviation ≤ 5.00%  (≤ 500 bps) → 50 bps base fee
    CRITICAL   // deviation >  5.00% (> 500 bps) → circuit breaker
}

// ─── Structs ───────────────────────────────────────────────────────────────────

/// @notice Immutable configuration stored at pool initialization.
struct PoolConfig {
    /// @dev StableSwap amplification coefficient (1–1000).
    ///      Higher A = flatter curve near peg; lower A = more slippage.
    uint256 amplification;
    /// @dev Base LP fee in ppm (hundredths of a basis point).
    ///      Example: 100 ppm = 1 bps = 0.01%.
    uint24 baseFee;
    /// @dev Hard cap on any computed fee, in ppm.
    ///      Example: 10000 ppm = 100 bps = 1%.
    uint24 maxFee;
    /// @dev Decimal places of token0 (1–18).
    uint8 decimals0;
    /// @dev Decimal places of token1 (1–18).
    uint8 decimals1;
}

/// @notice Mutable per-pool state snapshot updated after each swap.
struct ZoneState {
    /// @dev The current peg zone after the last swap.
    PegZone zone;
    /// @dev Raw reserve of token0 at the last snapshot.
    uint256 reserve0;
    /// @dev Raw reserve of token1 at the last snapshot.
    uint256 reserve1;
    /// @dev Block number when zone was last updated.
    uint256 lastUpdateBlock;
}

// ─── Errors ────────────────────────────────────────────────────────────────────

/// @notice Swap blocked: pool is in CRITICAL peg deviation.
/// @param zone        Current peg zone (always CRITICAL when thrown).
/// @param deviationBps Deviation in basis points that triggered the breaker.
error CircuitBreakerTripped(PegZone zone, uint256 deviationBps);

/// @notice A pool config value is outside its valid range.
/// @param reason Human-readable explanation of which invariant was violated.
error InvalidConfiguration(string reason);

/// @notice Caller is not the Uniswap v4 PoolManager.
error NotPoolManager();

/// @notice beforeInitialize was called a second time for the same pool.
error AlreadyInitialized();

// ─── Events ────────────────────────────────────────────────────────────────────

/// @notice Emitted when a pool transitions between peg zones.
/// @param poolId  Keccak256 hash of the PoolKey.
/// @param oldZone Zone before the transition.
/// @param newZone Zone after the transition.
event ZoneChanged(bytes32 indexed poolId, PegZone oldZone, PegZone newZone);

/// @notice Emitted when the circuit breaker prevents a swap.
/// @param poolId       Keccak256 hash of the PoolKey.
/// @param deviationBps Deviation in basis points at time of trigger.
event CircuitBreakerTriggered(bytes32 indexed poolId, uint256 deviationBps);

/// @notice Emitted each time a fee override is applied via beforeSwap.
/// @param poolId     Keccak256 hash of the PoolKey.
/// @param fee        Applied fee in ppm.
/// @param towardPeg  True if the swap pushes reserves toward parity.
event FeeApplied(bytes32 indexed poolId, uint24 fee, bool towardPeg);
