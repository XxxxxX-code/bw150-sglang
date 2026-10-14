#!/bin/bash
# 兼容入口 —— 赛题 §5.1 规定的规范位置是 scripts/run.sh（含完整启动参数），
# 本文件仅转发，保证两种调用方式都能跑通。
#
#   bash run.sh server       等价于  bash scripts/run.sh server
#
# 注意：两种写法都必须在 submit/ 目录下执行（脚本内的 logs/ 、scripts/ 为相对 cwd 路径）。
exec bash "$(dirname "${BASH_SOURCE[0]}")/scripts/run.sh" "$@"
