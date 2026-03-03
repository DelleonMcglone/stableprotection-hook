// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

// ─── v4-core types & libs ────────────────────────────────────────────────────
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";

// ─── v4-periphery ───────────────────────────────────────────────────────────
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";

// ─── Project ─────────────────────────────────────────────────────────────────
import {StableProtectionHook} from "../../src/StableProtectionHook.sol";
import {PegZone, PoolConfig, CircuitBreakerTripped, AlreadyInitialized, ZoneChanged, FeeApplied} from "../../src/types/SPTypes.sol";

// ─────────────────────────────────────────────────────────────────────────────
// TestableHook
// ─────────────────────────────────────────────────────────────────────────────
// Inherits StableProtectionHook but:
//   1. Bypasses validateHookAddress so the contract can be deployed at any address.
//   2. Overrides _getVirtualReservesNormalized to return fully controllable
//      mock reserves so tests never need a live PoolManager.
//   3. Exposes _beforeInitialize / _beforeSwap / _afterSwap as external
//      functions for direct testing without onlyPoolManager guard.
contract TestableHook is StableProtectionHook {
    using PoolIdLibrary for PoolKey;

    uint256 public mockR0 = 1e18;
    uint256 public mockR1 = 1e18;

    constructor(IPoolManager mgr) StableProtectionHook(mgr) {}

    // ── Skip address-permission validation at deploy time ───────────────────
    function validateHookAddress(BaseHook) internal pure override {}

    // ── Inject controlled reserves ───────────────────────────────────────────
    function setMockReserves(uint256 r0, uint256 r1) external {
        mockR0 = r0;
        mockR1 = r1;
    }

    function _getVirtualReservesNormalized(PoolId, PoolConfig storage)
        internal
        view
        override
        returns (uint256, uint256)
    {
        return (mockR0, mockR1);
    }

    // ── Exposed internal hooks (bypass onlyPoolManager) ──────────────────────
    function exposed_beforeInitialize(PoolKey calldata key) external returns (bytes4) {
        return _beforeInitialize(address(0), key, 0);
    }

    function exposed_beforeSwap(PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return _beforeSwap(address(0), key, params, hookData);
    }

    function exposed_afterSwap(PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        returns (bytes4, int128)
    {
        return _afterSwap(address(0), key, params, BalanceDelta.wrap(0), hookData);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// StableProtectionHookTest
// ─────────────────────────────────────────────────────────────────────────────
contract StableProtectionHookTest is Test {
    using PoolIdLibrary for PoolKey;

    TestableHook hook;

    // Dummy addresses for currency / PoolManager (not interacted with in unit tests).
    address constant FAKE_MANAGER = address(0x1234);
    Currency constant TOKEN0 = Currency.wrap(address(0xAA));
    Currency constant TOKEN1 = Currency.wrap(address(0xBB));

    PoolKey key;

    // ─── setUp ───────────────────────────────────────────────────────────────

    function setUp() public {
        // Deploy hook using the fake PoolManager address.
        // validateHookAddress is overridden to no-op, so any address is valid.
        hook = new TestableHook(IPoolManager(FAKE_MANAGER));

        // Build a PoolKey with DYNAMIC_FEE_FLAG so beforeInitialize accepts it.
        key = PoolKey({
            currency0: TOKEN0,
            currency1: TOKEN1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
    }

    // ─── Helper ──────────────────────────────────────────────────────────────

    function _initPool() internal {
        hook.exposed_beforeInitialize(key);
    }

    function _swapParams(bool zeroForOne) internal pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -1e18, // exact-in
            sqrtPriceLimitX96: 0
        });
    }

    // ─── beforeInitialize ────────────────────────────────────────────────────

    function test_beforeInitialize_returnsSelector() public {
        bytes4 sel = hook.exposed_beforeInitialize(key);
        assertEq(sel, hook.beforeInitialize.selector);
    }

    function test_beforeInitialize_storesDefaultConfig() public {
        _initPool();
        PoolConfig memory cfg = hook.getPoolConfig(key.toId());
        assertEq(cfg.amplification, 100);
        assertEq(cfg.baseFee, 100);
        assertEq(cfg.maxFee, 10_000);
        assertEq(cfg.decimals0, 18);
        assertEq(cfg.decimals1, 18);
    }

    function test_beforeInitialize_revertsOnStaticFee() public {
        PoolKey memory badKey = PoolKey({
            currency0: TOKEN0,
            currency1: TOKEN1,
            fee: 500, // static fee — not DYNAMIC_FEE_FLAG
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
        vm.expectRevert(bytes("SPH: pool fee must be DYNAMIC_FEE_FLAG"));
        hook.exposed_beforeInitialize(badKey);
    }

    function test_beforeInitialize_revertsOnSecondCall() public {
        _initPool();
        vm.expectRevert(AlreadyInitialized.selector);
        hook.exposed_beforeInitialize(key);
    }

    function test_beforeInitialize_seedsZoneAsHealthy() public {
        _initPool();
        (PegZone zone,,,) = hook.getZoneState(key.toId());
        assertEq(uint8(zone), uint8(PegZone.HEALTHY));
    }

    // ─── beforeSwap – fee logic ───────────────────────────────────────────────

    function test_beforeSwap_returnsSelector() public {
        _initPool();
        (bytes4 sel,,) = hook.exposed_beforeSwap(key, _swapParams(true), hex"");
        assertEq(sel, hook.beforeSwap.selector);
    }

    function test_beforeSwap_returnsZeroDelta() public {
        _initPool();
        (, BeforeSwapDelta delta,) = hook.exposed_beforeSwap(key, _swapParams(true), hex"");
        assertEq(BeforeSwapDelta.unwrap(delta), BeforeSwapDelta.unwrap(BeforeSwapDeltaLibrary.ZERO_DELTA));
    }

    function test_beforeSwap_setsOverrideFeeFlag() public {
        _initPool();
        (,, uint24 feeRet) = hook.exposed_beforeSwap(key, _swapParams(true), hex"");
        assertTrue(feeRet & LPFeeLibrary.OVERRIDE_FEE_FLAG != 0, "OVERRIDE_FEE_FLAG must be set");
    }

    /// HEALTHY zone, at-peg reserves (r0==r1), swap away from peg (zeroForOne=true
    /// with r0==r1 means isTowardPeg returns false since r0 == r1 edge case):
    /// fee = FEE_HEALTHY * AWAY_MULT / 10000 = 100 * 30000 / 10000 = 300
    function test_beforeSwap_healthyZone_awayFromPeg_fee() public {
        _initPool();
        hook.setMockReserves(1e18, 1e18); // at peg → isTowardPeg returns false
        (,, uint24 feeRet) = hook.exposed_beforeSwap(key, _swapParams(true), hex"");
        uint24 raw = feeRet & ~LPFeeLibrary.OVERRIDE_FEE_FLAG;
        // base=100, mult=3.0 → raw=300; capped at maxFee=10000 → 300
        assertEq(raw, 300, "HEALTHY away-from-peg fee mismatch");
    }

    /// HEALTHY zone, toward-peg swap:
    /// fee = FEE_HEALTHY * TOWARD_MULT / 10000 = 100 * 5000 / 10000 = 50
    function test_beforeSwap_healthyZone_towardPeg_fee() public {
        _initPool();
        // 10 bps deviation (exactly HEALTHY boundary):
        // r0=10005e18, r1=9995e18 → diff=10e18, avg=10000e18 → 10*10000/10000=10 bps → HEALTHY
        // r0 > r1 → isTowardPeg requires zeroForOne=false for toward-peg
        hook.setMockReserves(10_005e18, 9_995e18);
        (,, uint24 feeRet) = hook.exposed_beforeSwap(key, _swapParams(false), hex"");
        uint24 raw = feeRet & ~LPFeeLibrary.OVERRIDE_FEE_FLAG;
        // base=100, mult=0.5 → 100*5000/10000=50
        assertEq(raw, 50, "HEALTHY toward-peg fee mismatch");
    }

    /// MINOR zone (40 bps deviation), away from peg:
    /// base=500, mult=3.0 → 1500; capped at 10000 → 1500
    function test_beforeSwap_minorZone_awayFromPeg_fee() public {
        _initPool();
        // 40 bps deviation (MINOR: >10, ≤50):
        // r0=10020e18, r1=9980e18 → diff=40e18, avg=10000e18 → 40*10000/10000=40 bps → MINOR
        // r0 > r1, zeroForOne=true → away from peg
        hook.setMockReserves(10_020e18, 9_980e18);
        (,, uint24 feeRet) = hook.exposed_beforeSwap(key, _swapParams(true), hex"");
        uint24 raw = feeRet & ~LPFeeLibrary.OVERRIDE_FEE_FLAG;
        // base=500, mult=3.0 → 500*30000/10000=1500
        assertEq(raw, 1500, "MINOR away-from-peg fee mismatch");
    }

    /// MODERATE zone (100 bps deviation):
    /// base=1500, toward-peg: 1500*5000/10000=750
    function test_beforeSwap_moderateZone_towardPeg_fee() public {
        _initPool();
        // 100 bps deviation (MODERATE: >50, ≤200):
        // r0=10050e18, r1=9950e18 → diff=100e18, avg=10000e18 → 100*10000/10000=100 bps → MODERATE
        // r0 > r1, zeroForOne=false → toward peg
        hook.setMockReserves(10_050e18, 9_950e18);
        (,, uint24 feeRet) = hook.exposed_beforeSwap(key, _swapParams(false), hex"");
        uint24 raw = feeRet & ~LPFeeLibrary.OVERRIDE_FEE_FLAG;
        // base=1500, mult=0.5 → 1500*5000/10000=750
        assertEq(raw, 750, "MODERATE toward-peg fee mismatch");
    }

    /// SEVERE zone (300 bps deviation, circuit breaker NOT triggered at SEVERE).
    /// base=5000, away: 5000*30000/10000=15000 → capped at maxFee=10000
    function test_beforeSwap_severeZone_fee_cappedAtMaxFee() public {
        _initPool();
        // 300 bps deviation (SEVERE: >200, ≤500):
        // r0=10150e18, r1=9850e18 → diff=300e18, avg=10000e18 → 300*10000/10000=300 bps → SEVERE
        // r0 > r1, zeroForOne=true → away from peg
        hook.setMockReserves(10_150e18, 9_850e18);
        (,, uint24 feeRet) = hook.exposed_beforeSwap(key, _swapParams(true), hex"");
        uint24 raw = feeRet & ~LPFeeLibrary.OVERRIDE_FEE_FLAG;
        // 5000 * 30000 / 10000 = 15000 > maxFee(10000) → capped at 10000
        assertEq(raw, 10_000, "SEVERE fee should be capped at maxFee");
    }

    /// CRITICAL zone → circuit breaker reverts.
    function test_beforeSwap_criticalZone_revertsCircuitBreaker() public {
        _initPool();
        // 600 bps deviation (CRITICAL: >500):
        // r0=10300e18, r1=9700e18 → diff=600e18, avg=10000e18 → 600*10000/10000=600 bps → CRITICAL
        hook.setMockReserves(10_300e18, 9_700e18);
        vm.expectRevert(
            abi.encodeWithSelector(CircuitBreakerTripped.selector, PegZone.CRITICAL, uint256(600))
        );
        hook.exposed_beforeSwap(key, _swapParams(true), hex"");
    }

    /// Zero reserve triggers CRITICAL (type(uint256).max deviation).
    function test_beforeSwap_zeroReserve_revertsCircuitBreaker() public {
        _initPool();
        hook.setMockReserves(0, 1e18);
        vm.expectRevert();
        hook.exposed_beforeSwap(key, _swapParams(true), hex"");
    }

    // ─── beforeSwap – events ──────────────────────────────────────────────────

    function test_beforeSwap_emitsFeeApplied() public {
        _initPool();
        hook.setMockReserves(1e18, 1e18);
        vm.expectEmit(true, false, false, true, address(hook));
        // at-peg, zeroForOne=true → towardPeg=false, fee=300
        emit FeeApplied(PoolId.unwrap(key.toId()), 300, false);
        hook.exposed_beforeSwap(key, _swapParams(true), hex"");
    }

    // ─── afterSwap – state update ─────────────────────────────────────────────

    function test_afterSwap_returnsSelector() public {
        _initPool();
        (bytes4 sel,) = hook.exposed_afterSwap(key, _swapParams(true), hex"");
        assertEq(sel, hook.afterSwap.selector);
    }

    function test_afterSwap_updatesReserveSnapshot() public {
        _initPool();
        hook.setMockReserves(1_100e18, 1_000e18);
        hook.exposed_afterSwap(key, _swapParams(true), hex"");
        (, uint256 r0, uint256 r1,) = hook.getZoneState(key.toId());
        assertEq(r0, 1_100e18);
        assertEq(r1, 1_000e18);
    }

    function test_afterSwap_updatesBlockNumber() public {
        _initPool();
        vm.roll(42);
        hook.exposed_afterSwap(key, _swapParams(true), hex"");
        (,,, uint256 blk) = hook.getZoneState(key.toId());
        assertEq(blk, 42);
    }

    function test_afterSwap_emitsZoneChanged_whenZoneShifts() public {
        _initPool();
        // First swap at peg: zone = HEALTHY (already set in init)
        hook.setMockReserves(1e18, 1e18);
        hook.exposed_afterSwap(key, _swapParams(true), hex"");

        // Simulate depeg → MINOR (40 bps):
        // r0=10020e18, r1=9980e18 → diff=40e18, avg=10000e18 → 40 bps → MINOR
        hook.setMockReserves(10_020e18, 9_980e18);
        vm.expectEmit(true, false, false, true, address(hook));
        emit ZoneChanged(PoolId.unwrap(key.toId()), PegZone.HEALTHY, PegZone.MINOR);
        hook.exposed_afterSwap(key, _swapParams(false), hex"");
    }

    function test_afterSwap_noEventIfZoneUnchanged() public {
        _initPool();
        hook.setMockReserves(1e18, 1e18);
        hook.exposed_afterSwap(key, _swapParams(true), hex"");

        // Still at peg → zone stays HEALTHY; no event
        vm.recordLogs();
        hook.exposed_afterSwap(key, _swapParams(true), hex"");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // ZoneChanged has topic keccak256("ZoneChanged(bytes32,uint8,uint8)")
        bytes32 topic = keccak256("ZoneChanged(bytes32,uint8,uint8)");
        for (uint256 i; i < logs.length; ++i) {
            assertNotEq(logs[i].topics[0], topic, "unexpected ZoneChanged emitted");
        }
    }

    // ─── View functions ──────────────────────────────────────────────────────

    function test_getPoolConfig_returnsStoredConfig() public {
        _initPool();
        PoolConfig memory cfg = hook.getPoolConfig(key.toId());
        assertEq(cfg.amplification, 100);
    }

    function test_getZoneState_returnsCurrentState() public {
        _initPool();
        // 40 bps → MINOR zone
        hook.setMockReserves(10_020e18, 9_980e18);
        hook.exposed_afterSwap(key, _swapParams(true), hex"");
        (PegZone zone, uint256 r0, uint256 r1,) = hook.getZoneState(key.toId());
        assertEq(uint8(zone), uint8(PegZone.MINOR));
        assertEq(r0, 10_020e18);
        assertEq(r1, 9_980e18);
    }

    function test_currentDeviationBps_atPeg() public {
        _initPool();
        hook.setMockReserves(1e18, 1e18);
        uint256 dev = hook.currentDeviationBps(key.toId());
        assertEq(dev, 0);
    }

    function test_currentDeviationBps_offPeg() public {
        _initPool();
        // r0=10010, r1=9990 → diff=20, avg=10000 → 20 bps
        hook.setMockReserves(10_010e18, 9_990e18);
        uint256 dev = hook.currentDeviationBps(key.toId());
        assertEq(dev, 20);
    }

    // ─── getHookPermissions ──────────────────────────────────────────────────

    function test_hookPermissions_correct() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize,  "beforeInitialize must be true");
        assertFalse(p.afterInitialize,  "afterInitialize must be false");
        assertTrue(p.beforeSwap,        "beforeSwap must be true");
        assertTrue(p.afterSwap,         "afterSwap must be true");
        assertFalse(p.beforeAddLiquidity, "beforeAddLiquidity must be false");
        assertFalse(p.afterAddLiquidity,  "afterAddLiquidity must be false");
        assertFalse(p.beforeSwapReturnDelta, "beforeSwapReturnDelta must be false");
    }
}
