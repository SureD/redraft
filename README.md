# Redraft

Redraft 是一款原生 macOS 伴随式写作编辑器。先写正文，再请 AI 批注，等作者读完并选定改动后形成下一稿。

## 运行 Swift 原型

运行 `make run` 即可在空稿中输入。从「文章库」可打开示例，《给新同事的一封信》带有一轮可读批注，《阳台的一年》含图片与表格。

在正文输入「院子里的薄荷长得非常非常慢。」，点「请 AI 批注」。收到意见后点段落旁的批注标记，或从工具栏打开本轮批注。选用一条建议、保留原文或自己改写后，再明确成稿。也可以一次采用其余建议。段落菜单中的轨迹可回看原文、AI 建议和作者的取舍。

图片支持文件选择、粘贴和拖入；表格可增删行列、切换表头，并用 Tab 和方向键在单元格之间移动。正文提供混合格式状态和原生撤销，选中整张图片或表格后可用 Delete 删除。当前正文按内容块编辑，跨块连续选区与统一文档级撤销尚未实现。

- Core 的 `Article`、`DocumentBlock`、语义富文本、版本和审阅类型是统一数据契约；`ArticleSession` 持有一篇文章的当前文档、版本快照、本轮批注和历轮成稿，文档修改只能经会话提交。标题、图片、表格、格式和标记均属于同一份文档状态。
- `WorkspaceStore` 持有文章会话集合和改写范例；`WorkspaceViewModel` 观察 Store，计算只读 `ArticleViewState`、筛选结果与统计。`WorkspaceState` 只保存当前窗口的选择、搜索、侧栏与弹窗草稿，不再复制正文。
- 原生 TextKit 2 编辑器通过 `RichTextBridge` 在 Core 语义富文本与 `NSAttributedString` 之间转换。标题有显式语义，原生焦点和输入属性由窗口级 `EditorSession` 管理；输入法组字缓冲仍留在原生控件中；提交时校验基准内容，避免旧缓冲覆盖已更新正文。
- 文章来源、改稿服务与图片资源在应用入口显式注入。默认装配 `DemoWorkspaceContentSource`、`DemoReviewProvider` 和 `DemoImageResolver`，固定稿件、示例改稿与插画都位于 `App/Preview`。替换或使用空文章源不需要修改 ViewModel，也不会自动回退到示例数据。
- 侧栏、工具栏和检查器使用 `NSVisualEffectView` 原生毛玻璃，跟随系统深浅色和窗口激活状态；降低透明度或提高对比度时回退到不透明背景。正文始终保留纸面底色。
- 文章、批注和轨迹保存在本次运行的内存里。当前批注来自本地演示，真实模型服务、磁盘保存和导出仍待接入。

界面与交互直接在 SwiftUI / AppKit 实现中迭代，运行当前构建即可体验最新设计。[开发流程](devflow.md)

## 数据与状态入口

| 文件 | 责任 |
| --- | --- |
| `Packages/RedraftCore/Sources/RedraftCore/Document.swift` | 文章、内容块、图片、表格和版本快照 |
| `Packages/RedraftCore/Sources/RedraftCore/RichText.swift` | 语义段落、文字样式与块内 UTF-16 范围 |
| `Packages/RedraftCore/Sources/RedraftCore/Review.swift` | 改稿请求、基准版本、批注、作者决定和成稿轮次 |
| `Packages/RedraftCore/Sources/RedraftCore/ArticleSession.swift` | 一篇文章的唯一文档修改入口和会话生命周期 |
| `App/Models/WorkspaceStore.swift` | 文章会话集合与改写范例的所有者 |
| `App/Models/WorkspaceState.swift` | 窗口交互状态，不存文章正文 |
| `App/Models/ArticleViewState.swift` | 从会话产生的只读界面投影 |
| `App/Models/WorkspaceContentSource.swift` | 初始文章来源的注入接口 |
| `App/RedraftApp.swift` | 本次运行使用哪些来源和服务的装配入口 |

## 本地开发

使用 Xcode 16 或更高版本，以便直接运行 Swift 格式检查。将 Xcode 设为当前开发工具。使用 Homebrew 安装 XcodeGen（`brew install xcodegen`）。App 的最低部署版本为 macOS 13。

在仓库根目录运行以下命令。

| 命令 | 用途 |
| --- | --- |
| `make project` | 从 `project.yml` 生成 `Redraft.xcodeproj`，可用 Xcode 打开 |
| `make build` | 生成工程并构建 Debug 版 App |
| `make run` | 构建并打开 Redraft 窗口 |
| `make architecture` | 更新可离线打开的架构页面 |
| `make monitor` | 启动本机需求运行看板，查看 Agent 分工、待决策事项和验收记录 |
| `make test` | 验证 Core 文档不变量、版本与审阅状态、异步取消和过期结果隔离 |
| `make test-ui` | 验证注入数据源、共享会话、窗口状态隔离、批注阅读及成稿 |
| `make test-editor` | 验证混合格式、原生撤销、组字保护与表格单元格边界 |
| `make snapshots` | 渲染真实原生视图，检查 TextKit 2 / 材质并输出深浅色和窄窗截图到 `.build/ui-snapshots` |
| `make lint` | 按随 Xcode 提供的 swift-format 默认规范检查全部 Swift 源码 |

