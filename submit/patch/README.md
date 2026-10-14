# patch/ —— 本方案不含任何框架或算子源码改动

本提交的全部优化均由**启动参数与环境变量**构成，未修改 SGLang 框架源码、
未替换算子实现文件、未改动 benchmark 脚本。因此本目录为空。

验证方式（在容器内执行）：

    # 1. sglang 源码未被改动
    python3 -c "import sglang,os;print(os.path.dirname(sglang.__file__))"
    #    与镜像原始状态一致，无本地修改痕迹

    # 2. bench_serving 未被改动
    diff <(python3 -c "import inspect,sglang.bench_serving as m;print(inspect.getsource(m))") \
         <(同镜像原始副本)

    # 3. 启动脚本即全部改动面
    cat submit/run.sh

对应赛题允许的优化类别：并行与调度 / KV Cache 与显存管理 / 批处理与调度算法 / 算子内核替换。
