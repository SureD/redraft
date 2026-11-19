# Redraft 技术设计

## 原生 UI、数据模型与状态归属（2026-11-15）

依据 design 分支的 prototype 实现原生 macOS 界面：文章库、窗口工具栏、排版工具栏、图文表编辑区、标记检查器、逐处审阅、历史对比、句子来历及改写范例。沿用 XcodeGen + SwiftUI/AppKit + RedraftCore 分层与 Swift 6、macOS 13 基线。

本轮将原先 App 展示模型与 Core 纯文本草稿两套契约收拢为结构化文档。Core 的 `Article` 包含文章 ID、当前版本 ID、标题、内容块与标记；`DocumentBlock` 使用带关联值的内容枚举，分别承载语义富文本、图片或表格。标题层级、列表和文字样式有显式类型，AppKit 字体与颜色不进入 Core。`ArticleVersion` 保存特定版本的文档快照；审阅批次记录文章和基准版本，选区明确使用内容块内的 UTF-16 坐标。

状态按所有者分开，而不是统一塞入全局 ViewModel：

| 状态 | 唯一所有者 | 界面访问方式 |
| --- | --- | --- |
| 一篇文章的当前正文、标题、格式与标记 | Core `ArticleSession.document` | 经 ViewModel 读取只读投影；修改动作由会话校验后提交 |
| 历史快照、改稿请求、审阅批次和取舍 | 同一篇文章的 `ArticleSession` | 会话发布变化，ViewModel 派生审阅与历史显示 |
| 文章会话集合、改写范例 | App `WorkspaceStore` | ViewModel 观察 Store；多个窗口可共享 Store 与会话 |
| 当前文章 ID、选区、搜索、模式、侧栏、弹窗草稿 | 每个窗口自己的 `WorkspaceState` | ViewModel 动作或界面绑定 |
| 原生焦点、输入格式、组字缓冲、布局测量 | 窗口级 `EditorSession` 与原生控件 | 明确的桥接回调；不作为第二份文档存储 |

`WorkspaceViewModel` 不再持有文章内容副本。它从 Store 中的会话计算 `ArticleViewState`、文章列表、字数、未处理建议数量和操作可用性。UI 读取这些投影并发出动作，文档修改统一经过会话；历史快照是特定版本的只读值，不作为另一个可编辑当前稿。核心状态更新会通知所有订阅者，使共享文章的多个 ViewModel 读取同一事实来源。Store 在变更提交后发出通知，窗口再校正本地引用：其他窗口删除文章或内容块时清理对应选择与弹窗，正文缩短时收拢越界选区，审阅批次结束时关闭已失效的重写弹窗；这些校正不改变其他窗口的文档内容。

原生编辑器通过 `RichTextBridge` 将 Core 语义富文本转换为 `NSAttributedString`，并将原生编辑结果转换回 Core 后提交。标题不再通过字号猜测。窗口级 `EditorSession` 取代进程级静态焦点，工具栏读取它发布的输入会话状态。输入法 marked text 期间只维护原生组字缓冲，不向文档提交中间结果，也不让外部正文覆盖组字。提交时同时携带文章身份与本次原生编辑的基准内容；若该内容已被另一处编辑更新，则拒绝旧缓冲覆盖并恢复当前权威正文，不尝试自动合并冲突。成功提交后立即刷新基准，避免快速连续输入依赖下一次界面重绘。当前按内容块编辑，跨块连续选区与统一文档级撤销仍未实现。

应用入口显式注入 `WorkspaceContentSource`、`ReviewProviding` 与 `DocumentImageResolving`。默认演示装配放在 `App/Preview`：固定文章与历史、改稿样例、演示延迟、插画资源都属于适配器。通用 ViewModel、编辑器和图片渲染器不认识示例稿件或样例图片名；空数据源保持为空，无法读取的图片显示缺失占位。Core 与业务边界通过同一套真实类型和协议定义，业务服务的实现仍可替换。

模块映射为 `App/Workspace`（窗口、文章库、弹层与菜单）、`App/Editor`（正文、排版、图片与表格）、`App/Review`（审阅、历史、来历与范例）、`App/Models` / `App/ViewModels`（文章会话集合、窗口状态、只读投影及动作协调）、`App/Platform`（原生输入和富文本转换）、`App/Preview`（演示注入实现）、`App/Shared`（配色和系统材质）。Core 不依赖 AppKit 或 SwiftUI。

当前会话只提供 UI 所需的内存编辑、版本快照、请求取消、过期结果隔离与审阅状态管理。审阅完成记录本次取舍，正文保持原样；没有真实 AI 调用、Loro 引擎、磁盘保存、Markdown 导出、词级 Diff、逐句定位或跨版本定稿合成。后续接入 Loro 时，由会话封装其权威文档，UI 继续读取派生快照，不能同时维护两份可独立修改的正文。

视觉沿用纸面配色，正文为不透明暖白 / 炭灰；侧栏、工具栏、检查器用 NSVisualEffectView 原生材质，跟随窗口活跃状态和系统外观，并支持“降低透明度”。默认收起检查器，窄窗口让出阅读空间。使用系统菜单、弹层、键盘快捷键及辅助功能标签。

验证覆盖原生构建、Core 文档不变量与会话测试、共享状态和注入边界测试、编辑器富文本及输入保护、Swift 格式检查，以及真实原生视图的深浅色与窄窗快照。以下技术选型中的 Loro、真实 AI 和磁盘存储描述后续目标，不代表已接入。

