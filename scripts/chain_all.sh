#!/bin/bash
# 等 final 链结束后自动接上基线侧收尾链，避免人工守着。
set -uo pipefail
while pgrep -f "run_final.sh" > /dev/null; do sleep 20; done
echo "### run_final 已结束，接 run_b2_side.sh $(date '+%F %T')"
bash /data/baseline/scripts/run_b2_side.sh