import AppKit
import RedraftCore
import SwiftUI
import WebKit

@main
struct EditorInteractionTests {
  @MainActor static func main() throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let model = try TestSupport.demoModel()
    let balcony = model.articles.first { $0.title == "阳台的一年" }!
    model.newArticle()
    let draft = model.currentArticle!.id
    let first = model.currentArticle!.blocks[0].id
    let host = NSHostingView(
      rootView: WorkspaceView(model: model).environment(
        \.documentImageResolver, DemoImageResolver()))
    host.sizingOptions = []
    let window = OffscreenTestWindow(
      contentRect: NSRect(x: -8000, y: -8000, width: 1080, height: 700), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }
    try window.waitForEditor(editable: true)
    try window.waitFor("First input must go to the body, not the optional title") {
      try window.js("document.activeElement?.classList.contains('ProseMirror')") as? Bool == true
    }
    try expect(window.web?.url?.isFileURL == true, "Writing must not require a server")
    let original = "院子里的薄荷长得非常非常慢。"
    _ = try window.js("document.execCommand('insertText',false,'\(original)')")
    try window.waitFor("Typed text did not reach the native session") {
      model.currentArticle?.blocks.first?.plainText == original
    }
    _ = try window.js("window.beforeProofreading = document.querySelector('.ProseMirror'); true")
    let proofread = ProofreadingEdit(
      articleID: draft, revisionID: model.currentArticle!.document.revisionID, blockID: first,
      paragraph: original, original: "非常非常慢", replacement: "很慢")
    model.proofreadingEditRequested.send(proofread)
    try window.waitFor("A proofreading change must commit through the active WebKit page") {
      model.currentArticle?.blocks.first?.plainText == "院子里的薄荷长得很慢。"
    }
    try window.waitFor("Applying a suggestion must return focus to the same editor") {
      try window.js("document.activeElement === window.beforeProofreading") as? Bool == true
    }
    _ = try window.js(
      "document.querySelector('.ProseMirror').dispatchEvent(new KeyboardEvent('keydown',{key:'z',code:'KeyZ',keyCode:90,metaKey:true,bubbles:true,cancelable:true}))"
    )
    try window.waitFor("Undo must restore the original paragraph in a single step") {
      model.currentArticle?.blocks.first?.plainText == original
    }
    model.proofreadingEditRequested.send(proofread)
    try expect(
      try window.js("document.querySelector('.ProseMirror').textContent.includes('\(original)')")
        as? Bool == true,
      "The old revision must not apply again after undo")
    let revision = model.currentArticle!.document.revisionID
    model.renameArticle("薄荷手记")
    model.markBlock(first, instruction: "更简洁")
    try expect(
      model.currentArticle!.document.revisionID != revision, "Native metadata is versioned")
    // Native title/mark updates must not remount the DOM or discard the page's undo stack.
    _ = try window.js(
      "document.activeElement.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',keyCode:13,bubbles:true,cancelable:true}))"
    )
    _ = try window.js("document.execCommand('insertText',false,'第二段🪴')")
    try window.waitFor("Return did not create a second identifiable block") {
      model.currentArticle?.blocks.last?.plainText == "第二段🪴"
        && model.currentArticle?.blocks.count == 2
    }
    _ = try window.js(
      "document.querySelector('.ProseMirror').dispatchEvent(new KeyboardEvent('keydown',{key:'z',code:'KeyZ',keyCode:90,metaKey:true,bubbles:true,cancelable:true}))"
    )
    try window.waitFor("BlockNote undo did not reach the article") {
      model.currentArticle?.blocks.last?.plainText != "第二段🪴"
    }
    _ = try window.js(
      "document.querySelector('.ProseMirror').dispatchEvent(new KeyboardEvent('keydown',{key:'z',code:'KeyZ',keyCode:90,metaKey:true,shiftKey:true,bubbles:true,cancelable:true}))"
    )
    try window.waitFor("Redo must restore both the original paragraph and new text before review") {
      model.currentArticle?.blocks.first?.plainText == original
        && model.currentArticle?.blocks.last?.plainText == "第二段🪴"
    }
    _ = try window.js(
      "document.querySelector('.ProseMirror').dispatchEvent(new CompositionEvent('compositionstart',{bubbles:true}))"
    )
    try window.waitFor("WebKit composition signal missing") { model.composingInEditor }
    model.beginReview()
    try expect(!model.isEditorLocked, "A pending candidate must not be reviewed")
    _ = try window.js(
      "document.querySelector('.ProseMirror').dispatchEvent(new CompositionEvent('compositionend',{bubbles:true}))"
    )
    try window.waitFor("Composition never released the document") { !model.composingInEditor }
    model.beginReview()
    try window.waitFor("Demo annotation did not target the saved paragraph") {
      model.currentArticle?.phase == .ready
    }
    try window.waitForEditor(editable: false)
    model.enterReview()
    try expect(
      model.currentChange?.blockID == first, "Review must retain the BlockNote paragraph UUID")
    model.completeReview(acceptRemaining: true)
    try window.waitForEditor(editable: true)
    try window.waitFor("Accepted revision did not render back in BlockNote") {
      try (window.js("document.querySelector('.ProseMirror')?.textContent") as? String)?.contains(
        "薄荷长得非常慢") == true
    }
    model.selectArticle(balcony.id)
    try window.waitFor("Mixed article must render the actual embedded table and local image") {
      try window.js(
        "!!document.querySelector('.ProseMirror table') && [...document.querySelectorAll('.ProseMirror img')].some(i=>i.complete && i.naturalWidth>0 && i.src.startsWith('redraft-image:'))"
      ) as? Bool == true
    }
    let images = EditorImages(resolver: DemoImageResolver())
    images.reset(to: balcony.blocks)
    let export = try MarkdownExport(article: balcony.document, images: images)
    let paths = String(decoding: try JSONEncoder().encode(export.paths), as: UTF8.self)
    guard let markdown = try window.js("window.redraft.markdown(\(paths))") as? String else {
      throw PaperTestFailure(message: "Missing Markdown export")
    }
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: parent) }
    let exported = try export.write(markdown, in: parent)
    let copy = try export.write(markdown, in: parent)
    let text = try String(contentsOf: exported.appendingPathComponent("稿件.md"), encoding: .utf8)
    try expect(
      exported != copy && !text.contains("redraft-image:") && !export.paths.isEmpty
        && export.paths.values.allSatisfy {
          text.contains($0)
            && FileManager.default.fileExists(atPath: exported.appendingPathComponent($0).path)
        },
      "Portable Markdown must reference the exported images without overwriting a previous export")
    // A replaced image can have a live undo handle that still identifies the old bitmap.
    var revised = balcony.document
    let pixel = Data(
      base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j4XoAAAAASUVORK5CYII="
    )!
    let index = revised.blocks.firstIndex { $0.image != nil }!
    let imageID = revised.blocks[index].id.uuidString.lowercased()
    revised.blocks[index].image = ImageContent(data: pixel)
    images.remember(revised.blocks)
    let replacement = try MarkdownExport(article: revised, images: images)
    let updatedFolder = try replacement.write(markdown, in: parent)
    let updatedFile = updatedFolder.appendingPathComponent(replacement.paths[imageID]!)
    let undoURL = URL(string: "redraft-image://asset/" + imageID)!
    try expect(
      images.data(for: undoURL) != pixel && (try Data(contentsOf: updatedFile)) == pixel,
      "Undo must keep the old image while export uses the replacement")
    let page = window.web
    model.selectArticle(draft)
    try window.waitFor("Returning to an article must restore its adopted revision") {
      try (window.js("document.querySelector('.ProseMirror')?.textContent") as? String)?.contains(
        "薄荷长得非常慢") == true
    }
    try expect(window.web === page, "One writing surface supports the complete document")
    // A second writer can publish while this page is showing an unconfirmed candidate.
    _ = try window.js(
      """
      window.beforeComposition = document.querySelector('.ProseMirror');
      window.beforeComposition.dispatchEvent(new CompositionEvent('compositionstart',{bubbles:true}));
      document.execCommand('insertText',false,'候选文字');
      """)
    try window.waitFor("Missing composition before external edit") { model.composingInEditor }
    let externalText = "另一窗口已经保存的正文。"
    TestSupport.replaceText(model, first, externalText)
    try window.waitFor("The authoritative session did not accept the other writer") {
      model.currentArticle?.blocks.first?.plainText == externalText
    }
    try expect(
      try window.js("window.beforeComposition === document.querySelector('.ProseMirror')") as? Bool
        == true,
      "A concurrent edit must wait for the IME to finish before replacing the writing surface")
    _ = try window.js(
      "window.beforeComposition.dispatchEvent(new CompositionEvent('compositionend',{bubbles:true}))"
    )
    try window.waitFor("A stale IME commit must restore the current article in the editor") {
      guard !model.composingInEditor, model.currentArticle?.blocks.first?.plainText == externalText
      else { return false }
      return try window.js(
        "document.querySelector('.ProseMirror').textContent.includes('\(externalText)')") as? Bool
        == true
    }
    let assets = EditorImages(resolver: BundleImageResolver())
    try expect(
      assets.stage("data:image/png;base64,Zm9v") == nil
        && assets.data(for: URL(fileURLWithPath: "/tmp/example.png")) == nil,
      "An image handle cannot introduce arbitrary files or non-image bytes")
    print(
      "Real BlockNote window: focus, Chinese/emoji, split, undo, IME guard, proofreading, review, local image/table and article switching passed"
    )
  }

  private static func expect(_ test: Bool, _ message: String) throws {
    if !test { throw PaperTestFailure(message: message) }
  }
}
