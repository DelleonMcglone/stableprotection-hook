// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

// ─── v4-core ─────────────────────────────────────────────────────────────────
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";

// ─── v4-core test routers (already deployed on Unichain Sepolia) ─────────────
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

// ─── v4-periphery ────────────────────────────────────────────────────────────
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

// ─── project ─────────────────────────────────────────────────────────────────
import {StableProtectionHook} from "../src/StableProtectionHook.sol";
import {MockStablecoin} from "../src/mocks/MockStablecoin.sol";

/// @title  Deploy
/// @notice Deploys StableProtectionHook on Unichain Sepolia, creates a tUSDC/tUSDT
///         pool, adds liquidity, and executes a test swap to verify the hook's
///         dynamic-fee and zone-classification logic end-to-end.
///
///         Run:
///           forge script script/Deploy.s.sol:Deploy \
///             --rpc-url unichain_sepolia \
///             --broadcast \
///             --verify \
///             -vvvv
contract Deploy is Script {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // ─── Unichain Sepolia constants ──────────────────────────────────────────

    /// @dev Uniswap v4 PoolManager on Unichain Sepolia.
    address constant POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;

    /// @dev Standard CREATE2 proxy used by `forge script --broadcast`.
    address constant CREATE2_PROXY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @dev PoolModifyLiquidityTest deployed on Unichain Sepolia.
    address constant LIQ_ROUTER  = 0x5fa728C0A5cfd51BEe4B060773f50554c0C8A7AB;

    /// @dev PoolSwapTest deployed on Unichain Sepolia.
    address constant SWAP_ROUTER = 0x9140a78c1A137c7fF1c151EC8231272aF78a99A4;

    // ─── Pool / hook parameters ──────────────────────────────────────────────

    /// @dev sqrtPriceX96 for 1:1 price (tick = 0).
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    /// @dev Initial liquidity: 10,000 tokens per side (18 decimals).
    int256 constant INITIAL_LIQUIDITY = 10_000e18;

    /// @dev Test swap: exact-input 10 token0 → token1.
    int256 constant SWAP_AMOUNT = -10e18;

    /// @dev Permission bits that exactly match StableProtectionHook.getHookPermissions():
    ///      beforeInitialize (bit 13) | beforeSwap (bit 7) | afterSwap (bit 6)
    uint160 constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
    );

    // ─── run ────────────────────────────────────────────────────────────────

    function run() external {
        uint256 pk       = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        IPoolManager manager = IPoolManager(POOL_MANAGER);

        // ── 1. Mine CREATE2 salt for a valid hook address ────────────────────
        console2.log("Mining hook address...");
        (address hookAddr, bytes32 salt) = HookMiner.find(
            CREATE2_PROXY,
            HOOK_FLAGS,
            type(StableProtectionHook).creationCode,
            abi.encode(address(manager))
        );
        console2.log("Hook will deploy to:", hookAddr);

        vm.startBroadcast(pk);

        // ── 2. Deploy mock stablecoins (18 dec matches hook's hardcoded config) ─
        MockStablecoin tUSDC = new MockStablecoin("Test USD Coin", "tUSDC", 18);
        MockStablecoin tUSDT = new MockStablecoin("Test Tether",   "tUSDT", 18);
        tUSDC.mint(deployer, 1_000_000e18);
        tUSDT.mint(deployer, 1_000_000e18);
        console2.log("tUSDC:", address(tUSDC));
        console2.log("tUSDT:", address(tUSDT));

        // ── 3. Deploy hook via CREATE2 ────────────────────────────────────────
        StableProtectionHook hook = new StableProtectionHook{salt: salt}(manager);
        require(address(hook) == hookAddr, "Hook address mismatch");
        console2.log("StableProtectionHook:", address(hook));

        // ── 4. Sort currencies (v4 requires currency0 < currency1) ───────────
        (Currency c0, Currency c1) = address(tUSDC) < address(tUSDT)
            ? (Currency.wrap(address(tUSDC)), Currency.wrap(address(tUSDT)))
            : (Currency.wrap(address(tUSDT)), Currency.wrap(address(tUSDC)));

        // ── 5. Build PoolKey and initialize at 1:1 ───────────────────────────
        PoolKey memory key = PoolKey({
            currency0:   c0,
            currency1:   c1,
            fee:         LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 1,
            hooks:       IHooks(address(hook))
        });

        bytes32 poolId = PoolId.unwrap(key.toId());
        console2.log("PoolId:", vm.toString(poolId));

        manager.initialize(key, SQRT_PRICE_1_1);
        console2.log("Pool initialized at 1:1.");

        // ── 6. Add liquidity via pre-deployed PoolModifyLiquidityTest ─────────
        //       Approval is to the router; CurrencySettler calls
        //       transferFrom(deployer, manager) from inside unlockCallback.
        PoolModifyLiquidityTest liqRouter = PoolModifyLiquidityTest(LIQ_ROUTER);
        MockStablecoin(Currency.unwrap(c0)).approve(address(liqRouter), type(uint256).max);
        MockStablecoin(Currency.unwrap(c1)).approve(address(liqRouter), type(uint256).max);

        liqRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower:      -10,
                tickUpper:       10,
                liquidityDelta:  INITIAL_LIQUIDITY,
                salt:            bytes32(0)
            }),
            ""
        );
        console2.log("Liquidity added: 10,000 tokens per side in [-10, 10].");

        // ── 7. Execute test swap via pre-deployed PoolSwapTest ────────────────
        //       Swap 10 tUSDC (token0) → tUSDT (token1), exact-input.
        //       This fires beforeSwap (dynamic fee) and afterSwap (zone update).
        PoolSwapTest swapRouter = PoolSwapTest(SWAP_ROUTER);
        MockStablecoin(Currency.unwrap(c0)).approve(address(swapRouter), type(uint256).max);
        MockStablecoin(Currency.unwrap(c1)).approve(address(swapRouter), type(uint256).max);

        swapRouter.swap(
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
        console2.log("Test swap executed: 10 tUSDC -> tUSDT.");

        vm.stopBroadcast();

        // ── 8. Deployment summary ─────────────────────────────────────────────
        console2.log("");
        console2.log("=== DEPLOYMENT SUMMARY ===");
        console2.log("Network:     Unichain Sepolia (1301)");
        console2.log("tUSDC:      ", address(tUSDC));
        console2.log("tUSDT:      ", address(tUSDT));
        console2.log("Hook:       ", address(hook));
        console2.log("PoolId:     ", vm.toString(poolId));
        console2.log("PoolManager:", POOL_MANAGER);
        console2.log("");
        console2.log("Uniscan Links:");
        console2.log("Hook:  https://sepolia.uniscan.xyz/address/", address(hook));
        console2.log("Pool:  https://sepolia.uniscan.xyz/address/", POOL_MANAGER);
        console2.log("==========================");
    }
}
