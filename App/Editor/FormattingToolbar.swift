import AppKit
import RedraftCore
import SwiftUI

struct FormattingToolbar: View {
  @ObservedObject var model: WorkspaceViewModel

  private var canFormat: Bool { model.selectedBlock?.kind == .text && !model.isEditorLocked }
  private var selectionStyle: EditorSelectionStyle { model.editorSelectionStyle }

  private var familyTitle: String {
    guard let family = selectionStyle.commonFamily else { return "混合" }
    if family.contains("Songti") { return "宋体" }
    if family.contains("Kaiti") { return "楷体" }
    if family.contains("Menlo") { return "等宽" }
    return "黑体"
  }

  var body: some View {
    HStack(spacing: 0) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 3) {
          Menu {
            Button("正文") { model.formatSelection(.heading(0)) }.keyboardShortcut(
              "0", modifiers: [.command, .option])
            Button("标题 1") { model.formatSelection(.heading(1)) }.keyboardShortcut(
              "1", modifiers: [.command, .option])
            Button("标题 2") { model.formatSelection(.heading(2)) }.keyboardShortcut(
              "2", modifiers: [.command, .option])
            Button("标题 3") { model.formatSelection(.heading(3)) }.keyboardShortcut(
              "3", modifiers: [.command, .option])
            Divider()
            Button("引用") { model.formatSelection(.quote) }
          } label: {
            Text(selectionStyle.paragraphTitle)
              .frame(width: 42)
          }
          .disabled(!canFormat)

          separator
          Menu {
            Button("黑体 · 系统") { model.formatSelection(.font("系统")) }
            Button("宋体") { model.formatSelection(.font("Songti SC")) }
            Button("楷体") { model.formatSelection(.font("Kaiti SC")) }
            Button("等宽") { model.formatSelection(.font("Menlo")) }
          } label: {
            Text(familyTitle).frame(width: 38)
          }
          .disabled(!canFormat)

          Menu {
            ForEach([12, 13, 14, 15, 16, 17, 18, 20, 22, 24, 28, 32, 36, 40], id: \.self) { size in
              Button("\(size)") { model.formatSelection(.size(CGFloat(size))) }
            }
          } label: {
            Text(selectionStyle.commonSize.map { String(Int($0)) } ?? "—").monospacedDigit().frame(
              width: 24)
          }
          .disabled(!canFormat)
          separator

          formatButton("bold", "粗体 ⌘B", command: .bold)
            .keyboardShortcut("b")
          formatButton(
            "italic", "斜体 ⌘I",
            command: .italic
          )
          .keyboardShortcut("i")
          formatButton(
            "underline", "下划线 ⌘U",
            command: .underline
          )
          .keyboardShortcut("u")
          formatButton(
            "strikethrough", "删除线 ⇧⌘X",
            command: .strikethrough
          )
          .keyboardShortcut("x", modifiers: [.command, .shift])
          separator

          Menu {
            ForEach(Array(textColors.enumerated()), id: \.offset) { _, entry in
              Button(entry.0) { model.formatSelection(.color(entry.1)) }
            }
          } label: {
            Image(systemName: "textformat").frame(width: 23)
          }
          .help("文字颜色").accessibilityLabel("文字颜色").disabled(!canFormat)
          Menu {
            Button("无高亮") { model.formatSelection(.highlight(nil)) }
            Divider()
            ForEach(Array(highlightColors.enumerated()), id: \.offset) { _, entry in
              Button(entry.0) {
                model.formatSelection(.highlight(entry.1.withAlphaComponent(0.25)))
              }
            }
          } label: {
            Image(systemName: "highlighter").frame(width: 23)
          }
          .help("高亮颜色").accessibilityLabel("高亮颜色").disabled(!canFormat)
          separator

          Menu {
            Button("左对齐") { model.formatSelection(.alignment(.left)) }
              .keyboardShortcut("l", modifiers: [.command, .shift])
            Button("居中") { model.formatSelection(.alignment(.center)) }
              .keyboardShortcut("e", modifiers: [.command, .shift])
            Button("右对齐") { model.formatSelection(.alignment(.right)) }
              .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("两端对齐") { model.formatSelection(.alignment(.justified)) }
              .keyboardShortcut("j", modifiers: [.command, .shift])
          } label: {
            Image(systemName: "text.alignleft").frame(width: 23)
          }
          .help("段落对齐").accessibilityLabel("段落对齐").disabled(!canFormat)
          Menu {
            ForEach([1.35, 1.6, 1.9, 2.3], id: \.self) { spacing in
              Button("\(spacing.formatted()) 倍行距") { model.formatSelection(.spacing(spacing)) }
            }
          } label: {
            Image(systemName: "arrow.up.and.down.text.horizontal").frame(width: 23)
          }
          .help("行距").accessibilityLabel("行距").disabled(!canFormat)
          formatButton("list.bullet", "项目符号 ⇧⌘8", command: .list(false))
            .keyboardShortcut("8", modifiers: [.command, .shift])
          formatButton("list.number", "编号列表 ⇧⌘7", command: .list(true))
            .keyboardShortcut("7", modifiers: [.command, .shift])
          formatButton("decrease.indent", "减少缩进 ⌘[", command: .indent(-1)).keyboardShortcut("[")
          formatButton("increase.indent", "增加缩进 ⌘]", command: .indent(1)).keyboardShortcut("]")
          separator
          formatButton("eraser", "清除格式 ⌘\\", command: .clear).keyboardShortcut("\\")
          Button {
            model.chooseImage()
          } label: {
            Image(systemName: "photo").frame(width: 27, height: 27)
          }
          .help("插入图片").accessibilityLabel("插入图片")
          Button {
            model.showSheet(.insertTable)
          } label: {
            Image(systemName: "tablecells").frame(width: 27, height: 27)
          }
          .help("插入表格").accessibilityLabel("插入表格")
        }
        .padding(.horizontal, 12)
      }
      .disabled(model.isEditorLocked)
      .mask {
        HStack(spacing: 0) {
          LinearGradient(colors: [.clear, .white], startPoint: .leading, endPoint: .trailing)
            .frame(width: 8)
          Color.white
          LinearGradient(colors: [.white, .clear], startPoint: .leading, endPoint: .trailing)
            .frame(width: 14)
        }
      }

      HStack(spacing: 10) {
        separator
        if model.isEditorLocked {
          Image(systemName: "lock").foregroundStyle(PaperTheme.secondaryText).help("当前稿件已送审")
        } else {
          Menu {
            ForEach(["更简洁", "更具体", "更顺口", "语气更自然"], id: \.self) { instruction in
              Button(instruction) {
                if let id = model.state.selectedBlockID {
                  model.markBlock(id, instruction: instruction)
                }
              }
            }
            Button("自定义要求…") { model.showSheet(.customMark) }
            if let id = model.state.selectedBlockID, model.currentArticle?.marks[id] != nil {
              Divider()
              Button("取消标记") { model.unmarkBlock(id) }
            }
          } label: {
            Label("标记", systemImage: "bookmark").fixedSize()
          }
          .disabled(model.state.selectedBlockID == nil)
          .help("标记当前段落、图片或表格")

          Menu {
            Button("上移段落") { model.moveSelectedBlock(-1) }.disabled(
              model.state.selectedBlockID == nil)
            Button("下移段落") { model.moveSelectedBlock(1) }.disabled(
              model.state.selectedBlockID == nil)
            Divider()
            Button("存为版本") { model.savePreviewVersion() }
            Button("这句话的来历") {
              model.state.inspectorTab = .provenance
              model.state.inspectorVisible = true
            }.disabled(model.state.selectedBlockID == nil)
          } label: {
            Image(systemName: "ellipsis").frame(width: 22)
          }
          .help("更多编辑操作").accessibilityLabel("更多编辑操作")
        }
      }
      .padding(.trailing, 14)
    }
    .font(.system(size: 12))
    .tint(.primary)
    .foregroundStyle(Color(nsColor: PaperTheme.textColor))
    .menuStyle(.borderlessButton)
    .buttonStyle(.plain)
    .frame(height: 42)
    .background(NativeMaterial(material: .headerView, blendingMode: .withinWindow))
    .overlay(alignment: .bottom) { Rectangle().fill(PaperTheme.separator).frame(height: 1) }
  }

  private var separator: some View { Divider().frame(height: 18).padding(.horizontal, 4) }

  private func formatButton(
    _ symbol: String, _ title: String, command: EditorFormat
  ) -> some View {
    let state = selectionStyle.state(for: command)
    return Button {
      model.formatSelection(command)
    } label: {
      Image(systemName: symbol).frame(width: 27, height: 27)
        .background(
          state != .off ? PaperTheme.fill : Color.clear, in: RoundedRectangle(cornerRadius: 4)
        )
        .overlay(alignment: .bottom) {
          if state == .mixed {
            Capsule().fill(PaperTheme.accent).frame(width: 10, height: 2).padding(.bottom, 2)
          }
        }
    }
    .help(title).accessibilityLabel(title).accessibilityAddTraits(state == .on ? .isSelected : [])
    .accessibilityValue(state == .mixed ? "混合格式" : state == .on ? "已启用" : "未启用")
    .disabled(!canFormat)
  }

  private var textColors: [(String, NSColor)] {
    [
      ("正文", PaperTheme.textColor), ("灰色", .secondaryLabelColor), ("红色", .systemRed),
      ("橙色", .systemOrange), ("绿色", .systemGreen), ("蓝色", .systemBlue), ("紫色", .systemPurple),
    ]
  }
  private var highlightColors: [(String, NSColor)] {
    [
      ("黄色", .systemYellow), ("绿色", .systemGreen), ("蓝色", .systemBlue), ("粉色", .systemPink),
      ("紫色", .systemPurple),
    ]
  }
}

extension WorkspaceViewModel {
  func moveSelectedBlock(_ direction: Int) {
    guard !isEditorLocked, let id = state.selectedBlockID else { return }
    mutateSelectedArticle { article in
      guard let index = article.blocks.firstIndex(where: { $0.id == id }),
        article.blocks.indices.contains(index + direction)
      else { return }
      article.blocks.swapAt(index, index + direction)
    }
  }
}
