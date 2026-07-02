// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

// ─── v4-core ─────────────────────────────────────────────────────────────────
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

// ─── v4-periphery ────────────────────────────────────────────────────────────
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

// ─── project ─────────────────────────────────────────────────────────────────
import {StableProtectionHook} from "../src/StableProtectionHook.sol";

/// @title  DeployArc
/// @notice Deploys the FX-aware StableProtectionHook on Arc Testnet against the
///         existing "hero" PoolManager, creates + initializes the USDC/EURC pool
///         at the FX-fair price (from EUR_USD_X18), seeds liquidity, and sets the
///         pool's peg reference so the circuit breaker anchors to EUR/USD.
///
///         Env:
///           PRIVATE_KEY   deployer (also default hook owner); needs USDC gas +
///                         USDC & EURC balances to seed.
///           EUR_USD_X18   EUR/USD scaled by 1e18 (e.g. 1143240000000000000).
///           HOOK_OWNER    (optional) peg-reference admin; defaults to deployer.
///                         Set this to the keeper EOA (MANTUA_ADMIN_PRIVATE_KEY).
///           POOL_MANAGER  (optional) defaults to the Arc hero PoolManager.
///           SEED_L        (optional) liquidity units to seed; default 5_000e6.
///
///         Run:
///           forge script script/DeployArc.s.sol:DeployArc \
///             --rpc-url https://rpc.testnet.arc.network --broadcast -vvvv
contract DeployArc is Script {
    using PoolIdLibrary for PoolKey;

    // Arc Testnet hero PoolManager (Stable Protection stack).
    address constant DEFAULT_POOL_MANAGER = 0x15B5f2c054b9DC788250131FCD1bcfCC34080a59;
    // Standard CREATE2 proxy used by forge script --broadcast.
    address constant CREATE2_PROXY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    address constant USDC = 0x3600000000000000000000000000000000000000; // 6 dp
    address constant EURC = 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a; // 6 dp

    uint160 constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
    );

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        uint256 eurUsdX18 = vm.envUint("EUR_USD_X18");
        require(eurUsdX18 > 0, "EUR_USD_X18 required");
        address hookOwner = vm.envOr("HOOK_OWNER", deployer);
        address poolManager = vm.envOr("POOL_MANAGER", DEFAULT_POOL_MANAGER);
        uint256 seedL = vm.envOr("SEED_L", uint256(5_000e6));

        require(poolManager.code.length > 0, "PoolManager has no bytecode");
        IPoolManager manager = IPoolManager(poolManager);

        // ── 1. Mine + deploy the hook (owner = keeper EOA) ───────────────────
        (address hookAddr, bytes32 salt) = HookMiner.find(
            CREATE2_PROXY,
            HOOK_FLAGS,
            type(StableProtectionHook).creationCode,
            abi.encode(poolManager, hookOwner)
        );
        console2.log("Mined hook:", hookAddr);

        vm.startBroadcast(pk);

        StableProtectionHook hook =
            new StableProtectionHook{salt: salt}(manager, hookOwner);
        require(address(hook) == hookAddr, "hook address mismatch");
        console2.log("Deployed hook:", address(hook));

        // ── 2. Build the USDC/EURC pool key (USDC < EURC ⇒ c0=USDC) ──────────
        (Currency c0, Currency c1) = USDC < EURC
            ? (Currency.wrap(USDC), Currency.wrap(EURC))
            : (Currency.wrap(EURC), Currency.wrap(USDC));
        PoolKey memory key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
        PoolId id = key.toId();
        console2.log("PoolId:");
        console2.logBytes32(PoolId.unwrap(id));

        // ── 3. Initialize at the FX-fair price ───────────────────────────────
        // price(cur1/cur0) = EURC per USDC = 1/eurUsd (both 6 dp → no decimal
        // adjustment). sqrtPriceX96 = sqrt(price · 2^192) = sqrt(1e18·2^192 / ref).
        uint160 sqrtP = uint160(_sqrt((uint256(1e18) << 192) / eurUsdX18));
        require(sqrtP >= TickMath.MIN_SQRT_PRICE && sqrtP < TickMath.MAX_SQRT_PRICE, "sqrtP range");
        manager.initialize(key, sqrtP);
        console2.log("Initialized at sqrtPriceX96:", sqrtP);

        // ── 4. Seed liquidity around the fair tick ───────────────────────────
        _seedLiquidity(manager, key, sqrtP, seedL);

        // ── 5. Anchor the peg reference to EUR/USD ────────────────────────────
        hook.setPegReference(id, eurUsdX18);
        console2.log("Peg reference set (EUR/USD x18):", eurUsdX18);

        vm.stopBroadcast();

        console2.log("=== ARC STABLE PROTECTION (FX-AWARE) ===");
        console2.log("hook:       ", address(hook));
        console2.log("poolManager:", poolManager);
        console2.log("owner:      ", hookOwner);
        console2.log("Update HOOK_DEPLOYMENTS_ARC['stable-protection'].hook to the hook above.");
    }

    /// @dev Deploy a modify-liquidity router and seed a band around the fair tick.
    function _seedLiquidity(IPoolManager manager, PoolKey memory key, uint160 sqrtP, uint256 seedL)
        private
    {
        PoolModifyLiquidityTest liq = new PoolModifyLiquidityTest(manager);
        IERC20Minimal(USDC).approve(address(liq), type(uint256).max);
        IERC20Minimal(EURC).approve(address(liq), type(uint256).max);

        int24 fairTick = TickMath.getTickAtSqrtPrice(sqrtP);
        liq.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: fairTick - 1000,
                tickUpper: fairTick + 1000,
                liquidityDelta: int256(seedL),
                salt: bytes32(0)
            }),
            ""
        );
        console2.log("Seeded liquidity L:", seedL);
    }

    /// @dev Babylonian integer square root.
    function _sqrt(uint256 x) private pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
