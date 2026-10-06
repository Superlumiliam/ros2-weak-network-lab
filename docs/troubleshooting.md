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

## 10. Phase 12：WSL2 与真实机器人跨主机 DDS 不通

本节记录一次真实机器人接入时的完整排障过程。命令中的尖括号是部署者必须替换的参数：

```text
<ROBOT_IP>                 机器人在局域网中的地址
<WSL_LAN_IP>               mirrored 模式下 WSL 的局域网地址
<ROS_DOMAIN_ID>            两端统一使用的 ROS domain
<DISCOVERY_SERVER_PORT>    Fast DDS Discovery Server TCP 端口，例如 42100
<DDS_DATA_PORT>            WSL 可选的固定 TCP 数据监听端口；默认每个参与者自动分配
<WSL_HYPERV_VMCREATOR_ID>  WSL 对应的 Hyper-V VM creator ID
<ROS_DISTRO>               ROS 发行版，例如 humble
<ROBOT_DRIVER_PACKAGE>     机器人底盘 driver package
<ROBOT_DRIVER_EXECUTABLE>  机器人底盘 driver executable
```

不要把本节中的示例 IP 直接复制到自己的网络；只替换参数，不要改变排查层次。

### 10.1 典型现象

常见症状是：

- WSL2 可以 `ping` 机器人；
- 机器人本机可以看到自己的 ROS 2 节点；
- WSL2 看不到 `/cmd_vel`，或者只能看到 `/parameter_events` 和 `/rosout`；
- 设置 `ROS_DISCOVERY_SERVER` 后，`ros2 node list` 偶尔能看到参与者，但 topic endpoint 不完整；
- Jetson 上 `ss -tanp` 显示连接 WSL 地址的 DDS 数据连接长期处于 `SYN-SENT`。

这里要区分三个层次：

```text
ICMP ping 成功
    ≠ DDS discovery 成功
    ≠ DDS endpoint/data channel 成功
```

### 10.2 先统一 ROS 2 运行环境

在机器人底盘 driver 启动前，确认两端使用相同的 domain、RMW 和 localhost 设置：

```bash
source /opt/ros/<ROS_DISTRO>/setup.bash

export ROS_DOMAIN_ID=<ROS_DOMAIN_ID>
export RMW_IMPLEMENTATION=rmw_fastrtps_cpp
export ROS_LOCALHOST_ONLY=0
```

机器人底盘 driver 进程也必须继承这些变量，而不是只在查询命令所在的 shell 中设置。可以检查实际进程：

```bash
tr '\0' '\n' < /proc/<DRIVER_PID>/environ | \
  grep -E '^(ROS_DOMAIN_ID|RMW_IMPLEMENTATION|ROS_LOCALHOST_ONLY|ROS_DISCOVERY_SERVER|FASTDDS_BUILTIN_TRANSPORTS)='
```

曾经出现过的根因是：机器人底盘 driver 使用默认 domain 0，而 WSL2 查询 shell 使用 domain 61。两端都能运行，但它们不在同一个 ROS 2 graph 中。

### 10.3 判断 UDP discovery 是否被 WSL2 NAT 破坏

先在机器人上检查普通 DDS 端口和网络接口：

```bash
ip -br addr
ip route
ss -uapn | grep -E ':7400|:741[0-9]' || true
```

在 WSL2 中检查到机器人的路由：

```bash
ip route get <ROBOT_IP>
ping -c 3 <ROBOT_IP>
```

如果 WSL2 使用传统 NAT，通常会看到一个 `172.*` 的 WSL 地址；机器人可能能接收 WSL2 发出的连接，但 DDS 端点数据需要机器人反向连接 WSL2 公布的临时端口，NAT 不一定能正确转发。

不要仅凭 `ping` 判断 DDS 正常。对 DDS 来说，必须同时验证 discovery 和 endpoint/data channel。

### 10.4 使用 TCP Discovery Server，避免依赖跨网段 UDP discovery

在机器人上启动 Fast DDS TCP Discovery Server：

