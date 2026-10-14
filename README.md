# Qwen3.8-27B @ 2 × 海光 DCU BW150 — SGLang 推理优化提交

**子赛道 B（SGLang）· 开放组（其他卡型）**

本机为 **海光 DCU BW150**（`gcnArchName = gfx936:sramecc+:xnack-`，非 BW100 / K100-AI），
官方未发布 BW150 基线，按赛题 `notes` §3.1 属于**开放组·其他卡型**，
基线由本团队在**同环境、出厂默认配置**下自测，并按 §5.3 归档四类原始日志。

> **正式提交包在 [`submit/`](submit/)** —— 评审请从这里开始。
> 本页只是仓库导航；`submit/README.md` 是提交包本体，`submit/REPORT.md` 是五段式实测报告。

---

## 1. 成绩摘要（分母 = 本机自测基线 B2）

| 指标 | 基线 B2 | 本方案 | 提升率 |
|---|---|---|---|
| ShareGPT 输出吞吐 conc 1 | 26.92 tok/s | **67.96** | **+152.5%** |
| ShareGPT conc 16 | 322.89 | **486.90** | **+50.8%** |
| ShareGPT conc 64 | 556.09 | **801.83** | **+44.2%** |
| 官方 SLA 4K/1K 最大并发 | 16 | **32** | **+100%** |
| 官方 SLA 64K/1K 最大并发 | 3 | **6** | **+100%**（两侧同口径 n=6） |
| GSM8K（5-shot / 贪心 / 全量 1314） | 96.19% | **96.35%** | **+0.16 pp** |

全部档位 3 轮测量，输出吞吐极差 **≤ 1.82%**（赛题容差 ±5%）。

**必须一并阅读的边界条件**：本方案**在长 prefill 场景没有优势**
（64K conc1 TTFT 基线 6133.5 ms vs 本方案 6518.1 ms，略慢 6.3%），
且 **TTFT 绝对值相对基线是退化的**（ShareGPT conc64：219 ms → 390 ms）。
详见 [`submit/REPORT.md`](submit/REPORT.md) 第 5 段。

---

## 2. 目录导航

| 路径 | 内容 |
|---|---|
| **`submit/`** | **提交包本体**（§5.1 布局：README / env_declare / config / scripts / patch / requirements / logs） |
| `submit/README.md` | 提交包主页：成绩摘要 + 一键复现 + 目录说明 |
| `submit/REPORT.md` | **五段式实测报告**（环境声明→基线对比→优化方法→数据表格→结论与适用边界） |
| `submit/BASELINE_COMPLIANCE.md` | 基线合规性论证：出厂默认在本机无法启动的完整证据链 |
| `submit/EXPERIMENTS.md` | 优化探索期的配置消融记录（含未归档中间配置的诚实声明） |
| `submit/env_declare.yaml` | 环境声明（硬件/软件/框架/模型/运行/采集，按 §5.2 模板逐字段对齐） |
| `submit/logs/` | **四类原始日志归档**（13 项，见下节） |
| `submit/scripts/run.sh` | **一键复现启动脚本**，完整启动参数不省略任何 flag |
| `viz/` | 可视化对比页（`index.html`，基线 vs 本方案逐档位对照） |
| `logs/` `result/` `scripts/` | 上述归档的**上游原始工作区**，保留供溯源；内容与 `submit/` 内归档同源 |
| `data/` | 数据集副本（ShareGPT_V3、GSM8K test） |

---

## 3. 四类原始日志对应关系（§5.3）

| §5.3 要求 | 归档位置 |
|---|---|
| ① 硬件驱动信息 | `submit/logs/01_hardware_driver_info.log` |
| ② 服务启动日志 | `submit/logs/00_default_crash.log`（出厂默认启动失败证据）<br>`submit/logs/05_server_b2.log` / `05_server_final.log`（两条测量链路完整启动日志） |
| ③ benchmark 原始输出 | `submit/logs/10_sla/{b2,final}_{4k,64k}/conc*_n*.log`（SLA 场景，含并发/吞吐/TTFT/P99 字段）<br>`submit/logs/20_sharegpt_{b2,final}/`（ShareGPT 全档位逐轮） |
| ④ 结束统计与时间戳 | `submit/logs/12_run_timeline.txt`（全流程带时间戳）<br>`submit/logs/30_precision/`（GSM8K 精度）|

另有 `submit/logs/04_model_sha256.txt`（权重清单指纹）、
`submit/logs/06_final_runtime_env.txt`（被测进程逐项生效的 env，用于核对 `run.sh` 声明与实际一致）。

---

## 4. 一键复现

```bash
cd submit
bash scripts/run.sh server     # 只起服务（最终配置）
bash scripts/run.sh bench      # ShareGPT 全档位 3 轮
bash scripts/run.sh sla        # 官方 SLA 两场景
bash scripts/run.sh precision  # GSM8K 全量
```

复现前提：镜像 `sglang:0.5.12-ubuntu22.04-dtk2604-py3.10`、权重 `/models/Qwen3.8-27B`、
`HIP_VISIBLE_DEVICES=6,7`（8 卡机器只用 6、7 号卡）。依赖见 [`submit/requirements.txt`](submit/requirements.txt)。

---

## 5. 声明

本仓库全部数据均在 `submit/env_declare.yaml` 声明的环境中实测，
未伪造、未拼接、未编辑原始日志；未更换或裁剪模型权重；未修改官方 benchmark 的计时与统计逻辑。
本方案**不含任何框架/算子源码改动**（`submit/patch/` 为空），全部优化由启动参数与环境变量构成。
