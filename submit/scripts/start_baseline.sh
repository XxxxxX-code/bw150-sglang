#!/bin/bash
# 自测基线启动器（notes.docx §3.1 合规用）
#
# 规则要求基线 = 官方镜像 + 推理框架出厂参数。但出厂默认在本机直接崩：
#   mamba_scheduler_strategy 默认 auto → no_buffer；no_buffer + radix cache 会把
#   page_size 强制改回 1（server_args.py:2651-2658），而 DCU 的 fa3 kernel 硬要求 64
#   → RuntimeError: Paged KV cache block size must be 64
# 所以基线必须是「最小必要偏差」版本，二者只能取一：
#
#   MODE=default  : 纯出厂默认，只加 --page-size 64（预期崩，用于留取证）
#   MODE=b1       : 出厂默认 + --mamba-scheduler-strategy extra_buffer --page-size 64
#                   （保住出厂默认开启的 radix cache）
#   MODE=b2       : 出厂默认 + --disable-radix-cache --page-size 64
#                   （保住出厂默认的 no_buffer 策略，代价是丢 radix cache）
#
# 除以上 flag 外**一切不设**：不给 --mem-fraction-static、不给 --context-length、
# 不给 --max-running-requests、不加任何 env、不用 EAGLE、不用投机。这才是自测基线。
set -uo pipefail

MODE="${MODE:-b1}"
TAG="${TAG:-baseline_${MODE}}"
MODEL_PATH="${MODEL_PATH:-/models/Qwen3.8-27B}"
PORT="${PORT:-30000}"
GPUS="${GPUS:-6,7}"
LOG="${LOG:-/data/baseline/logs/server_${TAG}.log}"

# 只用最小运行时 env，不引入任何性能调优项
export HIP_VISIBLE_DEVICES="$GPUS"

ARGS=(--model-path "$MODEL_PATH" --host 0.0.0.0 --port "$PORT"
      --served-model-name Qwen3.8-27B --trust-remote-code
      --tp-size 2 --pp-size 1)

case "$MODE" in
  default)
    ARGS+=(--page-size 64)
    ;;
  b1)
    ARGS+=(--mamba-scheduler-strategy extra_buffer --page-size 64)
    ;;
  b2)
    ARGS+=(--disable-radix-cache --page-size 64)
    ;;
  *)
    echo "unknown MODE=$MODE (want default|b1|b2)" >&2; exit 2
    ;;
esac

echo "[start_baseline] MODE=$MODE TAG=$TAG"
echo "[start_baseline] args: ${ARGS[*]}"
echo "[start_baseline] log -> $LOG"

python3 -u -m sglang.launch_server "${ARGS[@]}" 2>&1 | tee "$LOG"
