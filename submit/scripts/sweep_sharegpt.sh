#!/bin/bash
# 子赛道 B (SGLang) — ShareGPT 标准数据集 全并发档扫描
# 并发档: 1 / 4 / 16 / 32 / 64，每档固定 300 条请求
# 先跑快档以便尽早拿到数据，慢档(并发1)放最后
set -uo pipefail

NUM="${NUM:-300}"
CONCS="${CONCS:-16 32 64 4 1}"

BASE="$(cd "$(dirname "$0")" && pwd)"
SUMMARY="/data/baseline/result/sharegpt_summary.txt"

: > "$SUMMARY"

for c in $CONCS; do
    echo "==================== concurrency=$c num_prompts=$NUM ===================="
    bash "$BASE/run_sharegpt.sh" "$c" "$NUM"
    echo
    {
        echo "----- concurrency=$c num_prompts=$NUM -----"
        grep -E "^Output token throughput|^Mean TTFT|^Median TTFT|^P99 TTFT|^Mean TPOT|^Median TPOT|^P99 TPOT|^Request throughput|^Successful requests|^Benchmark duration" \
            "/data/baseline/result/sharegpt_conc${c}_n${NUM}.log" 2>/dev/null
        echo
    } >> "$SUMMARY"
done

echo "==================== ALL DONE ===================="
cat "$SUMMARY"
