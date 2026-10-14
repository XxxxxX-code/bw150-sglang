#!/bin/bash
# C5 = C3 之上调投机步数。
#
# 动机（从 c2 实测反推）：
#   conc64 时 TPOT 74.07ms、accept len ≈2.85 → 每步耗时 ≈ 74.07×2.85 ≈ 211ms，
#   每步产出 64×2.85 ≈ 182 token。而 configA 无投机时每步 95.39ms 产出 64 token。
#   即：投机把每步产出提到 2.85×，但把每步耗时提到 2.21×，净收益只剩 1.29×。
#   验证阶段要对 64×4=256 个 token 位置做前向，是主导开销。
#   → 把 --speculative-num-steps 从 3 降到 2（draft tokens 4→3），
#     验证算力降 25%，accept len 预计从 2.85 降到 ~2.4。若净收益为正，说明高并发下
#     步数过多是亏的。
#
# 用法: STEPS=2 bash scripts/run_c5.sh
set -uo pipefail

STEPS="${STEPS:-2}"
TAG="${TAG:-c5s${STEPS}}"

EXTRA="--disable-radix-cache --max-running-requests 64 --max-mamba-cache-size 64
       --mamba-ssm-dtype bfloat16"

TAG="$TAG" \
MAMBA_STRATEGY=no_buffer \
CONTEXT_LEN=262144 \
MEM_FRACTION=0.90 \
SPEC_STEPS="$STEPS" \
EXTRA_ARGS="$EXTRA" \
EXTRA_ENV="$(cat /data/baseline/scripts/env_c3_kernels.txt)" \
bash /data/baseline/scripts/restart.sh || { echo "$TAG START FAILED"; exit 1; }

echo "######## $TAG ShareGPT 快速判定（conc 32/64）$(date '+%F %T')"
LEVELS="32:300 64:300" TAG="$TAG" bash /data/baseline/scripts/grid.sh || exit 1

echo "$TAG QUICK DONE $(date '+%F %T')"
