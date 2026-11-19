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
    let window = NSWindow(
      contentRect: NSRect(x: -8000, y: -8000, width: 1220, height: 820),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderFront(nil)

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

    try capture("writing-light")
    let textViews = descendants(of: host).compactMap { $0 as? BlockTextView }
    precondition(!textViews.isEmpty, "Writing must use native TextKit text views")
    precondition(
      textViews.allSatisfy { $0.textLayoutManager != nil }, "TextKit 2 must remain active")
    precondition(textViews.allSatisfy { $0.bounds.width > 100 && $0.bounds.height >= 30 })
    let materials = descendants(of: host).compactMap { $0 as? NSVisualEffectView }
    precondition(!materials.isEmpty, "Chrome must contain native materials")
    precondition(materials.allSatisfy { $0.state == .followsWindowActiveState })

    model.selectBlock(model.currentArticle?.blocks.first(where: { $0.kind == .table })?.id)
    try capture("writing-table-light")

    model.state.inspectorVisible = true
    model.selectBlock(model.currentArticle?.blocks.first?.id)
    try capture("writing-inspector-light")
    try capture("writing-dark", dark: true)

    if let diary = model.articles.first(where: { $0.title == "写日记的第一百天" }) {
      model.selectArticle(diary.id)
      model.state.inspectorVisible = false
      try capture("diary-light")
    }

    guard let pending = model.articles.first(where: { $0.phase == .ready }) else {
      fatalError("Expected a review fixture")
    }
    model.selectArticle(pending.id)
    model.enterReview()
    try capture("review-light")
    model.state.inspectorVisible = false
    model.state.sidebarVisible = false
    model.state.diffLayout = .sideBySide
    try capture("review-compact", width: 780)

    model.state.sidebarVisible = true
    model.state.inspectorVisible = true
    model.setMode(.history)
    try capture("history-dark", dark: true)
    model.showExamples()
    try capture("examples-light")

    model.newArticle()
    model.state.sidebarVisible = false
    model.state.inspectorVisible = false
    try capture("new-article-compact", width: 780)
    window.close()
    print("Native rendering checks passed")
  }

  @MainActor
  private static func descendants(of view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendants(of: $0) }
  }
}
