#!/usr/bin/env python3
"""多轮网格结果的汇总：每档给出 中位数 / 最小 / 最大 / 极差%，用于 §5.2 的「方差/轮次」。

summarize.py 只认 conc<N>_n<M>.log（单轮），轮次文件名是 conc<N>_n<M>_r<R>.log，
会被它整个跳过。这里两种文件名都吃，同档多轮时给出统计量。

用法:
    python3 scripts/summarize_rounds.py final b2r3
    python3 scripts/summarize_rounds.py            # 扫全部 tag
"""
import os
import re
import statistics
import sys
from collections import OrderedDict, defaultdict

RESULT_DIR = "/data/baseline/result"

FIELDS = {
    "out_tps": r"^Output token throughput \(tok/s\):\s+([\d.]+)",
    "ttft_med": r"^Median TTFT \(ms\):\s+([\d.]+)",
    "tpot_med": r"^Median TPOT \(ms\):\s+([\d.]+)",
    "e2e_med": r"^Median E2E Latency \(ms\):\s+([\d.]+)",
    "peak_conc": r"^Peak concurrent requests:\s+([\d.]+)",
    "ok": r"^Successful requests:\s+(\d+)",
}

PAT = re.compile(r"conc(\d+)_n(\d+)(?:_r(\d+))?\.log$")


def parse(path):
    txt = open(path, "rb").read().decode("utf-8", "replace")
    out = {}
    for k, pat in FIELDS.items():
        m = re.search(pat, txt, re.M)
        out[k] = float(m.group(1)) if m else None
    return out


def load(tag):
    d = os.path.join(RESULT_DIR, tag)
    if not os.path.isdir(d):
        return None
    per = defaultdict(list)
    for f in sorted(os.listdir(d)):
        m = PAT.match(f)
        if not m:
            continue
        per[int(m.group(1))].append((m.group(3), parse(os.path.join(d, f))))
    return OrderedDict(sorted(per.items())) if per else None


def stat(vals):
    """返回 (中位, 最小, 最大, 极差%)"""
    vals = [v for v in vals if v is not None]
    if not vals:
        return None
    med = statistics.median(vals)
    lo, hi = min(vals), max(vals)
    spread = (hi - lo) / med * 100 if med else 0.0
    return med, lo, hi, spread


def main():
    tags = sys.argv[1:] or sorted(
        d for d in os.listdir(RESULT_DIR) if os.path.isdir(os.path.join(RESULT_DIR, d)))
    data = OrderedDict()
    for tag in tags:
        r = load(tag)
        if r:
            data[tag] = r
    if not data:
        raise SystemExit("没找到任何网格结果")

    concs = sorted({c for per in data.values() for c in per})

    # 主表：TPS 中位数 + 相对 baseline 的提升率
    base = next(iter(data))
    print(f"\n### 输出吞吐 Output token throughput (tok/s)，中位数（括号 = 相对 {base} 的提升率）\n")
    print("| conc | " + " | ".join(data.keys()) + " |")
    print("|---" * (len(data) + 1) + "|")
    for c in concs:
        cells = []
        ref = stat([v["out_tps"] for _, v in data[base].get(c, [])])
        for tag in data:
            s = stat([v["out_tps"] for _, v in data[tag].get(c, [])])
            if s is None:
                cells.append("-")
                continue
            txt = f"{s[0]:.2f}"
            if ref and tag != base:
                txt += f" ({s[0] / ref[0] * 100 - 100:+.1f}%)"
            cells.append(txt)
        print(f"| {c} | " + " | ".join(cells) + " |")

    # 方差表：每档逐轮给出 min/max/极差
    for key, name, fmt in (("out_tps", "输出吞吐 (tok/s)", "{:.2f}"),
                           ("ttft_med", "TTFT 中位 (ms)", "{:.1f}"),
                           ("tpot_med", "TPOT 中位 (ms)", "{:.2f}")):
        print(f"\n### {name} —— 中位 / 最小 / 最大 / 极差%（§5.2 方差）\n")
        print("| conc | " + " | ".join(data.keys()) + " |")
        print("|---" * (len(data) + 1) + "|")
        for c in concs:
            cells = []
            for tag in data:
                s = stat([v[key] for _, v in data[tag].get(c, [])])
                cells.append("-" if s is None
                             else f"{fmt.format(s[0])} / {fmt.format(s[1])} / "
                                  f"{fmt.format(s[2])} / {s[3]:.2f}%")
            print(f"| {c} | " + " | ".join(cells) + " |")

    # 轮次清单，便于报告里写「本次测量 N 轮」
    print("\n### 轮次覆盖\n")
    for tag in data:
        print(f"- `{tag}`: " + ", ".join(
            f"conc{c}×{len(v)}轮" for c, v in data[tag].items()))


if __name__ == "__main__":
    main()
