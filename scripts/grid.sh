#!/bin/bash
# 全档位测量，结果按 TAG 归档到 result/<TAG>/，便于跨配置逐档对比。
# 档位与 prompt 数默认与参考配置(B)那次测量完全一致，保证可比。
# 用法: TAG=c1 bash scripts/grid.sh
set -uo pipefail

TAG="${TAG:-opt}"
OUTDIR="/data/baseline/result/${TAG}"
mkdir -p "$OUTDIR"

# 档位:prompt数  —— 与参考配置测量保持一致（conc1 用 100，其余 300）
LEVELS="${LEVELS:-1:100 4:300 16:300 32:300 64:300}"
WARMUP="${WARMUP:-5}"     # 与官方 benchmark 脚本默认一致
SEED="${SEED:-1}"
ROUNDS="${ROUNDS:-1}"     # §5.2 要求含方差/轮次；轮次 >1 时文件名带 _r<R> 后缀

echo "### GRID TAG=$TAG ROUNDS=$ROUNDS start $(date '+%F %T')"
for R in $(seq 1 "$ROUNDS"); do
for pair in $LEVELS; do
  C="${pair%%:*}"; N="${pair##*:}"
  if [ "$ROUNDS" -gt 1 ]; then
    LOG="$OUTDIR/conc${C}_n${N}_r${R}.log"
  else
    LOG="$OUTDIR/conc${C}_n${N}.log"
  fi
  echo "=== $TAG conc=$C round=$R n=$N start $(date '+%T') ==="
  python3 -m sglang.bench_serving \
    --backend sglang --host 127.0.0.1 --port 30000 \
    --model /models/Qwen3.8-27B \
    --dataset-name sharegpt \
    --dataset-path /data/baseline/data/ShareGPT_V3_unfiltered_cleaned_split.json \
    --num-prompts "$N" --max-concurrency "$C" \
    --warmup-requests "$WARMUP" --seed "$SEED" \
    > "$LOG" 2>&1
  grep -aE "^Output token throughput|^Median TTFT|^Median TPOT|^Successful requests|^Benchmark duration" \
    "$LOG" | sed 's/^/  /'
  echo "=== $TAG conc=$C round=$R done $(date '+%T') ==="
done
done
echo "GRID DONE $TAG $(date '+%F %T')"
