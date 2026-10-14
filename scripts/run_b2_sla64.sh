#!/bin/bash
# 补测基线 B2 的 64K SLA conc4 —— 之前只探到 conc2，最大并发被测量上界截断。
# 用与 C6 完全相同的口径（--num-prompts 4 --warmup 0）。
set -uo pipefail
cd /data/baseline
TAG=b2sla64
echo "######## 启动基线 B2 $(date '+%F %T')"
TAG="$TAG" MODE=b2 START_SCRIPT=/data/baseline/scripts/start_baseline.sh \
  bash /data/baseline/scripts/restart.sh || { echo "B2 START FAILED"; exit 1; }
echo "######## B2 SLA 64K/1K（1/2/4）$(date '+%F %T')"
python3 scripts/sla_probe.py --tag "$TAG" --scenario 64k \
  --concs 1,2,4 --num-prompts 4 --warmup 0 || echo "SLA64K FAILED"
echo "B2 SLA64 DONE $(date '+%F %T')"