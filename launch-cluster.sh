#!/usr/bin/env bash
# launch-cluster.sh
# DeepSeek-V4-Flash-Vision-Exp cluster deployment across ai + ai2.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKER_HOST="ai2"

echo "=== 1. Dropping page caches on both nodes ==="
sudo -n sync && sudo -n sysctl -w vm.drop_caches=3 || true
ssh "$WORKER_HOST" "sudo -n sync && sudo -n sysctl -w vm.drop_caches=3" || true

echo "=== 2. Removing existing vllm_ds4_vision containers ==="
docker rm -f vllm_ds4_vision 2>/dev/null || true
ssh "$WORKER_HOST" "docker rm -f vllm_ds4_vision 2>/dev/null || true"

echo "=== 3. Starting Rank 1 (worker) on $WORKER_HOST ==="
ssh "$WORKER_HOST" "$SCRIPT_DIR/launch-node.sh 1"

echo "Waiting 15 seconds for worker to enter rendezvous..."
sleep 15

echo "=== 4. Starting Rank 0 (head) on ai ==="
"$SCRIPT_DIR/launch-node.sh" 0

echo "=== 5. Waiting for vLLM API readiness on http://127.0.0.1:8888 ==="
API_URL="http://127.0.0.1:8888/v1/models"
CHAT_URL="http://127.0.0.1:8888/v1/chat/completions"

for i in $(seq 1 180); do
  if curl -fsS --max-time 3 "$API_URL" >/dev/null 2>&1; then
    echo
    echo "vLLM is READY!"
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
echo "  ssh ai2 'docker logs --tail 50 vllm_ds4_vision'" >&2
exit 1
