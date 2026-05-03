#!/usr/bin/env bash
set -euo pipefail

# Runs Gauss-method experiments from a JSON file on PARCS-Go.
#
# Required:
#   LEADER_URL=tcp://docker-proxy:4321
#
# Optional:
#   INPUT_JSON=<path>      # default: ./scripts/experiments.json
#   EXPERIMENT=<name>      # default: all (run all from JSON)
#   NUM_WORKERS=<n>        # global default workers if case does not define num_workers
#   SKIP_PUSH=1            # recommended for local runs
#   REGISTRY_NAMESPACE=local
#
# Each experiment in the JSON must have either:
#   "matrix": [...]        — explicit augmented matrix (small/fixed inputs)
#   "size": <n>            — generate a random n×n diagonally dominant matrix
#                            "seed": <int>  optional RNG seed (default: 42)
#
# Example:
#   LEADER_URL=tcp://docker-proxy:4321 SKIP_PUSH=1 ./scripts/experiments.sh
#   LEADER_URL=tcp://docker-proxy:4321 EXPERIMENT=case1000_w4 SKIP_PUSH=1 ./scripts/experiments.sh

if [[ -z "${LEADER_URL:-}" ]]; then
  echo "LEADER_URL is required (e.g. tcp://docker-proxy:4321)"
  exit 1
fi

INPUT_JSON="${INPUT_JSON:-./scripts/experiments.json}"
EXPERIMENT="${EXPERIMENT:-all}"
NUM_WORKERS="${NUM_WORKERS:-2}"
REGISTRY_NAMESPACE="${REGISTRY_NAMESPACE:-local}"
SKIP_PUSH="${SKIP_PUSH:-1}"

if [[ ! -f "${INPUT_JSON}" ]]; then
  echo "Input JSON file not found: ${INPUT_JSON}"
  exit 1
fi

# Output: name TAB workers TAB matrix TAB size TAB seed
# matrix is empty string for size-based experiments; size/seed empty for matrix-based.
build_experiment_list() {
  python3 - "${INPUT_JSON}" "${EXPERIMENT}" "${NUM_WORKERS}" <<'PY'
import json
import sys

json_path = sys.argv[1]
selected = sys.argv[2]
default_workers = int(sys.argv[3])

with open(json_path, "r", encoding="utf-8") as f:
    data = json.load(f)

if isinstance(data, dict):
    experiments = data.get("experiments", [])
elif isinstance(data, list):
    experiments = data
else:
    raise SystemExit("JSON must be either an array or an object with 'experiments' key")

if not experiments:
    raise SystemExit("No experiments found in input JSON")

names = {item.get("name") for item in experiments if isinstance(item, dict)}
if selected != "all" and selected not in names:
    raise SystemExit(f"Experiment '{selected}' not found in {json_path}")

for item in experiments:
    if not isinstance(item, dict):
        raise SystemExit("Each experiment must be an object")

    name = item.get("name")
    matrix = item.get("matrix")
    size = item.get("size")
    seed = item.get("seed", 42)
    workers = int(item.get("num_workers", default_workers))

    if not name:
        raise SystemExit("Each experiment must have a non-empty 'name'")
    if selected != "all" and name != selected:
        continue
    if matrix is None and size is None:
        raise SystemExit(f"Experiment '{name}' must have either 'matrix' or 'size'")
    if size is not None and (not isinstance(size, int) or size <= 0):
        raise SystemExit(f"Experiment '{name}' has invalid size={size}")
    if workers <= 0:
        raise SystemExit(f"Experiment '{name}' has invalid num_workers={workers}")

    if matrix is not None:
        matrix_compact = json.dumps(matrix, separators=(",", ":"))
        print(f"{name}|{workers}|{matrix_compact}||")
    else:
        print(f"{name}|{workers}||{size}|{seed}")
PY
}

