import AppKit
import RedraftCore
import SwiftUI

@main
@MainActor
struct RedraftApp: App {
  @NSApplicationDelegateAdaptor(LibraryLifecycle.self) private var lifecycle

  var body: some Scene {
    Window("Redraft", id: "main") {
      switch lifecycle.launch {
      case .success(let workspace):
        WorkspaceView(model: workspace.model).onDisappear { lifecycle.flushOnClose() }
      case .failure(let error):
        ContentUnavailableView {
          Label("无法打开本地文章库", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
          Text("\(error.localizedDescription)\n没有载入空白库，也不会覆盖原稿。请检查磁盘或备份后重新打开 Redraft。")
            .textSelection(.enabled)
        } actions: {
          Button("退出 Redraft") { NSApp.terminate(nil) }
        }
      }
    }
    .defaultSize(width: 1220, height: 820)
    .windowStyle(.hiddenTitleBar)
    .commands {
      if case .success(let workspace) = lifecycle.launch {
        WorkspaceCommands(model: workspace.model)
      }
    }
  }
}

@MainActor
private final class LibraryLifecycle: NSObject, NSApplicationDelegate {
  let launch: Result<(store: WorkspaceStore, model: WorkspaceViewModel), any Error>

  override init() {
    launch = Result {
      let store = try WorkspaceStore(libraryAt: SQLiteLibrary.location())
      let model = WorkspaceViewModel(
        store: store, reviewProvider: DemoReviewProvider(),
        proofreadingProvider: LocalProofreadingProvider())
      model.newArticle()  // A new launch sheet is not a stored draft until the author changes it.
      return (store, model)
    }
    super.init()
  }

  func flushOnClose() {
    if case .success(let workspace) = launch { try? workspace.store.flush() }
  }

  func applicationDidResignActive(_ notification: Notification) { flushOnClose() }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard case .success(let workspace) = launch else { return .terminateNow }
    do {
      try workspace.store.flush()
      return .terminateNow
    } catch {
      // A full disk on quit should not cost the author the only remaining (in-memory) copy.
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = "仍有稿件未保存"
      alert.informativeText = "\(error.localizedDescription)\n返回文章后可以复制内容，或解决磁盘问题后再退出。"
      alert.addButton(withTitle: "返回文章")
      alert.addButton(withTitle: "放弃未保存的更改并退出")
      return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
  }
}
