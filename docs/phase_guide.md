# Phase 指南

这份文档说明每个阶段为什么存在、要观察什么，以及完成阶段的最低标准。它不是把所有命令堆在一起，而是帮助复现实验的人理解从 ROS 2 工程到弱网研究的递进关系。

## Phase 0：确认环境

目标是确认“命令行能找到什么”和“节点将在哪个网络里通信”，而不是马上修复或重装环境。

需要确认：Ubuntu 版本、ROS 2 distribution、`ros2` 路径、`ROS_DISTRO`、RMW、网络接口、路由和 WSL2 内核。当前基线是 Ubuntu 22.04、ROS 2 Humble、`rmw_fastrtps_cpp`、Fast DDS。

概念关系可以先记成：

```text
应用节点 → rclcpp → RMW → DDS 实现 → UDP/IP
```

完成标准：`ros2 --help` 正常，ROS 发行版和 RMW 可解释，且知道普通 WSL2 流量通常经过 `eth0`，本项目实验流量后来会迁移到隔离 veth。

## Phase 1：官方 talker/listener

先运行 ROS 2 官方 demo，证明安装、source、DDS discovery 和本机基本通信都工作。用 `ros2 node list`、`ros2 topic list`、`ros2 topic info`、`ros2 topic echo`、`ros2 topic hz` 观察系统。

完成标准：`/talker` 和 `/listener` 存在，`/chatter` 有一个 publisher 和一个 subscriber，listener 能收到消息。此时还没有自己的工程代码。

## Phase 2：workspace 和 package

创建 `~/ros2exp_ws/src` 和 `weaknet_demo` package，理解 `src/` 是源码入口，`package.xml` 声明包和依赖，`CMakeLists.txt` 描述 C++ 构建目标，`build/`、`install/`、`log/` 是 colcon 生成的构建产物。

完成标准：`colcon build --packages-select weaknet_demo` 成功，`ros2 pkg prefix weaknet_demo` 指向 workspace 的 `install` overlay。

## Phase 3：publisher

实现最小的 C++ publisher：Node 创建 publisher，timer 周期性触发 callback，callback 创建消息并调用 `publish`，`rclcpp::spin` 让节点持续处理事件。

本项目的消息包含 `sequence`、ROS `send_time`、steady-clock 发送时间和 `payload`。steady clock 用于端到端延迟测量，因为它不受系统时间校准影响。

完成标准：节点可运行，`ros2 topic list` 有 `/weaknet/sample`，`ros2 topic echo` 能观察自定义消息，`ros2 topic hz` 约为 20 Hz。

## Phase 4：subscriber

实现 subscriber，并在回调中记录接收 steady time。用 `receive_steady - send_steady` 计算每条消息的延迟，通过 sequence gap 推断应用层丢失，再逐步增加平均值、最小/最大值、P95、接收率和 jitter。

完成标准：publisher 和 subscriber 能收发；停止 subscriber 时能打印 summary；正常网络下 sequence gap 为零或能解释启动时丢失的原因。

## Phase 5：baseline

在不施加弱网的条件下固定 20 Hz、消息类型、QoS 和运行时长，建立正常网络参考值。任何后续 delay/loss/QoS 结论都应该与 baseline 比较，而不是只看一轮绝对数字。

完成标准：保存至少一轮 raw CSV 或 summary，记录接收数、推断丢失、平均延迟、P95、最大延迟、jitter 和接收率。

## Phase 6：隔离弱网拓扑

`setup_weaknet_netns.sh` 创建两个 network namespace 和 veth：publisher 在 `weaknet_pub_ns`，subscriber 在 `weaknet_sub_ns`，地址分别为 `10.200.0.1/30` 和 `10.200.0.2/30`。这一步的目的，是让 `tc netem` 只影响实验链路，而不破坏 WSL2 管理流量。

概念关系是：

```text
namespace → veth pair → qdisc → netem → DDS UDP packet
```

完成标准：`setup_weaknet_netns.sh up` 能 ping 通对端，`status` 能看到两个接口；未加故障时 qdisc 是 `noqueue`，而不是 `netem`。

## Phase 7：delay

只改变一个变量：注入 delay；QoS、depth、频率、消息大小、运行时长不变。推荐逐步测试 20、50、100、200、500 ms。

预期现象：平均延迟和 P95 近似随配置线性增加；纯 delay 通常不会产生 sequence gap，但会直接降低消息新鲜度。

完成标准：每个 delay 点有独立记录，能把“配置的 qdisc delay”和“消息实际测得的端到端 latency”放在同一张表中。

## Phase 8：packet loss

只改变 loss，例如 1%、5%、10%、20%。注意 `tc -s qdisc` 中的 dropped 是网络包统计；subscriber 的 inferred loss 是消息 sequence gap，二者统计对象不同。

完成标准：能解释为什么 Reliable 下 loss 可能先表现为延迟尾部和 jitter 增大，而不是立即变成同等数量的应用消息丢失。

## Phase 9：Reliable 与 Best Effort

在相同网络条件、频率、depth 和消息内容下切换 Reliability。重点不是给 QoS 下“好/坏”的结论，而是观察：Reliable 可能通过重传提高最终到达率，却引入等待和长尾；Best Effort 可能丢得更多，但已到达消息通常更接近当前时刻。

完成标准：至少有正常网络、100 ms delay、10% loss、100 ms + 10% loss 的对照记录，且报告 received、inferred lost、P95、max 和 jitter。

## Phase 10：history/depth

使用相同的中断与恢复条件比较 `KEEP_LAST(1)`、`KEEP_LAST(5)` 和 `KEEP_LAST(10)`。这里研究的是恢复时缓存/可靠性机制是否交付旧消息，而不只是总体丢失率。

完成标准：能从逐消息日志中指出恢复后是否出现一串延迟逐步下降的旧消息，并解释 depth、消息新鲜度和恢复后的延迟尖峰之间的关系。

## Phase 11：自动记录和审计

自动套件固定场景、生成时间戳 run id，并保留 raw CSV、subscriber/publisher 日志、`tc -s` 日志和 analysis。`audit_phase11.py` 检查文件完整性、raw 行数与 received 一致性、summary 数量和乱序。

完成标准：manifest 中有效实验全部通过审计，结束时 qdisc 没有残留 netem；绘图脚本只读取 manifest 中标记为 `valid` 的实验。

## Phase 12：真实机器人扩展

计划将实验链路接到真实机器人的 `/cmd_vel` 或其他控制 topic。必须先增加安全设计：硬件急停、速度限制、命令超时自动停止、断网时的 fail-safe、明确的仿真/实机开关。

完成标准不应只是“车动起来”，还应能解释延迟、loss、QoS 和 depth 对控制体验和安全性的影响。当前仓库尚未授权或实现真实机器人控制。
