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
      Button("文章库") { model.state.sidebarVisible.toggle() }
        .keyboardShortcut("s", modifiers: [.command, .control])
      Divider()
      Button(model.currentArticle?.phase == .ready ? "阅读本轮批注" : "试读示例批注") {
        if model.currentArticle?.phase == .ready {
          model.enterReview()
        } else {
          model.beginReview()
        }
      }
      .keyboardShortcut(.return, modifiers: .command)
      .disabled(
        model.state.section != .articles || model.state.sheet != nil
          || !(model.canRequestAnnotations || model.currentArticle?.phase == .ready))
      Button("段落轨迹", action: model.showProvenance)
        .disabled(model.state.section != .articles || model.selectedBlock == nil)
    }
    CommandGroup(replacing: .help) {
      Button("快捷键") { model.showSheet(.shortcuts) }.keyboardShortcut("/", modifiers: .command)
    }
  }
}
