# 启停与测量脚本说明

## 核心脚本

| 脚本 | 作用 |
|---|---|
| `start_reference.sh` | 第三方参考配置（**不改动**，作为对照与溯源） |
| `start_opt.sh` | 参数化启动器。默认 = 参考配置。所有可覆盖项走环境变量 |
| `restart.sh` | 干净重启（显式 PID 杀进程 → 启动 → 等 /health → 打印内存账本） |
| `grid.sh` | 全档位测量（conc 1/4/16/32/64），结果归档 `result/<TAG>/` |
| `screen.sh` | 快速筛选（conc 1/16/64），用于配置间 A/B |
| `run_gsm8k.py` | 精度校验（sglang 自带评测器，temperature=0 对齐官方口径） |

## 用法示例

```bash
# 参考配置
TAG=ref bash scripts/restart.sh && TAG=ref bash scripts/grid.sh

# C3 = 并发解锁 + bf16 SSM + 官方 cookbook 内核包
TAG=c3 \
  MAMBA_STRATEGY=no_buffer \
  EXTRA_ARGS="--disable-radix-cache --max-running-requests 64 --max-mamba-cache-size 64 --mamba-ssm-dtype bfloat16" \
  EXTRA_ENV="$(cat scripts/env_c3_kernels.txt)" \
  bash scripts/restart.sh
```

## 准入检查（每次启动必看）

启动日志必须出现这三行，否则该配置没生效，不要往下跑：

```bash
grep -aE "Mamba Cache is allocated|KV Cache is allocated|max_total_num_tokens=" logs/server_<TAG>.log | tail -6
```

重点核对 `max_running_requests=` 是否符合预期。

## 精度校验

```bash
python3 scripts/run_gsm8k.py --tag c3 --num-examples 300   # 冒烟
python3 scripts/run_gsm8k.py --tag c3                      # 全量 1319 题
```

⚠️ **跑精度评测时不要同时跑 grid**，两边抢 GPU 会让数值两边都不可信。

## 踩过的坑（脚本里已经规避）

- `pkill -f launch_server` 会误杀脚本自身 → 一律用 `ps -ef | awk '/[l]aunch_server/{print $2}'` 取 PID
- EXTRA_ARGS 同时出现在命令行和 env 会导致 flag 重复 → 统一只走 env
- 参考脚本的 `--context-length 65535` 会挡住 64K/1K 场景（64K+1K=66560 > 65535）
