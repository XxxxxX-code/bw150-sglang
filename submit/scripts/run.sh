#!/bin/bash
# ============================================================================
# 最终方案一键复现脚本 —— 2 × 海光 DCU BW150，Qwen3.8-27B，SGLang 0.5.12
#
# 用法:
#   bash run.sh server     # 只起服务（日志同时落到 logs/server_<TAG>.log）
#   bash run.sh bench      # 起服务后跑 ShareGPT 全档位 3 轮
#   bash run.sh sla        # 起服务后跑官方 SLA 两场景
#   bash run.sh precision  # 起服务后跑 GSM8K 全量
#
# 复现前请确认:
#   1) HIP_VISIBLE_DEVICES 指向你要用的两张卡（默认 6,7）
#   2) /models/Qwen3.8-27B 存在
#   3) ShareGPT 数据集路径正确（默认见 DATASET 变量，可用环境变量覆盖）
#
# 本方案不含任何框架源码改动（patch/ 为空目录），
# 全部优化都由下面这些启动参数与环境变量构成。
# ============================================================================
set -euo pipefail

# ----------------------------- 可调项 ---------------------------------------
export HIP_VISIBLE_DEVICES="${HIP_VISIBLE_DEVICES:-6,7}"
MODEL="${MODEL:-/models/Qwen3.8-27B}"
PORT="${PORT:-30000}"
DATASET="${DATASET:-/data/baseline/data/ShareGPT_V3_unfiltered_cleaned_split.json}"
TAG="${TAG:-final}"

# ----------------------------- 环境变量 -------------------------------------
# 第一组：基础项。这 8 项来自第三方参考启动脚本（scripts/start_opt.sh 的 export 段），
# 基线与最终配置两侧都生效，被测进程的真实取值见 logs/06_final_runtime_env.txt。
# 它们必须出现在这里，否则「只用 run.sh 复现」跑出来的不是被测配置。
export SGLANG_USE_CUDA_IPC_TRANSPORT=1
export SGLANG_USE_LIGHTOP=1
export SGLANG_ENABLE_SPEC_V2=1            # EAGLE 走 spec v2 路径
export SGLANG_ALLOW_OVERWRITE_LONGER_CONTEXT_LEN=1   # 长于 context-length 的请求不报错
export HSA_FORCE_FINE_GRAIN_PCIE=1
export NCCL_MIN_NCHANNELS=16
export NCCL_MAX_NCHANNELS=16
export ALLREDUCE_STREAM_WITH_COMPUTE=1

# 第二组：本方案新增的「内核包」+ HCU 官方 cookbook 底层调优 env。
# 实测收益：ShareGPT conc 32/64 上 +2.8% / +3.5%（见 REPORT.md §3.5）。
export SGLANG_USE_AITER_LINEAR_ATTN=1     # 48 层 GDN 线性注意力走 aiter 实现
export SGLANG_USE_CAUSAL_CONV1D=1         # HCU 专属 causal_conv1d_fn_hcu
export SGLANG_USE_AITER_AR=1              # TP=2 的 all-reduce 走 aiter
export USE_HCU_CUSTOM_ALLREDUCE=1
export HIP_KERNEL_EVENT_SYSTENFENCE=1
export GLIBC_TUNABLES=glibc.rtld.optional_static_tls=0x40000
export HIP_KERNEL_BATCH_CEILING=100
export GPU_FORCE_BLIT_COPY_SIZE=16
export HSA_KERNARG_POOL_SIZE=8388608
export ROC_AQL_QUEUE_SIZE=131072
export GPU_MAX_HW_QUEUES=4

