import AppKit
import RedraftCore
import SwiftUI
import WebKit

/// Renders only the test application's own disposable window (never the desktop).
@main
struct NativeUISnapshots {
  @MainActor static func main() throws {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let output = URL(
      fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".build/ui-snapshots")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let model = try WorkspaceViewModel(
      source: DemoWorkspaceContentSource(), reviewProvider: DemoReviewProvider(),
      proofreadingProvider: RuleProofreadingProvider(), proofreadingDelay: .milliseconds(5))
    let host = NSHostingView(
      rootView: WorkspaceView(model: model).environment(
        \.documentImageResolver, DemoImageResolver()))
    host.sizingOptions = []
    host.autoresizingMask = [.width, .height]
    let window = OffscreenTestWindow(
      contentRect: NSRect(x: -8000, y: -8000, width: 1220, height: 820),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }

    func capture(_ name: String, width: CGFloat = 1220, dark: Bool = false) throws {
      app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
      window.appearance = app.appearance
      let size = NSSize(width: width, height: 820)
      window.setContentSize(size)
      host.setFrameSize(size)
      host.layoutSubtreeIfNeeded()
      var webImage: NSImage?
      var webFrame: NSRect?
      if model.state.section == .articles, let article = model.currentArticle {
        try window.waitForEditor(editable: !model.isEditorLocked)
        let firstID = article.blocks[0].id.uuidString.lowercased()
        try window.waitFor("Wrong document rendered for \(name)") {
          try window.js("!!document.querySelector('[data-id=\"\(firstID)\" i]')") as? Bool == true
        }
        if let web = window.web {
          let frame = web.convert(web.bounds, to: host)
          webFrame =
            host.isFlipped
            ? NSRect(
              x: frame.minX, y: size.height - frame.maxY, width: frame.width, height: frame.height)
            : frame
          var returned = false
          web.takeSnapshot(with: nil) { image, _ in
            webImage = image
            returned = true
          }
          try window.waitFor("WebKit snapshot timed out") { returned }
          guard webImage != nil else {
            throw PaperTestFailure(message: "Empty WebKit capture: \(name)")
          }
        }
      }
      guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        throw PaperTestFailure(message: name)
      }
      host.cacheDisplay(in: host.bounds, to: rep)
      let image = NSImage(size: size, flipped: false) { frame in
        rep.draw(in: frame)
        if let webImage, let webFrame { webImage.draw(in: webFrame) }
        return true
      }
      guard let tiff = image.tiffRepresentation,
        let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
      else { throw PaperTestFailure(message: name) }
      try png.write(to: output.appendingPathComponent(name + ".png"))
      print("Rendered \(name): \(Int(width)) × 820")
    }

    model.newArticle()
    try capture("new-article-light")
    let freshBlockID = model.currentArticle!.blocks[0].id
    TestSupport.replaceText(model, freshBlockID, "院子里的薄荷长得非常非常慢。")
    try window.waitFor("The live proofreading panel has no suggestions") {
      model.proofreadingSuggestions.contains { $0.blockID == freshBlockID }
    }
    try capture("proofreading-light")
    try capture("proofreading-compact-dark", width: 780, dark: true)
    let balcony = model.articles.first { $0.title == "阳台的一年" }!
    model.selectArticle(balcony.id)
    model.state.sidebarVisible = true
    try capture("writing-light")
    let diary = model.articles.first { $0.title == "写日记的第一百天" }!
    model.selectArticle(diary.id)
    try capture("diary-dark", dark: true)
    let pending = model.articles.first { $0.phase == .ready }!
    model.selectArticle(pending.id)
    model.state.sidebarVisible = false
    model.enterReview()
    try capture("annotations-light")
    try capture("annotations-compact", width: 780)
    try capture("annotations-dark", dark: true)
    precondition(model.currentArticle?.blocks == pending.blocks)
    model.showExamples()
    try capture("examples-light")
    model.newArticle()
    try capture("new-article-compact", width: 780)
    model.showExamples()
    model.state.sidebarVisible = true
    try capture("library-compact", width: 780)
  }
}
