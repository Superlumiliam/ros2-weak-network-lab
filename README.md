# ROS 2 弱网通信实验平台

这是一个面向 ROS 2/DDS 网络通信研究的可复现实验仓库。项目从最小的 C++ publisher/subscriber 开始，逐步引入 Linux network namespace、veth 和 `tc netem`，研究延迟、丢包、QoS 可靠性、history depth 与消息新鲜度之间的关系。

项目的核心问题不是“消息有没有最终到达”这么简单，而是：

> 在弱网环境下，一条已经过期的消息，即使可靠地到达了，是否仍然对机器人有用？

Phase 0–11 已形成逐消息 CSV、自动化实验、结果审计和基础可视化。Phase 12 提供面向 NVIDIA Jetson Orin Nano 的跨主机 DDS 配置与 `/cmd_vel` 验证脚本；当前实现和命令流程仅作参考，具体网络、驱动和安全条件需按实际设备确认。

## 实验拓扑

默认实验不依赖真实机器人，也不需要改变 WSL2 主机的默认网络。两个 ROS 2 节点分别运行在两个 network namespace 中，中间通过一对 veth 连接：

```text
weaknet_pub_ns                                      weaknet_sub_ns
┌─────────────────┐   wnpub0       wnsub0   ┌─────────────────┐
│ weaknet_pub     │── 10.200.0.1/30 ───────│ weaknet_sub     │
│ ROS 2 / DDS     │                         │ ROS 2 / DDS     │
└─────────────────┘                         └─────────────────┘
       ▲
       │ tc netem 注入点：只影响 publisher namespace 的 wnpub0 出口
       └── delay / loss / outage
```

ROS 2 应用通过 `rclcpp` 使用 RMW；RMW 再使用 DDS 实现完成发现和数据传输。本机当前验证环境是 ROS 2 Humble、`rmw_fastrtps_cpp`、Fast DDS。实验脚本显式使用 UDPv4，并把两个节点放入隔离的 namespace，避免把 netem 误施加到 WSL2 的真实出口接口。

## Phase 路线图

| 阶段 | 目标 | 结果 |
| --- | --- | --- |
| Phase 0 | 检查 Ubuntu、ROS 2、RMW、DDS 和 WSL2 网络 | 已完成 |
| Phase 1 | 运行官方 talker/listener，使用 ROS 2 CLI 观察系统 | 已完成 |
| Phase 2 | 创建 workspace 和 `weaknet_demo` C++ package | 已完成 |
| Phase 3 | 编写 20 Hz 自定义消息 publisher | 已完成 |
| Phase 4 | 编写 subscriber，计算延迟、丢失和 jitter | 已完成 |
| Phase 5 | 建立正常网络 baseline | 已完成 |
| Phase 6 | 使用 namespace/veth/netem 构造可恢复弱网拓扑 | 已完成 |
| Phase 7 | 单独研究 delay | 已完成 |
| Phase 8 | 单独研究 packet loss | 已完成 |
| Phase 9 | 比较 Reliable 与 Best Effort | 已完成 |
| Phase 10 | 比较 KEEP_LAST depth 和中断恢复后的旧消息排空 | 已完成 |
| Phase 11 | 自动化采集 raw CSV、审计和绘图 | 已完成 |
| Phase 12 | 配置真实机器人跨主机 DDS 环境并接入 `/cmd_vel` | 环境脚本已完成，控制实验待执行 |

每个 Phase 的教学目标和验收标准见 [docs/phase_guide.md](docs/phase_guide.md)。

## 环境要求

已验证环境：

- Windows 11 + WSL2
- Ubuntu 22.04.5 LTS
- ROS 2 Humble
- C++ package：`rclcpp` + `ament_cmake`
- RMW：`rmw_fastrtps_cpp` / Fast DDS
- Linux tools：`iproute2`（`ip`、`tc`）、`sudo`、`ping`、`python3`
- 绘图可选：`numpy`、`matplotlib`

其他 ROS 2 发行版理论上可能可用，但尚未作为本项目的复现基线。开始实验前先执行：

