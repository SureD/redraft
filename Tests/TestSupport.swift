import AppKit
import RedraftCore
import WebKit

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

  @discardableResult
  static func edit(_ model: WorkspaceViewModel, _ mutate: (inout [DocumentBlock]) -> Void) -> Bool {
    guard let document = model.currentArticle?.document else { return false }
    var blocks = document.blocks
    mutate(&blocks)
    return model.commitEditorBlocks(blocks, articleID: document.id, basedOn: document.revisionID)
  }

  static func replaceText(_ model: WorkspaceViewModel, _ id: UUID, _ text: String) {
    edit(model) { blocks in
      guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
      blocks[index].text = RichTextContent(string: text)
    }
  }
}

struct NoReviewProvider: ReviewProviding {
  func changes(for request: ReviewRequest) async throws -> [ReviewChange] { [] }
}

final class OffscreenTestWindow: NSWindow {
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }
}

@MainActor
extension OffscreenTestWindow {
  func waitFor(_ message: String, seconds: Double = 8, until ready: () throws -> Bool) throws {
    let deadline = Date().addingTimeInterval(seconds)
    repeat {
      contentView?.layoutSubtreeIfNeeded()
      if try ready() { return }
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    } while Date() < deadline
    throw PaperTestFailure(message: message)
  }

  var web: WKWebView? {
    func find(_ view: NSView) -> WKWebView? {
      if let web = view as? WKWebView { return web }
      for child in view.subviews { if let web = find(child) { return web } }
      return nil
    }
    return contentView.flatMap(find)
  }

  func js(_ script: String) throws -> Any? {
    guard let web else { throw PaperTestFailure(message: "No WKWebView on paper") }
    var reply: Result<Any?, Error>?
    web.evaluateJavaScript(script) { value, error in
      if let error { reply = .failure(error) } else { reply = .success(value) }
    }
    try waitFor("WebKit did not answer: \(script)") { reply != nil }
    return try reply?.get()
  }

  func waitForEditor(editable: Bool) throws {
    try waitFor("The bundled BlockNote editor did not mount (editable=\(editable))", seconds: 15) {
      guard web != nil else { return false }
      return try js("!!document.querySelector('.ProseMirror[contenteditable=\"\(editable)\"]')")
        as? Bool == true
    }
  }
}

struct PaperTestFailure: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}
