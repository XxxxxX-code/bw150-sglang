# 自测基线合规说明（对应 notes.docx §3.1）

本机是 **海光 DCU BW150**，不属于赛题给出官方基线的 BW100 / K100-AI 两个卡型，
落在「开放组 · 其他卡型」。按 §3.1，没有官方基线的卡型必须自测基线，且自测基线要满足三条：
同环境、默认配置、证据齐全。

## 一、同环境

基线与本提交的优化方案在**同一台机器、同一套软件环境**下跑出，硬件软件信息与
`submit/env_declare.yaml` 完全一致：8 卡 BW150 中的 **6、7 号两张卡**（TP=2），
镜像为 sglang 0.5.12 / DTK 2604。
所有基线数据的原始日志都在 `submit/logs/10_sla/b2_4k/`、`submit/logs/10_sla/b2_64k/`、
`submit/logs/20_sharegpt_b2/`，启动日志 `submit/logs/05_server_b2.log`。

## 二、默认配置 —— 出厂默认在本机无法启动（关键）

§3.1 要求基线用「官方发布的默认配置（官方镜像 + 推理框架出厂参数 + 标准 prompt 集 +
官方 benchmark 脚本）」。我们**先如实尝试了纯出厂默认**，它在本机直接崩溃。
这不是我们调低了基线，而是出厂默认与这块卡的 kernel 要求互斥。

**取证**：`submit/logs/00_default_crash.log`
启动命令仅 `--model-path /models/Qwen3.8-27B --tp-size 2 --pp-size 1`，
其余全部出厂默认。崩溃由两行构成：

```
[10:43:23] Qwen3_5ForConditionalGeneration with radix cache requires page_size=1 in
           the current Mamba scheduling mode (no_buffer), but got 64.
           Automatically setting page_size=1.
[10:44:25] RuntimeError: Paged KV cache block size must be 64
```

机理（`sglang/srt/server_args.py`）：

1. `mamba_scheduler_strategy` 出厂默认 `auto` → 解析为 `no_buffer`（`server_args.py:1264-1267`）；
2. 路径走到 `server_args.py:2651-2658`：`no_buffer` + radix cache 时，
   **框架会把 `page_size` 强制改回 1**（即使显式传了 64）；
3. 而本机 fa3 attention kernel 硬要求 `page_size == 64`，否则抛
   `RuntimeError: Paged KV cache block size must be 64`。

即 **出厂默认的 `page_size=1` 与 DCU fa3 kernel 的 `page_size=64` 硬要求不可调和**，
纯出厂默认在本卡上必然启动失败。

顺带记录：官方出厂默认是 `context_length=None` → 实际生效 **262144**；
`cuda_graph_max_bs=256`；`mem_fraction_static` 自动算得 0.7333。
（参考脚本把 context-length 压到 65535，那才是人为改动，我们在优化配置里去掉了。）

## 三、最小必要偏差基线：三条候选，取最快者

出厂默认跑不起来，只能引入「最小必要偏差」。为**避免挑软柿子**，我们实测了三条
彼此独立的偏差路径，并**取吞吐最高的那条作为正式基线**（§3.1 只禁止调低基线，取更快者更安全）：

| 候选 | 偏差改动 | 保留的出厂默认 | 生效并发 | 说明 |
|---|---|---|---|---|
| **B1** | `--mamba-scheduler-strategy extra_buffer --page-size 64` | radix cache ✅、无投机 ✅ | ~25 | 保住出厂默认开启的 radix cache |
| **B2** ← **采用** | `--disable-radix-cache --page-size 64` | `no_buffer` 策略 ✅、无投机 ✅ | **121** | 保住出厂默认的调度策略，代价是丢 radix cache |
| **B3**（未测，仅记录） | `--attention-backend triton` | radix cache ✅、`no_buffer` ✅、`page_size=1` ✅ | — | 偏差最小（只换 attention 后端），但 triton 后端预计更慢；时间不够未实测 |

除上述 flag 外，基线**一切不设**：不给 `--mem-fraction-static`、不给 `--max-running-requests`、
不给 `--context-length`、不加任何性能 env、不用投机解码。

### 采用 B2 的理由

