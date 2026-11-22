import AppKit
import SwiftUI

/// Renders the real native views in a disposable test window; never reads the user's desktop.
@main
struct NativeUISnapshots {
  @MainActor
  static func main() throws {
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)
    let output = URL(
      fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".build/ui-snapshots")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let model = try TestSupport.demoModel()
    let host = NSHostingView(
      rootView: WorkspaceView(model: model)
        .environment(\.documentImageResolver, DemoImageResolver()))
    host.sizingOptions = []
    host.autoresizingMask = [.width, .height]
    let window = OffscreenTestWindow(
      contentRect: NSRect(x: -8000, y: -8000, width: 1220, height: 820),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }

    func settle() {
      for _ in 0..<12 {
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
      }
    }

    func capture(_ name: String, width: CGFloat = 1220, dark: Bool = false) throws {
      application.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
      window.appearance = application.appearance
      window.setContentSize(NSSize(width: width, height: 820))
      host.setFrameSize(NSSize(width: width, height: 820))
      settle()
      precondition(
        host.visibleRect.contains(host.bounds), "Every part of the test window must be drawable")
      guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        fatalError("Cannot allocate snapshot for \(name)")
      }
      host.cacheDisplay(in: host.bounds, to: bitmap)
      guard let data = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Cannot encode snapshot for \(name)")
      }
      try data.write(to: output.appendingPathComponent("\(name).png"))
      print("Rendered \(name): \(Int(host.bounds.width)) × \(Int(host.bounds.height))")
    }

    let balcony = model.articles.first { $0.title == "阳台的一年" }!
    model.newArticle()
    try capture("new-article-light")
    guard let body = window.firstResponder as? BlockTextView, let blockID = body.blockID else {
      fatalError("Opening a new draft must put the insertion point in its body")
    }
    precondition(body.isEditable && body.string.isEmpty)
    precondition(!model.state.inspectorVisible && !model.state.formattingVisible)

    let original = "院子里的薄荷长得非常非常慢。"
    let revised = "院子里的薄荷长得非常慢。"
    body.insertText(original, replacementRange: body.selectedRange())
    precondition(model.currentArticle?.blocks.first?.plainText == original)
    model.renameArticle("阳台手记")
    precondition(model.canRequestAnnotations)
    model.beginReview()
    let deadline = Date().addingTimeInterval(3)
    while model.currentArticle?.phase == .running && Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    try capture("draft-annotations-ready")
    precondition(model.currentArticle?.phase == .ready)
    precondition(!model.state.inspectorVisible, "Returning suggestions must not open a panel")
    precondition(
      body.string == original && model.currentArticle?.blocks.first?.plainText == original)

    model.showAnnotations(for: blockID)
    try capture("draft-reading")
    guard let change = model.currentChange, change.blockID == blockID else {
      fatalError("The block's note must open its own suggestion")
    }
    precondition(change.before == original && change.after == revised)
    model.decide(.accept, changeID: change.id)
    precondition(model.currentArticle?.blocks.first?.plainText == original)
    model.completeReview()
    model.dismissNotice()
    model.selectBlock(blockID)
    model.showProvenance()
    try capture("block-trail-dark", dark: true)
    guard let round = model.currentArticle?.rounds.last else {
      fatalError("The accepted round must be available from the same paragraph")
    }
    precondition(model.currentArticle?.blocks.first?.plainText == revised)
    precondition(round.source.blocks.first?.plainText == original)
    precondition(round.result.blocks.first?.plainText == revised)
    precondition(model.state.inspectorVisible && model.state.inspectorTab == .provenance)

    model.selectArticle(balcony.id)
    model.state.inspectorVisible = false
    model.state.sidebarVisible = true
    try capture("writing-light")
    let textViews = descendants(of: host).compactMap { $0 as? BlockTextView }
    precondition(!textViews.isEmpty, "Writing must use native TextKit text views")
    precondition(
      textViews.allSatisfy { $0.textLayoutManager != nil }, "TextKit 2 must remain active")
    for view in textViews {
      let textHeight = view.textLayoutManager!.usageBoundsForTextContainer.height
      precondition(
        view.bounds.width > 100 && textHeight > 0 && view.bounds.height >= floor(textHeight),
        "Each paragraph must fit its laid-out text")
    }
    let materials = descendants(of: host).compactMap { $0 as? NSVisualEffectView }
    precondition(!materials.isEmpty, "Chrome must contain native materials")
    precondition(materials.allSatisfy { $0.state == .followsWindowActiveState })

    model.selectBlock(model.currentArticle?.blocks.first(where: { $0.kind == .table })?.id)
    model.state.formattingVisible = true
    try capture("writing-table-light")
    let diary = model.articles.first { $0.title == "写日记的第一百天" }!
    model.selectArticle(diary.id)
    try capture("diary-dark", dark: true)

    guard let pending = model.articles.first(where: { $0.phase == .ready }) else {
      fatalError("Expected an annotated letter in the article library")
    }
    model.selectArticle(pending.id)
    model.state.sidebarVisible = false
    model.enterReview()
    try capture("annotations-light")
    try capture("annotations-compact", width: 780)
    precondition(model.state.inspectorVisible && model.state.inspectorTab == .annotations)
    let visibleParagraphs = descendants(of: host).compactMap { $0 as? BlockTextView }
    precondition(visibleParagraphs.contains { $0.string == pending.blocks.first?.plainText })
    model.showExamples()
    try capture("examples-light")
    model.newArticle()
    try capture("new-article-compact", width: 780)
    print("Native rendering checks passed")
  }

  @MainActor
  private static func descendants(of view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendants(of: $0) }
  }
}
