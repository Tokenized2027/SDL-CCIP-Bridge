#!/usr/bin/env bash
# Simulate full bridge lifecycle on Sepolia
# Prerequisites: wallet must have LINK tokens on Sepolia
# Get LINK from: https://faucets.chain.link/sepolia
#
# This script drives the vault through all 5 stages:
#   1. LP deposits LINK into vault
#   2. OPS reserves liquidity for a bridge route
#   3. OPS executes fill (simulates solver)
#   4. Settlement (simulates CCIP callback)
#   5. LP withdraws
#
# Usage: ./scripts/simulate-bridge-lifecycle.sh [deposit_amount_link]
#   Default deposit: 5 LINK

set -euo pipefail

CAST="${CAST:-/home/avi/.foundry/bin/cast}"

# Load env
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../.env"

RPC="$SEPOLIA_RPC_URL"
PK="$PRIVATE_KEY"
VAULT="$VAULT_ADDRESS"
LINK="$LINK_TOKEN_SEPOLIA"

DEPOSIT_LINK="${1:-5}"
DEPOSIT_WEI=$($CAST --to-wei "$DEPOSIT_LINK")

echo "=== SDL CCIP Bridge - Lifecycle Simulation ==="
echo "Vault:   $VAULT"
echo "Deposit: $DEPOSIT_LINK LINK ($DEPOSIT_WEI wei)"
echo ""

# Check LINK balance
BALANCE=$($CAST call --rpc-url "$RPC" "$LINK" "balanceOf(address)(uint256)" "$DEPLOYER_ADDRESS")
echo "LINK balance: $($CAST --from-wei "$BALANCE") LINK"

if [ "$BALANCE" = "0" ]; then
  echo ""
  echo "ERROR: No LINK tokens. Get testnet LINK from:"
  echo "  https://faucets.chain.link/sepolia"
  echo "  Wallet: $DEPLOYER_ADDRESS"
  exit 1
fi

if [ "$(echo "$BALANCE < $DEPOSIT_WEI" | bc 2>/dev/null || python3 -c "print(int($BALANCE < $DEPOSIT_WEI))")" = "1" ]; then
  echo "WARNING: LINK balance ($($CAST --from-wei "$BALANCE")) < deposit ($DEPOSIT_LINK). Using max balance."
  DEPOSIT_WEI="$BALANCE"
  DEPOSIT_LINK=$($CAST --from-wei "$DEPOSIT_WEI")
fi

echo ""
echo "--- Step 1: Approve LINK for Vault ---"
TX=$($CAST send --rpc-url "$RPC" --private-key "$PK" \
  "$LINK" "approve(address,uint256)(bool)" "$VAULT" "$DEPOSIT_WEI" \
  --json | python3 -c "import sys,json; print(json.load(sys.stdin)['transactionHash'])")
echo "Approve tx: $TX"

echo ""
echo "--- Step 2: Deposit LINK into Vault ---"
TX=$($CAST send --rpc-url "$RPC" --private-key "$PK" \
  "$VAULT" "deposit(uint256,address)(uint256)" "$DEPOSIT_WEI" "$DEPLOYER_ADDRESS" \
  --json | python3 -c "import sys,json; print(json.load(sys.stdin)['transactionHash'])")
echo "Deposit tx: $TX"

# Read shares received
SHARES=$($CAST call --rpc-url "$RPC" "$VAULT" "balanceOf(address)(uint256)" "$DEPLOYER_ADDRESS")
echo "Shares received: $($CAST --from-wei "$SHARES") lvLP"

# Read vault state after deposit
FREE=$($CAST call --rpc-url "$RPC" "$VAULT" "freeLiquidityAssets()(uint256)")
TOTAL=$($CAST call --rpc-url "$RPC" "$VAULT" "totalAssets()(uint256)")
echo "Free liquidity: $($CAST --from-wei "$FREE") LINK"
echo "Total assets:   $($CAST --from-wei "$TOTAL") LINK"

# Reserve half the deposit
RESERVE_WEI=$(echo "$DEPOSIT_WEI / 2" | bc)
ROUTE_ID="0x$(openssl rand -hex 32)"

echo ""
echo "--- Step 3: Reserve Liquidity for Bridge Route ---"
echo "Route ID:   $ROUTE_ID"
echo "Amount:     $($CAST --from-wei "$RESERVE_WEI") LINK"
# reserveLiquidity takes 3 params: routeId, amount, expiry (uint64 unix timestamp)
EXPIRY=$(( $(date +%s) + 86400 ))
TX=$($CAST send --rpc-url "$RPC" --private-key "$PK" \
  "$VAULT" "reserveLiquidity(bytes32,uint256,uint64)" "$ROUTE_ID" "$RESERVE_WEI" "$EXPIRY" \
  --json | python3 -c "import sys,json; print(json.load(sys.stdin)['transactionHash'])")
echo "Reserve tx: $TX"

RESERVED=$($CAST call --rpc-url "$RPC" "$VAULT" "reservedLiquidityAssets()(uint256)")
echo "Reserved:   $($CAST --from-wei "$RESERVED") LINK"

