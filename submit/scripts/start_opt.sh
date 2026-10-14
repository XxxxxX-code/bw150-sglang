#!/bin/bash
# 可参数化的优化配置启动脚本。
# 默认 = 参考配置(B)。可用环境变量覆盖常用项，也可用 EXTRA_ARGS 追加任意 flag。
#
# 用法示例:
#   TAG=c1 MAMBA_STRATEGY=no_buffer EXTRA_ARGS="--disable-radix-cache --max-running-requests 32 --max-mamba-cache-size 32" \
#     bash scripts/restart.sh
#
# 可覆盖的环境变量:
#   TAG MAMBA_STRATEGY MEM_FRACTION CONTEXT_LEN KV_DTYPE SPEC_STEPS CUDA_GRAPH_BS EXTRA_ENV EXTRA_ARGS
set -uo pipefail

MODEL_PATH="${MODEL_PATH:-/models/Qwen3.8-27B}"
PORT="${PORT:-30000}"
GPUS="${GPUS:-6,7}"
TAG="${TAG:-opt}"
LOG="${LOG:-/data/baseline/logs/server_${TAG}.log}"

MAMBA_STRATEGY="${MAMBA_STRATEGY:-extra_buffer}"
MEM_FRACTION="${MEM_FRACTION:-0.90}"
CONTEXT_LEN="${CONTEXT_LEN:-65535}"
KV_DTYPE="${KV_DTYPE:-bfloat16}"
SPEC_STEPS="${SPEC_STEPS:-3}"
CUDA_GRAPH_BS="${CUDA_GRAPH_BS:-64}"

export HIP_VISIBLE_DEVICES="$GPUS"
export SGLANG_USE_CUDA_IPC_TRANSPORT=1
export SGLANG_ALLOW_OVERWRITE_LONGER_CONTEXT_LEN=1
export SGLANG_USE_LIGHTOP=1
export SGLANG_USE_AITER_LINEAR_ATTN=0
export SGLANG_ENABLE_SPEC_V2=1
export NCCL_MIN_NCHANNELS=16
export NCCL_MAX_NCHANNELS=16
export ALLREDUCE_STREAM_WITH_COMPUTE=1
export HSA_FORCE_FINE_GRAIN_PCIE=1

# 允许外部注入/覆盖额外 env（形如 "A=1 B=2"）
if [ -n "${EXTRA_ENV:-}" ]; then
  for kv in $EXTRA_ENV; do export "$kv"; done
fi

echo "[start_opt] TAG=$TAG strategy=$MAMBA_STRATEGY mem_frac=$MEM_FRACTION ctx=$CONTEXT_LEN"
echo "[start_opt] kv=$KV_DTYPE spec_steps=$SPEC_STEPS graph_bs=$CUDA_GRAPH_BS"
echo "[start_opt] EXTRA_ENV=${EXTRA_ENV:-<none>}"
echo "[start_opt] EXTRA_ARGS=${EXTRA_ARGS:-<none>}"
echo "[start_opt] log -> $LOG"

python3 -u -m sglang.launch_server \
  --model-path "$MODEL_PATH" \
  --host 0.0.0.0 --port "$PORT" \
  --served-model-name Qwen3.8-27B \
  --trust-remote-code --dtype bfloat16 \
  --tp-size 2 --pp-size 1 --numa-node 0 0 \
  --attention-backend fa3 --mm-attention-backend fa3 \
  --mamba-scheduler-strategy "$MAMBA_STRATEGY" \
  --cuda-graph-max-bs "$CUDA_GRAPH_BS" \
  --kv-cache-dtype "$KV_DTYPE" \
  --page-size 64 \
  --context-length "$CONTEXT_LEN" \
  --mem-fraction-static "$MEM_FRACTION" \
  --reasoning-parser qwen3 --tool-call-parser qwen3_coder \
  --speculative-algorithm EAGLE \
  --speculative-num-steps "$SPEC_STEPS" \
  --speculative-eagle-topk 1 \
  --speculative-num-draft-tokens "$((SPEC_STEPS + 1))" \
  ${EXTRA_ARGS:-} \
  2>&1 | tee "$LOG"
