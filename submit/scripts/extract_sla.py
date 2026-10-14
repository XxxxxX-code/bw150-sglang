#!/usr/bin/env python3
"""把 result/sla/<tag>/ 下所有原始 bench_serving 日志抽成一张总表。

为什么要单独写这个：sla_probe.py 每次跑都会覆盖同 tag 的 SUMMARY.md，
所以同一 tag 下先跑的 4K 和后跑的 64K 只剩原始日志还能区分。
这里直接从日志里的 benchmark_args 读 random_input_len 来分场景，
避免把 4K 的行当成 64K 的。
"""
import os
import re
import sys

ROOT = "/data/baseline/result/sla"

FIELD = {
    "in_len": r"random_input_len=(\d+)",
    "out_len": r"random_output_len=(\d+)",
    "n": r"num_prompts=(\d+)",
    "conc": r"max_concurrency=(\d+)",
    "warmup": r"warmup_requests=(\d+)",
    "tps": r"^Output token throughput \(tok/s\):\s+([\d.]+)",
    "ttft": r"^Median TTFT \(ms\):\s+([\d.]+)",
    "ttft_p99": r"^P99 TTFT \(ms\):\s+([\d.]+)",
    "tpot": r"^Median TPOT \(ms\):\s+([\d.]+)",
    "ok": r"^Successful requests:\s+(\d+)",
    "dur": r"^Benchmark duration \(s\):\s+([\d.]+)",
}

SLA = {4096: (5000.0, 50.0), 65536: (20000.0, 60.0)}


def read(path):
    txt = open(path, "rb").read().decode("utf-8", "replace")
    out = {}
    for k, pat in FIELD.items():
        m = re.search(pat, txt, re.M)
        out[k] = float(m.group(1)) if m else None
    return out


def main():
    tags = sys.argv[1:] or sorted(
        d for d in os.listdir(ROOT) if os.path.isdir(os.path.join(ROOT, d)))
    rows = []
    for tag in tags:
        d = os.path.join(ROOT, tag)
        for fn in sorted(os.listdir(d)):
            if not fn.startswith("conc") or not fn.endswith(".log"):
                continue
            m = read(os.path.join(d, fn))
            if m["in_len"] is None or m["ttft"] is None:
                continue
            m["tag"] = tag
            m["file"] = fn
            rows.append(m)

    for in_len in sorted({r["in_len"] for r in rows}):
        ttft_sla, tpot_sla = SLA.get(int(in_len), (None, None))
        sel = [r for r in rows if r["in_len"] == in_len]
        print(f"\n===== 输入 {int(in_len)} / 输出 "
              f"{int(sel[0]['out_len'])}  SLA: TTFT<{ttft_sla:.0f}ms 且 "
              f"TPOT<{tpot_sla:.0f}ms =====")
        print(f"{'tag':<8}{'conc':>5}{'n':>4}{'warm':>5}{'TPS':>9}{'TTFT':>10}"
              f"{'P99TTFT':>10}{'TPOT':>8}{'ok':>4}  判定")
        for r in sorted(sel, key=lambda r: (r["tag"], r["conc"], r["n"])):
            ok = (r["ok"] is not None and r["ok"] >= r["n"])
            t_ok = r["ttft"] < ttft_sla
            p_ok = r["tpot"] < tpot_sla
            why = "" if (t_ok and p_ok and ok) else ",".join(
                x for x, v in (("TTFT", t_ok), ("TPOT", p_ok), ("req", ok)) if not v)
            print(f"{r['tag']:<8}{int(r['conc']):>5}{int(r['n']):>4}"
                  f"{int(r['warmup']):>5}{r['tps']:>9.2f}{r['ttft']:>10.1f}"
                  f"{r['ttft_p99']:>10.1f}{r['tpot']:>8.2f}{int(r['ok']):>4}"
                  f"  {'PASS' if not why else 'FAIL:' + why}")

        for tag in sorted({r["tag"] for r in sel}):
            good = [int(r["conc"]) for r in sel
                    if r["tag"] == tag and r["ttft"] < ttft_sla and r["tpot"] < tpot_sla
                    and r["ok"] is not None and r["ok"] >= r["n"]]
            print(f"  -> {tag:<8} 满足 SLA 的档位 {sorted(good)}  "
                  f"最大并发 = {max(good) if good else 0}")


if __name__ == "__main__":
    main()
