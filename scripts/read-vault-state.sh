#!/usr/bin/env bash
# Read current vault state from Sepolia
# Usage: ./scripts/read-vault-state.sh

set -euo pipefail

FORGE="${FORGE:-/home/avi/.foundry/bin/forge}"
CAST="${CAST:-/home/avi/.foundry/bin/cast}"

# Load env
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../.env"

RPC="$SEPOLIA_RPC_URL"
VAULT="$VAULT_ADDRESS"
QM="$QUEUE_MANAGER_ADDRESS"
ADAPTER="$ADAPTER_ADDRESS"

echo "=== SDL CCIP Bridge - Vault State ==="
echo "Vault:   $VAULT"
echo "Adapter: $ADAPTER"
echo "Queue:   $QM"
echo ""

echo "--- Pause State ---"
GLOBAL=$($CAST call --rpc-url "$RPC" "$VAULT" "globalPaused()(bool)")
DEPOSIT=$($CAST call --rpc-url "$RPC" "$VAULT" "depositPaused()(bool)")
RESERVE=$($CAST call --rpc-url "$RPC" "$VAULT" "reservePaused()(bool)")
echo "Global:  $GLOBAL"
echo "Deposit: $DEPOSIT"
echo "Reserve: $RESERVE"
echo ""

echo "--- 5-Bucket Accounting ---"
FREE=$($CAST call --rpc-url "$RPC" "$VAULT" "freeLiquidityAssets()(uint256)")
RESERVED=$($CAST call --rpc-url "$RPC" "$VAULT" "reservedLiquidityAssets()(uint256)")
INFLIGHT=$($CAST call --rpc-url "$RPC" "$VAULT" "inFlightLiquidityAssets()(uint256)")
BAD_DEBT=$($CAST call --rpc-url "$RPC" "$VAULT" "badDebtReserveAssets()(uint256)")
PROTO_FEE=$($CAST call --rpc-url "$RPC" "$VAULT" "protocolFeeAccruedAssets()(uint256)")
TOTAL=$($CAST call --rpc-url "$RPC" "$VAULT" "totalAssets()(uint256)")
SUPPLY=$($CAST call --rpc-url "$RPC" "$VAULT" "totalSupply()(uint256)")
AVAIL=$($CAST call --rpc-url "$RPC" "$VAULT" "availableFreeLiquidityForLP()(uint256)")

echo "Free Liquidity:   $($CAST --from-wei "$FREE") LINK"
echo "Reserved:         $($CAST --from-wei "$RESERVED") LINK"
echo "In-Flight:        $($CAST --from-wei "$INFLIGHT") LINK"
echo "Bad Debt Reserve: $($CAST --from-wei "$BAD_DEBT") LINK"
echo "Protocol Fees:    $($CAST --from-wei "$PROTO_FEE") LINK"
echo "Total Assets:     $($CAST --from-wei "$TOTAL") LINK"
echo "Total Supply:     $($CAST --from-wei "$SUPPLY") lvLP"
echo "Available for LP: $($CAST --from-wei "$AVAIL") LINK"
echo ""

echo "--- Policy Parameters ---"
MAX_UTIL=$($CAST call --rpc-url "$RPC" "$VAULT" "maxUtilizationBps()(uint16)")
RESERVE_CUT=$($CAST call --rpc-url "$RPC" "$VAULT" "badDebtReserveCutBps()(uint16)")
HOT_RESERVE=$($CAST call --rpc-url "$RPC" "$VAULT" "targetHotReserveBps()(uint16)")
PROTO_FEE_BPS=$($CAST call --rpc-url "$RPC" "$VAULT" "protocolFeeBps()(uint16)")
PROTO_CAP=$($CAST call --rpc-url "$RPC" "$VAULT" "protocolFeeCapBps()(uint16)")
EMER_DELAY_RAW=$($CAST call --rpc-url "$RPC" "$VAULT" "emergencyReleaseDelay()(uint48)")
# cast returns "6000 [6e3]" style - extract just the integer
MAX_UTIL=$(echo "$MAX_UTIL" | awk '{print $1}')
RESERVE_CUT=$(echo "$RESERVE_CUT" | awk '{print $1}')
HOT_RESERVE=$(echo "$HOT_RESERVE" | awk '{print $1}')
PROTO_FEE_BPS=$(echo "$PROTO_FEE_BPS" | awk '{print $1}')
PROTO_CAP=$(echo "$PROTO_CAP" | awk '{print $1}')
EMER_DELAY=$(echo "$EMER_DELAY_RAW" | awk '{print $1}')
echo "Max Utilization:   ${MAX_UTIL} bps ($(( MAX_UTIL / 100 ))%)"
echo "Reserve Cut:       ${RESERVE_CUT} bps ($(( RESERVE_CUT / 100 ))%)"
echo "Hot Reserve:       ${HOT_RESERVE} bps ($(( HOT_RESERVE / 100 ))%)"
echo "Protocol Fee:      ${PROTO_FEE_BPS} bps"
echo "Protocol Fee Cap:  ${PROTO_CAP} bps"
echo "Emergency Delay:   ${EMER_DELAY}s ($(( EMER_DELAY / 3600 ))h)"
echo ""

echo "--- Queue ---"
PENDING=$($CAST call --rpc-url "$RPC" "$QM" "pendingCount()(uint256)")
echo "Pending Redemptions: $PENDING"
echo ""

echo "--- Adapter ---"
ADAPTER_VAULT=$($CAST call --rpc-url "$RPC" "$ADAPTER" "vault()(address)")
ADAPTER_ROUTER=$($CAST call --rpc-url "$RPC" "$ADAPTER" "getRouter()(address)")
echo "Adapter->Vault:  $ADAPTER_VAULT"
echo "Adapter->Router: $ADAPTER_ROUTER"
echo ""

echo "--- LINK/USD Price Feed ---"
RAW_PRICE=$($CAST call --rpc-url "$RPC" "$LINK_USD_FEED_SEPOLIA" "latestAnswer()(int256)" 2>/dev/null || echo "0")
# cast returns "876700000 [8.767e8]" - extract just the integer
PRICE=$(echo "$RAW_PRICE" | awk '{print $1}')
if [ "$PRICE" != "0" ]; then
  echo "LINK/USD: \$$(python3 -c "print(f'{$PRICE / 1e8:.2f}')")"
else
  echo "LINK/USD: (feed unavailable)"
fi

echo ""
echo "=== State read complete ==="