```bash
lsb_release -a
printenv ROS_DISTRO
which ros2
printenv RMW_IMPLEMENTATION
ip addr
ip route
```

如果当前 shell 没有 ROS 环境，先加载系统 ROS 2：

```bash
source /opt/ros/humble/setup.bash
```

`source` 只修改当前 shell 的环境变量；它不会安装 ROS，也不会修改源码。编译本仓库后还需要加载 workspace overlay：

```bash
source ~/ros2exp_ws/install/setup.bash
```

## 快速开始

以下是从干净 clone 到最小实验的主路径。每条命令的背景、成功标准和排错方法见 [docs/phase_guide.md](docs/phase_guide.md)。

### 1. 编译 package

```bash
cd ~/ros2exp_ws
source /opt/ros/humble/setup.bash
colcon build --packages-select weaknet_demo
source install/setup.bash
```

### 2. 创建隔离网络拓扑

```bash
~/ros2exp_ws/scripts/setup_weaknet_netns.sh up
~/ros2exp_ws/scripts/setup_weaknet_netns.sh status
```

`up` 会创建两个 namespace 和 veth，验证 `10.200.0.1` 到 `10.200.0.2` 的连通性，但不会自动添加 delay/loss。`status` 用于确认接口和地址。

### 3. 启动 subscriber 和 publisher

建议打开两个终端。先在终端 A 启动 subscriber：

```bash
~/ros2exp_ws/scripts/run_weaknet_sub_ns.sh reliable 10
```

再在终端 B 启动 publisher：

```bash
~/ros2exp_ws/scripts/run_weaknet_pub_ns.sh reliable 10
```

两个脚本分别启动节点，故意没有合并成一个脚本，便于观察节点生命周期和单独替换 QoS。可选参数是 `reliable|best_effort` 和正整数 depth。按 `Ctrl-C` 停止节点。

### 4. 配置 Phase 12 跨主机环境

Phase 12 需要 WSL2 与机器人处于可双向访问的网络中。推荐先按 [docs/troubleshooting.md](docs/troubleshooting.md) 配置 WSL2 mirrored networking 和 Hyper-V firewall，然后在 WSL2 中执行：

```bash
export WEAKNET_ROBOT_IP=<ROBOT_IP>
export WEAKNET_ROBOT_USER=<ROBOT_SSH_USER>
export WEAKNET_ROS_DOMAIN_ID=<ROS_DOMAIN_ID>
# 可选；默认由到机器人的路由自动检测
export WEAKNET_WSL_LAN_IP=<WSL_LAN_IP>

# source 会修改当前终端环境，不能改成直接执行 bash 脚本
source ~/ros2exp_ws/scripts/setup_phase12_wsl.sh up

# 首次配置：打印 Windows 管理员 PowerShell 命令，在 Windows 执行该命令
source ~/ros2exp_ws/scripts/setup_phase12_wsl.sh firewall

# 一次性把 Jetson 本地 setup 脚本复制过去
scp ~/ros2exp_ws/scripts/setup_phase12_jetson_local.sh \
  <ROBOT_SSH_USER>@<ROBOT_IP>:~/weaknet_phase12_setup.sh

# SSH 进入 Jetson；之后重启只需在 Jetson 本机执行这一条
ssh <ROBOT_SSH_USER>@<ROBOT_IP>
chmod +x ~/weaknet_phase12_setup.sh
source ~/weaknet_phase12_setup.sh up
```

常用检查和停止命令：

```bash
source ~/ros2exp_ws/scripts/setup_phase12_wsl.sh check
# 以下命令在 Jetson SSH 终端执行
source ~/weaknet_phase12_setup.sh check
source ~/weaknet_phase12_setup.sh down
```

