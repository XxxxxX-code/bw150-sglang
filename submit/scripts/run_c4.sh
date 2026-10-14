#!/bin/bash
# C4 = C3 之上调 prefill 批处理。
#
# 动机：官方 SLA（4.1.3）4K/1K 要求 TTFT<5s 且 TPOT<50ms，而官方 BW100 自测基线在这个
# 场景下 SLA 最大并发只有 1。参考配置的 chunked_prefill_size=8192 / max_prefill_tokens=16384
# 都是出厂默认；4K 输入下 32 并发 = 131K token，要切成 16 个 chunk 才排空，
# TTFT 被 prefill 排空速度主导。放大 chunk 是这条指标最直接的杠杆。
#
# 用法: CHUNK=32768 IMPL=32768 bash scripts/run_c4.sh
set -uo pipefail

CHUNK="${CHUNK:-32768}"
IMPL="${IMPL:-32768}"
TAG="${TAG:-c4}"

EXTRA="--disable-radix-cache --max-running-requests 64 --max-mamba-cache-size 64
       --mamba-ssm-dtype bfloat16
       --chunked-prefill-size ${CHUNK} --max-prefill-tokens ${IMPL}"

TAG="$TAG" \
MAMBA_STRATEGY=no_buffer \
CONTEXT_LEN=262144 \
MEM_FRACTION=0.90 \
EXTRA_ARGS="$EXTRA" \
EXTRA_ENV="$(cat /data/baseline/scripts/env_c3_kernels.txt)" \
bash /data/baseline/scripts/restart.sh || { echo "$TAG START FAILED"; exit 1; }

echo "######## $TAG ShareGPT 快速判定（conc 32/64）$(date '+%F %T')"
LEVELS="32:300 64:300" TAG="$TAG" bash /data/baseline/scripts/grid.sh || { echo "$TAG GRID FAILED"; exit 1; }

echo "$TAG QUICK DONE $(date '+%F %T')"
