# 当前实验结果摘要

这是当前仓库可以公开引用的阶段性结果摘要。完整 raw CSV、节点日志和图表位于本地的 `exp/`，该目录被 `.gitignore` 忽略，其他开发者需要按 README 重新运行实验生成自己的数据。

## 实验边界

结果来自 WSL2 Ubuntu 22.04、ROS 2 Humble、Fast DDS、20 Hz、自定义小消息、namespace/veth 和 `tc netem`。它们说明当前拓扑下的机制和趋势，不是所有机器人、DDS 实现或物理网络的通用性能保证。

Phase 11 自动套件共完成 18 轮有效实验，raw CSV 与分析结果通过审计：manifest 中每轮为 `valid`，raw 行数与 `received` 一致，subscriber 每轮有一条 summary，未发现乱序消息，实验结束后没有残留 netem。

## 纯 delay

Reliable、KEEP_LAST(10)、20 Hz 条件下：

| 注入 delay | 平均延迟 | P95 | 最大延迟 | 推断丢失 |
| ---: | ---: | ---: | ---: | ---: |
| 20 ms | 20.660 ms | 21.033 ms | 22.026 ms | 0 |
| 50 ms | 50.571 ms | 50.853 ms | 51.503 ms | 0 |
| 100 ms | 100.621 ms | 100.935 ms | 101.632 ms | 0 |
| 200 ms | 200.628 ms | 201.071 ms | 201.459 ms | 0 |
| 500 ms | 500.720 ms | 501.182 ms | 502.059 ms | 0 |

观察：纯 delay 近似线性地增加端到端延迟，在这一轮中没有造成 sequence gap；但消息的新鲜度随 delay 直接变差。

## Reliable 下的 packet loss

| loss | received | 推断丢失 | 平均延迟 | P95 | 最大延迟 | jitter |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1% | 594 | 0 | 11.163 ms | 13.185 ms | 412.688 ms | 52.806 ms |
| 5% | 595 | 0 | 29.873 ms | 211.883 ms | 462.004 ms | 81.403 ms |
| 10% | 584 | 1 | 56.043 ms | 312.034 ms | 461.902 ms | 106.253 ms |
| 20% | 577 | 7 | 141.973 ms | 413.073 ms | 463.362 ms | 146.389 ms |

观察：Reliable 下，loss 增大时先明显恶化的是延迟尾部和 jitter；网络包的丢失可能通过重传变成“最终收到但已经过期”的消息。

## Reliable 与 Best Effort

在 10% loss、KEEP_LAST(10)、20 Hz 下：

| QoS | received | 推断丢失 | 平均延迟 | P95 | 最大延迟 | jitter |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Reliable | 584 | 1 | 56.043 ms | 312.034 ms | 461.902 ms | 106.253 ms |
| Best Effort | 530 | 65 | 0.309 ms | 0.611 ms | 1.132 ms | 0.158 ms |

在 100 ms delay + 10% loss 下：

| QoS | received | 推断丢失 | 平均延迟 | P95 | 最大延迟 | jitter |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Reliable | 582 | 7 | 179.275 ms | 463.232 ms | 582.519 ms | 127.690 ms |
| Best Effort | 521 | 67 | 100.562 ms | 101.116 ms | 104.513 ms | 0.328 ms |

初步结论：Reliable 更倾向于提高消息最终到达率，代价是重传、排队和长尾；Best Effort 更倾向于保持已到达消息的新鲜度，代价是应用层丢失更多。这也是实时控制中“宁愿丢旧命令，也不要执行过期命令”的工程背景之一。

## depth 与恢复

在约 10 s 完全中断后恢复网络：

| depth | received | 推断丢失 | 平均延迟 | P95 | 最大延迟 | jitter |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 395 | 201 | 0.477 ms | 0.811 ms | 0.977 ms | 0.196 ms |
| 5 | 399 | 196 | 1.964 ms | 1.286 ms | 210.189 ms | 14.557 ms |
| 10 | 405 | 191 | 6.257 ms | 0.826 ms | 458.647 ms | 42.761 ms |

观察：depth 增大时，恢复阶段更可能排空旧消息，导致少量很高的延迟尖峰；因此 P95 仍可能很低，必须同时检查 max、原始序列和恢复日志。

## 如何复核

```bash
python3 scripts/audit_phase11.py exp/raw/phase11/manifest.csv
python3 scripts/plot_phase11.py \
  exp/raw/phase11/manifest.csv --output-dir exp/plots
```

原始结论和异常历史仍保存在实验者本机的 `exp/conclusions.md` 与 `exp/anomalies.md`。提交新的结果时，请保留实验条件、run id 和异常说明，不要只提交一张经过筛选的漂亮图。
