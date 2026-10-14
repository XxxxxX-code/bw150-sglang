#!/usr/bin/env python3
"""把各配置的 grid 结果汇总成一张 markdown 对比表。

用法:
    python3 scripts/summarize.py                 # 扫描 result/*/conc*.log
    python3 scripts/summarize.py ref c1 c2       # 只列指定 tag，次序即列序
"""
import os
import re
import sys
from collections import OrderedDict

RESULT_DIR = "/data/baseline/result"

FIELDS = {
    "out_tps": r"^Output token throughput \(tok/s\):\s+([\d.]+)",
    "peak_tps": r"^Peak output token throughput \(tok/s\):\s+([\d.]+)",
    "ttft_med": r"^Median TTFT \(ms\):\s+([\d.]+)",
    "ttft_p99": r"^P99 TTFT \(ms\):\s+([\d.]+)",
    "tpot_med": r"^Median TPOT \(ms\):\s+([\d.]+)",
    "tpot_p99": r"^P99 TPOT \(ms\):\s+([\d.]+)",
    "e2e_med": r"^Median E2E Latency \(ms\):\s+([\d.]+)",
    "peak_conc": r"^Peak concurrent requests:\s+([\d.]+)",
    "dur": r"^Benchmark duration \(s\):\s+([\d.]+)",
    "ok": r"^Successful requests:\s+(\d+)",
}


def parse(path):
    txt = open(path, "rb").read().decode("utf-8", "replace")
    out = {}
    for k, pat in FIELDS.items():
        m = re.search(pat, txt, re.M)
        out[k] = float(m.group(1)) if m else None
    return out


def main():
    tags = sys.argv[1:]
    if not tags:
        tags = sorted(
            d for d in os.listdir(RESULT_DIR)
            if os.path.isdir(os.path.join(RESULT_DIR, d))
        )

    data = OrderedDict()   # tag -> {conc: metrics}
    for tag in tags:
        d = os.path.join(RESULT_DIR, tag)
        if not os.path.isdir(d):
            continue
        per = {}
        for f in os.listdir(d):
            m = re.match(r"conc(\d+)_n\d+\.log$", f)
            if m:
                per[int(m.group(1))] = parse(os.path.join(d, f))
        if per:
            data[tag] = OrderedDict(sorted(per.items()))
    if not data:
        raise SystemExit("没找到任何 result/<tag>/conc<N>_n<M>.log")

    concs = sorted({c for per in data.values() for c in per})

    def table(title, key, fmt="{}", base=None):
        print(f"\n### {title}\n")
        hdr = "| conc | " + " | ".join(data.keys()) + " |"
        sep = "|---" * (len(data) + 1) + "|"
        print(hdr)
        print(sep)
        for c in concs:
            cells = []
            ref_val = None
            if base and base in data and c in data[base]:
                ref_val = data[base][c].get(key)
            for tag in data:
                v = data[tag].get(c, {}).get(key)
                if v is None:
                    cells.append("-")
                    continue
                s = fmt.format(v)
                if ref_val and key == "out_tps" and tag != base:
                    s += f" ({v / ref_val * 100 - 100:+.1f}%)"
                cells.append(s)
            print(f"| {c} | " + " | ".join(cells) + " |")

    table("输出吞吐 Output token throughput (tok/s) — 括号为相对第一个 tag 的提升", "out_tps", "{:.2f}")
    table("峰值输出吞吐 Peak output (tok/s)", "peak_tps", "{:.2f}")
    table("TTFT 中位 (ms)", "ttft_med", "{:.1f}")
    table("TTFT P99 (ms)", "ttft_p99", "{:.1f}")
    table("TPOT 中位 (ms)", "tpot_med", "{:.2f}")
    table("TPOT P99 (ms)", "tpot_p99", "{:.2f}")
    table("E2E 中位 (ms)", "e2e_med", "{:.1f}")
    table("峰值并发", "peak_conc", "{:.0f}")


if __name__ == "__main__":
    main()
