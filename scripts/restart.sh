#!/bin/bash
# 干净重启：杀旧 server -> 启动新配置 -> 等健康 -> 打印内存账本
#
# 用法（所有可覆盖项都在 start_opt.sh 顶部列出）:
#   TAG=c1 MAMBA_STRATEGY=no_buffer \
#     EXTRA_ARGS="--disable-radix-cache --max-running-requests 32 --max-mamba-cache-size 32" \
#     bash scripts/restart.sh
#
# 说明：EXTRA_ARGS / MAMBA_STRATEGY / MEM_FRACTION 等通过环境变量透传给 start_opt.sh，
#       不再在命令行上重复传递，避免同一个 flag 出现两次。
set -uo pipefail

TAG="${TAG:-opt}"
PORT="${PORT:-30000}"
WAIT_HEALTH="${WAIT_HEALTH:-900}"   # 最多等 15 分钟（模型加载 + cuda graph capture）
START_SCRIPT="${START_SCRIPT:-/data/baseline/scripts/start_opt.sh}"

LOG="/data/baseline/logs/server_${TAG}.log"

# --- 1. 杀旧 server（用显式 PID，pkill -f 会误伤自己的 shell） ---
old=$(ps -ef | awk '/[l]aunch_server/{print $2}')
if [ -n "$old" ]; then
  echo "[restart] killing old server pids: $old"
  for pid in $old; do kill -9 "$pid" 2>/dev/null || true; done
  sleep 10
else
  echo "[restart] no running server"
fi

left=$(ps -ef | awk '/[l]aunch_server/{print $2}')
if [ -n "$left" ]; then
  echo "[restart] WARN still alive: $left ; waiting 15s more"
  kill -9 $left 2>/dev/null || true
  sleep 15
fi

# --- 2. 启动新配置（环境变量透传） ---
echo "[restart] TAG=$TAG start_script=$START_SCRIPT"
nohup bash "$START_SCRIPT" \
  > "/data/baseline/logs/restart_${TAG}.out" 2>&1 &
echo "[restart] launched pid $!, waiting for health on port $PORT ..."

# --- 3. 等健康 ---
deadline=$(( $(date +%s) + WAIT_HEALTH ))
ok=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  if ! ps -ef | grep -q "[l]aunch_server"; then
    echo "[restart] ERROR: server process died. tail of log:"
    tail -30 "$LOG"
    exit 1
  fi
  code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}/health" 2>/dev/null || echo 000)
  if [ "$code" = "200" ]; then ok=1; break; fi
  sleep 10
done

if [ "$ok" != "1" ]; then
  echo "[restart] ERROR: health timeout after ${WAIT_HEALTH}s"
  tail -30 "$LOG"
  exit 1
fi

echo "[restart] HEALTHY at $(date '+%T'). 内存账本:"
grep -aE "Mamba Cache is allocated|KV Cache is allocated|max_total_num_tokens=" "$LOG" | tail -6
echo "[restart] done $(date '+%F %T')"
