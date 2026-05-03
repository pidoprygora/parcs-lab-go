#!/usr/bin/env bash
# Run PARCS Gauss experiments on the AWS EC2 instance via SSM send-command.
#
# Prerequisites (local machine):
#   - AWS CLI v2 with session-manager-plugin installed
#   - Terraform applied (terraform apply in this directory)
#   - AWS credentials configured (aws configure or AWS_PROFILE)
#
# Usage:
#   ./run-experiments.sh                    # run all experiments
#   EXPERIMENT=case4x4 ./run-experiments.sh # run a single experiment
#
# Optional env vars:
#   EXPERIMENT       -- experiment name from experiments.json, or "all" (default: all)
#   AWS_REGION       -- override region (default: read from terraform output)
#   AWS_PROFILE      -- AWS credentials profile
#   POLL_INTERVAL    -- seconds between status polls (default: 5)
#   COMMAND_TIMEOUT  -- SSM send-command timeout in seconds (default: 600)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Logging: tee all output to logs/<timestamp>_<experiment>.log
# ---------------------------------------------------------------------------

LOGS_DIR="${REPO_ROOT}/logs"
mkdir -p "${LOGS_DIR}"
LOG_FILE="${LOGS_DIR}/$(date -u +%Y%m%dT%H%M%SZ)_${EXPERIMENT:-all}.log"
exec > >(tee -a "${LOG_FILE}") 2>&1
echo "Log: ${LOG_FILE}"
echo

# ---------------------------------------------------------------------------
# Resolve instance ID and region from Terraform outputs
# ---------------------------------------------------------------------------

echo "Reading Terraform outputs..."
INSTANCE_ID=$(terraform -chdir="$SCRIPT_DIR" output -raw instance_id 2>/dev/null)
TF_REGION=$(terraform -chdir="$SCRIPT_DIR" output -raw ssm_session_command 2>/dev/null \
  | grep -oE '\-\-region [a-z0-9-]+' | awk '{print $2}' || true)

REGION="${AWS_REGION:-${TF_REGION:-us-east-1}}"
EXPERIMENT="${EXPERIMENT:-all}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"
COMMAND_TIMEOUT="${COMMAND_TIMEOUT:-600}"

if [[ -z "${INSTANCE_ID}" ]]; then
  echo "ERROR: Could not read instance_id from Terraform outputs."
  echo "       Run 'terraform apply' first in docs/infrastructure/."
  exit 1
fi

echo "Instance  : ${INSTANCE_ID}"
echo "Region    : ${REGION}"
echo "Experiment: ${EXPERIMENT}"
echo

# ---------------------------------------------------------------------------
# Build the remote shell command
# ---------------------------------------------------------------------------

REMOTE_SCRIPT=$(cat <<'REMOTE'
set -euo pipefail
export HOME=/root

# SSM runs as root; repo is owned by ec2-user — mark it safe for Git 2.35+
git config --global --add safe.directory /home/ec2-user/parcs-lab-go

cd /home/ec2-user/parcs-lab-go

echo "==> git sync"
git fetch origin
git reset --hard origin/main
chmod +x scripts/*.sh

echo "==> Running experiments..."
LEADER_URL=tcp://docker-proxy:4321 \
SKIP_PUSH=1 \
EXPERIMENT=__EXPERIMENT__ \
./scripts/experiments.sh
REMOTE
)

# Substitute the experiment name (safe: no shell special chars expected)
REMOTE_SCRIPT="${REMOTE_SCRIPT//__EXPERIMENT__/${EXPERIMENT}}"

# ---------------------------------------------------------------------------
# Send command via SSM
# Use Python to build the JSON payload so special chars/quotes are escaped.
# ---------------------------------------------------------------------------

TMPFILE=$(mktemp /tmp/ssm-send-XXXXXX.json)
trap 'rm -f "$TMPFILE"' EXIT

# Pass everything via env vars so Python reads them safely — no quoting issues.
INSTANCE_ID="$INSTANCE_ID" \
COMMAND_TIMEOUT="$COMMAND_TIMEOUT" \
REMOTE_SCRIPT="$REMOTE_SCRIPT" \
python3 -c "
import json, os
payload = {
    'InstanceIds': [os.environ['INSTANCE_ID']],
    'DocumentName': 'AWS-RunShellScript',
    'Parameters': {'commands': [os.environ['REMOTE_SCRIPT']]},
    'TimeoutSeconds': int(os.environ['COMMAND_TIMEOUT']),
}
print(json.dumps(payload))
" > "$TMPFILE"

echo "Sending SSM command..."
COMMAND_ID=$(aws ssm send-command \
  --region "${REGION}" \
  --cli-input-json "file://${TMPFILE}" \
  --query "Command.CommandId" \
  --output text)

echo "Command ID: ${COMMAND_ID}"
echo "Waiting for completion..."

# ---------------------------------------------------------------------------
# Poll until the command finishes
# ---------------------------------------------------------------------------

while true; do
  STATUS=$(aws ssm get-command-invocation \
    --region "${REGION}" \
    --command-id "${COMMAND_ID}" \
    --instance-id "${INSTANCE_ID}" \
    --query "Status" \
    --output text 2>/dev/null || echo "Pending")

  case "${STATUS}" in
    Success|Failed|Cancelled|TimedOut|Undeliverable|Terminated)
      break
      ;;
  esac

  printf "  status: %-20s\r" "${STATUS}"
  sleep "${POLL_INTERVAL}"
done

echo ""
echo "===== STDOUT ====="
aws ssm get-command-invocation \
  --region "${REGION}" \
  --command-id "${COMMAND_ID}" \
  --instance-id "${INSTANCE_ID}" \
  --query "StandardOutputContent" \
  --output text

STDERR_OUTPUT=$(aws ssm get-command-invocation \
  --region "${REGION}" \
  --command-id "${COMMAND_ID}" \
  --instance-id "${INSTANCE_ID}" \
  --query "StandardErrorContent" \
  --output text)

if [[ -n "${STDERR_OUTPUT}" ]]; then
  echo "===== STDERR ====="
  echo "${STDERR_OUTPUT}" >&2
fi

if [[ "${STATUS}" != "Success" ]]; then
  echo "Command finished with status: ${STATUS}" >&2
  exit 1
fi
