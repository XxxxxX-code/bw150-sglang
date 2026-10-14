#!/bin/bash
# C6 = C4 去掉内核 env 包（其余完全相同）—— 内核包的干净消融实验。
#
# 动机（C4 vs B2 基线实测）：
#   64K/1K 场景       B2 基线      C4（带内核包）
#     conc1 TTFT      6262 ms      6656 ms
#     conc2 TTFT      7850 ms      13795 ms   ← 1.76x 回退
#   即：内核包在 ShareGPT 上只给 +2~3%，却让长序列 prefill 明显变慢。
#   本配置去掉 EXTRA_ENV（回到参考配置的 env 基线：AITER_LINEAR_ATTN=0、
#   SGLANG_USE_LIGHTOP=1 等），其余一切与 C4 相同，用同一套探测口径对比。
set -uo pipefail
cd /data/baseline

TAG="${TAG:-c6}"

EXTRA="--disable-radix-cache --max-running-requests 64 --max-mamba-cache-size 64
       --mamba-ssm-dtype bfloat16
       --chunked-prefill-size 32768 --max-prefill-tokens 32768"

echo "######## STEP A: 启动 $TAG（无内核 env 包）$(date '+%F %T')"
TAG="$TAG" \
MAMBA_STRATEGY=no_buffer \
CONTEXT_LEN=262144 \
MEM_FRACTION=0.85 \
EXTRA_ARGS="$EXTRA" \
EXTRA_ENV="" \
bash /data/baseline/scripts/restart.sh || { echo "$TAG START FAILED"; exit 1; }

echo "######## STEP B: $TAG ShareGPT 筛选（conc 32/64）$(date '+%F %T')"
LEVELS="32:300 64:300" TAG="$TAG" bash /data/baseline/scripts/grid.sh || echo "$TAG GRID FAILED"

echo "######## STEP C: $TAG SLA 4K/1K 全档（1..64）$(date '+%F %T')"
python3 scripts/sla_probe.py --tag "$TAG" --scenario 4k || echo "SLA4K FAILED"

echo "######## STEP D: $TAG SLA 64K/1K（1/2/4）$(date '+%F %T')"
python3 scripts/sla_probe.py --tag "$TAG" --scenario 64k \
  --concs 1,2,4 --num-prompts 4 --warmup 0 || echo "SLA64K FAILED"

echo "$TAG FULL DONE $(date '+%F %T')"
