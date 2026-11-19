# Redraft

Redraft 是一款以版本对比为核心的本地 macOS 写作编辑器。`design` 分支包含网页设计原型，以及按原型实现的 SwiftUI / AppKit 原生界面。

## 原生界面预览

运行 `make run`，默认打开《阳台的一年》。可以编辑文字和排版、插入图片与表格、标记段落，然后点击“改稿”预览示例；《给新同事的一封信》可直接审阅。顶部切换写作、审阅和历史，侧栏可搜索文章、新建文章或查看改写范例；检查器默认收起。

图片支持文件选择、粘贴和拖入；表格可增删行列、切换表头，并用 Tab 和方向键在单元格之间移动。正文提供混合格式状态和原生撤销，选中整张图片或表格后可用 Delete 删除。当前正文按内容块编辑，跨块连续选区与统一文档级撤销尚未实现。

- Core 的 `Article`、`DocumentBlock`、语义富文本、版本和审阅类型是统一数据契约；`ArticleSession` 持有一篇文章的当前文档、历史快照与审阅状态，文档修改只能经会话提交。标题、图片、表格、格式和标记均属于同一份文档状态。
- `WorkspaceStore` 持有文章会话集合和改写范例；`WorkspaceViewModel` 观察 Store，计算只读 `ArticleViewState`、筛选结果与统计。`WorkspaceState` 只保存当前窗口的选择、搜索、显示模式与弹窗草稿，不再复制正文。
- 原生 TextKit 2 编辑器通过 `RichTextBridge` 在 Core 语义富文本与 `NSAttributedString` 之间转换。标题有显式语义，原生焦点和输入属性由窗口级 `EditorSession` 管理；输入法组字缓冲仍留在原生控件中；提交时校验基准内容，避免旧缓冲覆盖已更新正文。
- 文章来源、改稿服务与图片资源在应用入口显式注入。默认装配 `DemoWorkspaceContentSource`、`DemoReviewProvider` 和 `DemoImageResolver`，固定稿件、示例改稿与插画都位于 `App/Preview`。替换或使用空文章源不需要修改 ViewModel，也不会自动回退到示例数据。
- 侧栏、工具栏和检查器使用 `NSVisualEffectView` 原生毛玻璃，跟随系统深浅色和窗口激活状态；降低透明度或提高对比度时回退到不透明背景。正文始终保留纸面底色。
- 当前实现仍限定为 UI、交互及支撑它们的内存状态管理。内容只保留在本次运行内；审阅完成记录取舍，不合成正文定稿。历史是内存快照的逐块对照，尚未接入词级 Diff、句子追溯、Loro、真实 AI、磁盘存储或导出。

设计依据和完整网页原型的能力见 [prototype/README.md](prototype/README.md)。原生界面不会读取或覆盖浏览器中的原型数据。

## 数据与状态入口

| 文件 | 责任 |
| --- | --- |
| `Packages/RedraftCore/Sources/RedraftCore/Document.swift` | 文章、内容块、图片、表格和版本快照 |
| `Packages/RedraftCore/Sources/RedraftCore/RichText.swift` | 语义段落、文字样式与块内 UTF-16 范围 |
| `Packages/RedraftCore/Sources/RedraftCore/Review.swift` | 改稿请求、基准版本、建议与审阅状态 |
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
| `make test` | 验证 Core 文档不变量、版本与审阅状态、异步取消和过期结果隔离 |
| `make test-ui` | 验证注入数据源、共享会话、窗口状态隔离及审阅取舍 |
| `make test-editor` | 验证混合格式、原生撤销、组字保护与表格单元格边界 |
| `make snapshots` | 渲染真实原生视图，检查 TextKit 2 / 材质并输出深浅色和窄窗截图到 `.build/ui-snapshots` |
| `make lint` | 按随 Xcode 提供的 swift-format 默认规范检查全部 Swift 源码 |

[架构视图](architecture.html) · [技术设计](design.md) · [开发流程](devflow.md) · [开发日志](devlog/README.md)

架构视图依次展示模块定义、依赖关系与实现状态，点击模块可查看对应的源码依据。更新时先核对 `scripts/architecture.json` 中的状态与证据，再运行 `make architecture`。完成代码与设计核对后，用 `python3 scripts/update_architecture.py --source-hash` 获取基线，更新 `reviewedSourceHash` 和 `reviewedAt`。生成日期代表快照时间，状态核对日期代表人工审阅时间。
