# Redraft

Redraft 是一款以版本对比为核心的本地 macOS 写作编辑器。当前骨架包含可启动的 SwiftUI 窗口和独立的 RedraftCore 包。

## 本地开发

使用 Xcode 16 或更高版本，以便直接运行 Swift 格式检查。将 Xcode 设为当前开发工具。使用 Homebrew 安装 XcodeGen（`brew install xcodegen`）。App 的最低部署版本为 macOS 13。

在仓库根目录运行以下命令。

| 命令 | 用途 |
| --- | --- |
| `make project` | 从 `project.yml` 生成 `Redraft.xcodeproj`，可用 Xcode 打开 |
| `make build` | 生成工程并构建 Debug 版 App |
| `make run` | 构建并打开 Redraft 窗口 |
| `make test` | 单独运行 RedraftCore 测试 |
| `make lint` | 按随 Xcode 提供的 swift-format 默认规范检查全部 Swift 源码 |

[技术设计](design.md) · [开发流程](devflow.md) · [开发日志](devlog/README.md)
