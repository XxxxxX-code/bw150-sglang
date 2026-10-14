#!/bin/bash
# 最终配置的完整测量链 —— 一次起服内跑完，避免多次重启引入的差异。
#
# 最终配置 = C4（保留内核 env 包，因为它在 ShareGPT 上实测 +3.5%，而 64K 的
# 「内核包拖慢 prefill」结论已被证伪：那是 prompt 数 n 不同造成的混淆，
# 用 n=4 重测后 B2 基线 conc1 是 4121ms、无内核包是 4131ms，两者持平）。
#
# 本链要补齐三件事：
#   ① 64K SLA 往上探到 conc6 —— B2 基线的 KV 池（320192 token）装不下第 5 条 64K 请求，
#      而本配置的 KV 池有 421376 token（6×66560=399360 刚好装下），这是可以拿到的增量。
#   ② 4K SLA 补 conc64（此前只测到 32）。
#   ③ ShareGPT 全档 3 轮（§5.2 要求含轮次/方差），随后在同一进程内跑 GSM8K 精度。
set -uo pipefail
cd /data/baseline

TAG="${TAG:-final}"

EXTRA="--disable-radix-cache --max-running-requests 64 --max-mamba-cache-size 64
       --mamba-ssm-dtype bfloat16
       --chunked-prefill-size 32768 --max-prefill-tokens 32768"

echo "######## STEP A: 启动 $TAG $(date '+%F %T')"
TAG="$TAG" \
MAMBA_STRATEGY=no_buffer \
CONTEXT_LEN=262144 \
MEM_FRACTION=0.85 \
EXTRA_ARGS="$EXTRA" \
EXTRA_ENV="$(cat /data/baseline/scripts/env_c3_kernels.txt)" \
bash /data/baseline/scripts/restart.sh || { echo "$TAG START FAILED"; exit 1; }

echo "######## STEP B: $TAG 64K SLA 上探（1/2/4/5/6）$(date '+%F %T')"
python3 scripts/sla_probe.py --tag "$TAG" --scenario 64k \
  --concs 1,2,4,5,6 --num-prompts 6 --warmup 0 || echo "SLA64K FAILED"

echo "######## STEP C: $TAG 4K SLA 补 conc64 $(date '+%F %T')"
python3 scripts/sla_probe.py --tag "$TAG" --scenario 4k \
  --concs 64 --num-prompts 64 --warmup 2 || echo "SLA4K-64 FAILED"

echo "######## STEP D: $TAG ShareGPT 全档 3 轮 $(date '+%F %T')"
ROUNDS=3 TAG="$TAG" bash /data/baseline/scripts/grid.sh || echo "$TAG GRID FAILED"

echo "######## STEP E: $TAG GSM8K 精度 $(date '+%F %T')"
python3 scripts/run_gsm8k.py --tag "$TAG" --num-threads 32 --max-tokens 8192 --no-thinking \
  || echo "GSM8K FAILED"

echo "$TAG FINAL DONE $(date '+%F %T')"
