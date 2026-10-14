#!/usr/bin/env python3
"""把 result/ 下的原始 bench_serving 日志抽成 viz/data.json，供可视化页面读取。
所有数字仍然源自原始日志，不引入任何手工录入值（内存账本除外，那是启动日志的摘录）。"""
import json, os, re, statistics
from collections import defaultdict

ROOT = "/data/baseline"
OUT  = os.path.join(ROOT, "viz", "data.json")

SHAREGPT_FIELD = {
    "tps":      r"^Output token throughput \(tok/s\):\s+([\d.]+)",
    "ttft":     r"^Median TTFT \(ms\):\s+([\d.]+)",
    "tpot":     r"^Median TPOT \(ms\):\s+([\d.]+)",
    "e2e":      r"^Median E2E Latency \(ms\):\s+([\d.]+)",
    "peak":     r"^Peak concurrent requests:\s+(\d+)",
    "ok":       r"^Successful requests:\s+(\d+)",
    "n":        r"num_prompts=(\d+)",
    "conc":     r"max_concurrency=(\d+)",
    "warmup":   r"warmup_requests=(\d+)",
    "dur":      r"^Benchmark duration \(s\):\s+([\d.]+)",
}
SLA_FIELD = dict(SHAREGPT_FIELD)
SLA_FIELD.update({
    "in_len":  r"random_input_len=(\d+)",
    "out_len": r"random_output_len=(\d+)",
    "ttft_p99": r"^P99 TTFT \(ms\):\s+([\d.]+)",
    "tpot_p99": r"^P99 TPOT \(ms\):\s+([\d.]+)",
})
SLA = {4096: (5000.0, 50.0), 65536: (20000.0, 60.0)}
ROUND_PAT = re.compile(r"conc(\d+)_n(\d+)(?:_r(\d+))?\.log$")


def read(path, fields):
    txt = open(path, "rb").read().decode("utf-8", "replace")
    out = {}
    for k, pat in fields.items():
        m = re.search(pat, txt, re.M)
        if not m:
            out[k] = None
        else:
            out[k] = float(m.group(1))
    return out


def med(vals):
    v = [x for x in vals if x is not None]
    return round(statistics.median(v), 2) if v else None


def spread(vals):
    v = [x for x in vals if x is not None]
    if len(v) < 2:
        return None
    m = statistics.median(v)
    return round((max(v) - min(v)) / m * 100, 2) if m else None


# ---------- ShareGPT ----------
sharegpt = {}
rdir = os.path.join(ROOT, "result")
for tag in sorted(os.listdir(rdir)):
    d = os.path.join(rdir, tag)
    if not os.path.isdir(d):
        continue
    per = defaultdict(list)
    for fn in sorted(os.listdir(d)):
        m = ROUND_PAT.match(fn)
        if not m:
            continue
        per[int(m.group(1))].append(read(os.path.join(d, fn), SHAREGPT_FIELD))
    if not per:
        continue
    sharegpt[tag] = {}
    for conc, rows in sorted(per.items()):
        sharegpt[tag][str(conc)] = {
            "tps":    med([r["tps"] for r in rows]),
            "ttft":   med([r["ttft"] for r in rows]),
            "tpot":   med([r["tpot"] for r in rows]),
            "e2e":    med([r["e2e"] for r in rows]),
            "ok":     med([r["ok"] for r in rows]),
            "n":      rows[0]["n"],
            "warmup": rows[0]["warmup"],
            "rounds": len(rows),
            "tps_spread":  spread([r["tps"] for r in rows]),
            "ttft_spread": spread([r["ttft"] for r in rows]),
            "tpot_spread": spread([r["tpot"] for r in rows]),
            "tps_min": min([r["tps"] for r in rows]),
            "tps_max": max([r["tps"] for r in rows]),
        }

