#!/usr/bin/env bash
#
# deploy_arc.sh — Full StableProtectionHook deployment on Arc Testnet (chain 5042002).
#
# Why this wrapper exists:
#   Arc's USDC/EURC are native fiat tokens whose transfers run through chain-level
#   precompiles that Foundry's local EVM cannot execute. `forge script` executes the
#   script locally to build its broadcast list, so any token transfer reverts there.
#   We therefore split the deploy:
#     1. forge script  -> deploy v4 stack + hook + initialize pool  (no token moves)
#     2. cast send     -> approvals + add liquidity + test swap     (run on the live node)
#
# Prerequisites:
#   - Foundry installed; deployer key imported as a keystore:
#       cast wallet new ~/.foundry/keystores arc-deployer   (or `cast wallet import`)
#   - Deployer funded with >= 20 USDC and >= 15 EURC on Arc (https://faucet.circle.com)
#
# Usage:
#   ./script/deploy_arc.sh <deployer-address> [keystore-account-name]
#   e.g.  ./script/deploy_arc.sh 0xceeD79dBB39bA3C6Cddb57eb6343BE25FfD6dd56 arc-deployer
#
set -euo pipefail

# ── Inputs ────────────────────────────────────────────────────────────────────
SENDER="${1:?Usage: deploy_arc.sh <deployer-address> [keystore-account]}"
ACCOUNT="${2:-arc-deployer}"

export ARC_TESTNET_RPC_URL="${ARC_TESTNET_RPC_URL:-https://rpc.testnet.arc.network}"
RPC="$ARC_TESTNET_RPC_URL"

# Arc Testnet constants
USDC=0x3600000000000000000000000000000000000000
EURC=0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a
FEE=8388608          # LPFeeLibrary.DYNAMIC_FEE_FLAG (0x800000)
TICK_SPACING=1
MAX_UINT=115792089237316195423570985008687907853269984665640564039457584007913129639935
ZERO_SALT=0x0000000000000000000000000000000000000000000000000000000000000000
LIQUIDITY_DELTA=30000000000   # ~15 USDC + ~15 EURC in tick range [-10, 10]
SWAP_AMOUNT=-5000000          # exact-input 5 USDC -> EURC
MIN_SQRT_PLUS_1=4295128740    # TickMath.MIN_SQRT_PRICE + 1 (limit for zeroForOne)

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# ── Signer config ─────────────────────────────────────────────────────────────
# Preferred: a keystore account (interactive password, stays local).
# Fallback:  PRIVATE_KEY env var (e.g. PRIVATE_KEY=0x... ./deploy_arc.sh ...) —
#            convenient for throwaway testnet wallets; never use a real-value key.
if [ -n "${PRIVATE_KEY:-}" ]; then
  WALLET=(--private-key "$PRIVATE_KEY")
else
  read -r -s -p "Keystore password for '$ACCOUNT': " KS_PW; echo
  WALLET=(--account "$ACCOUNT" --password "$KS_PW")
fi

echo "==> 1/4  Deploying v4 stack + hook + initializing USDC/EURC pool (forge script)"
forge script script/DeployArcTestnet.s.sol:DeployArcTestnet \
  --rpc-url arc_testnet \
  --sender "$SENDER" "${WALLET[@]}" \
  --broadcast --slow -vv

RUN_JSON="broadcast/DeployArcTestnet.s.sol/5042002/run-latest.json"
[ -f "$RUN_JSON" ] || { echo "ERROR: broadcast file not found: $RUN_JSON"; exit 1; }

pick() { jq -r --arg n "$1" '.transactions[] | select(.contractName==$n) | .contractAddress' "$RUN_JSON" | head -1; }
POOL_MANAGER="$(pick PoolManager)"
LIQ_ROUTER="$(pick PoolModifyLiquidityTest)"
SWAP_ROUTER="$(pick PoolSwapTest)"
HOOK="$(pick StableProtectionHook)"

echo "    PoolManager: $POOL_MANAGER"
echo "    LiqRouter:   $LIQ_ROUTER"
echo "    SwapRouter:  $SWAP_ROUTER"
echo "    Hook:        $HOOK"
[ -n "$HOOK" ] && [ -n "$POOL_MANAGER" ] || { echo "ERROR: failed to parse deployed addresses"; exit 1; }

# currency0 < currency1 ; USDC (0x36..) < EURC (0x89..) so c0=USDC, c1=EURC
KEY="($USDC,$EURC,$FEE,$TICK_SPACING,$HOOK)"
POOL_ID="$(cast keccak "$(cast abi-encode 'f((address,address,uint24,int24,address))' "$KEY")")"

echo "==> 2/4  Approving routers to pull USDC + EURC"
cast send "$USDC" "approve(address,uint256)" "$LIQ_ROUTER"  "$MAX_UINT" --rpc-url "$RPC" "${WALLET[@]}" >/dev/null
cast send "$EURC" "approve(address,uint256)" "$LIQ_ROUTER"  "$MAX_UINT" --rpc-url "$RPC" "${WALLET[@]}" >/dev/null
cast send "$USDC" "approve(address,uint256)" "$SWAP_ROUTER" "$MAX_UINT" --rpc-url "$RPC" "${WALLET[@]}" >/dev/null
cast send "$EURC" "approve(address,uint256)" "$SWAP_ROUTER" "$MAX_UINT" --rpc-url "$RPC" "${WALLET[@]}" >/dev/null
echo "    approvals done"

echo "==> 3/4  Adding liquidity (~15 USDC + ~15 EURC, range [-10,10])"
LIQ_TX="$(cast send "$LIQ_ROUTER" \
  "modifyLiquidity((address,address,uint24,int24,address),(int24,int24,int256,bytes32),bytes)" \
  "$KEY" "(-10,10,$LIQUIDITY_DELTA,$ZERO_SALT)" "0x" \
  --rpc-url "$RPC" "${WALLET[@]}" --json | jq -r '.transactionHash')"
echo "    liquidity tx: $LIQ_TX"

echo "==> 4/4  Test swap (5 USDC -> EURC)"
SWAP_TX="$(cast send "$SWAP_ROUTER" \
  "swap((address,address,uint24,int24,address),(bool,int256,uint160),(bool,bool),bytes)" \
  "$KEY" "(true,$SWAP_AMOUNT,$MIN_SQRT_PLUS_1)" "(false,false)" "0x" \
  --rpc-url "$RPC" "${WALLET[@]}" --json | jq -r '.transactionHash')"
echo "    swap tx: $SWAP_TX"

echo "==> Reading hook zone state for pool $POOL_ID"
cast call "$HOOK" "getZoneState(bytes32)(uint8,uint256,uint256,uint256)" "$POOL_ID" --rpc-url "$RPC" || true
cast call "$HOOK" "currentDeviationBps(bytes32)(uint256)" "$POOL_ID" --rpc-url "$RPC" || true

echo
echo "=== ARC TESTNET DEPLOYMENT COMPLETE ==="
echo "PoolManager: $POOL_MANAGER"
echo "LiqRouter:   $LIQ_ROUTER"
echo "SwapRouter:  $SWAP_ROUTER"
echo "Hook:        $HOOK"
echo "PoolId:      $POOL_ID"
echo "Liquidity tx: $LIQ_TX"
echo "Swap tx:      $SWAP_TX"
echo "Explorer: https://testnet.arcscan.app/address/$HOOK"
echo "======================================="
