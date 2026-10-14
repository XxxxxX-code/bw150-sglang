#!/bin/bash
# C4 = C3 + 放大 prefill 批处理（Chunked Prefill 调参）
#
# 动机（C3 实测）：
#   4K/1K SLA 各档 TTFT：conc1 394ms / conc4 964ms / conc8 1629ms / conc16 832ms / conc32 1300ms
#   64K/1K 单条 TTFT 11287ms，而门槛是 20000ms —— 只剩 1.77x 余量。
#   参考配置的 chunked_prefill_size=8192 意味着 4K 输入每批只装 2 条、64K 输入要切 8 段。
#   放大 chunk 是同时改善这两条 SLA 最直接的杠杆。
#
# 代价与风险：chunk 激活显存 ∝ chunk size，而 C3 起服后 available_gpu_mem 只剩 2.64GB，
#   所以同时把 mem_fraction_static 从 0.90 降到 0.85（KV 池 518K token 本就远超需求，
#   实测只有 64 并发 × 平均 ~600 token，缩 KV 不损失能力，换来的是激活显存余量）。
#   另一个已知风险是大 chunk 会挤压 decode、抬高 TPOT（4K SLA 的 TPOT 门槛是 50ms），
#   所以本脚本同时保留 ShareGPT 高并发档筛选来观察 TPOT 是否被拖坏。
#
# 用法: CHUNK=32768 bash scripts/run_c4_full.sh
set -uo pipefail
cd /data/baseline

CHUNK="${CHUNK:-32768}"
IMPL="${IMPL:-$CHUNK}"
MEMFRAC="${MEMFRAC:-0.85}"
TAG="${TAG:-c4}"

EXTRA="--disable-radix-cache --max-running-requests 64 --max-mamba-cache-size 64
       --mamba-ssm-dtype bfloat16
       --chunked-prefill-size ${CHUNK} --max-prefill-tokens ${IMPL}"

echo "######## STEP A: 启动 $TAG (chunk=$CHUNK impl=$IMPL memfrac=$MEMFRAC) $(date '+%F %T')"
TAG="$TAG" \
MAMBA_STRATEGY=no_buffer \
CONTEXT_LEN=262144 \
MEM_FRACTION="$MEMFRAC" \
EXTRA_ARGS="$EXTRA" \
EXTRA_ENV="$(cat /data/baseline/scripts/env_c3_kernels.txt)" \
bash /data/baseline/scripts/restart.sh || { echo "$TAG START FAILED"; exit 1; }

echo "######## STEP B: $TAG ShareGPT 筛选（conc 32/64）$(date '+%F %T')"
LEVELS="32:300 64:300" TAG="$TAG" bash /data/baseline/scripts/grid.sh || { echo "$TAG GRID FAILED"; }

echo "######## STEP C: $TAG SLA 4K/1K 全档 $(date '+%F %T')"
python3 scripts/sla_probe.py --tag "$TAG" --scenario 4k || echo "SLA4K FAILED"

echo "######## STEP D: $TAG SLA 64K/1K $(date '+%F %T')"
python3 scripts/sla_probe.py --tag "$TAG" --scenario 64k \
  --concs 1,2 --num-prompts 3 --warmup 0 || echo "SLA64K FAILED"

echo "$TAG FULL DONE $(date '+%F %T')"
