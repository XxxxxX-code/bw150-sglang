#!/bin/bash
# 基线的 64K 并发「容量墙」取证。
#
# 为什么要跑这个：64K/1K 单条请求占 65536+1024=66560 token，
# 基线 B2 的 KV 池只有 max_total_num_tokens=320192，即 4×66560=266240 装得下、
# 5×66560=332800 装不下 —— 所以基线在 conc5 是**物理上跑不了**，不是跑得慢。
# 而本方案的 KV 池是 421376，6×66560=399360 刚好装得下，可以做到 conc6。
# 这就是 64K 档位上唯一确定的增量（+50%），需要一个带原始日志的失败证据。
set -uo pipefail
cd /data/baseline

TAG="${TAG:-b2cap}"

echo "######## STEP A: 启动基线 B2 $(date '+%F %T')"
TAG="$TAG" MODE=b2 START_SCRIPT=/data/baseline/scripts/start_baseline.sh \
  bash /data/baseline/scripts/restart.sh || { echo "B2 START FAILED"; exit 1; }

echo "######## STEP B: 基线 64K SLA 容量墙取证（conc 4/5/6，n=6）$(date '+%F %T')"
python3 scripts/sla_probe.py --tag "$TAG" --scenario 64k \
  --concs 4,5,6 --num-prompts 6 --warmup 0 || echo "SLA64K FAILED"

echo "$TAG CAP DONE $(date '+%F %T')"
