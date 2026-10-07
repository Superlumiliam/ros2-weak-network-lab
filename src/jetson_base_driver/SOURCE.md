# Driver 来源

- 导入日期：2026-10-07。
- 来源设备：Jetson，aarch64，ROS 2 Humble，Python 3.10.12。
- 原文件：`/home/jetson/yahboomcar_ros2_ws/yahboomcar_ws/src/yahboomcar_bringup/yahboomcar_bringup/Mcnamu_driver_M1.py`。
- 来源 package/executable：`yahboomcar_bringup / Mcnamu_driver_M1`。
- 导入文件：`jetson_base_driver/Mcnamu_driver_M1.py`，字节内容与原文件一致。
- SHA-256：`68041e3d0f464a39756457988f2845c08e5a7c83a8d04b4ee370f90858f1f79c`。
- 设备现有依赖：`Rosmaster-Lib 3.3.9`、`pyserial 3.5`，`yahboomcar_msgs` 来自厂商 workspace。

本轮仅增加 ROS package 包装与入口，不修改 Driver 的参数、话题、回调或串口行为。后续修改直接在此文件中进行，通过 Git diff 对照这次导入基线；来源校验值不随修改更新。

原厂 `package.xml` 和 `setup.py` 均将许可证标为 `TODO: License declaration`。本包使用 `LicenseRef-Vendor-Unspecified` 记录这一事实；仓库的 Apache-2.0 声明不作为该厂商源码的授权声明。