run_case() {
  local name="$1"
  local workers="$2"
  local matrix="$3"
  local size="$4"
  local seed="$5"
  local service_name="gauss-${name}"
  local output
  local rc
  local service_logs
  local algo_ms
  local solution
  local status

  echo
  echo "============================================================"
  echo "Running experiment: ${name}"
  echo "NUM_WORKERS=${workers}"
  if [[ -n "${size}" ]]; then
    echo "SIZE=${size}  SEED=${seed:-42}"
  else
    echo "MATRIX_LEN=${#matrix}"
  fi
  echo "SERVICE_NAME=${service_name}"
  echo "============================================================"

  set +e
  if [[ -n "${size}" ]]; then
    output="$(
      LEADER_URL="${LEADER_URL}" \
      REGISTRY_NAMESPACE="${REGISTRY_NAMESPACE}" \
      WORKER_IMAGE_NAME=gauss-worker \
      RUNNER_IMAGE_NAME=gauss-runner \
      NUM_WORKERS="${workers}" \
      SIZE="${size}" \
      SEED="${seed:-42}" \
      SERVICE_NAME="${service_name}" \
      SKIP_PUSH="${SKIP_PUSH}" \
      ./scripts/run.sh \
      2>&1
    )"
  else
    output="$(
      LEADER_URL="${LEADER_URL}" \
      REGISTRY_NAMESPACE="${REGISTRY_NAMESPACE}" \
      WORKER_IMAGE_NAME=gauss-worker \
      RUNNER_IMAGE_NAME=gauss-runner \
      NUM_WORKERS="${workers}" \
      MATRIX="${matrix}" \
      SERVICE_NAME="${service_name}" \
      SKIP_PUSH="${SKIP_PUSH}" \
      ./scripts/run.sh \
      2>&1
    )"
  fi
  rc=$?
  set -e

  printf "%s\n" "${output}"

  service_logs="$(docker service logs "${service_name}" 2>&1 || true)"
  algo_ms="$(printf "%s\n" "${service_logs}" | awk -F= '/ALGO_DURATION_MS=/{value=$2} END{gsub(/^[ \t]+|[ \t]+$/, "", value); print value}')"
  solution="$(printf "%s\n" "${service_logs}" | awk -F= '/SOLUTION_JSON=/{value=$2} END{gsub(/^[ \t]+|[ \t]+$/, "", value); print value}')"

  if [[ -z "${algo_ms}" ]]; then
    algo_ms="-"
  fi
  if [[ -z "${solution}" ]]; then
    solution="-"
  fi

  if [[ "${rc}" -eq 0 ]]; then
    status="OK"
  elif [[ "${rc}" -eq 2 ]]; then
    status="TIMEOUT"
  else
    status="FAIL"
  fi

  SUMMARY_ROWS+=("${name}|${workers}|${size:-matrix}|${algo_ms}|${status}|${solution}")
  if [[ "${status}" != "OK" ]]; then
    HAS_FAILURE=1
  fi
}

SUMMARY_ROWS=()
HAS_FAILURE=0

while IFS='|' read -r name workers matrix size seed; do
  [[ -z "${name:-}" ]] && continue
  run_case "${name}" "${workers}" "${matrix}" "${size}" "${seed}"
done < <(build_experiment_list)

echo
echo "============================= FINAL SUMMARY ============================="
printf "%-26s %-10s %-8s %-12s %-8s\n" "experiment" "workers" "input" "algo_ms" "status"
printf "%-26s %-10s %-8s %-12s %-8s\n" "--------------------------" "----------" "--------" "------------" "--------"

for row in "${SUMMARY_ROWS[@]}"; do
  IFS='|' read -r name workers input algo_ms status solution <<< "${row}"
  printf "%-26s %-10s %-8s %-12s %-8s\n" "${name}" "${workers}" "${input}" "${algo_ms}" "${status}"
done

echo
echo "============================= SOLUTIONS ================================="
for row in "${SUMMARY_ROWS[@]}"; do
  IFS='|' read -r name workers input algo_ms status solution <<< "${row}"
  [[ "${status}" != "OK" || "${solution}" == "-" ]] && continue

  echo
  printf "  experiment : %s\n" "${name}"
  printf "  workers    : %s\n" "${workers}"
  printf "  input      : %s\n" "${input}"
  printf "  algo_ms    : %s\n" "${algo_ms}"
  printf "  roots      :\n"

  python3 - "${solution}" <<'PY'
import json, sys

sol = json.loads(sys.argv[1])
n = len(sol)
head = 10
tail = 10

def fmt(i, v):
    print(f"    x[{i:<6}] = {v:>12.6f}")

if n <= head + tail:
    for i, v in enumerate(sol):
        fmt(i, v)
else:
    for i in range(head):
        fmt(i, sol[i])
    print(f"    ... ({n - head - tail} values omitted) ...")
    for i in range(n - tail, n):
        fmt(i, sol[i])
PY
done

if [[ "${HAS_FAILURE}" -eq 1 ]]; then
  exit 1
fi
