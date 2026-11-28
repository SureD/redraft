# 写作页复选：哪些编辑细节可以交给现成组件

后续决定将最低系统版本提高到 macOS 26，正文采用 SwiftUI 原生富文本控件。[TextEditor 实现与验证](2026-11-22-swiftui-text-editor.md)

用户接受 macOS 14，并希望像使用系统控件一样接入一整页写作界面。按这个目标，先验证 **MarkupEditor**。如果稳定段落身份需要长期修改编辑器内核，优先回到 **BlockNote**。两者均可在现有 SwiftUI 窗口里承载整篇正文；Redraft 管理文章、批注与成稿轨迹。[MarkupEditor 的 Mac 示例和发布说明](https://github.com/stevengharris/MarkupEditor/blob/main/CHANGELOG.md) · [BlockNote 可编辑示例](https://www.blocknotejs.org/examples/basic/minimal)

## macOS 14 上可直接复用什么

Apple 的公开资料中没有可嵌入的备忘录编辑器或该应用的源码。Apple 提供了 TextEdit 的历史示例源码，以及系统富文本控件 `NSTextView`。整篇文档放进一个文本视图，就可以使用系统输入法、连续选区、图文附件和全文编辑撤销，AppKit 也提供表格面板。SwiftUI 直接绑定 `AttributedString` 的富文本 `TextEditor` 要求 macOS 26，已对照本机 Xcode SDK 接口核实。[Apple 开源发布目录](https://opensource.apple.com/releases/) · [Notes API 的 Apple DTS 答复](https://developer.apple.com/forums/thread/813810) · [TextEdit 源码示例](https://developer.apple.com/library/archive/samplecode/TextEdit/Introduction/Intro.html) · [AppKit 表格面板](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/TextLayout/Articles/TextTables.html) · [SwiftUI 富文本](https://developer.apple.com/videos/play/wwdc2025/280/)

MarkupEditor 0.9.1 以 Swift Package 交付，声明 macOS 14 和 Swift tools 6.1。SwiftUI 直接嵌入 `MarkupEditorView(html:)`，包中已有正文与工具栏所需的 Web 资源。编辑后通过 `markupInput` 感知变更、`getHtml()` 回读。该版本打包的段落节点只读写 `<p>`，不会保留输入 HTML 中普通段落的 `id`。宿主可指定分区 ID，仍需实测跨段编辑后的批注归属。验证时对同一篇旧稿拆段、合段、撤销，再读回，核对原来的段落 ID、图表身份、局部字号和高亮。若更看重 AppKit 输入手感，MarkdownKit 是支持 macOS 14 的成品对照，编辑行会显露 Markdown 标记。这里核对过发布源码与公开接口，尚未在 macOS 14 的 Redraft 中试用。[包清单](https://github.com/stevengharris/MarkupEditor/blob/0.9.1/Package.swift) · [保存接口](https://github.com/stevengharris/MarkupEditor#using-the-markupeditor) · [随包分发的段落定义](https://github.com/stevengharris/MarkupEditor/blob/0.9.1/MarkupEditor/Resources/markup-editor.js#L14641) · [分区示例](https://github.com/stevengharris/MarkupEditor/blob/0.9.1/SwiftUIDemo/DivsContentView.swift) · [MarkdownKit](https://emdzej.pl/projects/markdownkit.html)

## 为什么重看

11 月 8 日比较过 SwiftUI TextEditor、TextKit 2、裸 ProseMirror 和 STTextView，当时优先考虑 macOS 原生输入体验。现在已经有了两个具体的成本样本：混合字号时的插入点高度、连续输入长文时的自动滚动，都经过了专项修正。现有一篇文章由多个文本视图以及独立的图片和表格控件组成，跨块连续选区和整篇统一撤销仍待实现。更换每个块里的文本控件，对这两项帮助有限。[上次选型](2026-11-08-arch.md) · [光标与滚动实测](2026-11-19-writing-panel.md) · [当前写作页](../App/Editor/WritingView.swift)

## 候选

| 组件 | 交付到哪一层 | 在 Redraft 的成本与取舍 |
| --- | --- | --- |
| **BlockNote** | React 成品编辑器。标题、列表、图片、表格、块拖动、斜杠菜单和悬浮格式栏都有现成实现。默认工具栏和块菜单可分别开关，纸色、字体和留白可用主题和 CSS 调整。 | 最符合减少编辑交互开发的目标。正文新增一套随包发布的前端资源，以及 Swift 与编辑器之间的文档适配。基础编辑所需的主体采用 MPL-2.0，XL 包另用 GPL-3.0 或商业许可。[组件](https://www.blocknotejs.org/docs/react/components) · [主题](https://www.blocknotejs.org/docs/react/styling-theming) · [许可](https://github.com/TypeCellOS/BlockNote#license-) |
| **BlockInputKit** | 原生 Swift 包，有 SwiftUI/AppKit 宿主、文档级选择与撤销接口、可编辑表格、图片粘贴和逐次编辑回调。 | 希望坚持原生输入时最值得对照。包要求 macOS 15，当前项目支持 13；文档以 Markdown 语法为基础，旧稿的局部排版、独立图注和表格行列身份仍需适配。项目采用 LGPL v3。[宿主与编辑能力](https://github.com/afollestad/BlockInputKit#swiftui-hosting) · [部署目标](https://github.com/afollestad/BlockInputKit/blob/main/Package.swift) · [许可](https://github.com/afollestad/BlockInputKit/blob/main/LICENSE.txt) |
| **MarkupEditor** | MIT Swift 包。一个 SwiftUI 视图封装了 WKWebView、ProseMirror、格式工具栏、图片及表格，能直接使用 CSS 调整样式。 | Swift 侧接入最短。包要求 macOS 14；传入的 HTML binding 在编辑后须由宿主调用 `getHtml()` 取回新内容。逐块变更、批注身份和旧稿排版的对接成本较高。[读写接口](https://github.com/stevengharris/MarkupEditor#using-the-markupeditor) · [部署目标](https://github.com/stevengharris/MarkupEditor/blob/main/Package.swift) |
| **Tiptap 模板** | Simple Editor 是 MIT 成品模板，含常用排版、图片和撤销。Notion-like 模板进一步提供块拖动和上下文菜单，官方对生产使用要求 Start 或以上订阅。 | 如果表格或批注必须直接控制底层节点，Tiptap 值得作为备选。可给指定节点类型配置 UniqueID，列身份与现有审阅规则仍由项目定义。两套模板也都需要 Web 宿主。[Simple](https://tiptap.dev/docs/ui-components/templates/simple-editor) · [Notion-like](https://tiptap.dev/docs/ui-components/templates/notion-like-editor) · [UniqueID](https://tiptap.dev/docs/editor/extensions/functionality/uniqueid) |
| **RichTextKit / Apple 富文本 TextEditor** | RichTextKit 封装 NSTextView，带字体、字号、对齐和图片附件。Apple 在 macOS 26 提供绑定 AttributedString 的 TextEditor。 | RichTextKit 可以减少目前工具栏的开发；图文表混排、业务块身份和跨控件交互仍需应用处理。系统富文本 TextEditor 又超出 macOS 13 基线。[RichTextKit](https://github.com/danielsaidi/RichTextKit) · [Apple WWDC](https://developer.apple.com/videos/play/wwdc2025/280/) |
| **Milkdown Crepe** | 面向 Markdown 的成品所见即所得编辑器，带主题、图片、表格和格式工具。 | 如果核心需求是编辑可移植的 Markdown 文章，这条路很短。Redraft 需要保留局部字体字号、段落排版和稳定身份，以 Markdown 往返会引入另一份映射。[Crepe 指南](https://milkdown.dev/docs/guide/using-crepe) |

## BlockNote 接入后，我们还要做什么

| 位置 | 具体做法和成本 |
| --- | --- |
| 写作界面 | 让同一个编辑器承载整篇正文文本、图片和表格，负责选区、输入和编辑历史。排版工具出现在选中文字时。块手柄按需显示；页边位置优先留给批注。整页字号、纸色、列宽属于主题。作者单独给一句话设的楷体、字号或给一段设的行距属于文章数据，需扩展样式并验证往返。[界面开关示例](https://www.blocknotejs.org/examples/ui-components/ui-elements-remove) · [现有排版模型](../Packages/RedraftCore/Sources/RedraftCore/RichText.swift) |
| 段落及表格身份 | BlockNote 的块有稳定 ID，可以载入 Redraft 已有的块 UUID。旧稿的一个文本块可能容纳多段，首次打开须保留原来的批注归属，拆分、合并和撤销须有明确规则。官方表结构给出行和单元格内容，没有 Redraft 使用的行、列 UUID。结构操作要同步维护行列身份，只按坐标或内容猜测会把批注挂错。[块与表结构](https://www.blocknotejs.org/docs/foundations/document-structure) · [现有图文表模型](../Packages/RedraftCore/Sources/RedraftCore/Document.swift) |
| 编辑与成稿 | 由 ArticleSession 继续拥有文章。编辑器按同一次操作把变更交给会话，校验编辑所基于的原文；输入法组字留在控件内。读批注不影响原文，采用后按已有规则一次成稿并把变化同步给编辑器。避免每敲一个字都把整篇文档重新载入，否则会干扰选区、组字与撤销。Markdown 导出可丢失信息，不宜作为桥接格式。[变更事件](https://www.blocknotejs.org/docs/reference/editor/events) · [Markdown 的限制](https://www.blocknotejs.org/docs/features/export/markdown) · [文章会话](../Packages/RedraftCore/Sources/RedraftCore/ArticleSession.swift) |
| 图片与系统交互 | 图片块已有图注和预览；接入本地图片资源，映射替代文本及显示宽度，避免因切换窗口、复制或形成下一稿丢图。菜单快捷键、拼写与辅助功能在实际 WKWebView 中体验。离线编辑时，脚本、样式和字体都随 App 发布。[图片字段](https://www.blocknotejs.org/docs/features/blocks/embeds) · [文件接入示例](https://www.blocknotejs.org/examples/backend/file-uploading) |

## 用现成的稿件验证值不值得换

1. **空稿连续写。** 在最低支持系统的 WKWebView 里断网打开，使用系统拼音选词、撤销、混输 emoji，组字中触发批注再续写。写满一屏后继续输入，从两段中间跨段选择、复制、删除和撤销。对照当前原生版的插入点、滚动、焦点和菜单快捷键。
2. **《写日记的第一百天》保留排版。** 载入同一份 Core 稿件，修改一句话再读回，核对楷体、高亮、起始编号、缩进、对齐和原来的块身份。在含多段的旧块中按回车、合并、撤销，逐次检查页边批注对应的文字。
3. **《阳台的一年》保留图表批注。** 断网拖入、粘贴图片，核对图注和宽度。在表里放两行相同内容，在目标前插入一行、再删一列并撤销，核对每个保留行列的 ID。以编辑后的稿件请求批注，只采用其中一个单元格的建议，再检查归档的原文、建议与成稿；另开窗口确认旧输入不会覆盖新稿。[样稿](../App/Preview/DemoWorkspaceContentSource.swift) · [现有编辑器验证](../Tests/EditorInteractionTests.swift)

**决策标准。** 若能通过公开扩展和一层文档适配通过以上验证，就采用 BlockNote。若必须长期维护自己的表格编辑器、选区系统或输入法补丁，预期的省工收益就会下降，应保留当前实现。此次已核对仓库、官方文档和公开数据结构；本地没有 BlockNote 缓存且无法从 npm 取包，尚未完成目标 macOS 的宿主实测。
