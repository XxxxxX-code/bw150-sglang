#!/bin/bash
# 参考配置全档位测量（服务已在 30000 端口运行，逐档位跑，不重启服务）
set -uo pipefail
NUM="${NUM:-300}"
for C in 4 16 32 64; do
  echo "=== conc=$C start $(date '+%F %T') ==="
  bash /data/baseline/scripts/run_sharegpt.sh "$C" "$NUM" 2>&1 | tail -12
  echo "=== conc=$C end $(date '+%F %T') ==="
done
echo "ALL DONE $(date '+%F %T')"