# Generate a fill ID
FILL_ID="0x$(openssl rand -hex 32)"

echo ""
echo "--- Step 4: Execute Fill (Simulate Solver) ---"
echo "Fill ID: $FILL_ID"
TX=$($CAST send --rpc-url "$RPC" --private-key "$PK" \
  "$VAULT" "executeFill(bytes32,bytes32,uint256)" "$ROUTE_ID" "$FILL_ID" "$RESERVE_WEI" \
  --json | python3 -c "import sys,json; print(json.load(sys.stdin)['transactionHash'])")
echo "Fill tx: $TX"

INFLIGHT=$($CAST call --rpc-url "$RPC" "$VAULT" "inFlightLiquidityAssets()(uint256)")
echo "In-Flight: $($CAST --from-wei "$INFLIGHT") LINK"

# Settlement: simulate success via the settlement adapter
# We call reconcileSettlementSuccess directly on the vault (requires SETTLEMENT_ROLE)
# Since the adapter has SETTLEMENT_ROLE, we need to call through it.
# For simulation, we grant SETTLEMENT_ROLE to our deployer temporarily.

echo ""
echo "--- Step 5: Simulate Settlement (grant temp SETTLEMENT_ROLE) ---"

# Get SETTLEMENT_ROLE hash
SETTLEMENT_ROLE=$($CAST call --rpc-url "$RPC" "$VAULT" "SETTLEMENT_ROLE()(bytes32)")
echo "SETTLEMENT_ROLE: $SETTLEMENT_ROLE"

# Grant SETTLEMENT_ROLE to deployer
TX=$($CAST send --rpc-url "$RPC" --private-key "$PK" \
  "$VAULT" "grantRole(bytes32,address)" "$SETTLEMENT_ROLE" "$DEPLOYER_ADDRESS" \
  --json | python3 -c "import sys,json; print(json.load(sys.stdin)['transactionHash'])")
echo "Grant role tx: $TX"

# Simulate settlement success with 1% fee (fee = reserve_amount * 0.01)
FEE_WEI=$(echo "$RESERVE_WEI / 100" | bc)
echo "Settlement amount: $($CAST --from-wei "$RESERVE_WEI") LINK"
echo "Fee income:        $($CAST --from-wei "$FEE_WEI") LINK"

# First, transfer fee LINK to the vault (simulates CCIP delivering extra tokens)
TX=$($CAST send --rpc-url "$RPC" --private-key "$PK" \
  "$LINK" "transfer(address,uint256)(bool)" "$VAULT" "$FEE_WEI" \
  --json | python3 -c "import sys,json; print(json.load(sys.stdin)['transactionHash'])")
echo "Fee transfer tx: $TX"

# Call reconcileSettlementSuccess
TX=$($CAST send --rpc-url "$RPC" --private-key "$PK" \
  "$VAULT" "reconcileSettlementSuccess(bytes32,uint256,uint256)" "$FILL_ID" "$RESERVE_WEI" "$FEE_WEI" \
  --json | python3 -c "import sys,json; print(json.load(sys.stdin)['transactionHash'])")
echo "Settlement tx: $TX"

# Read post-settlement state
FREE=$($CAST call --rpc-url "$RPC" "$VAULT" "freeLiquidityAssets()(uint256)")
BAD_DEBT=$($CAST call --rpc-url "$RPC" "$VAULT" "badDebtReserveAssets()(uint256)")
PROTO_FEE=$($CAST call --rpc-url "$RPC" "$VAULT" "protocolFeeAccruedAssets()(uint256)")
TOTAL=$($CAST call --rpc-url "$RPC" "$VAULT" "totalAssets()(uint256)")
INFLIGHT=$($CAST call --rpc-url "$RPC" "$VAULT" "inFlightLiquidityAssets()(uint256)")

echo ""
echo "--- Post-Settlement State ---"
echo "Free Liquidity:   $($CAST --from-wei "$FREE") LINK"
echo "In-Flight:        $($CAST --from-wei "$INFLIGHT") LINK"
echo "Bad Debt Reserve: $($CAST --from-wei "$BAD_DEBT") LINK"
echo "Protocol Fees:    $($CAST --from-wei "$PROTO_FEE") LINK"
echo "Total Assets:     $($CAST --from-wei "$TOTAL") LINK"

# Revoke SETTLEMENT_ROLE from deployer (cleanup)
TX=$($CAST send --rpc-url "$RPC" --private-key "$PK" \
  "$VAULT" "revokeRole(bytes32,address)" "$SETTLEMENT_ROLE" "$DEPLOYER_ADDRESS" \
  --json | python3 -c "import sys,json; print(json.load(sys.stdin)['transactionHash'])")
echo ""
echo "Revoked temp SETTLEMENT_ROLE: $TX"

echo ""
echo "=== Lifecycle Simulation Complete ==="
echo ""
echo "The vault now has real state on Sepolia."
echo "Run CRE workflows to monitor it:"
echo "  ./scripts/bridge-unified-cycle.sh"
echo ""
echo "Read current state:"
echo "  ./scripts/read-vault-state.sh"
