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

// ─── v4-core test routers (already deployed on Base Sepolia) ─────────────────
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

// ─── v4-periphery ────────────────────────────────────────────────────────────
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

// ─── project ─────────────────────────────────────────────────────────────────
import {StableProtectionHook} from "../src/StableProtectionHook.sol";

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
}

/// @title  DeployBaseSepolia
/// @notice Deploys StableProtectionHook on Base Sepolia, creates a USDC/EURC
///         pool using Circle's official Base Sepolia testnet tokens, adds
///         liquidity, and executes a test swap to verify the hook's
///         dynamic-fee and zone-classification logic end-to-end.
///
///         Run:
///           forge script script/DeployBaseSepolia.s.sol:DeployBaseSepolia \
///             --rpc-url base_sepolia \
///             --broadcast \
///             -vvvv
contract DeployBaseSepolia is Script {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // ─── Base Sepolia constants ─────────────────────────────────────────────

    /// @dev Uniswap v4 PoolManager on Base Sepolia.
    address constant POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;

    /// @dev Standard CREATE2 proxy used by `forge script --broadcast`.
    address constant CREATE2_PROXY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @dev PoolModifyLiquidityTest deployed on Base Sepolia.
    address constant LIQ_ROUTER  = 0x37429cD17Cb1454C34E7F50b09725202Fd533039;

    /// @dev PoolSwapTest deployed on Base Sepolia.
    address constant SWAP_ROUTER = 0x8B5bcC363ddE2614281aD875bad385E0A785D3B9;

    /// @dev Circle USDC on Base Sepolia (6 decimals).
    address constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    /// @dev Circle EURC on Base Sepolia (6 decimals).
    address constant EURC = 0x808456652fdb597867f38412077A9182bf77359F;

    // ─── Pool / hook parameters ──────────────────────────────────────────────

    /// @dev sqrtPriceX96 for 1:1 price (tick = 0).
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    /// @dev Liquidity in v4 units. With tick range [-10, 10] and sqrtPrice 1,
    ///      L = 1e11 maps to roughly 50 USDC + 50 EURC (6-decimal tokens).
    int256 constant INITIAL_LIQUIDITY = 1e11;

    /// @dev Test swap: exact-input 5 USDC → EURC (5e6 in 6-decimal units).
    int256 constant SWAP_AMOUNT = -5e6;

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

        // ── 2. Verify deployer has USDC and EURC balances ────────────────────
        uint256 usdcBal = IERC20(USDC).balanceOf(deployer);
        uint256 eurcBal = IERC20(EURC).balanceOf(deployer);
        console2.log("Deployer USDC balance:", usdcBal);
        console2.log("Deployer EURC balance:", eurcBal);
        require(usdcBal >= 60e6, "Need >= 60 USDC at deployer");
        require(eurcBal >= 60e6, "Need >= 60 EURC at deployer");

        vm.startBroadcast(pk);

        // ── 3. Deploy hook via CREATE2 ────────────────────────────────────────
        StableProtectionHook hook = new StableProtectionHook{salt: salt}(manager);
        require(address(hook) == hookAddr, "Hook address mismatch");
        console2.log("StableProtectionHook:", address(hook));

        // ── 4. Sort currencies (v4 requires currency0 < currency1) ───────────
        (Currency c0, Currency c1) = USDC < EURC
            ? (Currency.wrap(USDC), Currency.wrap(EURC))
            : (Currency.wrap(EURC), Currency.wrap(USDC));

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
        PoolModifyLiquidityTest liqRouter = PoolModifyLiquidityTest(LIQ_ROUTER);
        IERC20(Currency.unwrap(c0)).approve(address(liqRouter), type(uint256).max);
        IERC20(Currency.unwrap(c1)).approve(address(liqRouter), type(uint256).max);

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
        console2.log("Liquidity added: ~50 USDC + ~50 EURC in [-10, 10].");

        // ── 7. Execute test swap via pre-deployed PoolSwapTest ────────────────
        PoolSwapTest swapRouter = PoolSwapTest(SWAP_ROUTER);
        IERC20(Currency.unwrap(c0)).approve(address(swapRouter), type(uint256).max);
        IERC20(Currency.unwrap(c1)).approve(address(swapRouter), type(uint256).max);

        // zeroForOne semantics depend on token sorting; USDC < EURC so
        // zeroForOne=true => USDC -> EURC.
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
        console2.log("Test swap executed: 5 USDC -> EURC.");

        vm.stopBroadcast();

        // ── 8. Deployment summary ─────────────────────────────────────────────
        console2.log("");
        console2.log("=== DEPLOYMENT SUMMARY ===");
        console2.log("Network:     Base Sepolia (84532)");
        console2.log("USDC:       ", USDC);
        console2.log("EURC:       ", EURC);
        console2.log("Hook:       ", address(hook));
        console2.log("PoolId:     ", vm.toString(poolId));
        console2.log("PoolManager:", POOL_MANAGER);
        console2.log("");
        console2.log("Basescan Links:");
        console2.log("Hook:  https://sepolia.basescan.org/address/", address(hook));
        console2.log("Pool:  https://sepolia.basescan.org/address/", POOL_MANAGER);
        console2.log("==========================");
    }
}
