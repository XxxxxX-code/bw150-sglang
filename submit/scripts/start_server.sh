#!/bin/bash
# 子赛道 B (SGLang) 基线服务启动脚本
# 硬件: 2x DCU BW150 (HIP_VISIBLE_DEVICES=6,7)
# 环境: sglang 0.5.12 / torch 2.10.0 / dtk2604 / py3.10 (官方镜像内)
set -euo pipefail

MODEL_PATH="${MODEL_PATH:-/models/Qwen3.8-27B}"
PORT="${PORT:-30000}"
TP_SIZE="${TP_SIZE:-2}"
GPUS="${GPUS:-6,7}"
LOG="${LOG:-/data/baseline/logs/server.log}"

mkdir -p "$(dirname "$LOG")"

export HIP_VISIBLE_DEVICES="$GPUS"
# DCU/ROCm 下的常规稳定性设置
export SGLANG_SET_CPU_AFFINITY="${SGLANG_SET_CPU_AFFINITY:-1}"

echo "[start_server] GPUs=$GPUS TP=$TP_SIZE PORT=$PORT MODEL=$MODEL_PATH"
echo "[start_server] log -> $LOG"

python3 -m sglang.launch_server \
    --model-path "$MODEL_PATH" \
    --tokenizer-path "$MODEL_PATH" \
    --tp-size "$TP_SIZE" \
    --host 0.0.0.0 \
    --port "$PORT" \
    --trust-remote-code \
    --dtype bfloat16 \
    --page-size 64 \
    --mamba-scheduler-strategy "${MAMBA_STRATEGY:-no_buffer}" \
    --disable-radix-cache \
    --max-running-requests "${MAX_RUNNING:-128}" \
    ${MAMBA_CACHE:+--max-mamba-cache-size "$MAMBA_CACHE"} \
    --mem-fraction-static "${MEM_FRACTION:-0.85}" \
    2>&1 | tee "$LOG"
