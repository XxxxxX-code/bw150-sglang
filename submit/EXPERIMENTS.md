# 实验台账（BW150 ×2，卡 6/7，SGLang 0.5.12）

> **归档范围声明（请先读）**：本文件记录的是**优化探索期的中间台账**
> （配置 `cA_nospec` / `ref` / `c1` / `c2`），用于交代第 3 段的优化是怎么一步步找到的。
> **这些配置的原始日志未随本次重跑一并归档**，因此本文件中的数字仅作过程叙述，
> **不作为任何成绩数字使用**（详见 `REPORT.md` 附录「日志归档范围声明」）。
>
> **参与计分的两条链路（基线 B2 与最终配置 final）的完整数字见 `REPORT.md` 第 4 段**，
> 其原始日志全部归档在 `logs/` 下。本次重跑已经统一了口径并复核了复现性：
> GSM8K 两侧与早期读数逐位相同，ShareGPT 各档吻合到 1% 以内。

测量口径：`sglang.bench_serving`，ShareGPT，conc 1(n=100)/4/16/32/64(n=300)，warmup=5，seed=1。
所有配置的启动日志在 `logs/server_<tag>.log`，结果在 `result/<tag>/`。
→ **但下表所列的早期配置（`cA_nospec` / `ref` / `c1` / `c2`）的日志与结果目录未随本次重跑归档**，
   下表的路径仅说明它们当初落在哪里，不构成提交包内的可复查证据。

## 配置一览

| tag | 关键改动 | 生效并发 | KV tokens | 启动日志 |
|---|---|---|---|---|
| `cA_nospec` | 无投机 + `no_buffer --disable-radix-cache --max-running-requests 128 --mem-fraction-static 0.85` | **128** | — | （早期 config A） |
| `ref` | 第三方参考脚本原样：EAGLE + `extra_buffer` + 默认并发 | **18** | 239,360 | `server_ref.log` |
| `c1` | `no_buffer --disable-radix-cache --max-running-requests 32 --max-mamba-cache-size 32` | **32** | 525,952 | `server_c1.log` |
| `c2` | c1 之上：`--max-running-requests 64 --max-mamba-cache-size 64 --mamba-ssm-dtype bfloat16` | **64** | 518,784 | `server_c2.log` |

## 内存账本

```
ref  (18并发, fp32 SSM, ratio=5)
  max_mamba_cache_size 90：conv 0.12 + ssm 6.40(71.1MB/槽) + intermediate_ssm 5.34 + intermediate_conv 0.10
  KV 239,360 tokens (K 3.65 + V 3.65 = 7.3GB)

c1   (32并发, fp32 SSM, ratio=1)
  max_mamba_cache_size 32：ssm 2.32GB(72.5MB/槽) + intermediate_ssm 9.28GB
  KV 525,952 tokens

c2   (64并发, bf16 SSM, ratio=1)
  max_mamba_cache_size 64：conv 0.09 + ssm 2.29(35.8MB/槽) + intermediate_ssm 9.14 + intermediate_conv 0.36
  KV 518,784 tokens (K 7.92 + V 7.92)，available_gpu_mem 2.63GB
  cuda_graph 捕获到 bs 64，耗时 18.1s，占用 1.03GB
```

**结论**：bf16 SSM 把 ssm_state 减半，槽位 32→64 而 ssm_state 几乎不涨；但
`intermediate_ssm_state_cache`（9.1GB）随 `max_num_reqs(64) × speculative_num_draft_tokens(4)`
线性增长，**现在是 mamba 侧的第一大开销** → 下一刀砍这里（降 spec steps）。

## 全档位结果（tok/s）

`python3 scripts/summarize.py cA_nospec ref c1 c2`

| conc | cA_nospec | ref | c1 | c2 |
|---|---|---|---|---|
| 1 | 26.88 | 66.54 | 66.92 | 66.85 |
| 4 | — | 212.53 | 215.48 | 218.63 |
| 16 | 323.44 | 455.14 | 470.04 | 475.18 |
| 32 | 450.28 | 411.84 | 624.88 | 631.65 |
| 64 | 555.54 | 411.24 | 625.49 | **746.30** |

TTFT 中位 (ms)：

| conc | cA_nospec | ref | c1 | c2 |
|---|---|---|---|---|
| 32 | 206.48 | 7073.4 | 324.4 | 246.3 |
| 64 | 218.27 | 22276.1 | 10389.2 | **398.8** |

要点：
- ref 在 conc≥32 塌陷：TPS 锁死 ~411，TTFT 7073ms(32) / 22276ms(64)
- c1 把并发 18→32：conc32 **624.88**（ref 411.84，+51.7%），TTFT 7073→324ms
- c1 在 conc32/64 吞吐相同（624.88/625.49）→ 天花板卡在 32
- **c2 把并发推到 64：conc64 746.30**，相对 c1 +19.3%，相对 ref +81.5%，TTFT 22276→398.8ms（**56×**）
- EAGLE 的收益随 batch 增大而摊薄：accept len 从 bs1 的 3.18 降到 bs32 的 2.85。
  尽管如此，高并发档仍稳赢无投机：conc64 746.30 vs cA_nospec 555.54（+34.3%）

> 注：cA_nospec 的 conc1 用 n=300，其余 tag 用 n=100；TPS 是速率，差异仅来自 prompt 混合，可接受。
> cA_nospec 缺 conc=4。

## 未动的杠杆（按优先级）

1. **`intermediate_ssm_state_cache` 9.1GB** — 现为 mamba 第一大开销，随 spec steps 线性缩放。
   降 `--speculative-num-steps` 3→2 → 省 ~3GB。
2. **`chunked_prefill_size=8192` / `max_prefill_tokens=16384` 仍为出厂默认** — TTFT 的主杠杆。
   SLA 瓶颈是 TTFT 不是 TPOT（TPOT 48ms vs 门槛 50ms 才刚擦线，需注意）。
3. **`context_length=65535`** — 直接挡住 64K/1K 场景（64K+1K=66560 > 65535），必须调回 262144。
4. `SGLANG_USE_AITER_LINEAR_ATTN=1` 等官方 cookbook 内核开关（参考脚本显式设成 0）—— 见 `scripts/env_c3_kernels.txt`。

## 精度

`scripts/run_gsm8k.py`（sglang 自带评测器）。⚠️ 本模型默认开思考模式，且
`ChatCompletionSampler` 默认 `max_tokens=2048` 会被思考链吃光导致误判 0 分，脚本已改为 8192。

| tag | 配置 | GSM8K | 门槛 95.0 | 耗时 | 原始结果 |
|---|---|---|---|---|---|
| `b2` | 本机自测基线（出厂默认 + 最小必要偏差） | **96.19%** | ✅ | 477.4 s | `result/precision/gsm8k_b2_nothink.json` |
| `final` | **本方案最终配置**（= C4） | **96.35%** | ✅ | 364.6 s | `result/precision/gsm8k_final_nothink.json` |

口径：5-shot、`temperature=0`（贪心）、`max_tokens=8192`、关闭思考模式、全量 1314 题、32 线程。
**结论：精度没有下降，反而略升 +0.16 pp（在 1314 题的统计噪声内属持平）。**
