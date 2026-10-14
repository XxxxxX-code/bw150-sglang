#!/bin/bash
# C3 = c2（并发解锁 + bf16 SSM）之上叠加：
#   1. 去掉参考脚本人为压低的 --context-length 65535，回到出厂默认 262144
#      （否则 64K/1K 场景 66560 token 直接被拒，那一项拿不到分）
#   2. 官方 HCU cookbook 内核/运行时开关包（见 env_c3_kernels.md 的逐条依据）
#
# 先只跑 conc 32/64 两档做快速判定，与 c2 的同档位直接可比（同 LEVELS、同 warmup、同 seed）。
set -uo pipefail

TAG=c3 \
MAMBA_STRATEGY=no_buffer \
CONTEXT_LEN=262144 \
MEM_FRACTION=0.90 \
EXTRA_ARGS="--disable-radix-cache --max-running-requests 64 --max-mamba-cache-size 64 --mamba-ssm-dtype bfloat16" \
EXTRA_ENV="$(cat /data/baseline/scripts/env_c3_kernels.txt)" \
bash /data/baseline/scripts/restart.sh || { echo "C3 START FAILED"; exit 1; }

echo "######## C3 快速判定（conc 32/64）$(date '+%F %T')"
LEVELS="32:300 64:300" TAG=c3 bash /data/baseline/scripts/grid.sh || { echo "C3 QUICK FAILED"; exit 1; }

echo "######## C3 对照 c2:"
python3 /data/baseline/scripts/summarize.py c2 c3 2>/dev/null | head -12

echo "C3 QUICK DONE $(date '+%F %T')"
