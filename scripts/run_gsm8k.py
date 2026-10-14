#!/usr/bin/env python3
"""GSM8K 精度校验 —— 用 sglang 自带的评测脚本（与官方同源）。

用法:
    python3 scripts/run_gsm8k.py --tag c2 --num-examples 300   # 冒烟
    python3 scripts/run_gsm8k.py --tag c2                      # 全量 1314 题

几个必须显式控制的点（否则口径会错）:
  1. temperature=0（贪心）。服务端 generation_config 默认 temp=1.0/top_k=20，
     不覆盖就不是同一条输出路径。
  2. **本模型默认开思考模式**（chat_template.jinja:46
     `if enable_thinking is undefined or enable_thinking is true`）。
     ChatCompletionSampler 默认 max_tokens=2048 会被思考链吃光，content 返回空串，
     GSM8K 直接判 0。所以这里 max_tokens 默认给 8192，并支持 --no-thinking 关闭思考。
  3. GSM8KEval 会先切掉前 num_shots 条做 few-shot，所以 --num-examples N 是
     "除去 few-shot 之后的 N 条"。全量 = 1319 - 5 = 1314 条。
"""
import argparse
import json
import os
import time

from sglang.test.simple_eval_common import ChatCompletionSampler
from sglang.test.simple_eval_gsm8k import GSM8KEval

DEFAULT_DATA = "/data/baseline/data/gsm8k_test.jsonl"
GSM8K_TOTAL = 1314  # 1319 - 5 few-shot


def _token_stats(sampler):
    toks = getattr(sampler, "_completion_tokens", None)
    if not toks:
        return None
    return {"n": len(toks), "mean": sum(toks) / len(toks), "max": max(toks)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", default="opt", help="配置标签，用于归档结果")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=30000)
    ap.add_argument("--model", default="Qwen3.8-27B")
    ap.add_argument("--num-examples", type=int, default=None,
                    help="None = 全量 1314 题")
    ap.add_argument("--num-shots", type=int, default=5)
    ap.add_argument("--num-threads", type=int, default=32)
    ap.add_argument("--max-tokens", type=int, default=8192)
    ap.add_argument("--reasoning-effort", default=None,
                    choices=[None, "low", "medium", "high"])
    ap.add_argument("--no-thinking", action="store_true",
                    help="关闭思考模式（chat_template_kwargs.enable_thinking=False）")
    ap.add_argument("--data-path", default=DEFAULT_DATA)
    ap.add_argument("--out-dir", default="/data/baseline/result/precision")
    args = ap.parse_args()

    if not os.path.exists(args.data_path):
        raise SystemExit(f"缺少 GSM8K 数据: {args.data_path}")

    os.makedirs(args.out_dir, exist_ok=True)

    extra_body = {}
    if args.no_thinking:
        extra_body["chat_template_kwargs"] = {"enable_thinking": False}

    # openai SDK 即便对着本地服务也强制要求 api_key 非空，否则
    #   openai.OpenAIError: The api_key client option must be set ...
    # 本地 sglang server 不校验它，给个占位值即可。
    os.environ.setdefault("OPENAI_API_KEY", "EMPTY")

    sampler = ChatCompletionSampler(
        base_url=f"http://{args.host}:{args.port}/v1",
        model=args.model,
        temperature=0.0,          # 贪心，对齐官方口径
        max_tokens=args.max_tokens,
        reasoning_effort=args.reasoning_effort,
        extra_body=extra_body or None,
    )
    evaluator = GSM8KEval(
        num_examples=args.num_examples,
        num_threads=args.num_threads,
        num_shots=args.num_shots,
        data_path=args.data_path,
    )
    n = len(evaluator._lines)

    mode = "no-thinking" if args.no_thinking else "thinking"
    print(f"[gsm8k] tag={args.tag} n={n} shots={args.num_shots} "
          f"mode={mode} temp=0 max_tokens={args.max_tokens} "
          f"threads={args.num_threads}")

    t0 = time.time()
    result = evaluator(sampler)
    elapsed = time.time() - t0

    score = result.score or 0.0
    pct = score * 100
    print("=" * 62)
    print(f"GSM8K tag={args.tag}  mode={mode}")
    print(f"  score = {score:.4f}  ({pct:.2f}%)")
    print(f"  examples = {n}   elapsed = {elapsed:.1f}s")
    print(f"  门槛 >=95.0  ->  {'PASS' if pct >= 95.0 else 'FAIL'}"
          f"   (官方公布基线 97.0，仅作参考)")
    print("=" * 62)

    out = {
        "tag": args.tag,
        "score": score,
        "score_pct": round(pct, 4),
        "num_examples": n,
        "num_shots": args.num_shots,
        "thinking": not args.no_thinking,
        "reasoning_effort": args.reasoning_effort,
        "temperature": 0.0,
        "max_tokens": args.max_tokens,
        "num_threads": args.num_threads,
        "elapsed_sec": round(elapsed, 1),
        "threshold": 95.0,
        "pass": bool(pct >= 95.0),
        # 这个私有属性不是所有版本的 simple_eval_common 都有，
        # 拿不到就记 None —— 重要的是 score 本身，别为一个附属字段把结果丢了。
        "usage_completion_tokens": _token_stats(sampler),
    }
    suffix = "nothink" if args.no_thinking else "think"
    path = os.path.join(args.out_dir, f"gsm8k_{args.tag}_{suffix}.json")
    with open(path, "w") as f:
        json.dump(out, f, indent=2, ensure_ascii=False)
    print(f"结果已写入 {path}")


if __name__ == "__main__":
    main()
