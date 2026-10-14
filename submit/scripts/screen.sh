#!/bin/bash
# 快速筛选：只跑 3 个代表性档位（1 / 16 / 64），用于配置之间的 A/B 比较。
# 用法: TAG=c1 bash scripts/screen.sh
set -uo pipefail

TAG="${TAG:-opt}"
ROUNDS="${ROUNDS:-1}"
OUT="/data/baseline/result/screen_${TAG}.txt"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-30000}"
DATASET="${DATASET:-/data/baseline/data/ShareGPT_V3_unfiltered_cleaned_split.json}"
WARMUP="${WARMUP:-20}"
SEED="${SEED:-1}"

# 档位 -> prompt 数（低并发档位单请求耗时长，用小样本；高并发档位用大样本）
declare -A N=( [1]=50 [16]=150 [64]=200 )

: > "$OUT"
echo "### SCREEN TAG=$TAG ROUNDS=$ROUNDS $(date '+%F %T')" | tee -a "$OUT"

for C in 1 16 64; do
  for R in $(seq 1 "$ROUNDS"); do
    LOG="/data/baseline/result/${TAG}_conc${C}_r${R}.log"
    echo "--- conc=$C round=$R start $(date '+%T') ---" | tee -a "$OUT"
    python3 -m sglang.bench_serving \
      --backend sglang --host "$HOST" --port "$PORT" \
      --model /models/Qwen3.8-27B \
      --dataset-name sharegpt --dataset-path "$DATASET" \
      --num-prompts "${N[$C]}" --max-concurrency "$C" \
      --warmup-requests "$WARMUP" --seed "$SEED" \
      > "$LOG" 2>&1
    echo "  exit=$? log=$LOG" | tee -a "$OUT"
    grep -aE "^Output token throughput|^Mean TTFT|^Median TTFT|^P99 TTFT|^Mean TPOT|^Median TPOT|^P99 TPOT|^Successful requests|^Benchmark duration" \
      "$LOG" | sed 's/^/  /' | tee -a "$OUT"
  done
done

echo "### SCREEN DONE $TAG $(date '+%F %T')" | tee -a "$OUT"
echo "==> $OUT"
