# 实验协议

这份协议用于让不同开发者在不同时间运行的结果仍然可以比较。它不保证不同内核、DDS 版本或主机得到完全相同的数字；它规定的是变量、记录方式和解释边界。

## 默认固定条件

除非某一实验明确研究它们，否则固定：

- publisher 频率：20 Hz；
- 消息：`weaknet_demo/msg/WeaknetSample`；
- payload：`hello from weaknet_pub`；
- history：`KEEP_LAST`；
- depth：10；
- 默认 reliability：`RELIABLE`；
- 单轮时间：约 30 s；
- publisher namespace：`weaknet_pub_ns`；
- subscriber namespace：`weaknet_sub_ns`；
- netem 注入点：publisher namespace 的 `wnpub0` 出口；
- 传输：Fast DDS UDPv4；
- 延迟计算：steady clock 发送时间到 steady clock 接收时间。

研究 depth 时只改变 depth；研究 QoS 时只改变 reliability；研究 delay/loss 时不同时改变另一个网络参数，除非实验名称明确是组合条件。

## 指标定义

### received

raw CSV 中实际记录的消息行数，也是 subscriber 回调实际处理的消息数。

### inferred_lost

按 sequence 的相邻 gap 推断：如果前一条是 10、后一条是 13，则推断 11 和 12 未被该 subscriber 观测到。它不能识别 publisher 启动前的消息，也不能说明 DDS 在内部丢失了多少网络包。

### latency

```text
receive_steady_time - send_steady_time
```

单位是毫秒。steady clock 适合测持续时间；ROS time 字段保留用于日志对照，不作为主要延迟计算依据。

### P95

将逐消息 latency 排序后取约第 95 百分位，用于观察长尾。P95 不代表最大值，也可能掩盖很少量但很严重的旧消息，因此 depth 恢复实验必须同时看 max、原始序列和 jitter。

### jitter

当前分析脚本使用 latency 样本的总体标准差作为 `latency_jitter_stddev_ms`。这是一种可重复的离线指标，不是所有实时系统都使用的唯一 jitter 定义；跨项目比较时必须注明定义。

### receive_rate_hz

使用首末接收 steady 时间窗口计算。启动和停止边界会影响该值，所以它适合和 received、duration 一起看，不应单独解释。

## 网络统计和应用统计的区别

`tc -s qdisc show` 的 `dropped` 统计的是经过 qdisc 的网络包，可能包含 DDS 数据、发现流量、控制包和 Reliable 重传包。`inferred_lost` 统计的是应用消息 sequence gap。一个 ROS 2 消息也可能被拆成多个网络包，因此两者不能直接相除或互相替代。

## 运行前检查清单

```bash
source /opt/ros/humble/setup.bash
source ~/ros2exp_ws/install/setup.bash
~/ros2exp_ws/scripts/setup_weaknet_netns.sh up
~/ros2exp_ws/scripts/setup_weaknet_netns.sh status
sudo ip netns exec weaknet_pub_ns tc qdisc show dev wnpub0
```

开始正常网络实验前，最后一条应显示 `noqueue`。如果已有 `netem`，先清除或记录其来源，不要把上一轮故障带进 baseline。

## 运行后检查清单

```bash
python3 ~/ros2exp_ws/scripts/analyze_weaknet_csv.py <raw.csv>
sudo ip netns exec weaknet_pub_ns tc qdisc show dev wnpub0
```

正式套件还应运行：

```bash
python3 scripts/audit_phase11.py exp/raw/phase11/manifest.csv
```

预期 qdisc 没有 `netem`，审计输出为 `audit=PASS`。如果节点被强制 kill、CSV 没有完整 summary 或实验过程中改变了多个变量，应把这一轮标记为异常，而不是加入有效汇总。

## 推荐结果表字段

至少记录：

```text
run_id,qos_reliability,depth,network_condition,
received,inferred_lost,avg_latency_ms,p95_latency_ms,
min_latency_ms,max_latency_ms,latency_jitter_stddev_ms,
duration_s,receive_rate_hz
```

此外保留 raw CSV、subscriber/publisher 日志和 `tc -s` 输出，以便对异常尾延迟进行逐消息复核。