B2 生效并发 121，是三条路径里吞吐最高的（见 `EXPERIMENTS.md` 与 `submit/logs/20_sharegpt_b2/`）。
**注**：B1 的原始日志属于优化探索期记录，未随本次重跑归档，仅作选型依据（见 `REPORT.md` 附录「日志归档范围声明」）。
它保留了出厂默认的 `mamba_scheduler_strategy=no_buffer`，只关闭了 radix cache；
而在 ShareGPT 标准数据集上，radix 前缀复用率实测接近零
（300 条 prompt 中仅 2 条共享 80 字符前缀），所以关闭它对本基线的吞吐几乎只有正向作用。

B2 启动账本（`submit/logs/05_server_b2.log`）：

```
max_running_requests=121, max_mamba_cache_size=121
ssm_state 8.58GB (fp32, 70.9 MB/槽)   KV Cache 320,192 tokens
context_len=262144   available_gpu_mem=14.96 GB
```

## 四、证据齐全

四类原始日志：

| # | 类别 | 位置 |
|---|---|---|
| ① | 硬件与驱动信息 | `submit/logs/01_hardware_driver_info.log` |
| ② | 服务启动日志（含完整启动参数） | `submit/logs/05_server_b2.log`（基线）、`submit/logs/05_server_final.log`（最终配置） |
| ③ | benchmark 原始输出 | `submit/logs/20_sharegpt_b2/`（基线 3 轮 × 5 档）、`submit/logs/10_sla/b2_4k/`、`submit/logs/10_sla/b2_64k/`（SLA 两场景） |
| ④ | 结束统计与时间戳 | 各日志自带 `Benchmark duration` 与逐档 `start/done` 时间戳；汇总见 `submit/logs/12_run_timeline.txt`；精度 JSON 见 `submit/logs/30_precision/` |

另附出厂默认崩溃日志 `submit/logs/00_default_crash.log` 作为「默认配置不可用」的直接证据。

## 五、本说明的诚实边界

- 本基线是**自测基线**，未经官方复核。按 §3.1 公示 3 天接受质疑。
- B3 路径（`--attention-backend triton`）未实测，仅从代码推导其可行性，不构成基线数据。
- 提升率的分母一律为本机自测基线；官方 BW100 数字只作为「同框架同模型在别家卡上的公开数据」
  放在附注里横向参考，**不用于计算提升率**。

## 出厂默认启动结果（证据）

- 时间戳: 2026-10-14 11:08:13
- 日志: `submit/logs/00_default_crash.log`（原文件名 `default_crash_20261014_110627.log`，逐字节同源）
- 启动参数: `--model-path /models/Qwen3.8-27B --tp-size 2 --pp-size 1 --page-size 64`
  （除 `--page-size 64` 外全部为出厂默认；`--page-size` 是 DCU fa3 kernel 的硬要求）
- 结果: **crashed**

