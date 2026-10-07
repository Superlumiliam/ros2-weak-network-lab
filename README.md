# ROS 2 弱网通信实验平台

这是一个面向 ROS 2/DDS 网络通信研究的可复现实验仓库。项目从最小的 C++ publisher/subscriber 开始，逐步引入 Linux network namespace、veth 和 `tc netem`，研究延迟、丢包、QoS 可靠性、history depth 与消息新鲜度之间的关系。

项目的核心问题不是“消息有没有最终到达”这么简单，而是：

> 在弱网环境下，一条已经过期的消息，即使可靠地到达了，是否仍然对机器人有用？

Phase 0–11 已形成逐消息 CSV、自动化实验、结果审计和基础可视化。Phase 12 收录 Jetson M1 底盘 Driver 源码，提供跨主机 DDS 配置与 `/cmd_vel` 零速通信验证；达成标准为 WSL 与 Jetson 小车正常零速通信。

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
| Phase 12 | WSL–Jetson 小车正常零速通信，收录可编译 Driver 源码 | 两端编译与仓库 Driver 零速通信已通过 |

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

以下是从干净 clone 到本机弱网实验的主路径；Phase 12 是可选的真实机器人扩展，单独列在 Phase 11 自动复现之后。每条命令的背景、成功标准和排错方法见 [docs/phase_guide.md](docs/phase_guide.md)。

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

### 4. 保存一次逐消息实验记录

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

### 5. 清理网络拓扑

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

## Phase 12（可选）：Jetson 底盘接入

本阶段的控制链为 WSL publisher → `/cmd_vel` → Jetson Driver → `Rosmaster_Lib` → 串口底盘。独立 Safety Gateway 已移除，阶段达成标准是正常零速通信。Driver 源码原样收录在 [`src/jetson_base_driver`](src/jetson_base_driver/README.md)，已使用本仓库构建的 Driver 完成零速通信验收，后续改造需求另行确定。

```bash
# WSL：编译通信节点和源码 Driver package
source /opt/ros/humble/setup.bash
colcon build --packages-select weaknet_demo jetson_base_driver --symlink-install
source install/setup.bash

# 复制 Driver 源码和 Jetson setup，在 Jetson 上编译；不会重启当前 Driver
WEAKNET_JETSON_HOST=<JETSON_USER>@<JETSON_IP> scripts/deploy_phase12_jetson.sh

# WSL：加载环境后发送零速度，默认话题为 /cmd_vel
export WEAKNET_ROBOT_IP=<JETSON_IP>
source scripts/setup_phase12_wsl.sh up
scripts/run_phase12_cmdvel_pub.sh \
  --ros-args -p topic:=/cmd_vel -p rate_hz:=10.0 \
  -p linear_x:=0.0 -p linear_y:=0.0 -p angular_z:=0.0
```

Jetson 的编译、仓库 Driver 启动与零速接收验证步骤见 [Phase 12 操作与验收](docs/phase12_jetson.md)。网络、ROS domain、RMW 和 DDS profile 继续由 `scripts/setup_phase12_*.sh` 管理。WSL mirrored networking 与 Windows 防火墙排错见 [troubleshooting.md](docs/troubleshooting.md#10-phase-12wsl2-与真实机器人跨主机-dds-不通)。

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
│   ├── phase12_jetson.md
│   └── troubleshooting.md
├── scripts/
│   ├── setup_phase12_wsl.sh
│   ├── setup_phase12_jetson_local.sh
│   ├── deploy_phase12_jetson.sh
│   ├── setup_weaknet_netns.sh
│   ├── run_weaknet_pub_ns.sh
│   ├── run_weaknet_sub_ns.sh
│   ├── run_phase11_suite.sh
│   ├── analyze_weaknet_csv.py
│   ├── audit_phase11.py
│   └── plot_phase11.py
├── config/phase12/
│   └── fastdds_tcp_client.xml.in
├── src/jetson_base_driver/
│   ├── jetson_base_driver/Mcnamu_driver_M1.py
│   ├── SOURCE.md
│   ├── setup.py
│   ├── setup.cfg
│   └── package.xml
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
- Phase 12 仅验收零速通信；当前导入 Driver 未实现 ROS 命令超时保护，回调未应用已声明的速度限幅参数。

## 许可证

本项目原创代码使用 Apache License 2.0，见 [LICENSE](LICENSE)。导入的厂商 Driver 来源与许可证状态见 [SOURCE.md](src/jetson_base_driver/SOURCE.md)。
