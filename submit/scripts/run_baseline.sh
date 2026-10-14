#!/bin/bash
# 一次跑完基线取证 + B2 基线全档位测量。
#
#   1. 留存出厂默认启动失败的原始日志（合规证据）
#   2. 启动 B2（最小必要偏差基线，取更快的那条）
#   3. 跑全档位 grid
#   4. 收尾启动 B1 并只跑快速筛选，作为「没有挑软柿子」的旁证
#
# 任意一步失败即停，避免在死服务上白跑。
set -uo pipefail

echo "######## STEP 1: 出厂默认崩溃取证 $(date '+%F %T')"
bash /data/baseline/scripts/capture_default_crash.sh || { echo "STEP1 FAILED"; exit 1; }

echo "######## STEP 2: 启动 B2 基线 $(date '+%F %T')"
TAG=b2 MODE=b2 START_SCRIPT=/data/baseline/scripts/start_baseline.sh \
  bash /data/baseline/scripts/restart.sh || { echo "STEP2 FAILED (B2 启动没起来)"; exit 1; }

echo "######## STEP 3: B2 全档位 $(date '+%F %T')"
TAG=b2 bash /data/baseline/scripts/grid.sh || { echo "STEP3 FAILED"; exit 1; }

echo "######## STEP 4: 启动 B1 + 快速筛选（旁证） $(date '+%F %T')"
TAG=b1 MODE=b1 START_SCRIPT=/data/baseline/scripts/start_baseline.sh \
  bash /data/baseline/scripts/restart.sh || { echo "STEP4 FAILED (B1 启动没起来)"; exit 1; }
TAG=b1 bash /data/baseline/scripts/screen.sh || { echo "STEP4b FAILED"; exit 1; }

echo "BASELINE ALL DONE $(date '+%F %T')"
