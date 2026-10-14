#!/bin/bash
# 基线 B2 的 SLA 探测 —— 这是第 4.3 节提升率的**分母**，必须用与优化配置完全相同的
# 探测口径（同样的脚本、同样的并发档、同样的判定规则），否则对比不成立。
set -uo pipefail
cd /data/baseline

TAG=b2sla

echo "######## 启动基线 B2 $(date '+%F %T')"
TAG="$TAG" \
MODE=b2 \
START_SCRIPT=/data/baseline/scripts/start_baseline.sh \
bash /data/baseline/scripts/restart.sh || { echo "B2 START FAILED"; exit 1; }

echo "######## B2 SLA 4K/1K 全档 $(date '+%F %T')"
python3 scripts/sla_probe.py --tag "$TAG" --scenario 4k || echo "SLA4K FAILED"

echo "######## B2 SLA 64K/1K $(date '+%F %T')"
python3 scripts/sla_probe.py --tag "$TAG" --scenario 64k \
  --concs 1,2 --num-prompts 3 --warmup 0 || echo "SLA64K FAILED"

echo "B2 SLA DONE $(date '+%F %T')"