```bash
source /opt/ros/<ROS_DISTRO>/setup.bash

nohup fastdds discovery \
  -i 0 \
  -t <ROBOT_IP> \
  -q <DISCOVERY_SERVER_PORT> \
  >/tmp/weaknet-fastdds-tcp.log 2>&1 &

sleep 2
cat /tmp/weaknet-fastdds-tcp.log
ss -lntp | grep ":<DISCOVERY_SERVER_PORT>"
```

日志应包含 TCP server address，`ss` 应显示端口处于 `LISTEN`。

机器人底盘 driver 使用相同的 server：

```bash
source /opt/ros/<ROS_DISTRO>/setup.bash
source <ROBOT_WORKSPACE>/install/setup.bash

export ROS_DOMAIN_ID=<ROS_DOMAIN_ID>
export RMW_IMPLEMENTATION=rmw_fastrtps_cpp
export ROS_LOCALHOST_ONLY=0
export ROS_DISCOVERY_SERVER="TCPv4:[<ROBOT_IP>]:<DISCOVERY_SERVER_PORT>"
export FASTDDS_BUILTIN_TRANSPORTS=LARGE_DATA

ros2 run <ROBOT_DRIVER_PACKAGE> <ROBOT_DRIVER_EXECUTABLE>
```

本仓库提供了 Jetson 本地 setup 脚本。一次性从 WSL2 复制过去：

```bash
scp scripts/setup_phase12_jetson_local.sh \
  <ROBOT_SSH_USER>@<ROBOT_IP>:~/weaknet_phase12_setup.sh
```

SSH 进入 Jetson 后直接执行脚本。脚本会加载 Jetson 用户的厂商环境（或 `WEAKNET_ROBOT_ENV_FILE` 指定的环境文件），再设置 ROS/Fast DDS 变量。`up` 只启动或接管底盘 driver `Mcnamu_driver_M1`，不会启动厂商的手柄 bringup；如果检测到同名 driver 已经使用了不同的环境，脚本会报错并拒绝启动第二个 driver。这样可以避免重复 `/driver_node`。`down` 会停止脚本记录的 driver 和 Discovery Server。整个流程不会发布控制消息：

```bash
ssh <ROBOT_SSH_USER>@<ROBOT_IP>
chmod +x ~/weaknet_phase12_setup.sh
source ~/weaknet_phase12_setup.sh up
source ~/weaknet_phase12_setup.sh check
```

脚本支持 `source` 的原因是需要把 ROS/Fast DDS 变量留在当前终端；脚本不会在这种调用方式下启用 `errexit`/`pipefail`，因此 `check` 阶段的 `Unknown topic` 或网络诊断非零不会关闭 SSH。`check` 会为 CLI 使用单独的 `SUPER_CLIENT` profile，并停止旧 ROS daemon；否则 Discovery Server 的普通 `CLIENT` 只会收到与本地 endpoint 相关的发现信息，`ros2 topic list` 可能看不到远端 topic。更新 Jetson 脚本或 profile 后，先执行 `source ~/weaknet_phase12_setup.sh down`，再执行 `source ~/weaknet_phase12_setup.sh up`，确保已有 driver 不会继续使用旧的 DDS profile。

如果 WSL 的 `ros2 topic list` 或 `ros2 node list` 报 `xmlrpc.client.Fault: ... !rclpy.ok()`，这是 ROS 2 CLI daemon 的失效状态，不是 `/cmd_vel` 的消息错误。重新执行 WSL setup 的 `up` 或 `check` 会停止当前 domain 的旧 daemon；也可以手动执行：

```bash
ros2 daemon stop || true
source scripts/setup_phase12_wsl.sh up
ros2 topic list
```

如果机器人已经有同名 driver 进程，先检查它的 `/proc/<PID>/environ`；不要在环境不一致时强行再启动一个。仅修改当前 shell 不会改变已经运行的进程环境。Jetson 脚本只在 Jetson 本机执行，不依赖 WSL 的仓库路径。

Fast DDS 的 TCP Discovery Server 需要 TCP locator；`ROS_DISCOVERY_SERVER` 的 TCP 格式是 `TCPv4:[地址]:端口`。官方文档还要求 TCP Discovery Server 的参与者使用 TCP user transport，不能只把它当成普通 UDP discovery 使用：

