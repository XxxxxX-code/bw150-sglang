#!/bin/bash
# ============================================================================
# 从 result/ 与 logs/ 重建提交包的四类原始日志归档
#
# 四类（与 REPORT.md 附录「日志归档范围声明」逐条对应）：
#   00_*  出厂默认崩溃取证（基线合规证据）
#   01_*  ① 硬件 / 驱动 / 软件栈快照
#   05_*  ② 起服日志（含内存账本三行）
#   10_*  ③ 跑测原始日志 —— 官方 SLA
#   20_*  ③ 跑测原始日志 —— ShareGPT
#   12_*  ④ 结束统计 / 时间线
#   30_*  ④ 结束统计 —— 精度
#
# SLA 日志按日志内的 random_input_len 分场景，不靠文件名猜。
# ============================================================================
set -uo pipefail
cd /data/baseline
S=submit/logs

rm -rf "$S"
mkdir -p "$S"/{10_sla/{b2_4k,b2_64k,final_4k,final_64k},20_sharegpt_b2,20_sharegpt_final,30_precision}

echo "### 00 出厂默认崩溃取证"
cp logs/default_crash_*.log "$S/00_default_crash.log" 2>/dev/null \
  && echo "  ✓ 00_default_crash.log ($(wc -l < "$S/00_default_crash.log") 行)" \
  || echo "  ! 未找到崩溃取证日志"

echo "### 01 硬件/驱动快照"
cp logs/01_hardware_driver_info.log "$S/01_hardware_driver_info.log" \
  && echo "  ✓ 01_hardware_driver_info.log ($(wc -l < "$S/01_hardware_driver_info.log") 行)"

echo "### 05 起服日志"
cp logs/server_b2all.log "$S/05_server_b2.log" && echo "  ✓ 05_server_b2.log"
cp logs/server_final.log "$S/05_server_final.log" && echo "  ✓ 05_server_final.log"

echo "### 10 SLA 原始日志（按 random_input_len 分场景）"
split_sla () {   # $1=源目录  $2=基线前缀(b2|final)
  local src="$1" tag="$2" n4=0 n64=0
  for f in "$src"/conc*.log; do
    [ -e "$f" ] || continue
    if grep -qa "random_input_len=4096"  "$f"; then cp "$f" "$S/10_sla/${tag}_4k/";  n4=$((n4+1)); fi
    if grep -qa "random_input_len=65536" "$f"; then cp "$f" "$S/10_sla/${tag}_64k/"; n64=$((n64+1)); fi
  done
  echo "  ✓ ${tag}: 4K $n4 个 / 64K $n64 个"
}
split_sla result/sla/b2sla b2
split_sla result/sla/final final

echo "### 20 ShareGPT 全档位原始日志"
cp result/b2r3/*.log "$S/20_sharegpt_b2/"    2>/dev/null && echo "  ✓ 基线 $(ls "$S/20_sharegpt_b2/" | wc -l) 个"
cp result/final/*.log "$S/20_sharegpt_final/" 2>/dev/null && echo "  ✓ 本方案 $(ls "$S/20_sharegpt_final/" | wc -l) 个"

echo "### 30 精度"
cp result/precision/*.json "$S/30_precision/" 2>/dev/null && echo "  ✓ $(ls "$S/30_precision/" | tr '\n' ' ')"

echo "### 12 时间线（本次重跑，2026-10-14）"
{
  echo "# 本方案全部测量的时间线"
  echo "# 生成于 $(date '+%F %T')"
  echo "# 主机 $(hostname)  容器 $(head -1 /proc/self/cgroup | cut -d/ -f3)"
  echo "# 卡: HIP_VISIBLE_DEVICES=6,7  (hy-smi: BW150 x2, HSL 直连)"
  echo
  echo "## 本轮重跑（原始日志全部在 logs/ 与本目录下）"
  echo
  echo "阶段                                        起                    止"
  echo "------------------------------------------------------------------------------"
  grep -aE "^######## (全量重跑开始|补跑开始)|^################ " logs/00_rerun_master.log logs/00_rerun_p4_master.log 2>/dev/null \
    | sed 's/^logs\/00_rerun_p4_master.log:/[补跑] /; s/^logs\/00_rerun_master.log:/[主链] /' \
    | sed 's/################ /  /; s/ @ /  /'
} > "$S/12_run_timeline.txt"
echo "  ✓ 12_run_timeline.txt"

echo
echo "### 归档总览"
find "$S" -type f | sort | sed "s|$S|  submit/logs|"
echo
echo "文件数: $(find "$S" -type f | wc -l)   总大小: $(du -sh "$S" | cut -f1)"
