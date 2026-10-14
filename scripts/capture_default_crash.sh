#!/bin/bash
# 阶段 0 证据链：留存「出厂默认配置在本机启动失败」的原始日志。
#
# 这是 notes.docx §3.1「基线必须用官方发布的默认配置」这条规矩的合规证据：
# 出厂默认在本机跑不起来，所以基线只能是最小必要偏差版本。
#
# 产出: logs/default_crash_<ts>.log + result/BASELINE_COMPLIANCE.md 里的结论行
set -uo pipefail

TS="$(date +%Y%m%d_%H%M%S)"
LOG="/data/baseline/logs/default_crash_${TS}.log"
OUT="/data/baseline/result/BASELINE_COMPLIANCE.md"
PORT="${PORT:-30000}"

# 杀旧 server（显式 PID）
old=$(ps -ef | awk '/[l]aunch_server/{print $2}')
if [ -n "$old" ]; then
  echo "[crash-capture] killing $old"
  for pid in $old; do kill -9 "$pid" 2>/dev/null || true; done
  sleep 10
fi

echo "[crash-capture] 启动纯出厂默认（仅 --tp-size 2 --page-size 64），日志 -> $LOG"
nohup env MODE=default TAG=default_crash LOG="$LOG" \
  bash /data/baseline/scripts/start_baseline.sh > /dev/null 2>&1 &

# 等 12 分钟：要么 /health 200（意外能跑），要么进程挂掉（预期）
deadline=$(( $(date +%s) + 720 ))
result="timeout"
while [ "$(date +%s)" -lt "$deadline" ]; do
  if ! ps -ef | grep -q "[l]aunch_server"; then result="crashed"; break; fi
  code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}/health" 2>/dev/null || echo 000)
  if [ "$code" = "200" ]; then result="healthy"; break; fi
  sleep 5
done

echo "[crash-capture] 结果: $result"
echo "[crash-capture] 关键报错行:"
grep -aE "Error|error|assert|RuntimeError|ValueError|page_size|block size|Traceback" "$LOG" | tail -25

{
  echo ""
  echo "## 出厂默认启动结果（证据）"
  echo ""
  echo "- 时间戳: $(date '+%F %T')"
  echo "- 日志: \`logs/default_crash_${TS}.log\`"
  echo "- 启动参数: \`--model-path /models/Qwen3.8-27B --tp-size 2 --pp-size 1 --page-size 64\`"
  echo "  （除 \`--page-size 64\` 外全部为出厂默认；\`--page-size\` 是 DCU fa3 kernel 的硬要求）"
  echo "- 结果: **${result}**"
  echo ""
  echo '```'
  grep -aE "Error|RuntimeError|ValueError|assert|page_size|block size" "$LOG" | tail -10
  echo '```'
} >> "$OUT"

# 收尾：把可能活着的进程杀掉，交给下一步
left=$(ps -ef | awk '/[l]aunch_server/{print $2}')
if [ -n "$left" ]; then
  for pid in $left; do kill -9 "$pid" 2>/dev/null || true; done
  sleep 10
fi
echo "[crash-capture] done $(date '+%F %T')"
