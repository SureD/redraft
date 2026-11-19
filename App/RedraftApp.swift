import RedraftCore
import SwiftUI

@main
@MainActor
struct RedraftApp: App {
  @StateObject private var model: WorkspaceViewModel
  private let imageResolver = DemoImageResolver()

  init() {
    let model: WorkspaceViewModel
    do {
      model = try WorkspaceViewModel(
        source: DemoWorkspaceContentSource(), reviewProvider: DemoReviewProvider())
    } catch {
      model = WorkspaceViewModel(store: WorkspaceStore(), reviewProvider: DemoReviewProvider())
      model.showNotice("示例数据加载失败：\(error.localizedDescription)")
    }
    _model = StateObject(wrappedValue: model)
  }

  var body: some Scene {
    Window("Redraft", id: "main") {
      WorkspaceView(model: model)
        .environment(\.documentImageResolver, imageResolver)
    }
    .defaultSize(width: 1220, height: 820)
    .windowStyle(.hiddenTitleBar)
    .commands { WorkspaceCommands(model: model) }
  }
}
