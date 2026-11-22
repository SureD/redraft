---
name: start
description: 在 Redraft 中启动或继续一条按模块分工的多 Agent 开发需求。主 Agent 登记验收场景、分派任务并完成集成，Codex 为本地看板提供子 Agent 的启停事件。
---

# 按模块协作开发

在用户选定的 Redraft 工作区执行需求。沿用仓库的模块定义、开发流程、需求运行看板和用户指定的验收标准。向用户提供当前需求页面，承担派单、集成与验收。

## 开始或继续需求

1. 从仓库根目录读取 `scripts/architecture.json` 和 `devflow.md`。按需求写清目标、影响的模块和可实际执行的验收场景。为每项新需求选一个唯一的简短 ID。用户指定继续某条需求时复用已有 ID 和任务记录。
2. 用当前父聊天的真实 `CODEX_THREAD_ID` 登记会话。以下大写占位符代表本次实际参数。启动后，后续命令在同一工作区和同一数据库上运行。标准数据库位置是该工作区的 `.build/agent-monitor.sqlite3`。跨 Git 工作树协作时选定一个主工作区，并将其数据库绝对路径用 `--db`（放在子命令前）传给所有参与者。

   ```sh
   python3 scripts/agent_monitor.py new RUN --title '需求名称' --goal '用户要达到的目标' --acceptance '可执行的验收场景' --session-id "$CODEX_THREAD_ID"
   ```

   从新聊天接续已有需求时，使用 `python3 scripts/agent_monitor.py enroll RUN --session-id "$CODEX_THREAD_ID"`。如果运行环境没有给出父聊天 ID，先通过当前聊天可用的界面或工具获取真实标识。若仍无法获取，可继续用不带 `--session-id` 的 `new` 和主 Agent 转报，并向用户说明本次记录的来源。
3. 检查本地 `http://127.0.0.1:8765/api/state` 是否包含刚登记的需求。已经运行则复用；未启动则在可保留的本地进程中启动 `make monitor`。使用同一个数据库；需要显式路径或换端口时运行 `python3 scripts/agent_monitor.py --db DB serve --port PORT`。如果默认端口被其他服务占用，使用空闲端口。确认接口返回本条需求后，给用户 `http://127.0.0.1:PORT/#run=RUN` 的可点击链接，对需求 ID 做 URL 编码。遇到本地网络权限提示，使用当前宿主提供的审批流程。

## 模块分工与真实运行信号

1. 在开始相应子 Agent 前登记分工，共享文件在本次任务中指定一个写入方。使用现有模块 ID，开发工具任务可省略 `--module`。

   ```sh
   python3 scripts/agent_monitor.py task RUN TASK --module MODULE --agent '负责人' --summary '工作范围及验收目标'
   ```

2. 发起子 Agent 时传入需求 ID、任务 ID 和数据库绝对路径，要求它先将**本次真实 Agent ID**绑定到任务，再在指定范围内执行。在启用并信任插件 hooks 的 Codex 中，`SubagentStart` 会提供父会话、Agent 标识和数据库位置。绑定命令可由收到上下文的子 Agent 执行，也可由拿到同一组真实标识的主 Agent 执行。

   ```sh
   python3 scripts/agent_monitor.py --db DB bind RUN TASK --session-id PARENT_SESSION --agent-id CHILD_AGENT
   ```

   引导子 Agent 优先使用启动事件中的标识。若宿主暴露了真实的子线程 ID，可使用该 ID；分工昵称、任务路径、模块 ID 各有用途，都不能代替子线程 ID。若本轮宿主未投递 hooks，主 Agent 继续根据实际消息用 `report --source coordinator` 转记，并让用户知道如何在 Codex 的 Hooks 设置中检查信任状态。
3. 由子 Agent 在有变化时用 `report` 记录工作进展、等待对象、需要工程师决定的问题和建议，验证完成时附证据。由主 Agent 转记时指定 `--source coordinator`。已记录的同一消息直接沿用。产品架构取舍由用户参与，常规实现由 Agent 在现有约定下推进。
4. 集成所有结果，从实际用户入口验证登记的场景。使用 `review RUN verifying --summary ...` 记录集成阶段，成功后执行 `review RUN accepted --summary ... --evidence ...`。验收失败时用 `review RUN failed` 写明证据和剩余问题。最终报告写清可验证的结果和看板链接。
