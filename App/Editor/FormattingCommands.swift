import SwiftUI

/// Keep the writing shortcuts available when the formatting toolbar is folded away.
struct FormattingCommands: Commands {
  @ObservedObject var model: WorkspaceViewModel

  var body: some Commands {
    CommandMenu("排版") {
      item("粗体", .bold, "b")
      item("斜体", .italic, "i")
      item("下划线", .underline, "u")
      item("删除线", .strikethrough, "x", [.command, .shift])
      Divider()
      Menu("段落样式") {
        item("正文", .heading(0), "0", [.command, .option])
        item("标题 1", .heading(1), "1", [.command, .option])
        item("标题 2", .heading(2), "2", [.command, .option])
        item("标题 3", .heading(3), "3", [.command, .option])
      }
      Menu("段落对齐") {
        item("左对齐", .alignment(.left), "l", [.command, .shift])
        item("居中", .alignment(.center), "e", [.command, .shift])
        item("右对齐", .alignment(.right), "r", [.command, .shift])
        item("两端对齐", .alignment(.justified), "j", [.command, .shift])
      }
      item("项目符号", .list(false), "8", [.command, .shift])
      item("编号列表", .list(true), "7", [.command, .shift])
      item("减少缩进", .indent(-1), "[")
      item("增加缩进", .indent(1), "]")
      Divider()
      item("清除格式", .clear, "\\")
    }
  }

  private func item(
    _ title: String, _ command: EditorFormat, _ key: KeyEquivalent,
    _ modifiers: EventModifiers = .command
  ) -> some View {
    Button(title) {
      // A search field or a sheet can have keyboard focus while the document retains its selection.
      if let textInput = NSApp.keyWindow?.firstResponder as? NSTextView,
        !(textInput is BlockTextView)
      {
        return
      }
      model.formatSelection(command)
    }
    .keyboardShortcut(key, modifiers: modifiers)
    .disabled(
      model.isEditorLocked || model.selectedBlock?.kind != .text || model.state.sheet != nil)
  }
}
