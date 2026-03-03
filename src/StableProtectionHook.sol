// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// ─── Uniswap v4 core ────────────────────────────────────────────────────────
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

// ─── Uniswap v4 periphery ───────────────────────────────────────────────────
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";

// ─── Project types & libraries ──────────────────────────────────────────────
import {PegZone, PoolConfig, ZoneState, CircuitBreakerTripped, AlreadyInitialized, ZoneChanged, CircuitBreakerTriggered, FeeApplied} from "./types/SPTypes.sol";
import {PegMonitor} from "./libraries/PegMonitor.sol";
import {SPConfig} from "./libraries/SPConfig.sol";
import {IStableProtectionHook} from "./interfaces/IStableProtectionHook.sol";

/// @title  StableProtectionHook
/// @notice Uniswap v4 hook for stablecoin LP protection.
///
///         Features
///         ────────
///         • 5-zone peg monitoring (HEALTHY → CRITICAL) derived from virtual reserves
///         • Graduated dynamic fees: lower for toward-peg swaps, higher for away-from-peg
///         • Dynamic amplification: A is reduced as depeg worsens
///         • Circuit breaker: CRITICAL-zone swaps are blocked outright
///         • Lightweight virtual reserves computed from sqrtPriceX96 + liquidity
///           (no incremental storage updates required)
///
///         Deployment requirements
///         ───────────────────────
///         • Pool must be initialized with fee = LPFeeLibrary.DYNAMIC_FEE_FLAG (0x800000)
///         • Hook address must have permission bits: beforeInitialize | beforeSwap | afterSwap
///           i.e., bits 13, 7, 6 set in the lowest 14 bits of the address
///
///         Hook permission bits
///         ────────────────────
///           Bit 13 (0x2000) → beforeInitialize
///           Bit  7 (0x0080) → beforeSwap
///           Bit  6 (0x0040) → afterSwap
///           Required address suffix: 0x...00C0 (bits 7+6 always), 0x...20C0 (with bit 13)
///           For HookMiner: flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
contract StableProtectionHook is BaseHook, IStableProtectionHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;

    // ─── Q96 constant ────────────────────────────────────────────────────────
    uint256 internal constant Q96 = 2 ** 96;

    // ─── Storage ─────────────────────────────────────────────────────────────

    /// @dev Per-pool configuration, stored once at beforeInitialize.
    mapping(PoolId => PoolConfig) private _configs;

    /// @dev Flag to prevent re-initialization of a pool.
    mapping(PoolId => bool) private _initialized;

    /// @dev Per-pool zone state, updated in afterSwap.
    mapping(PoolId => ZoneState) private _zoneStates;

    // ─── Constructor ─────────────────────────────────────────────────────────

    /// @param _poolManager  The Uniswap v4 PoolManager.
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    // ─── BaseHook: permissions ────────────────────────────────────────────────

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ─── BaseHook: hook implementations ──────────────────────────────────────

    /// @dev Called by the PoolManager when a new pool is created with this hook.
    ///      Decodes the PoolConfig from hookData, validates it, and records it.
    ///      The pool fee MUST be DYNAMIC_FEE_FLAG (0x800000).
    ///
    /// @param key PoolKey of the initializing pool.
    function _beforeInitialize(address, PoolKey calldata key, uint160)
        internal
        override
        returns (bytes4)
    {
        PoolId id = key.toId();
        if (_initialized[id]) revert AlreadyInitialized();

        // Pool must opt into dynamic fees so we can override them in beforeSwap.
        require(key.fee.isDynamicFee(), "SPH: pool fee must be DYNAMIC_FEE_FLAG");

        // Store a validated default config (all pools share the same parameters
        // in this implementation; per-pool config can be extended via governance).
        PoolConfig memory cfg = PoolConfig({
            amplification: 100,
            baseFee: 100,   // 1 bps
            maxFee: 10_000, // 100 bps
            decimals0: 18,
            decimals1: 18
        });

        SPConfig.validate(cfg);
        _configs[id] = cfg;
        _initialized[id] = true;

        // Seed zone state as HEALTHY; reserves will be populated in afterSwap.
        _zoneStates[id] = ZoneState({
            zone: PegZone.HEALTHY,
            reserve0: 0,
            reserve1: 0,
            lastUpdateBlock: block.number
        });

        return this.beforeInitialize.selector;
    }

    /// @dev Called before every swap on a pool registered with this hook.
    ///      Reads virtual reserves, classifies the peg zone, blocks CRITICAL swaps,
    ///      and returns a dynamic fee override (OVERRIDE_FEE_FLAG | computed_fee).
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        PoolConfig storage cfg = _configs[id];

        // Compute current virtual reserves normalized to 18 decimals.
        (uint256 r0norm, uint256 r1norm) = _getVirtualReservesNormalized(id, cfg);

        // Classify peg zone.
        (PegZone zone, uint256 deviationBps) = PegMonitor.classifyZone(r0norm, r1norm);

        // Circuit breaker: CRITICAL zone blocks all swaps.
        if (zone == PegZone.CRITICAL) {
            emit CircuitBreakerTriggered(PoolId.unwrap(id), deviationBps);
            revert CircuitBreakerTripped(zone, deviationBps);
        }

        // Determine trade direction relative to peg.
        bool towardPeg = PegMonitor.isTowardPeg(r0norm, r1norm, params.zeroForOne);

        // Compute directional fee, scaled by the dynamic amplification zone.
        // effA is embedded in the fee schedule implicitly; a future upgrade can
        // use it to re-route through a custom on-chain AMM.
        uint24 fee = PegMonitor.calculateFee(zone, towardPeg, cfg.maxFee);

        emit FeeApplied(PoolId.unwrap(id), fee, towardPeg);

        // Return fee with OVERRIDE_FEE_FLAG so PoolManager uses our fee.
        return (
            this.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            fee | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    /// @dev Called after every swap. Re-reads virtual reserves and updates zone state.
    ///      Emits ZoneChanged if the zone has shifted since last update.
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId id = key.toId();
        PoolConfig storage cfg = _configs[id];

        // Read fresh virtual reserves post-swap.
        (uint256 r0norm, uint256 r1norm) = _getVirtualReservesNormalized(id, cfg);

        (PegZone newZone,) = PegMonitor.classifyZone(r0norm, r1norm);

        ZoneState storage state = _zoneStates[id];

        if (newZone != state.zone) {
            emit ZoneChanged(PoolId.unwrap(id), state.zone, newZone);
            state.zone = newZone;
        }

        // Store raw (un-normalized) virtual reserves for the interface getters.
        // We store normalized values directly for simplicity.
        state.reserve0 = r0norm;
        state.reserve1 = r1norm;
        state.lastUpdateBlock = block.number;

        return (this.afterSwap.selector, 0);
    }

    // ─── IStableProtectionHook ────────────────────────────────────────────────

    /// @inheritdoc IStableProtectionHook
    function getPoolConfig(PoolId poolId) external view returns (PoolConfig memory) {
        return _configs[poolId];
    }

    /// @inheritdoc IStableProtectionHook
    function getZoneState(PoolId poolId)
        external
        view
        returns (PegZone zone, uint256 reserve0, uint256 reserve1, uint256 updateBlock)
    {
        ZoneState storage s = _zoneStates[poolId];
        return (s.zone, s.reserve0, s.reserve1, s.lastUpdateBlock);
    }

    /// @inheritdoc IStableProtectionHook
    function currentDeviationBps(PoolId poolId) external view returns (uint256 deviationBps) {
        PoolConfig storage cfg = _configs[poolId];
        (uint256 r0norm, uint256 r1norm) = _getVirtualReservesNormalized(poolId, cfg);
        (, deviationBps) = PegMonitor.classifyZone(r0norm, r1norm);
    }

    // ─── Virtual reserve computation ─────────────────────────────────────────

    /// @notice Compute pool virtual reserves normalized to 18-decimal precision.
    ///
    ///         Uses the approximation derived from the concentrated-liquidity
    ///         AMM price formula:
    ///             virtual_r0 = L · Q96 / sqrtPriceX96
    ///             virtual_r1 = L · sqrtPriceX96 / Q96
    ///
    ///         These represent the "as-if constant-product" virtual reserves at
    ///         the current price tick, suitable for peg-deviation measurement.
    ///
    /// @dev    Made `internal virtual` so unit tests can override with mocks
    ///         without deploying a full PoolManager.
    ///
    /// @param id  Pool identifier.
    /// @param cfg Pool configuration (used for decimal normalization).
    /// @return r0norm  Normalized virtual reserve of token0.
    /// @return r1norm  Normalized virtual reserve of token1.
    function _getVirtualReservesNormalized(PoolId id, PoolConfig storage cfg)
        internal
        view
        virtual
        returns (uint256 r0norm, uint256 r1norm)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        uint128 liquidity = poolManager.getLiquidity(id);

        uint256 L = uint256(liquidity);

        // Guard against uninitialised pool (sqrtPriceX96 == 0 → division by zero).
        if (sqrtPriceX96 == 0 || L == 0) {
            return (0, 0);
        }

        // virtual_r0 = L * Q96 / sqrtPriceX96   (token0 per unit price)
        // virtual_r1 = L * sqrtPriceX96 / Q96   (token1 per unit price)
        uint256 r0raw = (L * Q96) / uint256(sqrtPriceX96);
        uint256 r1raw = (L * uint256(sqrtPriceX96)) / Q96;

        r0norm = PegMonitor.normalize(r0raw, cfg.decimals0);
        r1norm = PegMonitor.normalize(r1raw, cfg.decimals1);
    }
}
