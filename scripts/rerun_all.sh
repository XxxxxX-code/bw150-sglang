#!/bin/bash
# ============================================================================
# 全量重跑总链 —— 原始日志丢失后的完整证据重建
#
# 设计：只起 2 次服务（基线 1 次、最终配置 1 次），把该配置的全部测量
#       在同一进程内跑完。相比原方案多次重启的做法，差异更小、可比性更好。
#       顺带修掉原方案「64K 档 prompt 数 n 不一致」的方法学瑕疵（统一 n=6）。
#
# 卡：默认 6,7（与 env_declare.yaml 声明一致）
# ============================================================================
set -uo pipefail
cd /data/baseline

MASTER="logs/00_rerun_master.log"
mkdir -p logs result/sla result/b2r3 result/final
exec > >(tee -a "$MASTER") 2>&1

export GPUS="${GPUS:-6,7}"
export PORT="${PORT:-30000}"

stamp(){ date '+%F %T'; }
step(){ echo; echo "################ $* @ $(stamp)"; }
ok=1; fail(){ echo "!!!! $*"; ok=0; }

echo "######## 全量重跑开始 $(stamp) ########"
echo "GPUS=$GPUS PORT=$PORT  numa_balancing=$(cat /proc/sys/kernel/numa_balancing 2>/dev/null)"

# ---------------------------------------------------------------- P1 硬件信息
step "P1 硬件/驱动信息快照"
{
  echo "# 硬件与驱动信息"
  echo "采集时间: $(stamp)"
  echo; echo "## hy-smi 全卡快照"; hy-smi 2>&1
  echo; echo "## 驱动版本";  hy-smi --showdriverversion 2>&1
  echo; echo "## VBIOS";     hy-smi --showvbios 2>&1
  echo; echo "## VRAM 用量"; hy-smi --showmeminfo vram 2>&1
  echo; echo "## DTK 版本";  cat /opt/dtk/.dtk_version 2>/dev/null
  echo; echo "## 操作系统";  uname -a; sed -n '1,3p' /etc/os-release
  echo; echo "## 容器标识";  head -1 /proc/self/cgroup
  echo; echo "## 软件栈版本"
  python3 - <<'PY' 2>/dev/null
import importlib
for m in ['torch','triton','sglang','flash_attn','sgl_kernel','lightop','causal_conv1d','aiter','transformers','numpy']:
    try:
        mod=importlib.import_module(m)
        print(f"  {m:<16} {getattr(mod,'__version__','?')}")
    except Exception as e:
        print(f"  {m:<16} ERR {type(e).__name__}")
PY
} > logs/01_hardware_driver_info.log 2>&1
echo "-> logs/01_hardware_driver_info.log"

# ------------------------------------------------------- P2 出厂默认崩溃取证
step "P2 出厂默认启动崩溃取证"
bash scripts/capture_default_crash.sh || fail "崩溃取证脚本异常"

# ------------------------------------------------------------- P3 基线 B2
step "P3 基线 B2 —— 启动（一次起服，跑完该配置全部测量）"
if TAG=b2all MODE=b2 START_SCRIPT=/data/baseline/scripts/start_baseline.sh \
     bash scripts/restart.sh; then
  step "P3.1 基线 4K/1K SLA 全档"
  python3 scripts/sla_probe.py --tag b2sla --scenario 4k || fail "基线 SLA4K"
  step "P3.2 基线 64K/1K SLA（1..6，统一 n=6）"
  python3 scripts/sla_probe.py --tag b2sla --scenario 64k \
    --concs 1,2,3,4,5,6 --num-prompts 6 --warmup 0 || fail "基线 SLA64K"
  step "P3.3 基线 ShareGPT 全档 3 轮"
  ROUNDS=3 TAG=b2r3 bash scripts/grid.sh || fail "基线 grid"
  step "P3.4 基线 GSM8K 全量"
  python3 scripts/run_gsm8k.py --tag b2 --num-threads 32 --max-tokens 8192 --no-thinking \
    || fail "基线 GSM8K"
else
  fail "基线 B2 启动失败，跳过整条基线链"
fi

# -------------------------------------------------------- P4 最终配置 C4
step "P4 最终配置 C4 —— 启动"
EXTRA="--disable-radix-cache --max-running-requests 64 --max-mamba-cache-size 64
       --mamba-ssm-dtype bfloat16
       --chunked-prefill-size 32768 --max-prefill-tokens 32768"
if TAG=final MAMBA_STRATEGY=no_buffer CONTEXT_LEN=262144 MEM_FRACTION=0.85 \
     EXTRA_ARGS="$EXTRA" EXTRA_ENV="$(cat scripts/env_c3_kernels.txt)" \
     bash scripts/restart.sh; then
  step "P4.1 最终 4K/1K SLA 全档"
  python3 scripts/sla_probe.py --tag final --scenario 4k || fail "最终 SLA4K"
  step "P4.2 最终 64K/1K SLA（1..6，统一 n=6）"
  python3 scripts/sla_probe.py --tag final --scenario 64k \
    --concs 1,2,3,4,5,6 --num-prompts 6 --warmup 0 || fail "最终 SLA64K"
  step "P4.3 最终 ShareGPT 全档 3 轮"
  ROUNDS=3 TAG=final bash scripts/grid.sh || fail "最终 grid"
  step "P4.4 最终 GSM8K 全量"
  python3 scripts/run_gsm8k.py --tag final --num-threads 32 --max-tokens 8192 --no-thinking \
    || fail "最终 GSM8K"
else
  fail "最终配置 C4 启动失败"
fi

# ------------------------------------------------------------------ P5 收尾
step "P5 收尾：停服 + 生成时间线"
for pid in $(ps -ef | awk '/[l]aunch_server/{print $2}'); do kill -9 "$pid" 2>/dev/null; done
sleep 8
{
  echo "# 重跑时间线（从总日志提取）"
  echo "# 生成于 $(stamp)"
  grep -aE "^########|^################|^=== |DONE|FAILED|!!!!" "$MASTER"
} > logs/12_run_timeline.txt 2>&1
echo "-> logs/12_run_timeline.txt"

if [ "$ok" = "1" ]; then
  echo "######## 全量重跑全部成功 $(stamp) ########"
else
  echo "######## 全量重跑结束（有失败项，见上文 !!!! ）$(stamp) ########"
fi
