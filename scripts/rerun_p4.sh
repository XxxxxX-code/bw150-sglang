#!/bin/bash
# ============================================================================
# 补跑链 —— 承接 rerun_all.sh 的两处失败
#
# 失败 1（基线 GSM8K）：数据文件恢复时丢了，已从 openai/grade-school-math
#   的官方 test.jsonl 重新取回（1319 行，5-shot 后 1314 题，与 GSM8KEval 口径一致）。
# 失败 2（最终配置 C4 启动）：env_c3_kernels.txt 在恢复时停在了旧版本，
#   里面残留 SGLANG_ENABLE_OVERLAP_PLAN_STREAM=1 —— 该开关在 DCU 上会让
#   EAGLE 验证路径落回基类抛 NotImplementedError（见 EXPERIMENTS.md 已排除表）。
#   转录里对它的最后一次真实写入是 rec 2532 的 bash heredoc（不含该变量），
#   而恢复只重放了 Write/Edit、没有重放 Bash，所以磁盘上留的是 rec 2484 的旧版。
#   已按 rec 2532 逐字修正。
#
# 本脚本只补这两段：
#   A. 基线 B2 —— 仅补 GSM8K（SLA/ShareGPT 已在 rerun_all.sh 里跑完，不重跑）
#   B. 最终 C4 —— 整条重跑（4K SLA 全档 / 64K SLA 1..6 / ShareGPT 3 轮 / GSM8K）
# ============================================================================
set -uo pipefail
cd /data/baseline

MASTER="logs/00_rerun_p4_master.log"
mkdir -p logs result/sla result/final result/precision result/b2r3
exec > >(tee -a "$MASTER") 2>&1

export GPUS="${GPUS:-6,7}"
export PORT="${PORT:-30000}"

stamp(){ date '+%F %T'; }
step(){ echo; echo "################ $* @ $(stamp)"; }
ok=1; fail(){ echo "!!!! $*"; ok=0; }

echo "######## 补跑开始 $(stamp) ########"
echo "GPUS=$GPUS PORT=$PORT  numa_balancing=$(cat /proc/sys/kernel/numa_balancing 2>/dev/null)"
echo "env_c3_kernels.txt = $(cat scripts/env_c3_kernels.txt)"
echo "gsm8k 数据: $(wc -l < data/gsm8k_test.jsonl) 行"

# ============================================================ A 基线 GSM8K
step "A 基线 B2 启动（仅为补 GSM8K）"
if TAG=b2all MODE=b2 START_SCRIPT=/data/baseline/scripts/start_baseline.sh \
     bash scripts/restart.sh; then
  step "A.1 基线 GSM8K 全量"
  python3 scripts/run_gsm8k.py --tag b2 --num-threads 32 --max-tokens 8192 --no-thinking \
    || fail "基线 GSM8K"

  step "A.2 基线 64K 容量墙取证（conc 4/5/6，n=6）"
  python3 scripts/sla_probe.py --tag b2sla --scenario 64k \
    --concs 4,5,6 --num-prompts 6 --warmup 0 || fail "基线 SLA64K 容量墙"
else
  fail "基线 B2 启动失败"
fi

step "A.3 停基线服"
for pid in $(ps -ef | awk '/[l]aunch_server/{print $2}'); do kill -9 "$pid" 2>/dev/null; done
sleep 10

# ======================================================== B 最终配置 C4
step "B 最终配置 C4 启动"
EXTRA="--disable-radix-cache --max-running-requests 64 --max-mamba-cache-size 64
       --mamba-ssm-dtype bfloat16
       --chunked-prefill-size 32768 --max-prefill-tokens 32768"
if TAG=final MAMBA_STRATEGY=no_buffer CONTEXT_LEN=262144 MEM_FRACTION=0.85 \
     EXTRA_ARGS="$EXTRA" EXTRA_ENV="$(cat scripts/env_c3_kernels.txt)" \
     bash scripts/restart.sh; then

  step "B.1 最终 4K/1K SLA 全档"
  python3 scripts/sla_probe.py --tag final --scenario 4k || fail "最终 SLA4K"

  step "B.2 最终 64K/1K SLA（1..6，统一 n=6）"
  python3 scripts/sla_probe.py --tag final --scenario 64k \
    --concs 1,2,3,4,5,6 --num-prompts 6 --warmup 0 || fail "最终 SLA64K"

  step "B.3 最终 ShareGPT 全档 3 轮"
  ROUNDS=3 TAG=final bash scripts/grid.sh || fail "最终 grid"

  step "B.4 最终 GSM8K 全量"
  python3 scripts/run_gsm8k.py --tag final --num-threads 32 --max-tokens 8192 --no-thinking \
    || fail "最终 GSM8K"
else
  fail "最终配置 C4 启动失败"
fi

# ================================================================ C 收尾
step "C 收尾：停服 + 生成时间线"
for pid in $(ps -ef | awk '/[l]aunch_server/{print $2}'); do kill -9 "$pid" 2>/dev/null; done
sleep 8
{
  echo "# 补跑时间线"
  echo "# 生成于 $(stamp)"
  grep -aE "^########|^################|^=== |DONE|FAILED|!!!!" "$MASTER"
} > logs/13_rerun_p4_timeline.txt 2>&1
echo "-> logs/13_rerun_p4_timeline.txt"

if [ "$ok" = "1" ]; then
  echo "######## 补跑全部成功 $(stamp) ########"
else
  echo "######## 补跑结束（有失败项，见上文 !!!!）$(stamp) ########"
fi
