#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAPSHOT_PATH="${SNAPSHOT_PATH:-${ROOT_DIR}/../../intelligence/data/cre_vault_health_snapshot.json}"
CRE_BIN="${CRE_BIN:-${HOME}/.local/bin/cre}"

if [ -x "${HOME}/.bun/bin/bun" ]; then
  export PATH="${HOME}/.bun/bin:${PATH}"
fi

if [ ! -x "${CRE_BIN}" ]; then
  echo "CRE binary not found or not executable at ${CRE_BIN}" >&2
  exit 1
fi

if [ "$#" -gt 0 ]; then
  TARGETS=("$@")
else
  TARGETS=("staging-settings")
fi

tmp_dir="$(mktemp -d)"
tmp_json="$(mktemp)"
cleanup() {
  rm -rf "${tmp_dir}" "${tmp_json}"
}
trap cleanup EXIT

cd "${ROOT_DIR}"

run_target() {
  local target="$1"
  local out_file="$2"
  local max_attempts=3
  local attempt=1

  while true; do
    echo "Running CRE simulate for ${target} (attempt ${attempt}/${max_attempts})..."
    if "${CRE_BIN}" workflow simulate my-workflow --target "${target}" | tee "${out_file}"; then
      return 0
    fi

    if [ "${attempt}" -ge "${max_attempts}" ]; then
      echo "CRE simulate failed for ${target} after ${max_attempts} attempts." >&2
      return 1
    fi

    attempt=$((attempt + 1))
    sleep 2
  done
}

output_files=()
for target in "${TARGETS[@]}"; do
  out_file="${tmp_dir}/${target}.log"
  run_target "${target}" "${out_file}"
  output_files+=("${out_file}")
done

python3 - "${tmp_json}" "${SNAPSHOT_PATH}" "${output_files[@]}" <<'PY'
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path


def parse_output(text: str) -> dict | None:
    marker_matches = re.findall(r"VAULT_HEALTH_CRE_OUTPUT_JSON=(\{.*\})", text)
    if marker_matches:
        try:
            return json.loads(marker_matches[-1])
        except Exception:
            pass

    decoder = json.JSONDecoder()
    for idx in range(len(text)):
        try:
            obj, _ = decoder.raw_decode(text[idx:])
        except Exception:
            continue
        if isinstance(obj, dict) and "buckets" in obj:
            return obj
    return None


tmp_json_path = Path(sys.argv[1])
snapshot_path = Path(sys.argv[2])
raw_paths = [Path(p) for p in sys.argv[3:]]

parsed = None
for raw_path in raw_paths:
    text = raw_path.read_text(encoding="utf-8", errors="replace")
    parsed = parse_output(text)
    if parsed:
        break

if not parsed:
    raise SystemExit("Could not find structured vault-health workflow output")

snapshot = {
    "generated_at_utc": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    "source": "cre_simulate",
    "chain_name": parsed.get("chainName", "unknown"),
    **parsed,
}

snapshot_path.parent.mkdir(parents=True, exist_ok=True)
tmp_json_path.write_text(json.dumps(snapshot, indent=2), encoding="utf-8")
tmp_json_path.replace(snapshot_path)
print(f"Wrote vault-health snapshot to {snapshot_path}")
PY
