// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

// ─── v4-core ─────────────────────────────────────────────────────────────────
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

// ─── v4-core test routers (we deploy these — Arc has no v4 stack) ─────────────
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

// ─── v4-periphery ────────────────────────────────────────────────────────────
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

// ─── project ─────────────────────────────────────────────────────────────────
import {StableProtectionHook} from "../src/StableProtectionHook.sol";

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
}

/// @title  DeployArcTestnet
/// @notice Deploys StableProtectionHook on Arc Testnet (chain id 5042002).
///
///         Arc Testnet has NO public Uniswap v4 deployment, so this script first
///         stands up a self-contained v4 stack — PoolManager + the two test
///         routers — then mines and deploys the hook and initializes a USDC/EURC
///         pool using Circle's official Arc Testnet stablecoins.
///
///         IMPORTANT — why liquidity + the test swap are NOT in this script:
///         Arc's USDC/EURC are *native fiat tokens* whose transfers are executed
///         by chain-level precompiles (`isBlocklisted` at 0x1800…0001 and the
///         native-balance move at 0x1800…0000). Those precompiles do not exist in
///         Foundry's local EVM, so any token transfer reverts during the local
///         execution that `forge script` performs to build its broadcast list —
///         which would block the entire broadcast. This script therefore only
///         performs token-free operations (contract deploys + pool init), which
///         broadcast cleanly. Adding liquidity and the verification swap move
///         tokens and are executed afterward via `cast send` against the live Arc
///         node (which has the real precompiles). See script/deploy_arc.sh.
///
///         Run (driven by script/deploy_arc.sh, which also does liquidity+swap):
///           forge script script/DeployArcTestnet.s.sol:DeployArcTestnet \
///             --rpc-url arc_testnet \
///             --account arc-deployer --sender <deployer> \
///             --broadcast --slow -vvvv
contract DeployArcTestnet is Script {
    using PoolIdLibrary for PoolKey;

    // ─── Arc Testnet constants ───────────────────────────────────────────────

    /// @dev Standard CREATE2 proxy (deployed on Arc Testnet) used by HookMiner.
    address constant CREATE2_PROXY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @dev Circle USDC on Arc Testnet (6 decimals, ERC-20). Also the native gas token.
    address constant USDC = 0x3600000000000000000000000000000000000000;

    /// @dev Circle EURC on Arc Testnet (6 decimals).
    address constant EURC = 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a;

    // ─── Pool / hook parameters ──────────────────────────────────────────────

    /// @dev sqrtPriceX96 for 1:1 price (tick = 0).
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    /// @dev Permission bits that exactly match StableProtectionHook.getHookPermissions():
    ///      beforeInitialize (bit 13) | beforeSwap (bit 7) | afterSwap (bit 6)
    uint160 constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
    );

    // ─── run ────────────────────────────────────────────────────────────────

    function run() external {
        address deployer = msg.sender;

        // ── 1. Sanity-check deployer balances (read-only; staticcalls work) ───
        uint256 usdcBal = IERC20(USDC).balanceOf(deployer);
        uint256 eurcBal = IERC20(EURC).balanceOf(deployer);
        console2.log("Deployer:            ", deployer);
        console2.log("Deployer USDC balance:", usdcBal);
        console2.log("Deployer EURC balance:", eurcBal);
        require(usdcBal >= 20e6, "Need >= 20 USDC at deployer");
        require(eurcBal >= 15e6, "Need >= 15 EURC at deployer");

        vm.startBroadcast();

        // ── 2. Deploy the v4 stack (Arc has none) ─────────────────────────────
        PoolManager manager = new PoolManager(deployer);
        console2.log("PoolManager:        ", address(manager));

        PoolModifyLiquidityTest liqRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));
        console2.log("LiqRouter:          ", address(liqRouter));

        PoolSwapTest swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
        console2.log("SwapRouter:         ", address(swapRouter));

        // ── 3. Mine CREATE2 salt for a valid hook address ─────────────────────
        (address hookAddr, bytes32 salt) = HookMiner.find(
            CREATE2_PROXY,
            HOOK_FLAGS,
            type(StableProtectionHook).creationCode,
            abi.encode(address(manager))
        );

        // ── 4. Deploy hook via CREATE2 ────────────────────────────────────────
        StableProtectionHook hook =
            new StableProtectionHook{salt: salt}(IPoolManager(address(manager)));
        require(address(hook) == hookAddr, "Hook address mismatch");
        console2.log("StableProtectionHook:", address(hook));

        // ── 5. Sort currencies (v4 requires currency0 < currency1) ────────────
        (Currency c0, Currency c1) = USDC < EURC
            ? (Currency.wrap(USDC), Currency.wrap(EURC))
            : (Currency.wrap(EURC), Currency.wrap(USDC));

        // ── 6. Build PoolKey and initialize at 1:1 ────────────────────────────
        PoolKey memory key = PoolKey({
            currency0:   c0,
            currency1:   c1,
            fee:         LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 1,
            hooks:       IHooks(address(hook))
        });

        bytes32 poolId = PoolId.unwrap(key.toId());
        manager.initialize(key, SQRT_PRICE_1_1);

        vm.stopBroadcast();

        // ── 7. Deployment summary (machine-readable for deploy_arc.sh) ────────
        console2.log("");
        console2.log("=== DEPLOYMENT SUMMARY ===");
        console2.log("Network:     Arc Testnet (5042002)");
        console2.log("USDC:       ", USDC);
        console2.log("EURC:       ", EURC);
        console2.log("currency0:  ", Currency.unwrap(c0));
        console2.log("currency1:  ", Currency.unwrap(c1));
        console2.log("POOL_MANAGER=", address(manager));
        console2.log("LIQ_ROUTER=", address(liqRouter));
        console2.log("SWAP_ROUTER=", address(swapRouter));
        console2.log("HOOK=", address(hook));
        console2.log("POOL_ID=", vm.toString(poolId));
        console2.log("Hook:  https://testnet.arcscan.app/address/", address(hook));
        console2.log("==========================");
    }
}
