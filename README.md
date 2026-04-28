# Stable Protection Hook

A Uniswap v4 hook that protects stablecoin liquidity providers from depeg events through real-time peg monitoring, graduated dynamic fees, and an automatic circuit breaker.

Built for the **Atrium Academy UHI8 Hookathon** · Deployed on **Unichain Sepolia** (Chain ID 1301) and **Base Sepolia** (Chain ID 84532)

---

## Overview

Stablecoin pools on constant-product AMMs are especially vulnerable to depegging: as a stablecoin drifts from its $1 peg, arbitrageurs drain the pool at the expense of passive LPs. The Stable Protection Hook addresses this by:

- **Monitoring** real-time peg deviation on every swap using virtual reserves derived from `sqrtPriceX96` and pool liquidity — no oracle required, no off-chain reliance.
- **Applying graduated dynamic fees** that penalise swaps worsening the depeg and discount swaps that restore it, keeping LP revenue healthy under stress.
- **Blocking swaps entirely** via a circuit breaker when deviation exceeds 5% (500 bps), preventing catastrophic draining during a depeg crisis.

---

## Architecture

```
                   ┌─────────────────────────────────────────┐
                   │          Uniswap v4 PoolManager          │
                   └──────┬──────────────────────┬────────────┘
                          │ beforeSwap            │ afterSwap
                          ▼                       ▼
                   ┌────────────────────────────────────────┐
                   │         StableProtectionHook           │
                   │                                        │
                   │  _getVirtualReservesNormalized()        │
                   │   vr0 = L × Q96 / sqrtPriceX96         │
                   │   vr1 = L × sqrtPriceX96 / Q96         │
                   │                │                        │
                   │   PegMonitor.classifyZone()             │
                   │   deviation = |r0−r1|×10000 / avg       │
                   │                │                        │
                   │        ┌───────┴────────┐               │
                   │        │                │               │
                   │   CRITICAL?        other zone           │
                   │   revert CB     dynamic fee             │
                   │                 OVERRIDE_FEE_FLAG       │
                   └────────────────────────────────────────┘
```

### Hook Lifecycle

| Hook Point | Action |
|---|---|
| `beforeInitialize` | Validates pool uses `DYNAMIC_FEE_FLAG`; stores default `PoolConfig`; seeds zone as HEALTHY |
| `beforeSwap` | Reads virtual reserves → classifies zone → blocks if CRITICAL → returns `fee \| OVERRIDE_FEE_FLAG` |
| `afterSwap` | Re-reads reserves → reclassifies zone → emits `ZoneChanged` if shifted → snapshots state |

---

## 5-Zone Peg System

Deviation is computed as:

```
deviationBps = |reserve0 − reserve1| × 10000 / ((reserve0 + reserve1) / 2)
```

| Zone | Threshold | Base Fee | Dynamic A | Behaviour |
|---|---|---|---|---|
| HEALTHY | ≤ 0.10% (10 bps) | 1 bps | 100% of A | Normal trading |
| MINOR | ≤ 0.50% (50 bps) | 5 bps | 80% of A | Mild stress |
| MODERATE | ≤ 2.00% (200 bps) | 15 bps | 50% of A | Elevated risk |
| SEVERE | ≤ 5.00% (500 bps) | 50 bps | 25% of A | High risk |
| CRITICAL | > 5.00% (500 bps) | — | 10% of A | **Swaps blocked** |

### Directional Fee Multipliers

Each zone's base fee is scaled by swap direction relative to the peg:

| Direction | Multiplier | Rationale |
|---|---|---|
| Toward-peg | × 0.5 | Discounted — incentivises peg restoration |
| Away-from-peg | × 3.0 | Premium — disincentivises worsening depeg |

### Full Fee Schedule

| Zone | Toward-peg fee | Away-from-peg fee |
|---|---|---|
| HEALTHY | 0.5 bps | 3 bps |
| MINOR | 2.5 bps | 15 bps |
| MODERATE | 7.5 bps | 45 bps |
| SEVERE | 25 bps | 100 bps (capped) |
| CRITICAL | circuit breaker — swaps blocked | |

---

## Virtual Reserves

The hook derives virtual reserves directly from Uniswap v4's on-chain state — no oracle, no incremental storage tracking:

```
virtual_r0 = L × 2^96 / sqrtPriceX96
virtual_r1 = L × sqrtPriceX96 / 2^96
```

This approximates the "as-if constant-product" reserves at the current price tick. Reserves are normalised to 18-decimal precision before zone classification, supporting any token decimal configuration (1–18).

---

## Project Structure

