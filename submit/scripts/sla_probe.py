#!/usr/bin/env python3
"""SLA 最大并发探测（官方 4.1.3 口径）。

官方 SLA 条件：
    4K 输入 / 1K 输出 : TTFT < 5s  且 TPOT < 50ms
    64K 输入 / 1K 输出: TTFT < 20s 且 TPOT < 60ms

对每个并发档跑一次 sglang.bench_serving（random 数据集），判定该档是否满足 SLA，
输出「满足 SLA 的最大并发」。原始输出落到 result/sla/<tag>/。

用法:
    python3 scripts/sla_probe.py --tag c2 --scenario 4k
    python3 scripts/sla_probe.py --tag c2 --scenario 64k
    python3 scripts/sla_probe.py --tag c2 --scenario 4k --concs 1,4,8,16,32
"""
import argparse
import os
import re
import subprocess
import sys
import time

SCENARIOS = {
    # key: (input_len, output_len, ttft_sla_s, tpot_sla_ms, 默认并发档)
    # 64K 档并发只给到 4：单条 64K+1K=66560 token，4 并发就是 266K token，
    # 已经很接近 KV 池容量（c2/c3 约 518K token），再往上会因为装不下而失败，
    # 失败不代表性能不足，会把 SLA 结论带偏。
    # 4K 档补到 64：32 是上一版的上限，实测在该档通过且 TPOT 仍有 20% 余量
    # （39.79ms vs 50ms 门槛），说明最大并发被测量范围截断了，必须往上探到真正的失败点。
    # 64K 档补到 4：单条 66560 token，4 并发 = 266K token，仍在 KV 池（421K）之内。
    "4k":  (4096,  1024, 5.0,  50.0, [1, 4, 8, 16, 32, 64]),
    "64k": (65536, 1024, 20.0, 60.0, [1, 2, 4]),
}

FIELDS = {
    "tps": r"^Output token throughput \(tok/s\):\s+([\d.]+)",
    "ttft_med": r"^Median TTFT \(ms\):\s+([\d.]+)",
    "ttft_p99": r"^P99 TTFT \(ms\):\s+([\d.]+)",
    "tpot_med": r"^Median TPOT \(ms\):\s+([\d.]+)",
    "tpot_p99": r"^P99 TPOT \(ms\):\s+([\d.]+)",
    "ok": r"^Successful requests:\s+(\d+)",
}


