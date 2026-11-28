# 先用成品写一篇，再决定 Redraft 是否需要自己的编辑器

[产品规划](../design.md)把「打开就写、自动收录、能再找到」放在首位，标题、分类和助手都不应挡住第一句话。[上一次选型](2026-11-22-writing-editor-survey.md)问的是怎样在 SwiftUI 里复用编辑控件。这次先问：作者能否不等 Redraft 开发，今天就把一篇稿子写完？这是两个不同的选择。当前[原型](../README.md#运行-swift-原型)已能连续编辑相邻文字块，但图片和表格仍是独立控件，稿件只存在进程内存里；仅换一个富文本控件不能解决重开后找稿的问题。

## 今天就写：首选思源笔记

从[官网](https://b3log.org/siyuan/download.html)下载 macOS 稳定版，选与 Mac 匹配的 Apple Silicon 或 Intel 安装包。第一次只建一个「稿件」笔记本，用 `⌘N` [新建文档](https://siyuannote.com/11e20837f41341059f27a699c72a2a41)，进入正文写一篇新稿。不先建分类、装插件或开通云同步。它是完整应用，不需要编译、部署服务器或等待 Swift 接入。这不等于默认启动必定聚焦空白正文；后者要在实际 Mac 上体验。

以下核对截至 **2026-11-28**。维护证据看上游连续发布的正式版和 macOS 安装包，不用星数代替维护状态。

| 可直接使用的 Mac 应用 | 维护与许可 | 对个人写作的取舍 |
| --- | --- | --- |
| **思源笔记 SiYuan** | [3.8.11（11-19）](https://github.com/siyuan-note/siyuan/releases/tag/v3.8.11) → [3.8.12（11-24）](https://github.com/siyuan-note/siyuan/releases/tag/v3.8.12)；AGPL-3.0。 | 一套应用已有本地笔记本、所见即所得块编辑、按正文检索和带附件的 Markdown 导出。段落本身有 ID，日后可按段交给助手。[中文说明](https://github.com/siyuan-note/siyuan/blob/v3.8.12/README.zh-CN.md) · [定价](https://b3log.org/siyuan/pricing.html)：本地使用免费，云同步等另计。原稿是 `.sy`，不是一目录原生 `.md` 文件。 |
| **AppFlowy** | [0.15.0（11-02）](https://github.com/AppFlowy-IO/AppFlowy/releases/tag/0.15.0) → [0.15.1（11-15，含 Mac 安装包）](https://github.com/AppFlowy-IO/AppFlowy/releases/tag/0.15.1)；[桌面客户端 AGPL-3.0](https://github.com/AppFlowy-IO/AppFlowy/blob/main/LICENSE)。 | 如果「像 Notion」指的是一边写页面、一边用数据库和看板管项目，优先试它。若只写文章，这些工作区功能不是减少输入摩擦所必需的。[项目说明](https://github.com/AppFlowy-IO/AppFlowy) |
| **AFFiNE** | [0.27.3（07-23）](https://github.com/toeverything/AFFiNE/releases/tag/v0.27.3) → [0.27.4（08-18，含 Mac 安装包）](https://github.com/toeverything/AFFiNE/releases/tag/v0.27.4)；11 月仍有 [canary 预发行版](https://github.com/toeverything/AFFiNE/releases)，不算稳定版。 | 文档和白板共存，适合先把材料摊到画布上再写，不是单篇中文稿的首选。是开放核心项目，不应把整套都当作 MIT：见[稳定版许可及例外目录](https://github.com/toeverything/AFFiNE/blob/v0.27.4/LICENSE)。 |

**若思源写起来合适，Redraft 可以只做它没有的部分。** 思源的[本地 API](https://github.com/siyuan-note/siyuan/blob/v3.8.12/docs/API.md)支持按块 ID 读原文（`getBlockKramdown`）和按文档导出 Markdown（`exportMdContent`）。可以先只读一段，交回带来源的批注；作者确认前不改正文。如果原段已改或已删，不自动套用旧建议。这样思源仍是稿件的唯一来源，不需要在两个编辑器间双向同步，也不把 Markdown 导出当作能保留块身份的备份。自动分类、建议取舍和段落改稿历史都不是在这里承诺的成品能力。

## 如果正文必须留在 Redraft 窗口：首选 BlockNote

先用[官方最小编辑器](https://www.blocknotejs.org/examples/basic/minimal)试手感，不要把网页演示当作保存真稿的地方。BlockNote 是现成的 React 块编辑器，不是文章库应用。默认界面提供 `/` 菜单、块拖动和选区格式栏，正文、[图片](https://www.blocknotejs.org/docs/features/blocks/embeds)和[表格](https://www.blocknotejs.org/docs/features/blocks/tables)可在同一份文档内编辑。[0.56.0（10-14）](https://github.com/TypeCellOS/BlockNote/releases/tag/v0.56.0) 和 [0.57.0（10-30）](https://github.com/TypeCellOS/BlockNote/releases/tag/v0.57.0) 均为正式版；后者有自动格式化后撤销、快速输入时建议菜单的修复。主体为 **MPL-2.0**，`@blocknote/xl-*` 为 **GPL-3.0 或商业授权**；基础原型不需要 XL。[上游许可说明](https://github.com/TypeCellOS/BlockNote#license-)

建议保留 SwiftUI 窗口，只把**整篇正文**交给一个加载随包资源的 `WKWebView`，而不是每段文字放一个网页。让编辑器自己管输入、选区、图表和撤销；Redraft 管本地存盘、附件和找稿。用[带块 ID 的结构化数据](https://www.blocknotejs.org/docs/foundations/document-structure)保存新稿，[Markdown 只做导出](https://www.blocknotejs.org/docs/foundations/supported-formats)。官方[存取示例](https://www.blocknotejs.org/examples/backend/saving-loading)和[文件接入示例](https://www.blocknotejs.org/examples/backend/file-uploading)是接入点，不是已经替 Redraft 做好的持久化。第一轮只拿新稿验证，不迁移旧稿、不重写批注系统。另一个常见选项 Tiptap 的[官方 Notion-like 模板](https://tiptap.dev/docs/ui-components/templates/notion-like-editor)在生产环境要求付费订阅，不按免费成品推荐。

## 用一篇稿子判断，不做两套客户端

1. 不取正式标题、不选分类，记下从打开应用到输入第一个中文字要做什么。用系统拼音连续写到第二屏，跨段选取、删除、撤销，看组字、焦点和滚动有没有打断写作。
2. 粘贴一张本地图片、插入一个表格，从末尾继续写下一段。断网退出重开，只用正文里的一句话找回稿件；核对末段、图片和表格，再导出一份 Markdown 看附件是否可读。
3. 这些动作在思源里顺手，就留下稿件继续写；只有需要 Redraft 自己控制「打开即是一张新稿纸」或同窗段旁批注时，才投入 BlockNote 的 Mac 原型。同样的动作须在实际 `WKWebView` 重测，不能用浏览器 Demo 代替。

本轮核对了公开发布记录、许可和文档；未安装客户端，未在本机实测输入法、焦点或恢复行为，也未修改产品实现。