```
src/
├── types/
│   └── SPTypes.sol                  Enums, structs, errors, events
├── libraries/
│   ├── StableSwapMath.sol           StableSwap D-invariant, getY, swap output
│   ├── PegMonitor.sol               Zone classification, fee calc, dynamic A
│   └── SPConfig.sol                 PoolConfig validation
├── interfaces/
│   └── IStableProtectionHook.sol    External view interface
├── mocks/
│   └── MockStablecoin.sol           ERC-20 for testnet deployments
└── StableProtectionHook.sol         Main hook contract

test/
├── unit/
│   ├── StableSwapMath.t.sol         16 tests (incl. fuzz)
│   ├── PegMonitor.t.sol             30 tests (incl. fuzz)
│   └── StableProtectionHook.t.sol   26 tests (TestableHook harness)
└── integration/
    └── StableProtectionHook.integration.t.sol   9 tests (full PoolManager stack)

script/
├── Deploy.s.sol                     Full deploy on Unichain Sepolia (mock tUSDC/tUSDT)
├── DeployBaseSepolia.s.sol          Full deploy on Base Sepolia (real Circle USDC/EURC)
└── TestPoolSwap.s.sol               Standalone: new pool + swap on existing hook
```

---

## Test Suite

**81 tests · 0 failures · 0 skipped**

```
StableSwapMathTest                    16 passed  (incl. fuzz: getSwapOutput × 256 runs)
PegMonitorTest                        30 passed  (incl. fuzz: neverExceedsMaxFee × 256 runs)
StableProtectionHookTest              26 passed  (TestableHook harness — no PoolManager needed)
StableProtectionHookIntegrationTest    9 passed  (HookMiner + real PoolManager)
```

Run the full suite:

```bash
forge test --summary
```

---

## Setup

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Git (with submodule support)

### Clone & install

```bash
git clone https://github.com/<your-username>/stableprotection-hook
cd stableprotection-hook
forge install
```

### Build

```bash
forge build
```

### Test

```bash
forge test --summary
```

### Deploy to Unichain Sepolia

```bash
cp .env.example .env   # add PRIVATE_KEY and UNICHAIN_SEPOLIA_RPC
source .env

forge script script/Deploy.s.sol:Deploy \
  --rpc-url unichain_sepolia \
  --broadcast \
  --verify \
  -vvvv
```

### Deploy to Base Sepolia

Uses Circle's official testnet **USDC** and **EURC** on Base Sepolia — no mock tokens deployed. The deployer wallet must hold ≥ 60 USDC and ≥ 60 EURC (faucets: [Circle USDC](https://faucet.circle.com/), [Circle EURC](https://faucet.circle.com/)).

```bash
cp .env.example .env   # add PRIVATE_KEY and BASE_SEPOLIA_RPC
source .env

forge script script/DeployBaseSepolia.s.sol:DeployBaseSepolia \
  --rpc-url base_sepolia \
  --broadcast \
  --slow \
  -vvvv
```

Required `.env` variables:

```
PRIVATE_KEY=0x...
UNICHAIN_SEPOLIA_RPC=https://sepolia.unichain.org
BASE_SEPOLIA_RPC=https://sepolia.base.org
ETHERSCAN_API_KEY=<uniscan-api-key>
BASESCAN_API_KEY=<basescan-api-key>
```

---

## Deployed Addresses — Base Sepolia (Chain ID 84532)

