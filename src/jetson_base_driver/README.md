# Jetson 底盘 Driver

此包收录 Jetson 当前使用的 M1 Driver，入口为：

```bash
ros2 run jetson_base_driver Mcnamu_driver_M1
```

源码及原始校验值见 [SOURCE.md](SOURCE.md)。Driver 节点名保持 `/driver_node`，在默认 namespace 下订阅 `/cmd_vel`，将 `Twist.linear.x/y` 和 `Twist.angular.z` 交给 `Rosmaster_Lib.Rosmaster.set_car_motion`，由厂商库通过串口控制底盘。保留原有 `/vel_raw`、IMU、电压等发布接口和灯光、蜂鸣器、舵机订阅接口。

## 编译与依赖

WSL 可编译本包并查看 ROS executable 注册，无需连接底盘：

```bash
source /opt/ros/humble/setup.bash
colcon build --packages-select jetson_base_driver --symlink-install
source install/setup.bash
ros2 pkg executables jetson_base_driver
```

编译成功不代表 WSL 具备硬件运行依赖。Jetson 运行需要厂商 `yahboomcar_msgs`、`Rosmaster-Lib`、`pyserial` 和可访问的底盘串口。`Rosmaster-Lib` 是设备现有厂商 Python 库，没有在本包构建时下载或安装；当前版本记录在 SOURCE.md。

在 Jetson 上从源码编译，使用厂商 workspace 提供消息依赖：

```bash
source /opt/ros/humble/setup.bash
source ~/yahboomcar_ros2_ws/yahboomcar_ws/install/setup.bash
cd ~/ros2exp_ws
colcon build --packages-select jetson_base_driver --symlink-install
source install/setup.bash
ros2 pkg executables jetson_base_driver
# 仅导入模块，不初始化节点、不打开串口
python3 -c 'from jetson_base_driver.Mcnamu_driver_M1 import main; print("driver import OK")'
```

网络、ROS domain、RMW、DDS profile 和进程启动由仓库 `scripts/setup_phase12_*.sh` 管理。首次切换到本包前先停止已有 Driver，确保只有一个 Driver 占用串口。当前已切换为本包在 Jetson 上编译出的 Driver 并完成零速通信验收。完整步骤与验收标准见 [Phase 12](../../docs/phase12_jetson.md)。

## 当前行为边界

导入源码尚无 ROS 命令超时保护；`xlinear_limit`、`ylinear_limit`、`angular_limit` 虽已声明，`cmd_vel_callback` 尚未应用限幅。Phase 12 验收只发送六个分量全部为零的 `Twist`，Gateway、限幅、arm/disarm、超时保护和非零运动均不属于本轮验收。后续改造以这份已编译的原始源码为起点，另行确定需求。