[架构视图](architecture.html) · [技术设计](design.md) · [开发流程](devflow.md) · [开发日志](devlog/README.md)

架构视图依次展示模块定义、依赖关系与实现状态，点击模块可查看对应的源码依据。更新时先核对 `scripts/architecture.json` 中的状态与证据，再运行 `make architecture`。完成代码与设计核对后，用 `python3 scripts/update_architecture.py --source-hash` 获取基线，更新 `reviewedSourceHash` 和 `reviewedAt`。生成日期代表快照时间，状态核对日期代表人工审阅时间。

## 需求运行看板

### 在 Codex 中启动一次需求

打开 Redraft 项目，新建聊天。主 Agent 使用这条聊天所选的模型，可以在派单前选好用于规划的模型。输入 `$redraft-flow:start`，从技能列表选中它，然后写下需求和你要看到的结果。例如：

> $redraft-flow:start 实现「重开文章后恢复草稿」。按模块分工。验收时关闭并重新打开应用，检查草稿内容和版本能否恢复。

主 Agent 会登记需求和验收条件、分派受影响的模块，并给出本次需求的看板链接。看板中的「等待决策」会写明需要决定的问题。直接在这条聊天里答复，主 Agent 会把决定交给负责的模块继续实施。任务行显示 Codex 最近收到的启停事件；等待原因和验证结果由负责的 Agent 上报。最后由主 Agent 按最初的场景验收。

**第一次在一台 Mac 上启用。** 在 Redraft 仓库根目录执行以下两条命令。安装到本机 Codex 后，在桌面应用的「设置 → Hooks」中审阅并信任 Redraft Flow 的 `SubagentStart` 和 `SubagentStop`；CLI 可用 `/hooks`。新聊天会加载已启用的插件。钩子只为已登记的需求保存会话、子 Agent 和轮次标识及启停时间。[Codex 插件事件说明](https://learn.chatgpt.com/docs/hooks#plugin-bundled-hooks)

```sh
codex plugin marketplace add ./plugins
codex plugin add redraft-flow@redraft-local
```

### 查看记录或手动接入

在仓库根目录运行 `make monitor`，从架构页右上角进入[需求运行看板](http://127.0.0.1:8765/)。服务仅在本机监听，使用 Python 3.9 或更新版本的标准库。页面每四秒读取一次最新记录。关闭服务后记录仍在 `.build/agent-monitor.sqlite3`，可重新启动继续查看。需要更换端口时运行 `python3 scripts/agent_monitor.py serve --port 8766`，打开命令输出的地址。

主 Agent 在需求开始时登记目标、验收场景和分工。例如，以下命令记录一项文章库任务。

```sh
python3 scripts/agent_monitor.py new draft-recovery --title '重开文章后恢复草稿' --goal '退出后能继续编辑上次的草稿' --acceptance '保存、退出、重开，核对内容与版本；保存中断后仍能打开上一版'
python3 scripts/agent_monitor.py task draft-recovery disk --module library --agent '文章库 Agent' --summary '实现归档的可靠写入并验证中断恢复'
```

| 信号 | 如何记录 |
| --- | --- |
| 桌面聊天内的子 Agent | 插件把启停事件按父会话和子 Agent 标识关联到模块任务。具体进展由子 Agent 用 `report` 上报，也可由主 Agent 指定 `--source coordinator` 转记。未启用事件时仍可使用这两种上报方式。 |
| 从命令行启动的 Agent | 在原启动命令前加 `python3 scripts/agent_monitor.py run draft-recovery disk --`。工具启动该命令，记录进程心跳、退出和失败。命令的正常输出继续留在终端。 |
| 卡点与待决策 | 用 `report` 记录 `waiting` 并填写 `--waiting-for`，或记录 `decision` 并填写 `--decision` 和可选的 `--recommendation`。决定传回 Agent 后，上报新状态即可移出待决策区。 |
| 模块完成与整体验收 | 模块验证后上报 `done`。主 Agent 用 `review` 记录整体验收；标记 `accepted` 时附上集成验证证据。 |

例如，文章库 Agent 已经完成实现、正在等会话侧样例时，可以这样更新。

```sh
python3 scripts/agent_monitor.py report draft-recovery disk waiting --summary '开始验证磁盘恢复' --waiting-for '文章会话提供包含修改历史的快照样例'
```

运行 `python3 scripts/agent_monitor.py report --help` 可查看任务状态和字段。默认数据属于当前工作区。跨多个 Git 工作树使用自动事件时，将需求登记在 Git 主检出目录的 `.build/agent-monitor.sqlite3`，把这个绝对路径作为 `--db` 传给各工作树的命令。插件先在当前工作树查找已登记的会话，再到主检出目录查找。用 `python3 -B -m unittest discover -s scripts/tests -v` 验证看板与任务关联，用 `python3 -B -m unittest discover -s plugins/redraft-flow/tests -v` 验证插件接收事件的行为。
