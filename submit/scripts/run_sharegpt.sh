#!/bin/bash
# 子赛道 B (SGLang) — ShareGPT 标准数据集基线测试
# 用法: bash run_sharegpt.sh <max_concurrency> [num_prompts]
set -uo pipefail

CONC="${1:?用法: run_sharegpt.sh <max_concurrency> [num_prompts]}"
NUM="${2:-300}"

MODEL="${MODEL:-/models/Qwen3.8-27B}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-30000}"
DATASET="${DATASET:-/data/baseline/data/ShareGPT_V3_unfiltered_cleaned_split.json}"
OUT_DIR="${OUT_DIR:-/data/baseline/result}"
SEED="${SEED:-1}"
WARMUP="${WARMUP:-5}"

mkdir -p "$OUT_DIR"
LOG="$OUT_DIR/sharegpt_conc${CONC}_n${NUM}.log"

echo "[run_sharegpt] conc=$CONC num_prompts=$NUM seed=$SEED -> $LOG"

python3 -m sglang.bench_serving \
    --backend sglang \
    --host "$HOST" --port "$PORT" \
    --model "$MODEL" \
    --dataset-name sharegpt \
    --dataset-path "$DATASET" \
    --num-prompts "$NUM" \
    --max-concurrency "$CONC" \
    --warmup-requests "$WARMUP" \
    ${FLUSH_CACHE:+--flush-cache} \
    --seed "$SEED" \
    > "$LOG" 2>&1

echo "[run_sharegpt] done conc=$CONC exit=$?"
grep -E "^Output token throughput|^Total Token throughput|^Mean TTFT|^Median TTFT|^P99 TTFT|^Mean TPOT|^Median TPOT|^P99 TPOT|^Request throughput|Successful requests|Benchmark duration" "$LOG" 2>/dev/null
