# Qwen3.8-27B @ 2 × 海光 DCU BW150 — SGLang 推理优化提交包

**子赛道 B（SGLang）· 开放组（其他卡型）**

> 本机为 **BW150**，官方未发布 BW150 基线（不在 BW100 / K100-AI 之列），
> 按 `notes` §3.1 属于**开放组**，基线需**自测**。本包含自测基线、最终配置、
> 四类原始日志与完整复现脚本。

---

## 1. 成绩摘要（分母 = 本机自测基线 B2）

| 指标 | 基线 B2 | 本方案 | 提升率 |
|---|---|---|---|
| ShareGPT 输出吞吐 conc 1 | 26.92 tok/s | **67.96** | **+152.5%** |
| ShareGPT conc 4 | 117.27 | **220.50** | **+88.0%** |
| ShareGPT conc 16 | 322.89 | **486.90** | **+50.8%** |
| ShareGPT conc 32 | 450.78 | **647.74** | **+43.7%** |
| ShareGPT conc 64 | 556.09 | **801.83** | **+44.2%** |
| 官方 SLA 4K/1K 最大并发 | 16 | **32** | **+100%** |
| 官方 SLA 64K/1K 最大并发 | 3 | **6** | **+100%**（两侧同口径 n=6） |
| GSM8K（5-shot / 贪心 / 全量 1314） | 96.19% | **96.35%** | **+0.16 pp** |

测量方差：全部档位 3 轮，输出吞吐极差 **≤ 1.82%**（赛题容差 ±5%）。

**必须一并阅读的是边界条件**：本方案**在长 prefill 场景没有优势**
（64K conc1 TTFT 基线 6133.5 ms vs 本方案 6518.1 ms，略慢 6.3%），
且 **TTFT 绝对值是退化的**（ShareGPT conc64：219 ms → 390 ms）。
这两项与其它局限写在 `REPORT.md` 第 5 段，请对照使用。

---

## 2. 一键复现

在 `submit/` 目录下执行（脚本内的 `logs/`、`scripts/` 为相对 cwd 路径）：

```bash
# 只起服务（最终配置）
bash scripts/run.sh server

# ShareGPT 全档位 3 轮
bash scripts/run.sh bench

# 官方 SLA 两个场景
bash scripts/run.sh sla

# GSM8K 全量精度
bash scripts/run.sh precision
```

> 根下的 `run.sh` 是转发入口（`bash run.sh server` 等价），
> 赛题 §5.1 规定的规范位置是 `scripts/run.sh`。

可覆盖项：`HIP_VISIBLE_DEVICES`（默认 `6,7`）、`MODEL`、`PORT`、`DATASET`、`TAG`。
确切的完整启动参数见 `scripts/run.sh` 中的 `ARGS` 数组，**未省略任何 flag**。

> **保真性已核对（本次重跑实测）**：`scripts/run.sh` 不是「照记忆重写」的脚本 ——
> 它在本次收尾时被**真跑过一次**（`bash scripts/run.sh server`），起服后的准入三行与原测量配置逐项一致：
> `max_total_num_tokens=421376, chunked_prefill_size=32768, max_prefill_tokens=32768,
> max_running_requests=64, context_len=262144, available_gpu_mem=5.82 GB`。
> 环境变量以该次运行进程的 `/proc/<pid>/environ` 直出为准（`logs/06_final_runtime_env.txt`）；
> 启动参数逐项对照被测进程启动日志里的 `ServerArgs(...)`（`logs/05_server_final.log`），
> `page_size=64` / `mamba_scheduler_strategy=no_buffer` / `disable_radix_cache=True` /
> `mamba_ssm_dtype=bfloat16` / `max_mamba_cache_size=64` / `EAGLE steps3/topk1/draft4` /
> `context_length=262144` / `chunked_prefill_size=32768` / `mem_fraction_static=0.85` 全部一致。

### 准入检查（起服后必看，看不到就是没生效）

```
Mamba Cache is allocated. max_mamba_cache_size: 64, ...
KV Cache is allocated. #tokens: 421376, ...
max_total_num_tokens=421376, chunked_prefill_size=32768, max_prefill_tokens=32768,
  max_running_requests=64, context_len=262144, available_gpu_mem=5.82 GB
```

---

## 3. 目录结构

