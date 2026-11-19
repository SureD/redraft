import RedraftCore
import SwiftUI

struct WorkspaceCommands: Commands {
  @ObservedObject var model: WorkspaceViewModel

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("新建文章", action: model.newArticle).keyboardShortcut("n", modifiers: .command)
    }
    CommandGroup(replacing: .appInfo) {
      Button("关于 Redraft") { model.showSheet(.about) }
    }
    CommandMenu("工作区") {
      Button("写作") { model.setMode(.writing) }.keyboardShortcut("1", modifiers: .command)
      Button("审阅") { model.setMode(.review) }.keyboardShortcut("2", modifiers: .command)
      Button("历史") { model.setMode(.history) }.keyboardShortcut("3", modifiers: .command)
      Divider()
      Button("切换文章库") { model.state.sidebarVisible.toggle() }
        .keyboardShortcut("s", modifiers: [.command, .control])
      Button("切换检查器") { model.state.inspectorVisible.toggle() }
        .keyboardShortcut("i", modifiers: [.command, .option])
      Divider()
      Button("预览改稿 / 审阅") {
        if model.currentArticle?.phase == .ready {
          model.enterReview()
        } else {
          model.beginReview()
        }
      }
      .keyboardShortcut(.return, modifiers: .command)
      .disabled(model.currentArticle == nil || model.currentArticle?.phase == .running)
    }
    CommandGroup(replacing: .help) {
      Button("快捷键") { model.showSheet(.shortcuts) }.keyboardShortcut("/", modifiers: .command)
    }
  }
}
