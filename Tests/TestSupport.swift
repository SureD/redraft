import AppKit
import RedraftCore

@MainActor
enum TestSupport {
  static func demoModel() throws -> WorkspaceViewModel {
    try WorkspaceViewModel(
      source: DemoWorkspaceContentSource(),
      reviewProvider: DemoReviewProvider(delay: .milliseconds(5)))
  }

  static func model(articles: [Article], examples: [RewriteExample] = []) throws
    -> WorkspaceViewModel
  {
    try WorkspaceViewModel(
      source: Source(
        seed: WorkspaceSeed(
          articles: articles.map { ArticleSeed(document: $0) }, examples: examples)),
      reviewProvider: NoReviewProvider())
  }

  struct Source: WorkspaceContentSource {
    let seed: WorkspaceSeed
    func load() -> WorkspaceSeed { seed }
  }
}

struct NoReviewProvider: ReviewProviding {
  func changes(for request: ReviewRequest) async throws -> [ReviewChange] { [] }
}

/// AppKit can constrain a window to its title bar when no physical display is available.
/// Keep the test window offscreen at the requested size so TextKit lays out its visible paragraphs.
final class OffscreenTestWindow: NSWindow {
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }
}
