# 与 Agent 协作进行实验

这个项目适合让 Agent 作为实验导师和工程助手，但 Agent 不应替代实验记录。最可靠的方式是让每一轮实验都保留“目的、命令、原始输出、结论”四部分。

## 推荐交互循环

每个小步骤遵循下面的循环：

1. Agent 先说明这一步解决什么问题、哪些变量固定、成功标准是什么；
2. Agent 只给当前一步需要执行的命令，避免把后续十几步提前混在一起；
3. 用户在目标 shell 中执行命令，并贴出完整输出，包括错误、退出码和提示符附近的上下文；
4. Agent 先判断事实：成功、部分成功还是失败，再决定是否排错或进入下一步；
5. 对正式实验，用户记录 run id、qdisc 配置、节点参数和 raw CSV 路径；
6. 实验结束后，Agent 帮助解释结果，但不因为结果“不漂亮”而修改数据或隐藏异常。

如果用户已经熟悉某一类操作，可以把连续的只读检查合并；但涉及 `tc`、namespace 删除、真实机器人运动或可能影响系统网络的操作，仍应先说明范围和恢复命令。

## 提交给 Agent 的实验报告模板

```text
## Experiment
name: delay100_reliable_depth10
purpose: 只研究 100 ms delay 对端到端延迟的影响
independent_variable: delay=100ms
controlled_variables: qos=reliable, depth=10, rate=20Hz, duration=30s

commands:
  - ...

summary:
  - received=...
  - inferred_lost=...
  - avg_latency_ms=...
  - p95_latency_ms=...
  - max_latency_ms=...
  - jitter_stddev_ms=...

tc:
  - sudo ip netns exec weaknet_pub_ns tc -s qdisc show dev wnpub0

artifacts:
  - raw_csv=...
  - subscriber_log=...

observations:
  - ...
```

## 出错时怎么提供信息

不要只说“报错了”或只截取最后一行。至少提供：

- 执行的完整命令；
- 从第一条 error/warning 到命令结束的输出；
- 当前目录和相关文件的 `sed -n` 内容；
- `ros2 node list`、`ros2 topic info --verbose` 或 `tc` 状态等与假设直接相关的信息；
- 是否在 source ROS 系统环境和 workspace overlay 后执行。

不要在输出中包含 sudo 密码、SSH 私钥、机器人凭据、公司网络地址等秘密。必要时用 `<redacted>` 替换。

## Agent 应该保持的实验纪律

- 一次只改变一个研究变量；
- 给每轮实验唯一 run id，不覆盖旧 raw CSV；
- 把异常轮次记录到 `anomalies.md`，不要静默删除；
- 先检查节点、topic、QoS 和网络路径，再考虑重装；
- 修改脚本后先做 shell/Python 语法检查，再运行完整套件；
- 任何 `tc` 注入都要有明确的清理动作，并在结束后验证 qdisc；
- 真实机器人实验必须先确认急停和失联保护。

## 一个好的 Agent 首轮回复应该包含

```text
这一步的目的：...
控制变量：...
请执行：...
成功标准：...
如果失败，请把以下输出发回：...
```

这比一次性生成完整工程更适合 ROS 2 初学者，也更容易定位 DDS discovery、QoS 不匹配、namespace 路由或 qdisc 配置问题。