- [Fast DDS TCP Communication with Discovery Server](https://fast-dds.docs.eprosima.com/en/v2.6.12/fastdds/use_cases/tcp/tcp_with_discovery_server.html)
- [Fast DDS environment variables](https://fast-dds.docs.eprosima.com/en/2.6.x/fastdds/env_vars/env_vars.html)

### 10.5 在 Windows 11 上启用 WSL2 mirrored networking

在 Windows 用户目录 `%USERPROFILE%\\.wslconfig` 中加入：

```ini
[wsl2]
networkingMode=mirrored
firewall=true
```

然后从 PowerShell 或 WSL 执行：

```bash
wsl.exe --shutdown
```

重新进入 WSL 后确认：

```bash
ip -br addr
ip route get <ROBOT_IP>
```

预期是 WSL 出现一个可从局域网访问的接口，并且到机器人的路由使用该接口。不要假设接口名一定是 `eth0`；mirrored 模式下可能出现 `eth1`、`eth2` 等接口。

Microsoft 文档说明 mirrored networking 的目标包括让 WSL 直接接入 LAN；同时，Hyper-V firewall 仍可能过滤进入 WSL 的连接：

- [Microsoft WSL networking](https://learn.microsoft.com/windows/wsl/networking)
- [Microsoft WSL configuration](https://learn.microsoft.com/windows/wsl/wsl-config)

### 10.6 让防火墙覆盖每个 DDS 参与者的数据端口

WSL 和 Jetson 的 TCP listener 均使用 port `0`，每个参与者分配独立端口。
控制 publisher、CLI daemon、echo 可以并发运行；普通 `ros2` 命令无须专用 launcher。

常见故障是防火墙只放行旧的固定端口，而 Fast DDS 参与者使用各自的动态 TCP 端口，导致 Jetson 到 WSL 的数据连接停留在 `SYN-SENT`。只为一个控制 publisher 配固定端口也无法覆盖并发运行的 CLI daemon、echo 和其他 ROS 节点。

迁移旧配置，在实际 WSL 终端执行（不要从隔离网络的沙箱读取动态端口范围）：

```bash
unset WEAKNET_DDS_DATA_PORT WEAKNET_CONTROL_DATA_PORT WEAKNET_CONTROL_PROFILE_PATH
export WEAKNET_ROBOT_IP=<ROBOT_IP>
source scripts/setup_phase12_wsl.sh up
source scripts/setup_phase12_wsl.sh firewall
```

`firewall` 读取 `/proc/sys/net/ipv4/ip_local_port_range`，打印 Windows 管理员 PowerShell 命令。
复制执行它即可调用仓库的 `setup_phase12_windows.ps1`。该脚本：

- 验证管理员权限及 WSL VM creator ID；
- 创建或原地更新 `ROS2-WeakNet-DDS-Dynamic`，不先删除旧规则；
- 仅允许机器人 IP 访问 WSL 实际动态 TCP 端口范围，不修改默认入站策略；
- 输出 ActiveStore 规则及策略供核查；支持 `-WhatIf`、`-Action Check` 和 `-Action Down`。

该范围也可能包含其他服务的监听端口，因此只适用于可信机器人。
WSL 重启、机器人 IP 或动态范围改变后，重新执行该流程；配置脚本不会修改 Linux 全局端口范围。
只打印命令不等于规则已经生效，必须在 Windows 执行成功，并用 Jetson `verify` 验证消息。

WSL mirrored networking 可能同时有 LAN、内部和 VPN 地址。setup 从到机器人路由提取源地址，
写入 TCP interface whitelist，避免广播不可达地址。
参考 [Fast DDS Interface Whitelist](https://fast-dds.docs.eprosima.com/en/2.14.x/fastdds/transport/whitelist.html)
和 [Microsoft Hyper-V firewall](https://learn.microsoft.com/en-us/windows/security/operating-system-security/network-security/windows-firewall/hyper-v-firewall)。

### 10.7 分层验证修复是否成功

先检查 WSL 是否监听数据端口：

```bash
ss -lntp | grep ":<DDS_DATA_PORT>"
```

再让 WSL 查询 ROS graph，但使用较长等待时间并避免旧 daemon：

```bash
ros2 node list --no-daemon --spin-time 10
ros2 topic list --no-daemon --spin-time 10 -t
```

在机器人端观察连接状态：

```bash
ss -tanp | grep -E ":<DISCOVERY_SERVER_PORT>|:<DDS_DATA_PORT>|<WSL_LAN_IP>"
```

成功时，至少应看到：

```text
<ROBOT_IP>:<DISCOVERY_SERVER_PORT>  <WSL_LAN_IP>:<ephemeral-port>  ESTAB
<ROBOT_IP>:<some-port>              <WSL_LAN_IP>:<DDS_DATA_PORT>   ESTAB
```

如果机器人向 `<WSL_LAN_IP>:<DDS_DATA_PORT>` 长时间显示 `SYN-SENT`，优先检查：

1. WSL 是否真的监听 `<DDS_DATA_PORT>`；
2. Hyper-V firewall 规则是否启用且 `EnforcementStatus` 为 `OK`；
3. `RemoteAddresses` 是否是机器人的真实地址；
4. XML 中的 listener port 是否与规则一致；
5. 机器人和 WSL 是否使用同一个 `ROS_DOMAIN_ID`。

最后用真实数据而不是只看 CLI 图查询验证：

```bash
# 在一端运行官方 talker，另一端运行官方 listener
timeout 30 ros2 run demo_nodes_cpp talker
timeout 15 ros2 run demo_nodes_cpp listener
```

对于真实机器人，只读订阅已知类型的控制 topic，不要在排障时随意发布控制命令：

```bash
timeout 15 ros2 topic echo /cmd_vel geometry_msgs/msg/Twist \
  --qos-reliability reliable \
  --qos-durability volatile
```

若遥控器没有输入，`/cmd_vel` 没有消息并不一定表示网络故障；可以先验证 `/joy` 或使用官方 talker/listener 验证通路。严禁用未经确认的 `ros2 topic pub /cmd_vel ...` 作为网络测试。

### 10.8 清理和恢复

停止机器人底盘 driver 和 Discovery Server 后，删除 Windows Hyper-V 规则：

```powershell
Remove-NetFirewallHyperVRule -Name "ROS2-WeakNet-DDS-Dynamic"
```

如果不再需要 mirrored networking，从 `%USERPROFILE%\\.wslconfig` 删除对应配置，然后执行：

```bash
wsl.exe --shutdown
```

保留本次排障中的以下证据，便于复现和比较：

```text
ip -br addr
ip route get <ROBOT_IP>
ss -lntp
ss -tanp
ROS_DOMAIN_ID / RMW / ROS_DISCOVERY_SERVER / FASTDDS_BUILTIN_TRANSPORTS
机器人底盘 driver 进程的 /proc/<PID>/environ
官方 talker/listener 的实际收发日志
```


### 10.9 本项目 Phase 12 配置与验证边界

本项目的 Phase 12 流程基于 **NVIDIA Jetson Orin Nano**，并在该设备上验证过 WSL/Jetson 的 ROS graph 查询、双向 DDS 数据收发，以及默认全零的 `/cmd_vel` 消息接收。配置包含 ROS domain 61、`rmw_fastrtps_cpp`、TCP Discovery Server（默认端口 42100）和每个参与者独立分配的动态 TCP 数据端口。部署时仍应以本机脚本参数和实际环境为准。

**流程仅作参考**：其他 Jetson 型号、JetPack/ROS 版本、厂商 workspace、网络与防火墙策略可能不同。脚本可启动底盘 driver，也提供能够发布非零速度的控制节点；默认全零不构成安全保护。现有验证没有覆盖真实车轮运动、硬件急停、限速或断网停车。不要在完成现场安全评估前发布非零速度。`matched_subscribers=1` 仅表示 endpoint 匹配，验证实际数据请在 Jetson 运行：

```bash
source ~/weaknet_phase12_setup.sh verify
```

`verify` 只接收 `/cmd_vel` 消息，不会发布控制命令。排障时也应优先使用只读 echo 或官方 talker/listener，不要用未经确认的控制消息作为网络测试。