Jetson 脚本在 Jetson 本机运行，不保存 SSH 密码，也不会向 `/cmd_vel` 发布消息；WSL 脚本只配置 WSL 当前 shell。Jetson setup 只启动或接管 `Mcnamu_driver_M1` 底盘 driver，不再启动厂商的手柄 launch；`joy_node`/`joy_ctrl` 是可选控制端，实验 publisher 应由本仓库的 C++ 节点提供。脚本会拒绝启动第二个 driver，避免重复 `/driver_node`。机器人 workspace、driver package、driver executable 或厂商环境文件不同时，可以通过 `WEAKNET_ROBOT_WORKSPACE`、`WEAKNET_ROBOT_DRIVER_PACKAGE`、`WEAKNET_ROBOT_DRIVER_EXECUTABLE` 和 `WEAKNET_ROBOT_ENV_FILE` 覆盖默认值。WSL `up/check` 会清理当前 domain 的失效 ROS CLI daemon，并让交互式 `ros2` 默认使用 `SUPER_CLIENT` profile；Jetson driver 仍使用普通 `CLIENT` profile。

环境确认后，在 WSL 中先用零速度启动自己的控制 publisher，验证它是否匹配到 Jetson 的 `/driver_node`：

```bash
source ~/ros2exp_ws/install/setup.bash
ros2 run weaknet_demo weaknet_cmdvel_pub \
  --ros-args -p rate_hz:=20.0 -p linear_x:=0.0 -p linear_y:=0.0 -p angular_z:=0.0
```

所有 ROS 参与者使用独立动态 TCP 端口。Windows setup 仅允许机器人 IP 访问 WSL 当前动态端口范围；普通 `ros2 run/topic pub/echo/list` 使用同一环境，无需专用固定端口 launcher。旧版 `46000` 配置应先清理：`unset WEAKNET_DDS_DATA_PORT WEAKNET_CONTROL_DATA_PORT WEAKNET_CONTROL_PROFILE_PATH`。WSL 重启后动态范围可能改变，需重新检查 `firewall` 输出并更新规则。

