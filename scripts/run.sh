#!/usr/bin/env bash
set -euo pipefail

# Required environment variables:
# - LEADER_URL: tcp://<swarm-manager-ip>:4321
#
# Optional environment variables:
# - REGISTRY_NAMESPACE: docker registry namespace, default "local"
# - WORKER_IMAGE_NAME: default "gauss-worker"
# - RUNNER_IMAGE_NAME: default "gauss-runner"
# - IMAGE_TAG: default "latest"
# - NUM_WORKERS: default "2"
# - MATRIX: augmented matrix in JSON format

if [[ -z "${LEADER_URL:-}" ]]; then
  echo "LEADER_URL is required, e.g. tcp://10.0.0.1:4321"
  exit 1
fi

REGISTRY_NAMESPACE="${REGISTRY_NAMESPACE:-local}"
WORKER_IMAGE_NAME="${WORKER_IMAGE_NAME:-gauss-worker}"
RUNNER_IMAGE_NAME="${RUNNER_IMAGE_NAME:-gauss-runner}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
NUM_WORKERS="${NUM_WORKERS:-2}"
MATRIX="${MATRIX:-[[2,1,-1,8],[-3,-1,2,-11],[-2,1,2,-3]]}"
SERVICE_NAME="${SERVICE_NAME:-gauss-runner}"
LOG_FOLLOW="${LOG_FOLLOW:-0}"
WAIT_TIMEOUT_SEC="${WAIT_TIMEOUT_SEC:-180}"
POLL_INTERVAL_SEC="${POLL_INTERVAL_SEC:-2}"

WORKER_IMAGE="${REGISTRY_NAMESPACE}/${WORKER_IMAGE_NAME}:${IMAGE_TAG}"
RUNNER_IMAGE="${REGISTRY_NAMESPACE}/${RUNNER_IMAGE_NAME}:${IMAGE_TAG}"

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
  --env "MATRIX=${MATRIX}" \
  "${RUNNER_IMAGE}"

echo "Waiting for logs from ${SERVICE_NAME}..."
sleep 2

if [[ "${LOG_FOLLOW}" == "1" ]]; then
  docker service logs -f "${SERVICE_NAME}"
  exit 0
fi

deadline=$((SECONDS + WAIT_TIMEOUT_SEC))
final_state=""
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
    break
  fi
  sleep "${POLL_INTERVAL_SEC}"
done

echo "Final task state: ${final_state:-unknown}"
docker service logs "${SERVICE_NAME}"

case "${final_state}" in
  Failed*|Rejected*)
    exit 1
    ;;
esac
