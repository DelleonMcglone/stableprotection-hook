// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

// ─── v4-core ─────────────────────────────────────────────────────────────────
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";

// ─── v4-core test utilities ──────────────────────────────────────────────────
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

// ─── v4-periphery ────────────────────────────────────────────────────────────
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

// ─── mocks ───────────────────────────────────────────────────────────────────
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

// ─── project ─────────────────────────────────────────────────────────────────
import {StableProtectionHook} from "../../src/StableProtectionHook.sol";
import {PegZone, FeeApplied} from "../../src/types/SPTypes.sol";

/// @title  StableProtectionHook Integration Test
/// @notice Deploys a full Uniswap v4 stack and exercises the hook end-to-end:
///         pool initialization → liquidity provision → swap → zone state update.
contract StableProtectionHookIntegrationTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // ─── Constants ──────────────────────────────────────────────────────────

    /// @dev sqrtPriceX96 for 1:1 price (tick 0).
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // 2^96

    /// @dev Permission bits: beforeInitialize (bit 13) | beforeSwap (bit 7) | afterSwap (bit 6)
    uint160 constant HOOK_FLAGS =
        uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

    // ─── State ───────────────────────────────────────────────────────────────

    PoolManager manager;
    StableProtectionHook hook;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest liqRouter;

    MockERC20 tokenA;
    MockERC20 tokenB;

    Currency currency0;
    Currency currency1;

    PoolKey poolKey;

    // ─── setUp ───────────────────────────────────────────────────────────────

    function setUp() public {
        // 1. Deploy PoolManager.
        manager = new PoolManager(address(this));

        // 2. Mine a hook address with the required permission bits via CREATE2.
        (address hookAddr, bytes32 salt) = HookMiner.find(
            address(this),
            HOOK_FLAGS,
            type(StableProtectionHook).creationCode,
            abi.encode(address(manager))
        );

        // 3. Deploy the hook at the computed address using CREATE2.
        hook = new StableProtectionHook{salt: salt}(IPoolManager(address(manager)));
        assertEq(address(hook), hookAddr, "hook address mismatch");

        // 4. Deploy swap/liquidity routers.
        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
        liqRouter  = new PoolModifyLiquidityTest(IPoolManager(address(manager)));

        // 5. Deploy and sort two mock stablecoins (18 decimals each).
        tokenA = new MockERC20("USD Coin", "USDC", 18);
        tokenB = new MockERC20("Tether USD", "USDT", 18);

        // v4 requires currency0 < currency1 by address value.
        if (address(tokenA) < address(tokenB)) {
            currency0 = Currency.wrap(address(tokenA));
            currency1 = Currency.wrap(address(tokenB));
        } else {
            currency0 = Currency.wrap(address(tokenB));
            currency1 = Currency.wrap(address(tokenA));
        }

        // 6. Construct the PoolKey.
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });

        // 7. Mint tokens to this test contract.
        MockERC20(Currency.unwrap(currency0)).mint(address(this), 1_000_000e18);
        MockERC20(Currency.unwrap(currency1)).mint(address(this), 1_000_000e18);

        // 8. Approve routers.
        MockERC20(Currency.unwrap(currency0)).approve(address(liqRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(liqRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────

    function _initPool() internal {
        manager.initialize(poolKey, SQRT_PRICE_1_1);
    }

    function _addLiquidity(int256 liquidityDelta) internal {
        liqRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -120,
                tickUpper:  120,
                liquidityDelta: liquidityDelta,
                salt: bytes32(0)
            }),
            ""
        );
    }

    function _swap(bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        return swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    // ─── Deployment ──────────────────────────────────────────────────────────

    function test_integration_hookDeployedAtCorrectAddress() public view {
        // Verify permission bits are embedded in the hook address.
        assertTrue(
            uint160(address(hook)) & uint160(Hooks.BEFORE_INITIALIZE_FLAG) != 0,
            "missing BEFORE_INITIALIZE_FLAG"
        );
        assertTrue(
            uint160(address(hook)) & uint160(Hooks.BEFORE_SWAP_FLAG) != 0,
            "missing BEFORE_SWAP_FLAG"
        );
        assertTrue(
            uint160(address(hook)) & uint160(Hooks.AFTER_SWAP_FLAG) != 0,
            "missing AFTER_SWAP_FLAG"
        );
    }

    // ─── Pool initialization ──────────────────────────────────────────────────

    function test_integration_poolInitializes() public {
        _initPool();
        // Zone seeded as HEALTHY.
        (PegZone zone,,,) = hook.getZoneState(poolKey.toId());
        assertEq(uint8(zone), uint8(PegZone.HEALTHY), "initial zone must be HEALTHY");
    }

    function test_integration_poolConfig_stored() public {
        _initPool();
        // Default config is stored with expected amplification.
        assertEq(hook.getPoolConfig(poolKey.toId()).amplification, 100);
    }

    // ─── Liquidity + swap ────────────────────────────────────────────────────

    function test_integration_addLiquidity_succeeds() public {
        _initPool();
        _addLiquidity(100e18);
        // If no revert, liquidity was added successfully.
    }

    /// Full round-trip: init → add liquidity → swap → zone state updated.
    function test_integration_swap_updateszoneState() public {
        _initPool();
        _addLiquidity(100e18);

        // Perform a swap (exact-input, selling currency0 for currency1).
        _swap(true, -1e18);

        // afterSwap must have written a new reserve snapshot and block number.
        (,, , uint256 updateBlock) = hook.getZoneState(poolKey.toId());
        assertEq(updateBlock, block.number, "zone state block not updated");
    }

    /// FeeApplied event is emitted on every swap.
    function test_integration_swap_emitsFeeApplied() public {
        _initPool();
        _addLiquidity(100e18);

        vm.expectEmit(true, false, false, false, address(hook));
        emit FeeApplied(PoolId.unwrap(poolKey.toId()), 0, false); // values don't matter; check topic
        _swap(true, -1e18);
    }

    /// Verify zone state is updated after each swap (state tracking works end-to-end).
    function test_integration_multipleSwaps_zoneTracked() public {
        _initPool();
        _addLiquidity(100e18);

        // Zone state before any swap: HEALTHY, block = init block
        (PegZone z0,,, uint256 blk0) = hook.getZoneState(poolKey.toId());
        assertEq(uint8(z0), uint8(PegZone.HEALTHY));

        // Advance the block so we can detect the update.
        vm.roll(block.number + 1);

        // Perform a swap (any size); afterSwap must update zone state.
        _swap(true, -1e18);

        // Zone state must be updated regardless of which zone was reached.
        (,,, uint256 blk1) = hook.getZoneState(poolKey.toId());
        assertGt(blk1, blk0, "zone state block must advance after swap");
    }

    /// currentDeviationBps reads live state.
    function test_integration_currentDeviationBps_readable() public {
        _initPool();
        _addLiquidity(100e18);

        // After init + liquidity, deviation should be near zero (1:1 price).
        uint256 dev = hook.currentDeviationBps(poolKey.toId());
        // Allow for a small numerical error from the virtual reserve approximation.
        assertLt(dev, 50, "deviation should be near zero at 1:1 init price");
    }

    // ─── Double-initialize guard ──────────────────────────────────────────────

    function test_integration_doubleInitialize_reverts() public {
        _initPool();
        vm.expectRevert();
        // PoolManager.initialize will revert when the pool already exists,
        // before even reaching our AlreadyInitialized check.
        manager.initialize(poolKey, SQRT_PRICE_1_1);
    }
}