# ----------------------------- 启动参数 -------------------------------------
ARGS=(
  --model-path "$MODEL"
  --host 0.0.0.0 --port "$PORT"
  --served-model-name Qwen3.8-27B
  --trust-remote-code
  --dtype bfloat16
  --tp-size 2 --pp-size 1
  --numa-node 0 0

  # --- 后端：HCU 上 fa3 是本模型唯一可用组合（白名单见 REPORT.md §3.7）---
  --attention-backend fa3
  --mm-attention-backend fa3

  # --- 并发解锁（REPORT.md §3.1，最大单项收益）---
  # ratio 从 5 塌回 1: 必须 no_buffer + disable_radix_cache 成对使用，
  # 否则 extra_buffer + disable_radix_cache 会直接 ValueError。
  --mamba-scheduler-strategy no_buffer
  --disable-radix-cache
  --max-running-requests 64            # 顶掉 EAGLE 强制的 48 帽 + 消掉投机中间态的过量预留
  --max-mamba-cache-size 64
  --mamba-ssm-dtype bfloat16           # ssm_state 由 fp32 减半：6.40 GB -> 2.29 GB

  # --- 上下文长度（REPORT.md §3.3）---
  # 必须 >= 66560，否则 64K/1K 场景（65536+1024）会被直接拒绝、该项 0 分。
  --context-length 262144

  # --- prefill 批处理（REPORT.md §3.4，SLA 关键杠杆）---
  --chunked-prefill-size 32768
  --max-prefill-tokens 32768
  --mem-fraction-static 0.85           # 与上一行配套：把 KV 冗余换成 chunk 激活余量

  # --- 投机解码（REPORT.md §3.2，提升率主要来源）---
  --speculative-algorithm EAGLE
  --speculative-num-steps 3
  --speculative-eagle-topk 1
  --speculative-num-draft-tokens 4

  # --- 其他 ---
  --cuda-graph-max-bs 64
  --kv-cache-dtype bfloat16
  --page-size 64                       # DCU fa3 kernel 硬要求
  --reasoning-parser qwen3
  --tool-call-parser qwen3_coder
)

start_server() {
  local log="logs/server_${TAG}.log"
  mkdir -p logs
  echo "[run] 启动最终配置，日志 -> $log"
  echo "[run] 期望在日志中看到（准入检查，看不到就是没生效）:"
  echo "       Mamba Cache is allocated. max_mamba_cache_size: 64"
  echo "       KV Cache is allocated. #tokens: 421376"
  echo "       max_total_num_tokens=421376 ... max_running_requests=64 context_len=262144"
  python3 -u -m sglang.launch_server "${ARGS[@]}" 2>&1 | tee "$log" &
  SERVER_PID=$!
  echo "[run] pid=$SERVER_PID，等待 /health ..."
  for _ in $(seq 1 900); do
    if curl -sf -o /dev/null "http://127.0.0.1:${PORT}/health"; then
      echo "[run] 服务就绪 $(date '+%F %T')"
      grep -aE "max_total_num_tokens|Mamba Cache is allocated|KV Cache is allocated" "$log" | tail -3
      return 0
    fi
    kill -0 "$SERVER_PID" 2>/dev/null || { echo "[run] 进程已退出，见 $log"; exit 1; }
    sleep 1
  done
  echo "[run] 等待 /health 超时"; exit 1
}

run_bench() {
  # ShareGPT 全档位 3 轮（conc1 用 100 条，其余 300 条，与官方口径一致）
  for r in 1 2 3; do
    for pair in 1:100 4:300 16:300 32:300 64:300; do
      C="${pair%%:*}"; N="${pair##*:}"
      echo "=== conc=$C round=$r n=$N $(date '+%T') ==="
      python3 -m sglang.bench_serving \
        --backend sglang --host 127.0.0.1 --port "$PORT" \
        --model "$MODEL" \
        --dataset-name sharegpt --dataset-path "$DATASET" \
        --num-prompts "$N" --max-concurrency "$C" \
        --warmup-requests 5 --seed 1 \
        2>&1 | tee "logs/bench_sharegpt_${TAG}_conc${C}_r${r}.log" \
        | grep -aE "^Output token throughput|^Median TTFT|^Median TPOT|^Successful requests"
    done
  done
}

run_sla() {
  # 官方 §4.1.3 两个场景
  python3 scripts/sla_probe.py --tag "${TAG}_4k" --scenario 4k \
    --concs 1,4,8,16,32,64 --num-prompts 64
  python3 scripts/sla_probe.py --tag "${TAG}_64k" --scenario 64k \
    --concs 1,2,4,5,6 --num-prompts 6 --warmup 0
}

run_precision() {
  python3 scripts/run_gsm8k.py --tag "$TAG" --num-examples 1314 \
    --num-threads 32 --max-tokens 4096 --no-thinking
}

case "${1:-server}" in
  server)    start_server; wait "$SERVER_PID" ;;
  bench)     start_server; run_bench ;;
  sla)       start_server; run_sla ;;
  precision) start_server; run_precision ;;
  *)         echo "用法: bash run.sh {server|bench|sla|precision}"; exit 1 ;;
esac
