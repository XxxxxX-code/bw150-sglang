#!/bin/bash
# 精度链：先跑基线（当前已加载，省一次重启），再重启到最终配置跑同一口径。
#
# 为什么两边都要跑：notes 要求精度下降不超过 2pp，而 2pp 是**相对官方基线**说的；
# 官方评测脚本不在本镜像里，所以我能提供的完整证据是「同环境 A/B」
# —— 同一条 harness、同一份数据、同一口径，基线 vs 最终配置。
# 基线跑出 ~97（对上官方公布的 97.0）本身就证明这条 harness 的口径是对的。
set -uo pipefail
cd /data/baseline

echo "######## STEP A: 基线 B2 全量 GSM8K $(date '+%F %T')"
python3 scripts/run_gsm8k.py --tag b2 --num-examples 1314 \
  --num-threads 32 --max-tokens 4096 --no-thinking || echo "B2 GSM8K FAILED"

echo "######## STEP B: 重启到最终配置 $(date '+%F %T')"
EXTRA="--disable-radix-cache --max-running-requests 64 --max-mamba-cache-size 64
       --mamba-ssm-dtype bfloat16
       --chunked-prefill-size 32768 --max-prefill-tokens 32768"
TAG=final MAMBA_STRATEGY=no_buffer CONTEXT_LEN=262144 MEM_FRACTION=0.85 \
EXTRA_ARGS="$EXTRA" \
EXTRA_ENV="$(cat /data/baseline/scripts/env_c3_kernels.txt)" \
bash /data/baseline/scripts/restart.sh || { echo "FINAL START FAILED"; exit 1; }

echo "######## STEP C: 最终配置全量 GSM8K $(date '+%F %T')"
python3 scripts/run_gsm8k.py --tag final --num-examples 1314 \
  --num-threads 32 --max-tokens 4096 --no-thinking || echo "FINAL GSM8K FAILED"

echo "PRECISION DONE $(date '+%F %T')"
