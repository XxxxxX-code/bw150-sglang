#!/bin/bash
# C3 完整判定链 = C3 启动 → ShareGPT 高并发筛选 → SLA 4K 全档 → SLA 64K 快速判定
#
# C3 相对 c2 的两处改动：
#   ① --context-length 65535 → 262144（出厂默认），解开 64K/1K 场景的门（见报告 3.3）
#   ② 内核/后端 env 包 env_c3_kernels.txt（官方 HCU cookbook 配方 + Spec V2 plan stream）
#      —— 目标是压掉每步约 73ms 的固定开销（详见报告 3 段）
#
# SLA 探测用 random 数据集、长 prompt，与 ShareGPT 不同口径，是官方 §4.1.3 的评分口径。
set -uo pipefail
cd /data/baseline

TAG=c3
EXTRA="--disable-radix-cache --max-running-requests 64 --max-mamba-cache-size 64
       --mamba-ssm-dtype bfloat16"

echo "######## STEP A: 启动 $TAG $(date '+%F %T')"
TAG="$TAG" \
MAMBA_STRATEGY=no_buffer \
CONTEXT_LEN=262144 \
MEM_FRACTION=0.90 \
EXTRA_ARGS="$EXTRA" \
EXTRA_ENV="$(cat /data/baseline/scripts/env_c3_kernels.txt)" \
bash /data/baseline/scripts/restart.sh || { echo "$TAG START FAILED"; exit 1; }

echo "######## STEP B: $TAG ShareGPT 筛选（conc 32/64）$(date '+%F %T')"
LEVELS="32:300 64:300" TAG="$TAG" bash /data/baseline/scripts/grid.sh || { echo "$TAG GRID FAILED"; exit 1; }

echo "######## STEP C: $TAG SLA 4K/1K 全档 $(date '+%F %T')"
python3 scripts/sla_probe.py --tag "$TAG" --scenario 4k || echo "SLA4K FAILED"

echo "######## STEP D: $TAG SLA 64K/1K 快速判定 $(date '+%F %T')"
python3 scripts/sla_probe.py --tag "$TAG" --scenario 64k \
  --concs 1 --num-prompts 2 --warmup 0 || echo "SLA64K FAILED"

echo "$TAG FULL DONE $(date '+%F %T')"
