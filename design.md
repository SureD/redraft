# Redraft 技术设计

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

## 工程骨架

开发者可以生成 Xcode 工程、启动一个空白的 Redraft 窗口，并单独测试 RedraftCore。应用通过本地包导入核心接口。核心包用四个小协议分别描述编辑、Diff、AI 改稿和文章存储，通过值类型传递稿件、选区、改动与快照。编辑位置使用送审稿中的 UTF-16 偏移。AI 每次只接收一个选中段落和改稿要求。文章会话收齐结果后，以同一稿件版本为基准一次提交所有替换。期间作者若已改稿，编辑接口拒绝过期的提交。Diff 接口以阅读顺序返回保留、新增、删除或替换的文字。文档一次生成含文章 ID、完整快照和 Markdown 的归档。每篇文章由一个会话依序等待保存完成，存储实现整份提交归档，失败时保留上一份。重开时文档从快照恢复历史。

本步验收覆盖 App 构建与启动、包外调用接口，以及中文和 emoji 选区的边界。Loro 1.17.1 在实现文档适配器时接入，分层 Diff、模型服务和磁盘文章库分别在后续步骤实现。

App 和核心包均使用 Swift 6 语言模式。文本对比可交给后台任务。分段必须能够拼回两稿各自的原始 UTF-8，以保留原文的选区坐标。
