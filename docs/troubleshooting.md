# 分层排错指南

ROS 2 通信问题不要一上来重装 ROS 或重建 WSL。先判断问题发生在哪一层：环境、节点、topic、QoS、DDS discovery、namespace/veth，还是 qdisc。

## 1. 环境和 overlay

```bash
printenv ROS_DISTRO
printenv ROS_LOCALHOST_ONLY
printenv ROS_DOMAIN_ID
printenv RMW_IMPLEMENTATION
which ros2
ros2 pkg prefix weaknet_demo
```

如果 `which ros2` 不是 `/opt/ros/.../bin/ros2`，先检查系统 ROS setup；如果 package prefix 不是 workspace 的 `install/weaknet_demo`，再 source workspace overlay：

```bash
source /opt/ros/humble/setup.bash
source ~/ros2exp_ws/install/setup.bash
```

注意：当前 shell 的 source 不会自动影响已经启动的另一个终端或 namespace 内的进程。

## 2. 节点层

```bash
ros2 node list
ros2 node info /weaknet_pub
ros2 node info /weaknet_sub
```

如果节点不存在，先检查启动命令、namespace、可执行文件和 package 安装：

```bash
ros2 pkg executables weaknet_demo
colcon build --packages-select weaknet_demo
source ~/ros2exp_ws/install/setup.bash
```

## 3. topic 和消息类型

```bash
ros2 topic list
ros2 topic type /weaknet/sample
ros2 topic info /weaknet/sample
ros2 topic info /weaknet/sample --verbose
ros2 interface show weaknet_demo/msg/WeaknetSample
```

确认 publisher 和 subscriber 使用相同 topic 名称和消息类型。`--verbose` 可以直接看到 endpoint QoS，是排查 QoS 不匹配的关键证据。

## 4. QoS 层

当前节点通过参数设置 `reliable|best_effort` 和 depth。双方必须有兼容的 QoS；如果切换一端而没有切换另一端，可能出现节点都存在但没有数据的情况。

```bash
ros2 topic info /weaknet/sample --verbose
```

先用双方都为 `reliable 10` 的组合建立 baseline，再一次只改一端或一项参数。不要在网络故障、QoS 不匹配和旧进程残留同时存在时下结论。

## 5. Domain、RMW 和 discovery

```bash
printenv ROS_DOMAIN_ID
printenv RMW_IMPLEMENTATION
printenv FASTDDS_BUILTIN_TRANSPORTS
ss -uapn | grep -E ':7400|:741[0-9]'
```

两个 namespace 中的节点必须使用相同 `ROS_DOMAIN_ID` 和兼容 RMW。项目脚本显式设置 `ROS_LOCALHOST_ONLY=0`、`ROS_DOMAIN_ID=0`、`rmw_fastrtps_cpp` 和 UDPv4。若手动启动节点，先保持这些变量一致。

## 6. namespace/veth 层

```bash
ip netns list
~/ros2exp_ws/scripts/setup_weaknet_netns.sh status
sudo ip netns exec weaknet_pub_ns ip addr
sudo ip netns exec weaknet_sub_ns ip addr
sudo ip netns exec weaknet_pub_ns ping -c 2 10.200.0.2
```

如果 `ip netns list` 为空，说明 WSL2/Windows 重启后 namespace 已消失，需要重新执行：

```bash
~/ros2exp_ws/scripts/setup_weaknet_netns.sh up
```

如果只存在一半 veth，脚本会拒绝猜测修复方式；停止节点后使用 `down` 再 `up`。

## 7. qdisc/netem 层

```bash
sudo ip netns exec weaknet_pub_ns tc qdisc show dev wnpub0
sudo ip netns exec weaknet_pub_ns tc -s qdisc show dev wnpub0
```

正常状态是 `qdisc noqueue`。弱网状态应明确显示 `qdisc netem` 及其 delay/loss 参数。实验结束后清除：

```bash
sudo ip netns exec weaknet_pub_ns tc qdisc del dev wnpub0 root
```

不要把 `tc qdisc add dev eth0 ...` 直接用于这个 WSL2 实验：它可能影响 apt、SSH、ROS discovery 以及 WSL2 的全部网络。隔离拓扑的目的就是把影响范围缩小到实验链路。

## 8. 解释“延迟很高但没有丢包”

这通常不是测量代码马上出错。Reliable 可能等待重传或排空队列，因此 sequence 仍然连续，但消息已经过期；Best Effort 则可能直接跳过丢失消息，已收到消息的延迟较低。检查 raw CSV 中的 sequence、latency 尾部和 `tc -s`，不要只看平均值。

如果出现负延迟或数秒级异常值，先检查发送和接收是否使用同一种 steady clock、节点是否来自同一套新编译的 overlay，以及是否混入了旧进程。跨 namespace 的系统时间字段不适合直接替代 steady-clock duration。

## 9. 自动套件卡住或没有自动退出

套件必须向 namespace 内真正的 `weaknet_pub`/`weaknet_sub` 进程发送信号，而不是只终止外层 `sudo ip netns exec` 包装进程。当前 `run_phase11_suite.sh` 已使用 namespace 内 `pkill`，并在停止后检查 summary、CSV 和 qdisc。

遇到问题时保留：

```text
exp/raw/phase11/logs/*.log
exp/raw/phase11/analysis/*.txt
exp/raw/phase11/manifest.csv
```

再运行 `audit_phase11.py`。不要先删除异常文件；异常应记录并在结果文档中说明。
