#!/usr/bin/env bash
# Bridge Unified Cycle: runs all 3 CRE workflows, composite intelligence, and proof writes.
# Schedule: 7x/day via cron (0 0 0,3,7,10,14,17,21 * * *)
set -euo pipefail

export HOME="/home/avi"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
DATA_DIR="${ROOT_DIR}/intelligence/data"
LOG_DIR="${ROOT_DIR}/intelligence/logs"
LOCK_FILE="/tmp/bridge-unified-cycle.lock"

mkdir -p "${DATA_DIR}" "${LOG_DIR}"

exec 200>"${LOCK_FILE}"
if ! flock -n 200; then
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] Another cycle is running. Exiting."
  exit 0
fi

TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
LOG_FILE="${LOG_DIR}/cycle-${TIMESTAMP//[:\/]/-}.log"

echo "[${TIMESTAMP}] === Bridge Unified Cycle Start ===" | tee "${LOG_FILE}"

# ─── Phase 1: CRE Workflow Simulations (parallel) ───

run_workflow() {
  local name="$1"
  local dir="$2"
  local snapshot="$3"

  echo "[$(date -u '+%H:%M:%S')] Starting ${name}..." | tee -a "${LOG_FILE}"
  if SNAPSHOT_PATH="${DATA_DIR}/${snapshot}" bash "${ROOT_DIR}/workflows/${dir}/run_snapshot.sh" staging-settings >> "${LOG_FILE}" 2>&1; then
    echo "[$(date -u '+%H:%M:%S')] ${name}: OK" | tee -a "${LOG_FILE}"
  else
    echo "[$(date -u '+%H:%M:%S')] ${name}: FAILED" | tee -a "${LOG_FILE}"
  fi
}

run_workflow "vault-health"      "vault-health"      "cre_vault_health_snapshot.json" &
run_workflow "bridge-ai-advisor" "bridge-ai-advisor"  "cre_bridge_advisor_snapshot.json" &
run_workflow "queue-monitor"     "queue-monitor"      "cre_queue_monitor_snapshot.json" &

wait
echo "[$(date -u '+%H:%M:%S')] Phase 1 complete: all workflows finished" | tee -a "${LOG_FILE}"

# ─── Phase 1.5: Composite Intelligence ───

echo "[$(date -u '+%H:%M:%S')] Starting composite intelligence..." | tee -a "${LOG_FILE}"
if node "${SCRIPT_DIR}/composite-bridge-intelligence.mjs" >> "${LOG_FILE}" 2>&1; then
  echo "[$(date -u '+%H:%M:%S')] Composite: OK" | tee -a "${LOG_FILE}"
else
  echo "[$(date -u '+%H:%M:%S')] Composite: FAILED (non-fatal)" | tee -a "${LOG_FILE}"
fi

# ─── Phase 2: On-Chain Proof Writes ───

# Load env vars (PRIVATE_KEY, SEPOLIA_RPC_URL, etc.)
if [ -f "${ROOT_DIR}/.env" ]; then
  set -a; source "${ROOT_DIR}/.env"; set +a
fi

echo "[$(date -u '+%H:%M:%S')] Starting proof writes..." | tee -a "${LOG_FILE}"
if node "${SCRIPT_DIR}/record-bridge-proofs.mjs" >> "${LOG_FILE}" 2>&1; then
  echo "[$(date -u '+%H:%M:%S')] Proofs: OK" | tee -a "${LOG_FILE}"
else
  echo "[$(date -u '+%H:%M:%S')] Proofs: FAILED (non-fatal)" | tee -a "${LOG_FILE}"
fi

echo "[$(date -u '+%H:%M:%S')] === Bridge Unified Cycle Complete ===" | tee -a "${LOG_FILE}"