Redraft 是本地优先的 macOS 文本编辑器，以版本对比（Diff）为核心。编辑器让作者流畅地写下自己的表达，AI 按需改稿，Diff 让作者看清一段文字怎样从初稿演变到定稿。[产品理念](idea.md)

## 写作与改稿体验

作者先专注写作。写完一轮后，标记希望修改的段落，请 AI 改稿。AI 完成修改后生成新版本，作者可以对照原稿，决定下一稿采用哪种表达。

Diff 界面按文章的阅读顺序呈现改动，保留原句的上下文。一处措辞被替换时，作者可以对照着读旧句和新句。即使只改了一个标点，也能看清语气的变化。回看多轮修改时，作者可以沿着同一段落读到初稿、AI 改稿和自己的定稿。这样，日后再遇到类似的表达问题，就能回到这篇文章，看看自己当时怎样取舍。

## 技术选型

| 用途 | 选择 | 理由与取舍 |
| --- | --- | --- |
| macOS 客户端 | Swift、SwiftUI、AppKit，部署目标为 macOS 13 及以上 | SwiftUI 负责文章列表、版本对比和历史视图。正文通过 NSViewRepresentable 嵌入 NSTextView，使用系统的输入法、选区、拼写检查和辅助功能。macOS 13 可作为富文本编辑使用 TextKit 2 的基线。[Apple 的 TextKit 说明](https://developer.apple.com/videos/play/wwdc2022/10090/) |
| 文本编辑与显示 | TextKit 2，显式使用 `NSTextView(usingTextLayoutManager: true)` | 编辑视图能接收原生文本输入，并在版本对比时绘制差异高亮。代价是应用需要维护视图和文档之间的增量同步。 |
| 正文、富文本与历史 | 每篇文章一个 LoroDoc，Swift 绑定固定为 1.17.1 | LoroText 表示正文与富文本标记，Cursor 定位段落边界，forkAt 读取历史版本。Swift 绑定仍标为实验性，相关类型封装在文档模块内。采用完整快照以保留早期草稿。[Swift 绑定](https://github.com/loro-dev/loro-swift) · [快照格式](https://loro.dev/docs/tutorial/encoding) |
| 文本对比 | NaturalLanguage 的 NLTokenizer、Swift 标准库的 difference(from:) | 段落对齐后按句、词和原始标点比较。中英文都能保留可读的修改范围，核心包无需引入第三方 diff 库。[Apple 分词接口](https://developer.apple.com/documentation/naturallanguage/nltokenizer) |
| 本地保存与导出 | Foundation 文件 API、Loro 完整快照、UTF-8 Markdown | 文章可作为一个目录独立保存和备份。快照保存继续编辑所需的全部状态，Markdown 供阅读和交换。 |
| AI 服务 | Swift 异步协议、Codable、URLSession、系统钥匙串 | 模型适配器接收作者标记的段落，返回对应的改写文本。Mock 使用相同接口，便于用固定稿件复现版本差异。服务商可以替换，API 密钥由 Keychain 保存。[Keychain Services](https://developer.apple.com/documentation/security/keychain-services) |
| 工程组织 | XcodeGen 管理 macOS 工程，Swift Package Manager 管理本地核心包与 Loro 依赖 | 用 project.yml 描述应用配置，锁定依赖版本。核心逻辑可用 XCTest 独立测试，编辑器交互在 macOS 应用中验证。[XcodeGen](https://github.com/yonaskolb/XcodeGen) |

## 模块与依赖

macOS 应用负责界面和外部服务，依赖本地 Swift 包 RedraftCore。核心包负责编辑、改稿和版本对比所需的文档逻辑，并定义改稿与存储接口。

| 归属 | 模块 | 主要职责 | 直接依赖 |
| --- | --- | --- | --- |
| macOS 应用 | 编辑界面 | 提供流畅的正文编辑与段落标记体验，在原文上下文中呈现各轮改动。 | SwiftUI、AppKit、文章会话 |
| RedraftCore | 文章会话 | 协调一篇文章的编辑、改稿、对比与保存。每轮 AI 改稿完成后，保留送审稿并生成新版本。 | 文档与版本、文本对比、改稿服务接口、文章存储接口 |
| RedraftCore | 文档与版本 | 管理正文、格式和版本历史，保留修改来源及同一段落在各稿中的对应关系，供作者追溯。 | Foundation、loro-swift |
| RedraftCore | 文本对比（Diff） | 比较任意两稿，识别文字的新增、删除和替换，为界面提供改前、改后的文字及上下文。 | NaturalLanguage、Swift 标准库 |
| macOS 应用 | AI 改稿服务 | 按作者的请求改写标记段落，将改稿结果交给文章会话。 | 核心包的改稿服务接口、URLSession、Keychain |
| macOS 应用 | 本地文章库 | 保存和恢复文章及其完整版本历史，提供文章列表与 Markdown 导出。 | 核心包的文章存储接口、Foundation |

## 现有验证与适用边界

macOS 临时小样已用 loro-swift 1.17.1 验证中文与 emoji 混排的下标换算、富文本标记、前文插字后的锚点位置、历史版本读取和快照重载。系统拼音的确认与取消、AppKit 撤销与正文历史的一致性、生成改稿版本后重开文章并回看段落差异，仍是应用级行为，尚未经过端到端验证。
