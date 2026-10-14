# C3 内核/运行时开关包的逐条依据

全部来自本镜像内海光自带的官方配方 `sglang/test/hcu_cookbook_utils.py`，
以及代码里对该 env 的真实读取点。**只列真正改变默认值、且对本模型有作用路径的项。**

## 第一档：官方 Qwen3.6-27B 配方（与本模型同架构家族，同为 GDN 线性注意力）

`QWEN36_27B_COOKBOOK_ENV` 全文只有 5 项，逐条对照：

| env | 默认 | 作用路径 | 处置 |
|---|---|---|---|
| `SGLANG_ENABLE_SPEC_V2` | **True** | 投机解码 v2 | 参考脚本已显式设 1，与默认相同 |
| `SGLANG_USE_LIGHTOP` | False | lightop 融合算子 | 参考脚本已设 1，沿用 |
| `SGLANG_USE_FUSED_TOPK_SOFTMAX` | False | **仅 `layers/moe/topk.py:143` 读取** | **排除** —— 本模型是 dense、无 MoE，设了不起作用 |
| `SGLANG_USE_CAUSAL_CONV1D` | False | `linear/gdn_backend.py:68-72` → HCU 专属 `causal_conv1d_fn_hcu` | **采用** |
| `SGLANG_USE_AITER_LINEAR_ATTN` | False | 4 处：`fla/chunk_delta_h.py:30`、`fla/chunk_o.py:20`、`fla/fused_recurrent.py:19`、`kernels/gdn_triton.py:48` | **采用**。本模型 64 层里 48 层是线性注意力，是最大的单点机会 |

参考脚本把 `SGLANG_USE_AITER_LINEAR_ATTN` 显式设成 **0**，与官方配方相反 —— 这是我们第一个要 A/B 的分歧点。

## 第二档：其他 HCU 官方配方里的运行时/通信项

| env | 出处 | 说明 |
|---|---|---|
| `SGLANG_USE_FUSED_RMS_ROTARY` | QWEN35_397B 配方 | **直接命中本模型**：`models/qwen3_5.py:118,877` 在 `_is_hcu` 下用 lightop 的 `gammarms_rotary_embedding_fuse_with_kv_store`，把 RMSNorm+RoPE+KV写回融成一个 kernel |
| `SGLANG_USE_AITER_AR` | GLM51 配方 | `server_args.py:4558-4566`：HIP 上的 legacy 提升项 → `custom_all_reduce_backend=aiter`。TP=2 下 all-reduce 是每层固定开销 |
| `SGLANG_ENABLE_OVERLAP_PLAN_STREAM` | `environ.py:519` | `eagle_worker_v2.py:121-127,235,887` —— 给 Spec V2 的 draft 单独开 plan stream，与我们的 EAGLE 路径直接相关 |
| `USE_HCU_CUSTOM_ALLREDUCE` / `HIP_KERNEL_EVENT_SYSTENFENCE` / `GLIBC_TUNABLES` / `HIP_KERNEL_BATCH_CEILING` / `GPU_FORCE_BLIT_COPY_SIZE` / `HSA_KERNARG_POOL_SIZE` / `ROC_AQL_QUEUE_SIZE` / `GPU_MAX_HW_QUEUES` | 397B / GLM51 配方 | DTK 运行时与 HIP 队列层，零代码改动 |

## 明确排除（写进报告的"技术深度"）

| 项 | 排除理由 |
|---|---|
| `SGLANG_USE_FUSED_TOPK_SOFTMAX` | MoE 专用，dense 模型无作用 |
| `SGLANG_KV_LAYOUT_HCU_FA` | `environ.py:329` 默认已是 `EnvBool(True)`，设了不产生差异 |
| `SGLANG_CHUNKED_PREFIX_CACHE_THRESHOLD` | `environ.py:458` 默认已是 `EnvInt(0)`，同上 |
| `SGL_CHUNKED_PREFIX_CACHE_THRESHOLD` | 397B 配方里的陈旧拼写，代码中不存在此变量 |
| `HSA_ENABLE_COREDUMP` | 只影响崩溃时是否落 core，与性能无关 |
| `SGLANG_USE_FP8_W8A8_MOE` / `SGLANG_ROCM_USE_AITER_MOE` / `W8A8_SUPPORT_METHODS` | MoE 专用 |
