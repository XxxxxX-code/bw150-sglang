#!/bin/bash
# 参考配置（他人提供的「目前性能最好」启动脚本）——原样保留，仅适配本机 2 卡/路径/端口
set -uo pipefail

MODEL_PATH="${MODEL_PATH:-/models/Qwen3.8-27B}"
PORT="${PORT:-30000}"
GPUS="${GPUS:-6,7}"
LOG="${LOG:-/data/baseline/logs/server_ref.log}"

export HIP_VISIBLE_DEVICES="$GPUS"
export HSA_FORCE_FINE_GRAIN_PCIE=1
export SGLANG_USE_CUDA_IPC_TRANSPORT=1
export SGLANG_ALLOW_OVERWRITE_LONGER_CONTEXT_LEN=1
export SGLANG_USE_LIGHTOP=1
export SGLANG_USE_AITER_LINEAR_ATTN=0
export SGLANG_ENABLE_SPEC_V2=1
export NCCL_MIN_NCHANNELS=16
export NCCL_MAX_NCHANNELS=16
export ALLREDUCE_STREAM_WITH_COMPUTE=1

python3 -u -m sglang.launch_server \
  --model-path "$MODEL_PATH" \
  --host 0.0.0.0 \
  --port "$PORT" \
  --served-model-name Qwen3.8-27B \
  --trust-remote-code \
  --dtype bfloat16 \
  --tp-size 2 \
  --pp-size 1 \
  --numa-node 0 0 \
  --attention-backend fa3 \
  --mm-attention-backend fa3 \
  --mamba-scheduler-strategy extra_buffer \
  --cuda-graph-max-bs 64 \
  --kv-cache-dtype bfloat16 \
  --page-size 64 \
  --context-length 65535 \
  --mem-fraction-static 0.90 \
  --reasoning-parser qwen3 \
  --tool-call-parser qwen3_coder \
  --speculative-algorithm EAGLE \
  --speculative-num-steps 3 \
  --speculative-eagle-topk 1 \
  --speculative-num-draft-tokens 4 \
  2>&1 | tee "$LOG"