| Contract | Address | Basescan |
|---|---|---|
| StableProtectionHook | `0xe5e6a9E09Ad1e536788f0c142AD5bc69e8B020C0` | [view](https://sepolia.basescan.org/address/0xe5e6a9E09Ad1e536788f0c142AD5bc69e8B020C0) |
| USDC (Circle) | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` | [view](https://sepolia.basescan.org/address/0x036CbD53842c5426634e7929541eC2318f3dCF7e) |
| EURC (Circle) | `0x808456652fdb597867f38412077A9182bf77359F` | [view](https://sepolia.basescan.org/address/0x808456652fdb597867f38412077A9182bf77359F) |
| PoolManager (v4) | `0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408` | [view](https://sepolia.basescan.org/address/0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408) |

**Pool ID**: `0x8e929e2af7edea4c196aa0718602f0892b7ecbc205491ffb170640ca75b3c4ab`
**Pair**: USDC / EURC (currency0 = USDC, currency1 = EURC; both 6-decimal)
**Tick spacing**: 1 · **Fee**: dynamic · **Tick range at deploy**: `[-10, 10]`

### End-to-End Verified Transactions

| Action | Basescan |
|---|---|
| Hook deployed (CREATE2) | [0xad6032…](https://sepolia.basescan.org/tx/0xad6032f043fd55783f0d5a7ce015d68ef8bd50f3dde0dde6838a2b1d27d017ef) |
| Pool created (`initialize`) | [0x5cc896…](https://sepolia.basescan.org/tx/0x5cc896b9bb6e2501d49554a70951d9f2d8ca16b53f2cd98092eea56357e8e4eb) |
| Liquidity added (~50 USDC + ~50 EURC) | [0xd93732…](https://sepolia.basescan.org/tx/0xd937322f8aa9051e1fc9e6e8e29cd764ca558e2b969d44ccabf2a5a32633543a) |
| Test swap (5 USDC → EURC) | [0x53c8f0…](https://sepolia.basescan.org/tx/0x53c8f07ae248c4cf7b14126e0aaf5dfd0d236c40e3daa9a1c1d8a1aad8e9a884) |

Post-swap on-chain state read from `getZoneState(poolId)`: zone = **HEALTHY**, `currentDeviationBps` = **0**, confirming `beforeSwap` (dynamic fee applied via `OVERRIDE_FEE_FLAG`) and `afterSwap` (zone snapshot updated) executed correctly against the real Circle stablecoins.

---

## Deployed Addresses — Unichain Sepolia (Chain ID 1301)

| Contract | Address | Uniscan |
|---|---|---|
| StableProtectionHook | `0x1510926ba6986cb3c93BFFF25839C0ef740820c0` | [view](https://sepolia.uniscan.xyz/address/0x1510926ba6986cb3c93BFFF25839C0ef740820c0) |
| tUSDC | `0x3D0aD0014933b87332BE00E832D16d219c65346c` | [view](https://sepolia.uniscan.xyz/address/0x3D0aD0014933b87332BE00E832D16d219c65346c) |
| tUSDT | `0xEa3B5B015a5289bE6fFa7196aF5386A86E50a8c2` | [view](https://sepolia.uniscan.xyz/address/0xEa3B5B015a5289bE6fFa7196aF5386A86E50a8c2) |
| PoolManager | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` | [view](https://sepolia.uniscan.xyz/address/0x00B036B58a818B1BC34d502D3fE730Db729e62AC) |

### Verified Transactions

| Action | Uniscan |
|---|---|
| Hook deployed (CREATE2) | [0xb69507…](https://sepolia.uniscan.xyz/tx/0xb69507632516000a95b260fc1d3154b54fc270a6d8d5c5e7ee964c28ec69dbc1) |
| Pool created (`initialize`) | [0x1ba84a…](https://sepolia.uniscan.xyz/tx/0x1ba84a6d33f16c5afce8c8fcd2a674c1d8c3745b0107af5b06a3d5cf50a8d7e2) |
| Liquidity added | [0x057661…](https://sepolia.uniscan.xyz/tx/0x057661ec12166ecd602eb647c40b134296bbd5f38e4da237085e22a874afdd3c) |
| Test swap (10 tUSDC → tUSDT) | [0x6af6e9…](https://sepolia.uniscan.xyz/tx/0x6af6e96ac2d101a61d70d2b95fa23fcfa5842bce5153745da84deadc393134ee) |

The swap exercised `beforeSwap` (HEALTHY zone, 0.5 bps fee applied via `OVERRIDE_FEE_FLAG`) and `afterSwap` (zone snapshot updated).

---

## Hook Deployment Requirements

The hook address encodes permissions in its lowest 14 bits (Uniswap v4 convention). The required flags:

```solidity
uint160 flags = uint160(
    Hooks.BEFORE_INITIALIZE_FLAG |  // bit 13
    Hooks.BEFORE_SWAP_FLAG       |  // bit  7
    Hooks.AFTER_SWAP_FLAG           // bit  6
);
```

Use `HookMiner.find(CREATE2_PROXY, flags, creationCode, constructorArgs)` to mine the correct CREATE2 salt. The `Deploy.s.sol` script handles this automatically.

### Pool Requirements

| Parameter | Required value |
|---|---|
| `fee` | `LPFeeLibrary.DYNAMIC_FEE_FLAG` (0x800000) |
| `tickSpacing` | Any; 1 recommended for stablecoin pairs |
| Token decimals | 1–18 (hook normalises to 18 internally) |

---

## Partner Integrations

### ai-assisted-security-analysis

Automated static analysis and security scanning of the hook contract and supporting libraries. Provides vulnerability detection and audit tooling across the Solidity codebase. https://github.com/trailofbits/skills

### uniswap-ai

Research tooling and reference implementations from the Uniswap AI ecosystem. Contributed to advanced AMM pattern research and hook development workflow during the hackathon build. https://github.com/Uniswap/uniswap-ai

---

## Dependencies

| Package | Version / Commit | Purpose |
|---|---|---|
| `uniswap/v4-core` | via `v4-periphery` | PoolManager, hook interfaces, StateLibrary |
| `uniswap/v4-periphery` | `eeb3eff` | BaseHook, HookMiner |
| `transmissions11/solmate` | via `v4-core` | ERC-20 base, arithmetic |
| `foundry-rs/forge-std` | latest | Testing framework, scripting |

---

## License

MIT
