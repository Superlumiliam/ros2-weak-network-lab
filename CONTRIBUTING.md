# 贡献指南

感谢参与这个实验项目。它同时包含 ROS 2 C++ 代码、Linux 网络脚本和实验数据分析，因此贡献必须让别人能够理解“改了什么、为什么改、如何复现”。

## 开始前

```bash
source /opt/ros/humble/setup.bash
colcon build --packages-select weaknet_demo
source install/setup.bash
```

代码修改后至少运行：

```bash
colcon build --packages-select weaknet_demo
bash -n scripts/*.sh
python3 -m py_compile scripts/*.py
git diff --check
```

如果修改了网络脚本，还应在 namespace/veth 拓扑中做一次最小 smoke test，并确认结束后 `wnpub0` 没有 `netem`。

## 添加一个新实验

请同时记录：

- 实验目的和假设；
- 自变量与控制变量；
- ROS 2 发行版、RMW、DDS 和消息频率；
- namespace、接口和 qdisc 配置；
- raw CSV、分析结果和异常日志的路径；
- 结果是否支持原假设，或为什么不支持。

`exp/` 是本地实验产物目录，默认不提交。请将稳定、可公开复核的结论整理到 `docs/experiment_results.md`，而不是提交单机生成的全部日志。

## 修改 ROS 2 package

- 新依赖必须同时更新 `package.xml` 和 `CMakeLists.txt`；
- 自定义消息字段变化要说明兼容性影响，并重新构建；
- 不要把构建产物、install overlay 或临时日志提交到仓库；
- 尽量保持 publisher/subscriber 的实验参数接口稳定：`reliability`、`depth`、`csv_path`；
- 任何影响指标定义的变化都要更新实验协议。

## 修改网络脚本

- 明确脚本作用的 namespace 和 interface；
- 提供恢复命令；
- 避免默认修改 WSL2 的 `eth0`；
- 脚本应幂等，重复执行不会重复创建冲突的 veth；
- 运行结束后检查 qdisc，不能留下未说明的 netem；
- 不要在脚本或文档中写入密码、密钥或机器私有地址。

## 提交和 Pull Request

提交信息建议使用简短动词开头，例如：

```text
Add Phase 12 command timeout guard
Document Reliable recovery behavior
Fix namespace cleanup verification
```

Pull Request 描述至少回答：

1. 为什么需要这个改动？
2. 改变了哪些实验或接口？
3. 执行了哪些验证命令？
4. 是否有已知限制、异常结果或尚未验证的环境？

如果涉及真实机器人，请额外说明急停、速度限制和断网 fail-safe；没有这些信息的控制实验不应直接合并。
