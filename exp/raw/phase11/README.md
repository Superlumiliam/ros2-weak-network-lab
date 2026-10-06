# Phase 11 参考数据

这是仓库随附的一套有效 Phase 11 参考运行结果，生成于 2026-10-01，运行标签为 `20261001_175114`。它包含 18 轮有效实验：

- 正常网络下 Reliable 与 Best Effort baseline；
- 20/50/100/200/500 ms delay；
- 1/5/10/20% loss；
- Reliable 与 Best Effort 的 10% loss 对照；
- 100 ms + 10% loss 的 QoS 对照；
- KEEP_LAST depth=1/5/10 的 10 s 中断恢复实验。

`manifest.csv` 中的路径相对于本目录记录，因此 clone 仓库后不需要修改本机绝对路径。每轮包含：

- raw CSV：每一条 subscriber 收到的消息及延迟；
- `analysis/`：标准库分析脚本生成的 summary；
- `logs/`：publisher、subscriber 和 `tc -s qdisc` 日志；
- manifest：实验参数和产物映射。

从仓库根目录复核：

```bash
python3 scripts/audit_phase11.py exp/raw/phase11/manifest.csv
python3 scripts/plot_phase11.py \
  exp/raw/phase11/manifest.csv --output-dir exp/plots
```

预期审计结果为 `audit=PASS`。这些数据是 WSL2、ROS 2 Humble、Fast DDS、20 Hz 和本项目 veth/netem 拓扑下的参考，不是跨机器的性能保证。完整解释见 [docs/experiment_results.md](../../../docs/experiment_results.md) 和 [docs/experiment_protocol.md](../../../docs/experiment_protocol.md)。