def parse(path):
    txt = open(path, "rb").read().decode("utf-8", "replace")
    out = {}
    for k, pat in FIELDS.items():
        m = re.search(pat, txt, re.M)
        out[k] = float(m.group(1)) if m else None
    out["total_req"] = None
    m = re.search(r"^Total requests:\s+(\d+)", txt, re.M)
    if m:
        out["total_req"] = int(m.group(1))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", required=True)
    ap.add_argument("--scenario", required=True, choices=sorted(SCENARIOS))
    ap.add_argument("--concs", default=None, help="逗号分隔，默认按场景给")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=30000)
    ap.add_argument("--model", default="/models/Qwen3.8-27B")
    ap.add_argument("--num-prompts", type=int, default=64,
                    help="每档请求数；低并发档会自动调小以免太慢")
    ap.add_argument("--warmup", type=int, default=2)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--out-dir", default="/data/baseline/result/sla")
    ap.add_argument("--dataset-path",
                    default="/data/baseline/data/ShareGPT_V3_unfiltered_cleaned_split.json",
                    help="仅用于短路 bench_serving 的数据集去外网下载；random 模式不使用其内容")
    args = ap.parse_args()

    in_len, out_len, ttft_sla, tpot_sla, default_concs = SCENARIOS[args.scenario]
    concs = [int(x) for x in args.concs.split(",")] if args.concs else default_concs

    outdir = os.path.join(args.out_dir, args.tag)
    os.makedirs(outdir, exist_ok=True)

    print(f"# SLA 探测 tag={args.tag} 场景={args.scenario} "
          f"({in_len}in/{out_len}out)  SLA: TTFT<{ttft_sla}s 且 TPOT<{tpot_sla}ms")
    rows = []
    for c in concs:
        # 高并发档减少请求数，避免 64K 场景跑太久
        n = min(args.num_prompts, max(c * 2, 8))
        log = os.path.join(outdir, f"conc{c}_n{n}.log")
        cmd = [
            sys.executable, "-m", "sglang.bench_serving",
            "--backend", "sglang", "--host", args.host, "--port", str(args.port),
            "--model", args.model,
            "--dataset-name", "random",
            # bench_serving 即便在 dataset-name=random 下也会去 HEAD 下载 ShareGPT
            # 数据集（common.py 里的默认路径），本机无外网会卡在重试循环里。
            # 显式给本地路径短路掉这次下载。
            "--dataset-path", args.dataset_path,
            "--random-input-len", str(in_len),
            "--random-output-len", str(out_len),
            "--num-prompts", str(n),
            "--max-concurrency", str(c),
            "--warmup-requests", str(args.warmup),
            "--seed", str(args.seed),
        ]
        # 双保险：离线模式让任何漏网的外网访问立刻失败而不是重试挂死
        env = dict(os.environ)
        env.update({
            "HF_HUB_OFFLINE": "1",
            "HF_DATASETS_OFFLINE": "1",
            "TRANSFORMERS_OFFLINE": "1",
        })
        t0 = time.time()
        print(f"--- conc={c} n={n} start {time.strftime('%T')} ---", flush=True)
        with open(log, "w") as f:
            p = subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, env=env)
        if p.returncode != 0:
            print(f"    FAILED rc={p.returncode} (见 {log})", flush=True)
            rows.append((c, None, None, None, False, "run_failed"))
            continue
        m = parse(log)
        ttft = m["ttft_med"]
        tpot = m["tpot_med"]
        tps = m["tps"]
        # 注意：本版 bench_serving 只打印 "Successful requests:"，没有 "Total requests:"，
        # 所以不能用「成功数 == 总数」判定；改为「成功数 >= 本次提交的请求数」。
        ok_req = (m["ok"] is not None and m["ok"] >= n)
        if ttft is None or tpot is None:
            passed = False
            why = "no_metrics"
        else:
            t_ok = ttft < ttft_sla * 1000
            p_ok = tpot < tpot_sla
            passed = t_ok and p_ok and ok_req
            why = ("ok" if passed
                   else ",".join(x for x, v in
                                 (("TTFT", t_ok), ("TPOT", p_ok),
                                  ("req_ok", ok_req)) if not v))
        rows.append((c, tps, ttft, tpot, passed, why))
        print(f"    TPS={tps} TTFT={ttft}ms TPOT={tpot}ms "
              f"-> {'PASS' if passed else 'FAIL(' + why + ')'} "
              f"[{time.time() - t0:.0f}s]", flush=True)

    print("\n## 结果\n")
    print("| 并发 | TPS | TTFT med (ms) | TPOT med (ms) | SLA | 未达标项 |")
    print("|---|---|---|---|---|---|")
    for c, tps, ttft, tpot, passed, why in rows:
        f = lambda v, p=1: "-" if v is None else f"{v:.{p}f}"
        print(f"| {c} | {f(tps,2)} | {f(ttft)} | {f(tpot,2)} | "
              f"{'✅' if passed else '❌'} | {'' if passed else why} |")

    passing = [c for c, _, _, _, p, _ in rows if p]
    print(f"\n**SLA 最大并发 = {max(passing) if passing else 0}**"
          f"  (官方 BW100 基线: "
          f"{'1' if args.scenario == '4k' else '0'})")

    with open(os.path.join(outdir, "SUMMARY.md"), "w") as fh:
        fh.write(f"# SLA 探测 {args.tag} / {args.scenario}\n\n")
        fh.write(f"SLA: TTFT < {ttft_sla}s 且 TPOT < {tpot_sla}ms\n\n")
        fh.write("| 并发 | TPS | TTFT med | TPOT med | SLA |\n|---|---|---|---|---|\n")
        for c, tps, ttft, tpot, passed, why in rows:
            fh.write(f"| {c} | {tps} | {ttft} | {tpot} | "
                     f"{'PASS' if passed else 'FAIL:' + why} |\n")
        fh.write(f"\nSLA 最大并发 = {max(passing) if passing else 0}\n")


if __name__ == "__main__":
    main()