# ---------- SLA ----------
sla = {"4096": {}, "65536": {}}
sdir = os.path.join(ROOT, "result", "sla")
seen = {}
for tag in sorted(os.listdir(sdir)):
    d = os.path.join(sdir, tag)
    if not os.path.isdir(d):
        continue
    for fn in sorted(os.listdir(d)):
        if not fn.startswith("conc") or not fn.endswith(".log"):
            continue
        r = read(os.path.join(d, fn), SLA_FIELD)
        if r["in_len"] is None or r["ttft"] is None:
            continue
        key = (tag, int(r["in_len"]), int(r["conc"]))   # 去重必须在 tag 内，否则 final 会被 b2sla 挤掉
        # 同场景同并发有多份探测时，保留样本数更大的那份
        if key in seen and seen[key]["n"] >= r["n"]:
            continue
        ttft_lim, tpot_lim = SLA[int(r["in_len"])]
        full = r["ok"] is not None and r["ok"] >= r["n"]
        t_ok, p_ok = r["ttft"] < ttft_lim, r["tpot"] < tpot_lim
        rec = {
            "tag": tag, "file": fn, "conc": int(r["conc"]), "n": int(r["n"]),
            "warmup": int(r["warmup"]), "tps": round(r["tps"], 2),
            "ttft": round(r["ttft"], 1), "ttft_p99": round(r["ttft_p99"], 1) if r["ttft_p99"] else None,
            "tpot": round(r["tpot"], 2), "ok": int(r["ok"]),
            "ok_all": bool(full),
            "ttft_pass": bool(t_ok), "tpot_pass": bool(p_ok),
            "verdict": "PASS" if (full and t_ok and p_ok) else "FAIL",
            "fail_on": [x for x, v in (("TTFT", t_ok), ("TPOT", p_ok), ("请求", full)) if not v],
        }
        seen[key] = rec
        sla[str(int(r["in_len"]))][tag + "|" + str(int(r["conc"]))] = rec

# 转成 {scenario: {tag: [rows]}}
sla_out = {}
for scen, entries in sla.items():
    by_tag = defaultdict(list)
    for rec in entries.values():
        by_tag[rec["tag"]].append({k: v for k, v in rec.items() if k != "tag"})
    sla_out[scen] = {
        "ttft_limit": SLA[int(scen)][0], "tpot_limit": SLA[int(scen)][1],
        "tags": {t: sorted(rs, key=lambda x: x["conc"]) for t, rs in sorted(by_tag.items())},
    }

# ---------- 精度 ----------
prec = {}
pdir = os.path.join(ROOT, "result", "precision")
if os.path.isdir(pdir):
    for fn in sorted(os.listdir(pdir)):
        if fn.endswith(".json"):
            prec[fn[:-5]] = json.load(open(os.path.join(pdir, fn)))

# ---------- 内存账本（启动日志摘录，非计算值） ----------
ledger = {
    "b2": {"max_running_requests": 121, "kv_tokens": 320192, "ssm_state_gb": 8.58,
           "ssm_dtype": "fp32", "chunked_prefill": 8192, "max_prefill_tokens": 16384,
           "cuda_graph_max_bs": 256, "mem_fraction_static": 0.7333,
           "available_gpu_mem_gb": 14.96, "spec_decode": "无", "radix_cache": "关闭（偏差项）",
           "context_len": 262144, "log": "submit/logs/05_server_b2.log"},
    "final": {"max_running_requests": 64, "kv_tokens": 421376, "ssm_state_gb": 2.29,
              "ssm_dtype": "bfloat16", "chunked_prefill": 32768, "max_prefill_tokens": 32768,
              "cuda_graph_max_bs": 64, "mem_fraction_static": 0.85,
              "available_gpu_mem_gb": 5.82, "spec_decode": "EAGLE steps3/topk1/draft4",
              "radix_cache": "关闭", "context_len": 262144, "log": "submit/logs/05_server_final.log"},
}

# SLA 两场景的「基线段 vs 最终段」并排结构，供页面矩阵直接取用
sla_series = {}
for scen in ("4096", "65536"):
    tags = sla_out[scen]["tags"]
    base_rows = tags.get("b2sla", [])
    fin_rows = tags.get("final", [])
    sla_series[scen] = {
        "baseline": {"tag": "b2sla", "rows": base_rows},
        "final": {"tag": "final", "rows": fin_rows},
    }

data = {
    "generated": "2026-10-14",
    "sharegpt": sharegpt,
    "sla": sla_out,
    "sla_series": sla_series,
    "precision": prec,
    "ledger": ledger,
}
with open(OUT, "w") as f:
    json.dump(data, f, ensure_ascii=False, indent=1)
print("wrote", OUT, os.path.getsize(OUT), "bytes")
print("sharegpt tags:", list(sharegpt))
print("sla scenarios:", {k: list(v["tags"]) for k, v in sla_out.items()})
print("precision:", list(prec))