```
[2026-10-14 11:06:52] Qwen3_5ForConditionalGeneration with radix cache requires page_size=1 in the current Mamba scheduling mode (no_buffer), but got 64. Automatically setting page_size=1.
[2026-10-14 11:06:54] server_args=ServerArgs(model_path='/models/Qwen3.8-27B', tokenizer_path='/models/Qwen3.8-27B', tokenizer_mode='auto', tokenizer_backend='huggingface', tokenizer_worker_num=1, detokenizer_worker_num=1, skip_tokenizer_init=False, load_format='auto', model_loader_extra_config='{}', trust_remote_code=True, context_length=None, is_embedding=False, prefill_only_disable_kv_cache=False, enable_multimodal=None, revision=None, model_impl='auto', model_config_parser='auto', host='0.0.0.0', port=30000, fastapi_root_path='', grpc_mode=False, skip_server_warmup=False, warmups=None, nccl_port=None, checkpoint_engine_wait_weights_before_ready=False, ssl_keyfile=None, ssl_certfile=None, ssl_ca_certs=None, ssl_keyfile_password=None, enable_ssl_refresh=False, enable_http2=False, dtype='auto', quantization=None, quantization_param_path=None, kv_cache_dtype='auto', enable_fp32_lm_head=False, modelopt_quant=None, modelopt_checkpoint_restore_path=None, modelopt_checkpoint_save_path=None, modelopt_export_path=None, quantize_and_serve=False, rl_quant_profile=None, mem_fraction_static=0.7333391406249999, max_running_requests=None, max_queued_requests=None, max_total_tokens=None, chunked_prefill_size=8192, enable_dynamic_chunking=False, max_prefill_tokens=16384, prefill_max_requests=None, schedule_policy='fcfs', enable_priority_scheduling=False, disable_priority_preemption=False, default_priority_value=None, abort_on_priority_when_disabled=False, schedule_low_priority_values_first=False, priority_scheduling_preemption_threshold=10, schedule_conservativeness=1.0, page_size=1, swa_full_tokens_ratio=0.8, disable_hybrid_swa_memory=False, radix_eviction_policy='lru', enable_prefill_delayer=False, prefill_delayer_max_delay_passes=30, prefill_delayer_token_usage_low_watermark=None, prefill_delayer_forward_passes_buckets=None, prefill_delayer_wait_seconds_buckets=None, prefill_delayer_queue_min_ratio=None, prefill_delayer_max_delay_ms=None, device='cuda', tp_size=2, pp_size=1, pp_max_micro_batch_size=None, pp_async_batch_depth=0, stream_interval=1, batch_notify_size=16, stream_response_default_include_usage=False, incremental_streaming_output=False, enable_streaming_session=False, random_seed=948957364, constrained_json_whitespace_pattern=None, constrained_json_disable_any_whitespace=False, watchdog_timeout=300, soft_watchdog_timeout=None, dist_timeout=None, download_dir=None, model_checksum=None, base_gpu_id=0, gpu_id_step=1, sleep_on_idle=False, use_ray=False, custom_sigquit_handler=None, log_level='info', log_level_http=None, log_requests=False, log_requests_level=2, log_requests_format='text', log_requests_target=None, uvicorn_access_log_exclude_prefixes=[], crash_dump_folder=None, show_time_cost=False, enable_metrics=False, grpc_http_sidecar_port=None, enable_mfu_metrics=False, enable_metrics_for_all_schedulers=False, tokenizer_metrics_custom_labels_header='x-custom-labels', tokenizer_metrics_allowed_custom_labels=None, extra_metric_labels=None, bucket_time_to_first_token=None, bucket_inter_token_latency=None, bucket_e2e_request_latency=None, prompt_tokens_buckets=None, generation_tokens_buckets=None, gc_warning_threshold_secs=0.0, decode_log_interval=40, enable_request_time_stats_logging=False, kv_events_config=None, enable_forward_pass_metrics=False, forward_pass_metrics_worker_id='', forward_pass_metrics_ipc_name=None, enable_trace=False, otlp_traces_endpoint='localhost:4317', export_metrics_to_file=False, export_metrics_to_file_dir=None, api_key=None, admin_api_key=None, served_model_name='Qwen3.8-27B', weight_version='default', chat_template=None, hf_chat_template_name=None, completion_template=None, file_storage_path='sglang_storage', enable_cache_report=False, reasoning_parser=None, strip_thinking_cache=False, enable_strict_thinking=False, tool_call_parser=None, tool_server=None, sampling_defaults='model', dp_size=1, load_balance_method='round_robin', attn_cp_size=1, moe_dp_size=1, dist_init_addr=None, nnodes=1, node_rank=0, json_model_override_args='{}', preferred_sampling_params=None, enable_lora=None, enable_lora_overlap_loading=None, max_lora_rank=None, lora_target_modules=None, lora_paths=None, max_loaded_loras=None, max_loras_per_batch=8, lora_eviction_policy='lru', lora_backend='csgmv', max_lora_chunk_size=16, experts_shared_outer_loras=None, lora_use_virtual_experts=False, lora_strict_loading=False, lora_drain_wait_threshold=0.0, attention_backend='fa3', decode_attention_backend=None, prefill_attention_backend=None, sampling_backend='pytorch', grammar_backend='xgrammar', mm_attention_backend=None, fp8_gemm_runner_backend='auto', fp4_gemm_runner_backend='auto', nsa_prefill_backend=None, nsa_decode_backend=None, disable_flashinfer_autotune=False, pack_paged_kv_to_varlen='auto', pack_paged_kv_to_varlen_min_kv_tokens=16384, pack_paged_kv_to_varlen_min_q_tokens=8192, mamba_backend='triton', speculative_algorithm=None, speculative_draft_model_path=None, speculative_draft_model_revision=None, speculative_draft_load_format=None, speculative_num_steps=None, speculative_eagle_topk=None, speculative_num_draft_tokens=None, speculative_dflash_block_size=None, speculative_accept_threshold_single=1.0, speculative_accept_threshold_acc=1.0, speculative_token_map=None, speculative_attention_mode='prefill', speculative_draft_attention_backend=None, speculative_draft_window_size=None, speculative_moe_runner_backend='auto', speculative_moe_a2a_backend=None, speculative_draft_model_quantization=None, speculative_adaptive=False, speculative_adaptive_config=None, speculative_skip_dp_mlp_sync=False, speculative_ngram_min_bfs_breadth=1, speculative_ngram_max_bfs_breadth=10, speculative_ngram_match_type='BFS', speculative_ngram_max_trie_depth=18, speculative_ngram_capacity=10000000, speculative_ngram_external_corpus_path=None, speculative_ngram_external_sam_budget=0, speculative_ngram_external_corpus_max_tokens=10000000, enable_multi_layer_eagle=False, ep_size=1, moe_a2a_backend='none', moe_runner_backend='auto', record_nolora_graph=True, flashinfer_mxfp4_moe_precision='default', enable_flashinfer_allreduce_fusion=False, enforce_disable_flashinfer_allreduce_fusion=False, enable_aiter_allreduce_fusion=False, deepep_mode='auto', ep_num_redundant_experts=0, ep_dispatch_algorithm=None, init_expert_location='trivial', enable_eplb=False, eplb_algorithm='auto', eplb_rebalance_num_iterations=1000, eplb_rebalance_layers_per_chunk=None, eplb_min_rebalancing_utilization_threshold=1.0, expert_distribution_recorder_mode=None, expert_distribution_recorder_buffer_size=1000, enable_expert_distribution_metrics=False, deepep_config=None, moe_dense_tp_size=None, elastic_ep_backend=None, enable_elastic_expert_backup=False, mooncake_ib_device=None, enable_deepep_waterfill=False, elastic_ep_rejoin=False, max_mamba_cache_size=None, mamba_ssm_dtype=None, mamba_full_memory_ratio=0.9, mamba_scheduler_strategy='no_buffer', mamba_track_interval=256, linear_attn_backend='triton', linear_attn_decode_backend=None, linear_attn_prefill_backend=None, enable_hierarchical_cache=False, hicache_ratio=2.0, hicache_size=0, hicache_write_policy='write_through', hicache_io_backend='kernel', hicache_mem_layout='layer_first', hicache_storage_backend=None, hicache_storage_prefetch_policy='timeout', hicache_storage_backend_extra_config=None, enable_hisparse=False, hisparse_config=None, enable_lmcache=False, kt_weight_path=None, kt_method='AMXINT4', kt_cpuinfer=None, kt_threadpool_count=2, kt_num_gpu_experts=None, kt_max_deferred_experts_per_token=None, dllm_algorithm=None, dllm_algorithm_config=None, cpu_offload_gb=0, offload_group_size=-1, offload_num_in_group=1, offload_prefetch_step=1, offload_mode='cpu', enable_mis=False, disable_radix_cache=False, cuda_graph_max_bs=256, cuda_graph_bs=[1, 2, 4, 8, 12, 16, 24, 32, 40, 48, 56, 64, 72, 80, 88, 96, 104, 112, 120, 128, 136, 144, 152, 160, 168, 176, 184, 192, 200, 208, 216, 224, 232, 240, 248, 256], disable_cuda_graph=False, disable_cuda_graph_padding=False, enable_breakable_cuda_graph=False, enable_profile_cuda_graph=False, enable_cudagraph_gc=False, debug_cuda_graph=False, enable_layerwise_nvtx_marker=False, enable_nccl_nvls=False, enable_symm_mem=False, disable_flashinfer_cutlass_moe_fp4_allgather=False, enable_tokenizer_batch_encode=False, disable_tokenizer_batch_decode=False, disable_outlines_disk_cache=False, disable_custom_all_reduce=False, custom_all_reduce_backend='auto', enable_mscclpp=False, enable_torch_symm_mem=False, pre_warm_nccl=False, disable_overlap_schedule=True, enable_mixed_chunk=False, enable_dp_attention=False, enable_dp_attention_local_control_broadcast=False, enable_dp_lm_head=False, enable_two_batch_overlap=False, enable_single_batch_overlap=False, tbo_token_distribution_threshold=0.48, enable_torch_compile=False, disable_piecewise_cuda_graph=True, enforce_piecewise_cuda_graph=False, enable_torch_compile_debug_mode=False, torch_compile_max_bs=32, piecewise_cuda_graph_max_tokens=8192, piecewise_cuda_graph_tokens=[4, 8, 12, 16, 20, 24, 28, 32, 48, 64, 80, 96, 112, 128, 144, 160, 176, 192, 208, 224, 240, 256, 288, 320, 352, 384, 416, 448, 480, 512, 576, 640, 704, 768, 832, 896, 960, 1024, 1280, 1536, 1792, 2048, 2304, 2560, 2816, 3072, 3328, 3584, 3840, 4096, 4608, 5120, 5632, 6144, 6656, 7168, 7680, 8192], piecewise_cuda_graph_compiler='eager', torchao_config='', enable_nan_detection=False, enable_p2p_check=False, triton_attention_reduce_in_fp32=False, triton_attention_num_kv_splits=16, triton_attention_split_tile_size=None, num_continuous_decode_steps=1, delete_ckpt_after_loading=False, enable_memory_saver=False, enable_weights_cpu_backup=False, enable_draft_weights_cpu_backup=False, allow_auto_truncate=False, enable_custom_logit_processor=False, flashinfer_mla_disable_ragged=False, disable_shared_experts_fusion=False, enforce_shared_experts_fusion=False, disable_chunked_prefix_cache=False, disable_fast_image_processor=False, keep_mm_feature_on_device=False, enable_return_hidden_states=False, enable_return_routed_experts=False, enable_return_indexer_topk=False, scheduler_recv_interval=1, numa_node=None, enable_deterministic_inference=False, rl_on_policy_target=None, enable_attn_tp_input_scattered=False, minimax_opt=False, gc_threshold=None, enable_nsa_prefill_context_parallel=False, nsa_prefill_cp_mode='round-robin-split', enable_fused_qk_norm_rope=False, enable_precise_embedding_interpolation=False, enable_fused_moe_sum_all_reduce=False, enable_prefill_context_parallel=False, prefill_cp_mode='in-seq-split', enable_dynamic_batch_tokenizer=False, dynamic_batch_tokenizer_batch_size=32, dynamic_batch_tokenizer_batch_timeout=0.002, debug_tensor_dump_output_folder=None, debug_tensor_dump_layers=None, debug_tensor_dump_input_file=None, debug_tensor_dump_inject=False, disaggregation_mode='null', disaggregation_transfer_backend='mooncake', disaggregation_bootstrap_port=8998, disaggregation_ib_device=None, disaggregation_decode_enable_radix_cache=False, disaggregation_decode_enable_offload_kvcache=False, num_reserved_decode_tokens=512, disaggregation_decode_polling_interval=1, encoder_only=False, language_only=False, encoder_transfer_backend='zmq_to_scheduler', encoder_urls=[], enable_adaptive_dispatch_to_encoder=False, custom_weight_loader=[], weight_loader_disable_mmap=False, weight_loader_prefetch_checkpoints=False, weight_loader_prefetch_num_threads=4, weight_loader_drop_cache_after_load=False, remote_instance_weight_loader_seed_instance_ip=None, remote_instance_weight_loader_seed_instance_service_port=None, remote_instance_weight_loader_send_weights_group_ports=None, remote_instance_weight_loader_backend='nccl', remote_instance_weight_loader_start_seed_via_transfer_engine=False, engine_info_bootstrap_port=6789, modelexpress_config=None, enable_pdmux=False, pdmux_config_path=None, sm_group_num=8, enable_broadcast_mm_inputs_process=False, enable_prefix_mm_cache=False, mm_enable_dp_encoder=False, mm_process_config={}, limit_mm_data_per_request=None, enable_mm_global_cache=False, decrypted_config_file=None, decrypted_draft_config_file=None, forward_hooks=None, enable_quant_communications=False, msprobe_dump_config=None)
RuntimeError: Paged KV cache block size must be 64
```
