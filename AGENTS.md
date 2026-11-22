# Redraft 多 Agent 协作

在此仓库开发时遵循 [开发流程](devflow.md)。一次需求分给多个 Agent 时，主 Agent 用[需求运行看板](README.md#需求运行看板)登记需求、验收条件和各项分工。单人完成的日常修改可沿用原流程。

- 给参与者传递本次需求 ID 和任务 ID。任务归属使用 `scripts/architecture.json` 中的模块 ID。开发工具自身的任务可省略模块。
- 用户调用 `$redraft-flow:start` 时按插件的工作流登记父会话、分配任务和关联子 Agent。启停由插件记录；业务进展、等待条件和证据由模块 Agent 用 `report` 上报，或由主 Agent 收到消息后用 `report --source coordinator` 转记一次。等待设计决定时记录具体问题、建议及受影响的工作，收到决定后更新任务。
- 独立命令行 Agent 可以从 `run` 启动以自动记录进程状态。验收由主 Agent 在集成后执行，并用 `review` 写回结果。运行记录保存在当前工作区；使用多个工作树时向参与者传递主工作区数据库的绝对路径（`--db`）。
