// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

// ─── v4-core ─────────────────────────────────────────────────────────────────
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";

// ─── v4-core test routers (pre-deployed on Unichain Sepolia) ─────────────────
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

// ─── project ─────────────────────────────────────────────────────────────────
import {MockStablecoin} from "../src/mocks/MockStablecoin.sol";

/// @title  TestPoolSwap
/// @notice Creates a fresh tUSDC/tUSDT pool on the already-deployed
///         StableProtectionHook, adds liquidity, and executes a test swap.
///         All routers are pre-deployed on Unichain Sepolia — no new router
///         deployments required.
///
///         Run:
///           forge script script/TestPoolSwap.s.sol:TestPoolSwap \
///             --rpc-url unichain_sepolia \
///             --broadcast \
///             -vvvv
contract TestPoolSwap is Script {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // ─── Unichain Sepolia addresses ──────────────────────────────────────────

    address constant POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    address constant LIQ_ROUTER   = 0x5fa728C0A5cfd51BEe4B060773f50554c0C8A7AB;
    address constant SWAP_ROUTER  = 0x9140a78c1A137c7fF1c151EC8231272aF78a99A4;

    /// @dev Already deployed by Deploy.s.sol — no re-deployment needed.
    address constant HOOK = 0xbaacDCFfA93B984C914014F83Ee28B68dF88DC87;

    // ─── Pool parameters ─────────────────────────────────────────────────────

    uint160 constant SQRT_PRICE_1_1  = 79228162514264337593543950336;
    int256  constant INITIAL_LIQUIDITY = 10_000e18;
    int256  constant SWAP_AMOUNT       = -10e18; // exact-input, token0 → token1

    // ─── run ─────────────────────────────────────────────────────────────────

    function run() external {
        uint256 pk       = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        IPoolManager manager = IPoolManager(POOL_MANAGER);

        vm.startBroadcast(pk);

        // ── 1. Deploy fresh stablecoins ───────────────────────────────────────
        MockStablecoin tUSDC = new MockStablecoin("Test USD Coin", "tUSDC", 18);
        MockStablecoin tUSDT = new MockStablecoin("Test Tether",   "tUSDT", 18);
        tUSDC.mint(deployer, 1_000_000e18);
        tUSDT.mint(deployer, 1_000_000e18);
        console2.log("tUSDC:", address(tUSDC));
        console2.log("tUSDT:", address(tUSDT));

        // ── 2. Sort currencies (v4: currency0 < currency1) ───────────────────
        (Currency c0, Currency c1) = address(tUSDC) < address(tUSDT)
            ? (Currency.wrap(address(tUSDC)), Currency.wrap(address(tUSDT)))
            : (Currency.wrap(address(tUSDT)), Currency.wrap(address(tUSDC)));

        // ── 3. Build PoolKey ──────────────────────────────────────────────────
        PoolKey memory key = PoolKey({
            currency0:   c0,
            currency1:   c1,
            fee:         LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 1,
            hooks:       IHooks(HOOK)
        });

        bytes32 poolId = PoolId.unwrap(key.toId());
        console2.log("PoolId:", vm.toString(poolId));

        // ── 4. Initialize pool at 1:1 price ──────────────────────────────────
        manager.initialize(key, SQRT_PRICE_1_1);
        console2.log("Pool initialized.");

        // ── 5. Add liquidity (approve router, not manager) ────────────────────
        MockStablecoin(Currency.unwrap(c0)).approve(LIQ_ROUTER, type(uint256).max);
        MockStablecoin(Currency.unwrap(c1)).approve(LIQ_ROUTER, type(uint256).max);

        PoolModifyLiquidityTest(LIQ_ROUTER).modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower:      -10,
                tickUpper:       10,
                liquidityDelta:  INITIAL_LIQUIDITY,
                salt:            bytes32(0)
            }),
            ""
        );
        console2.log("Liquidity added: 10,000 tokens per side.");

        // ── 6. Execute swap (10 tUSDC → tUSDT, exact-input) ──────────────────
        //       beforeSwap: hook classifies zone, overrides fee
        //       afterSwap:  hook updates zone snapshot
        MockStablecoin(Currency.unwrap(c0)).approve(SWAP_ROUTER, type(uint256).max);
        MockStablecoin(Currency.unwrap(c1)).approve(SWAP_ROUTER, type(uint256).max);

        PoolSwapTest(SWAP_ROUTER).swap(
            key,
            SwapParams({
                zeroForOne:        true,
                amountSpecified:   SWAP_AMOUNT,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims:      false,
                settleUsingBurn: false
            }),
            ""
        );
        console2.log("Swap executed: 10 tUSDC -> tUSDT.");

        vm.stopBroadcast();

        // ── 7. Verified Uniscan links ─────────────────────────────────────────
        console2.log("");
        console2.log("=== VERIFIED LINKS ===");
        console2.log("Hook:        https://sepolia.uniscan.xyz/address/", HOOK);
        console2.log("tUSDC:       https://sepolia.uniscan.xyz/address/", address(tUSDC));
        console2.log("tUSDT:       https://sepolia.uniscan.xyz/address/", address(tUSDT));
        console2.log("Pool (PoolManager): https://sepolia.uniscan.xyz/address/", POOL_MANAGER);
        console2.log("PoolId:", vm.toString(poolId));
    }
}