```
├─ run.sh                     ← 转发入口（等价于 scripts/run.sh）
├─ requirements.txt           ← 依赖声明（脚本依赖 + 镜像预装的推理栈版本清单）
├─ REPORT.md                  ← 五段式正式报告（主文档，先看这个）
├─ env_declare.yaml           ← 环境声明（硬件/软件/框架/模型/采集方法）
├─ BASELINE_COMPLIANCE.md     ← 自测基线的合规性论证（为什么必须自测、偏差项理由）
├─ EXPERIMENTS.md             ← 实验台账（每条改动 vs 结果，含被推翻的结论）
├─ scripts/                   ← 启停与测量脚本
│   ├─ run.sh                 一键复现（最终配置完整启动参数，赛题 §5.1 规范位置）
│   ├─ start_opt.sh           参数化启动器（默认=参考配置，可覆盖）
│   ├─ start_baseline.sh      出厂默认基线启动器（MODE=default|b1|b2）
│   ├─ start_reference.sh     第三方参考配置（原样保留，供溯源）
│   ├─ restart.sh             干净重启 + 等 /health + 打印内存账本
│   ├─ sla_probe.py           官方 §4.1.3 SLA 最大并发探测
│   ├─ grid.sh / screen.sh    全档位测量 / 快速筛选
│   ├─ run_gsm8k.py           精度校验（sglang 自带评测器，对齐官方口径）
│   ├─ env_c3_kernels.md / .txt  内核与运行时 env 开关包的逐条依据（对照镜像内官方 HCU 配方）
│   ├─ extract_sla.py         从原始日志汇总跨配置 SLA 总表
│   ├─ summarize_rounds.py    多轮网格汇总（中位/min/max/极差%）
│   ├─ run_b2_sla.sh / run_b2_cap.sh / run_b2_side.sh   基线侧 SLA 探测
│   ├─ run_final.sh / run_precision.sh                  本方案侧 SLA 与精度
│   ├─ capture_default_crash.sh                         出厂默认崩溃取证
│   ├─ run_c3.sh / run_c3_full.sh / run_c4.sh / run_c4_full.sh / run_c5.sh / run_c6_full.sh
│   │                         优化探索期的中间配置脚本（对应报告第 3 段的消融，
│   │                         其中间原始日志未随本次重跑归档，见第 6 节第 3 项）
│   └─ start_server.sh / run_sharegpt.sh / sweep_sharegpt.sh / summarize.py   辅助脚本
├─ config/                    ← 模型配置 / 框架版本 / 并行策略 / 显存账本
│   ├─ model_config.json      模型 config.json 原样副本
│   ├─ generation_config.json 模型 generation_config.json 原样副本
│   ├─ parallel_strategy.yaml TP/PP/EP 切分、显存账本、调度与投机参数
│   └─ framework.yaml         框架与后端版本、env 包、已排除项
├─ patch/                     ← 空。本方案未改动任何框架或算子源码
└─ logs/                      ← 四类原始日志（见下）
```

---

## 4. 四类原始日志对应关系

| notes 要求 | 本包位置 | 说明 |
|---|---|---|
| ① 硬件状态 | `logs/01_hardware_driver_info.log` | `hy-smi` 全卡快照 / 驱动 / VBIOS / VRAM / DTK / OS / 容器标识 / 软件栈版本 |
| ② 服务启动日志（含完整参数） | `logs/05_server_b2.log`（基线）<br>`logs/05_server_final.log`（最终配置） | 含完整 `ServerArgs(...)` 与内存账本三行 |
| ③ 压测原始输出 | `logs/20_sharegpt_b2/`（基线，3 轮 × 5 档）<br>`logs/20_sharegpt_final/`（本方案，3 轮 × 5 档）<br>`logs/10_sla/{b2,final}_{4k,64k}/`（SLA 两场景 × 两侧） | `sglang.bench_serving` 的 stdout 原文，未编辑 |
| ④ 结束统计与时间戳 | 各日志自带 `Benchmark duration` 与逐档 `start/done` 时间戳；`logs/12_run_timeline.txt` 汇总时间线；`logs/30_precision/` 为 GSM8K 完整结果 JSON | |

**附加证据**：
- `logs/00_default_crash.log` —— **出厂默认配置在本机直接崩溃**的原始日志
  （`MambaRadixCache v1` 断言 `page_size==1` 与 DCU fa3 kernel 要求 `page_size=64` 冲突）。
  这是自测基线必须做「最小必要偏差」的原因，是合规性论证的核心证据。
- `logs/04_model_sha256.txt` —— 模型目录 32 个文件的逐文件 sha256
  （证明**未更换、未裁剪模型权重**）。
- `logs/06_final_runtime_env.txt` —— 最终配置进程 `/proc/<pid>/environ` 的直出摘录，
  用于核对 `run.sh` 声明的环境变量与实际生效的一致。
- `logs/10_sla/` 内的 SLA 日志按日志自身记录的 `random_input_len` 分场景
  （4096 → `*_4k/`，65536 → `*_64k/`），不靠文件名推断。

---

## 5. 违规项自检

| 违规红线 | 本包情况 |
|---|---|
| 伪造 / 拼接 / 编辑原始日志 | 日志均为脚本 `tee` 直出，逐档带起止时间戳；SLA 日志按自身 `random_input_len` 分场景归档，tag 命名说明见 `REPORT.md` §4.3 |
| 虚构成绩 | 所有数字均可由原始日志用 `python3 scripts/extract_sla.py` 与 `summarize_rounds.py` 重新生成 |
| 更换 / 裁剪模型权重 | `logs/04_model_sha256.txt` 提供模型目录 32 个文件的完整 sha256；`/models` 只读挂载，未修改 |
| 修改官方 benchmark 计时 / 统计逻辑 | **未修改**。`patch/` 为空目录；所有计时与统计均来自官方 `sglang.bench_serving` 原文 |

---

## 6. 已知未完成项（如实列出）

1. **精度只完成了 GSM8K**（96.35%，门槛 ≥95.0，相对基线 +0.16 pp）。
   LiveCodeBench v6 / RealWorldQA / MathVision 的**官方评测脚本不在本镜像内**
   （`lm_eval` / `lighteval` / `vlm_eval` / `evalplus` 全部 ModuleNotFoundError）。
   按赛题「基于官方指定的数据版本、测试子集和评测脚本」的要求，
   这三项需向主办方索取脚本后补测，**本包不声称其数值**。
2. **≥3 张带命令行上下文与时间戳的截图**：本环境无图形界面，无法自行采集，需人工补。
3. **中间过程配置的原始日志未归档**：报告第 3 段引用的参考配置 / B1 / C2 / C3 / C6
   属于优化探索期的记录，其原始日志未随本次重跑一并归档；本轮只重跑了
   **参与计分的两条链路（基线 B2 与最终配置）**。
   报告中所有与成绩相关的数字均可由 `logs/` 下的原始日志复算，
   过程数字已在 `REPORT.md` 附录「日志归档范围声明」中逐条标出。
