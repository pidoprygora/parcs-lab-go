#!/usr/bin/env bash
set -euo pipefail

# Required environment variables:
# - LEADER_URL: tcp://<swarm-manager-ip>:4321
#
# Matrix input — provide exactly one of:
# - MATRIX: augmented matrix in JSON format (for small/explicit matrices)
# - SIZE:   matrix dimension n (runner generates a random n×n diag-dominant matrix)
#           SEED: optional RNG seed (default: 42)
#
# Optional environment variables:
# - REGISTRY_NAMESPACE: docker registry namespace, default "local"
# - WORKER_IMAGE_NAME: default "gauss-worker"
# - RUNNER_IMAGE_NAME: default "gauss-runner"
# - IMAGE_TAG: default "latest"
# - NUM_WORKERS: default "2"

if [[ -z "${LEADER_URL:-}" ]]; then
  echo "LEADER_URL is required, e.g. tcp://10.0.0.1:4321"
  exit 1
fi

REGISTRY_NAMESPACE="${REGISTRY_NAMESPACE:-local}"
WORKER_IMAGE_NAME="${WORKER_IMAGE_NAME:-gauss-worker}"
RUNNER_IMAGE_NAME="${RUNNER_IMAGE_NAME:-gauss-runner}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
NUM_WORKERS="${NUM_WORKERS:-2}"
MATRIX="${MATRIX:-}"
SIZE="${SIZE:-}"
SEED="${SEED:-42}"
SERVICE_NAME="${SERVICE_NAME:-gauss-runner}"
LOG_FOLLOW="${LOG_FOLLOW:-0}"
WAIT_TIMEOUT_SEC="${WAIT_TIMEOUT_SEC:-3600}"
POLL_INTERVAL_SEC="${POLL_INTERVAL_SEC:-2}"

WORKER_IMAGE="${REGISTRY_NAMESPACE}/${WORKER_IMAGE_NAME}:${IMAGE_TAG}"
RUNNER_IMAGE="${REGISTRY_NAMESPACE}/${RUNNER_IMAGE_NAME}:${IMAGE_TAG}"

# Decide how to pass the matrix to the runner container.
# SIZE+SEED avoids the env-var size limit for large matrices (n >= ~300).
if [[ -n "${SIZE}" ]]; then
  matrix_env_flags=(--env "SIZE=${SIZE}" --env "SEED=${SEED}")
else
  if [[ -z "${MATRIX}" ]]; then
    MATRIX='[[2,1,-1,8],[-3,-1,2,-11],[-2,1,2,-3]]'
  fi
  matrix_env_flags=(--env "MATRIX=${MATRIX}")
fi

echo "Building images..."
docker build -t "${WORKER_IMAGE}" "./gauss-worker"
docker build -t "${RUNNER_IMAGE}" "./gauss-runner"

if [[ "${SKIP_PUSH:-0}" != "1" ]]; then
  echo "Pushing images..."
  docker push "${WORKER_IMAGE}"
  docker push "${RUNNER_IMAGE}"
fi

if docker service inspect "${SERVICE_NAME}" >/dev/null 2>&1; then
  echo "Removing existing service ${SERVICE_NAME}..."
  docker service rm "${SERVICE_NAME}" >/dev/null
fi

echo "Starting runner service..."
docker service create \
  --name "${SERVICE_NAME}" \
  --network parcs \
  --restart-condition none \
  --env "LEADER_URL=${LEADER_URL}" \
  --env "WORKER_IMAGE=${WORKER_IMAGE}" \
  --env "NUM_WORKERS=${NUM_WORKERS}" \
  "${matrix_env_flags[@]}" \
  "${RUNNER_IMAGE}"

echo "Waiting for logs from ${SERVICE_NAME}..."
sleep 2

if [[ "${LOG_FOLLOW}" == "1" ]]; then
  docker service logs -f "${SERVICE_NAME}"
  exit 0
fi

deadline=$((SECONDS + WAIT_TIMEOUT_SEC))
final_state=""
timed_out=0
while true; do
  final_state="$(docker service ps "${SERVICE_NAME}" --no-trunc --format '{{.CurrentState}}' | awk 'NR==1{print; exit}')"

  if [[ -n "${final_state}" ]]; then
    case "${final_state}" in
      Complete*|Failed*|Rejected*|Shutdown*)
        break
        ;;
    esac
  fi

  if (( SECONDS >= deadline )); then
    echo "Timed out waiting for ${SERVICE_NAME} to finish (state: ${final_state:-unknown})"
    timed_out=1
    break
  fi
  sleep "${POLL_INTERVAL_SEC}"
done

echo "Final task state: ${final_state:-unknown}"
docker service logs --tail 2000 "${SERVICE_NAME}"

if [[ "${timed_out}" -eq 1 ]]; then
  echo "ERROR: experiment did not finish within ${WAIT_TIMEOUT_SEC}s" >&2
  exit 2
fi

case "${final_state}" in
  Failed*|Rejected*)
    exit 1
    ;;
esac
