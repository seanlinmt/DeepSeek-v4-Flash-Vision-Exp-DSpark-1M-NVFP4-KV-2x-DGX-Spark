#!/usr/bin/env bash
# launch-cluster.sh
# DeepSeek-V4-Flash-Vision-Exp cluster deployment across ai + ai2.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then
  # shellcheck disable=SC1091
  set -a
  source "$SCRIPT_DIR/.env"
  set +a
fi

WORKER_HOST="${WORKER_HOST:-ai2}"
PORT="${VLLM_PORT:-8888}"

echo "=== 1. Dropping page caches on both nodes ==="
sudo -n sync && sudo -n sysctl -w vm.drop_caches=3 || true
ssh -n "$WORKER_HOST" "sudo -n sync && sudo -n sysctl -w vm.drop_caches=3" || true

echo "=== 2. Removing existing vllm_ds4_vision containers ==="
docker rm -f vllm_ds4_vision 2>/dev/null || true
ssh -n "$WORKER_HOST" "docker rm -f vllm_ds4_vision 2>/dev/null || true"

echo "=== 3. Syncing configuration to $WORKER_HOST ==="
scp "$SCRIPT_DIR/.env" "${WORKER_HOST}:${SCRIPT_DIR}/.env"
scp "$SCRIPT_DIR/launch-node.sh" "${WORKER_HOST}:${SCRIPT_DIR}/launch-node.sh"

echo "=== 4. Starting Rank 1 (worker) on $WORKER_HOST ==="
ssh -n "$WORKER_HOST" "$SCRIPT_DIR/launch-node.sh 1"

echo "Waiting 15 seconds for worker to enter rendezvous..."
sleep 15

echo "=== 5. Starting Rank 0 (head) on ai ==="
"$SCRIPT_DIR/launch-node.sh" 0

echo "=== 6. Waiting for vLLM API readiness on http://127.0.0.1:${PORT} ==="
API_URL="http://127.0.0.1:${PORT}/v1/models"
CHAT_URL="http://127.0.0.1:${PORT}/v1/chat/completions"

for i in $(seq 1 180); do
  if curl -fsS --max-time 3 "$API_URL" >/dev/null 2>&1; then
    echo
    echo "vLLM is READY!"
    echo "Endpoint accessible at: http://${VLLM_HOST_IP:-192.168.20.63}:${PORT} (network) and http://127.0.0.1:${PORT} (local)"
    curl -fsS "$API_URL" | jq . || curl -fsS "$API_URL"
    echo
    echo "Testing minimal chat completion..."
    curl -fsS --max-time 60 "$CHAT_URL" \
      -H "Content-Type: application/json" \
      -d '{"model":"deepseek-v4-flash-dspark","messages":[{"role":"user","content":"Respond with OK."}],"max_tokens":8,"temperature":0.0}'
    echo
    echo "Deployment successful!"
    exit 0
  fi
  printf "."
  sleep 5
done

echo "Timed out waiting for vLLM readiness. Inspect logs with:" >&2
echo "  docker logs --tail 50 vllm_ds4_vision" >&2
echo "  ssh -n ai2 'docker logs --tail 50 vllm_ds4_vision'" >&2
exit 1