保持零速度发布时，在 Jetson 执行 `source ~/weaknet_phase12_setup.sh verify`，只有收到实际 `Twist` 才验收通过。分层排障、配置恢复和已知限制见 [Phase 12 排障说明](docs/troubleshooting.md#10-phase-12wsl2-与真实机器人跨主机-dds-不通)。

日志出现 `matched_subscribers=1` 只表示 DDS endpoint 已匹配，不代表机器人会运动；本节点的默认速度也是全零。实验中不要同时启动厂商 `joy_ctrl` 和本节点，否则两个 publisher 会同时向 `/cmd_vel` 写入控制命令。

### 5. 保存一次逐消息实验记录

subscriber 的第三个参数是 CSV 路径：

```bash
~/ros2exp_ws/scripts/run_weaknet_sub_ns.sh \
  reliable 10 ~/ros2exp_ws/exp/raw/manual_baseline.csv
```

另一个终端启动 publisher 后，停止 subscriber，再分析：

```bash
python3 ~/ros2exp_ws/scripts/analyze_weaknet_csv.py \
  ~/ros2exp_ws/exp/raw/manual_baseline.csv
```

### 6. 清理网络拓扑

实验结束后：

```bash
~/ros2exp_ws/scripts/setup_weaknet_netns.sh down
```

如果只想清除 netem 而保留 namespace，可执行：

```bash
sudo ip netns exec weaknet_pub_ns tc qdisc del dev wnpub0 root
```

清除后应看到 `qdisc noqueue`，而不是 `qdisc netem`。不要把 `tc` 直接施加到 WSL2 的 `eth0`，除非你明确希望影响整个 WSL2 实例的网络。

## Phase 11 自动复现

Phase 11 套件会运行 18 轮固定条件实验，生成每条收到消息的 raw CSV、节点日志、`tc -s` 统计、分析结果和 manifest。它会为每次套件运行加时间戳，不覆盖旧数据，并在每轮和最终阶段检查 netem 是否清除。

套件启动时会通过一次 `sudo -v` 请求权限，并检查 namespace 已存在；如果 Windows/WSL2 刚重启，先重新执行上面的 `setup_weaknet_netns.sh up`。

```bash
cd ~/ros2exp_ws
source /opt/ros/humble/setup.bash
source install/setup.bash
~/ros2exp_ws/scripts/setup_weaknet_netns.sh up
~/ros2exp_ws/scripts/run_phase11_suite.sh
```

套件结束后审计产物：

```bash
python3 scripts/audit_phase11.py \
  exp/raw/phase11/manifest.csv
```

生成汇总表和图表：

```bash
python3 scripts/plot_phase11.py \
  exp/raw/phase11/manifest.csv \
  --output-dir exp/plots
```

最终再次确认没有残留 netem：

```bash
sudo ip netns exec weaknet_pub_ns tc qdisc show dev wnpub0
```

预期是 `qdisc noqueue`。完整的实验变量、指标定义、有效性边界和解释方式见 [docs/experiment_protocol.md](docs/experiment_protocol.md)。当前公开结论见 [docs/experiment_results.md](docs/experiment_results.md)。

## 目录结构

```text
.
├── README.md
├── CONTRIBUTING.md
├── LICENSE
├── docs/
│   ├── agent_workflow.md
│   ├── experiment_protocol.md
│   ├── experiment_results.md
│   ├── phase_guide.md
│   └── troubleshooting.md
├── scripts/
│   ├── setup_phase12_wsl.sh
│   ├── setup_phase12_jetson_local.sh
│   ├── setup_weaknet_netns.sh
│   ├── run_weaknet_pub_ns.sh
│   ├── run_weaknet_sub_ns.sh
│   ├── run_phase11_suite.sh
│   ├── analyze_weaknet_csv.py
│   ├── audit_phase11.py
│   └── plot_phase11.py
├── config/phase12/
│   └── fastdds_tcp_client.xml.in
└── src/weaknet_demo/
    ├── msg/WeaknetSample.msg
    ├── src/weaknet_pub.cpp
    ├── src/weaknet_cmdvel_pub.cpp
    ├── src/weaknet_sub.cpp
    ├── CMakeLists.txt
    └── package.xml
```

`build/`、`install/`、`log/` 是 colcon 生成目录，不应提交。`exp/` 默认保存本机 raw CSV、日志和图表；其中只有经过审计的 `exp/raw/phase11/` 和 `exp/plots/` 参考结果被显式纳入版本控制，其余本地实验仍被 `.gitignore` 忽略。这样既提供了可下载的参考数据，又避免把所有机器相关的实验产物混入仓库。稳定的阶段结论放在 `docs/experiment_results.md`。

已提交的参考数据说明见 [exp/raw/phase11/README.md](exp/raw/phase11/README.md)。clone 后可以直接用仓库内的相对路径 manifest 运行审计和绘图。

## Agent 协作方式

这个仓库按“实验导师 + 工程助手”的方式设计。推荐让 Agent 每次只推进一个可验证的小目标：先说明实验目的、控制变量和成功标准，再给出当前一步的命令；用户执行并贴出完整输出；Agent 根据事实排错后再进入下一步。

请先阅读：

- [docs/agent_workflow.md](docs/agent_workflow.md)：如何与 Agent 协作、如何提供输出、如何保留实验上下文；
- [docs/troubleshooting.md](docs/troubleshooting.md)：ROS 2、DDS、namespace、veth 和 tc 的分层排错；
- [CONTRIBUTING.md](CONTRIBUTING.md)：如何添加实验、脚本和文档。

不要把 sudo 密码、私有网络凭据或其他秘密粘贴到 issue、日志或 Agent 对话中。

## 已知限制

- 当前拓扑是 WSL2 内的本地 namespace/veth 实验，不等同于真实 Wi-Fi、交换机或跨主机链路；
- `tc dropped` 统计的是网络包，不是 ROS 2 应用消息；
- sequence gap 是应用层丢失的推断值，不能替代 DDS 内部传输统计；
- 单轮实验不能代表普遍规律，改变 CPU 负载、DDS 版本、消息大小或网络拓扑后应重新建立 baseline；
- Phase 12 面向 NVIDIA Jetson Orin Nano 实现了跨主机配置和 `/cmd_vel` publisher；默认速度为零，但节点可配置非零速度。流程仅作参考，仓库未实现或验证硬件急停、限速、命令超时和断网保护，未经实机安全评估不要发布非零速度。

## 许可证

本项目使用 Apache License 2.0，见 [LICENSE](LICENSE)。
