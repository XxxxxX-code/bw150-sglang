#!/bin/bash
# 收尾链：基线侧的两件必做事项，一次重启内完成。
#   ① 基线 64K 的「容量墙」取证：conc 4/5/6，用原始日志证明 conc5 装不下
#      （max_total_num_tokens=320192 < 5×66560=332800），而不是跑得慢。
#   ② 基线 ShareGPT 全档 3 轮 —— 提升率的分母必须是稳的，
#      §5.2 要求数据表含轮次/方差，基线侧也要有，否则提升率的分母没有误差棒。
set -uo pipefail
cd /data/baseline

TAG="b2cap"
echo "######## STEP A: 启动基线 B2 $(date '+%F %T')"
TAG="$TAG" MODE=b2 START_SCRIPT=/data/baseline/scripts/start_baseline.sh \
  bash /data/baseline/scripts/restart.sh || { echo "B2 START FAILED"; exit 1; }

echo "######## STEP B: 基线 64K 容量墙取证（conc 4/5/6，n=6）$(date '+%F %T')"
python3 scripts/sla_probe.py --tag "$TAG" --scenario 64k \
  --concs 4,5,6 --num-prompts 6 --warmup 0 || echo "SLA64K FAILED"

echo "######## STEP C: 基线 ShareGPT 全档 3 轮 $(date '+%F %T')"
ROUNDS=3 TAG=b2r3 bash /data/baseline/scripts/grid.sh || echo "B2 GRID FAILED"

echo "B2 SIDE DONE $(date '+%F %T')"
