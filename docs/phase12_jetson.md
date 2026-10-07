# Phase 12：Jetson 底盘接入

Phase 12 的达成标准是 **WSL 与 Jetson 小车正常进行零速通信**。本轮建立可追踪、可编译、可修改的 Jetson Driver 源码基线；独立 Safety Gateway 已从仓库移除。限幅、命令超时、arm/disarm 和非零运动均不作为本阶段要求。

## 结构与职责

```text
WSL weaknet_cmdvel_pub（六个分量为零）
    → /cmd_vel → Jetson /driver_node
    → Rosmaster_Lib → 串口 → 底盘

src/jetson_base_driver/       Driver 源码、ROS package 元数据、executable
scripts/setup_phase12_wsl.sh  WSL ROS/DDS 环境
scripts/setup_phase12_jetson_local.sh
                             Jetson ROS/DDS 环境、Discovery Server、Driver 进程
scripts/setup_phase12_windows.ps1
                             Windows/Hyper-V firewall
scripts/deploy_phase12_jetson.sh
                             复制 Driver 源码与 Jetson setup，不启动或重启 Driver
config/phase12/               WSL Fast DDS profile 模板
```

Driver 原样收录于 [Mcnamu_driver_M1.py](../src/jetson_base_driver/jetson_base_driver/Mcnamu_driver_M1.py)，来源、校验值和依赖版本见 [SOURCE.md](../src/jetson_base_driver/SOURCE.md)。新入口是 `ros2 run jetson_base_driver Mcnamu_driver_M1`，节点和话题接口保留。网络配置继续放在 setup 脚本中。

Driver 当前直接把速度交给厂商库，尚未应用已声明的速度限幅参数，也未实现 ROS 命令超时保护。这是源码现状记录，后续改造需求另行确定。

## 从源码复现编译

在 WSL 的仓库根目录：

```bash
source /opt/ros/humble/setup.bash
colcon build --packages-select weaknet_demo jetson_base_driver --symlink-install
source install/setup.bash
ros2 pkg executables jetson_base_driver

# 复制源代码，不能复制 WSL 的 build/install 到 Jetson
WEAKNET_JETSON_HOST=<JETSON_USER>@<JETSON_IP> scripts/deploy_phase12_jetson.sh
```

在 Jetson：

```bash
source /opt/ros/humble/setup.bash
source ~/yahboomcar_ros2_ws/yahboomcar_ws/install/setup.bash
cd ~/ros2exp_ws
colcon build --packages-select jetson_base_driver --symlink-install
source install/setup.bash
ros2 pkg executables jetson_base_driver
python3 -c 'from jetson_base_driver.Mcnamu_driver_M1 import main; print("driver import OK")'
```

应看到 `jetson_base_driver Mcnamu_driver_M1` 和 `driver import OK`。模块导入不会初始化节点或打开串口。运行依赖为 ROS 消息包、厂商 `yahboomcar_msgs`、设备现有 `Rosmaster-Lib`、`pyserial` 和串口访问；仅编译不验证硬件运行。

## 环境与零速通信

在 WSL：

```bash
export WEAKNET_ROBOT_IP=<JETSON_IP>
source ~/ros2exp_ws/scripts/setup_phase12_wsl.sh up
# 首次配置或网络变化时，按输出在 Windows 管理员 PowerShell 执行
source ~/ros2exp_ws/scripts/setup_phase12_wsl.sh firewall
source ~/ros2exp_ws/scripts/setup_phase12_wsl.sh check
```

Jetson setup 默认加载系统 ROS、厂商 underlay 和 `~/ros2exp_ws/install/setup.bash`，使用本仓库的 `jetson_base_driver`。`up` 启动 Discovery Server 和 Driver，`check` 检查进程和 ROS graph，`verify` 在 15 秒内接收六个分量全部为零的 `/cmd_vel`，`down` 停止受管理的 Driver 和 Discovery Server。

当前验收使用本仓库 `jetson_base_driver` 在 Jetson 本机编译出的产物。在 Jetson 终端清除旧厂商覆盖值，再启动或接管该 Driver：

```bash
unset WEAKNET_ROBOT_WORKSPACE WEAKNET_ROBOT_DRIVER_PACKAGE
source ~/ros2exp_ws/scripts/setup_phase12_jetson_local.sh up
ros2 pkg prefix jetson_base_driver
ps -p "$(cat ~/.cache/weaknet_phase12/robot_driver.pid)" -o pid,ppid,args
ps --ppid "$(cat ~/.cache/weaknet_phase12/robot_driver.pid)" -o pid,ppid,args
```

package prefix 应为 `~/ros2exp_ws/install/jetson_base_driver`，运行命令应为 `ros2 run jetson_base_driver Mcnamu_driver_M1`，子进程 executable 应位于该 prefix 的 `lib/jetson_base_driver/` 中。

如果还在运行厂商 Driver，先停止已核实的旧 Driver，再执行 `up`；package 或 DDS 环境不同会拒绝重复启动。厂商手柄 launch 的 `takeover` 只适用于已知 `yahboomcar_joy_launch.py`，不能用它停止独立的 `ros2 run` Driver。不要同时运行两个 Driver 占用串口。

在 WSL 启动有限时长的零速 publisher：

```bash
timeout --signal=INT --kill-after=3s 30s \
  ~/ros2exp_ws/scripts/run_phase12_cmdvel_pub.sh \
  --ros-args -p topic:=/cmd_vel -p rate_hz:=10.0 \
  -p linear_x:=0.0 -p linear_y:=0.0 -p angular_z:=0.0
```

保持 publisher 运行，在 Jetson 执行：

```bash
source ~/ros2exp_ws/scripts/setup_phase12_jetson_local.sh verify
```

`verify` 输出收到的零值 `Twist` 和 `PASS`，只订阅消息。超时退出的 publisher 返回码 124 是上面的有限时长运行结束。DDS graph 的匹配数量用于排障，实际消息接收才是通信证据。

动态 TCP 端口、WSL mirrored networking、防火墙和 daemon 排错见 [troubleshooting.md](troubleshooting.md#10-phase-12wsl2-与真实机器人跨主机-dds-不通)。

## 验收标准

| 项目 | 通过标准 | 证据 |
| --- | --- | --- |
| 源码基线 | 本仓库 Driver 与导入时 Jetson 原文件一致 | SOURCE.md 中的 SHA-256 与实际文件一致 |
| 可编译 | WSL 与 Jetson 的 `colcon build` 成功，ROS executable 可发现 | 构建摘要与 `ros2 pkg executables` |
| Jetson 依赖 | 新包 Driver 可导入 | `driver import OK` |
| 控制链 | Jetson 使用本仓库构建的 `jetson_base_driver`，有单个 `/driver_node` 订阅 `/cmd_vel`；验收 publisher 来自 WSL，Gateway 未运行 | package prefix、Driver executable 路径与 `ros2 topic info /cmd_vel --verbose` |
| 零速通信 | WSL 发布全零 `Twist`，Jetson 实际收到该消息 | publisher 日志、Jetson `verify` 输出；`/vel_raw` 可用于观察速度反馈 |

接收端 echo 与 Driver 是独立订阅者：echo 证明跨主机数据到达 Jetson，结合 Driver 的订阅信息确认控制链配置；它不单独证明串口每一帧已被底盘执行。构建和零速通信不代表非零运动或失联保护已验收。
