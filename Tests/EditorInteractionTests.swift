import AppKit
import RedraftCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct EditorInteractionTests {
  @MainActor
  static func main() async throws {
    _ = NSApplication.shared
    try semanticBridgePreservesParagraphRoles()
    try editorSessionsStayIndependent()
    try nativeCommitRejectsStaleComposition()
    try mixedFormattingPreservesRuns()
    try paragraphFormattingPreservesIndependentStyles()
    try clearingAtCaretDoesNotEraseDocumentFormatting()
    try tableBoundariesRejectStaleCallbacks()
    try nativeFormattingUndoAndComposition()
    try tableKeyboardNavigationRespectsTextBoundaries()
    try selectedBlockShortcutsRespectTextFocus()
    try imagePastePreservesRichText()
    try await imageImportsKeepTheirOriginalTarget()
    print("Editor interactions: 12 scenarios passed")
  }

  @MainActor
  private static func model(text: NSAttributedString) throws -> WorkspaceViewModel {
    let block = DocumentBlock(text: RichTextBridge.content(from: text))
    let article = Article(title: "编辑器测试", blocks: [block])
    let model = try TestSupport.model(articles: [article])
    model.selectArticle(article.id)
    model.selectBlock(block.id)
    model.state.selectedRange = NSRange(location: 0, length: text.length)
    return model
  }

  @MainActor
  private static func semanticBridgePreservesParagraphRoles() throws {
    let largeBody = NSAttributedString(
      string: "这是大号正文", attributes: [.font: NSFont.systemFont(ofSize: 28)])
    let model = try model(text: largeBody)
    try expect(
      model.editorSelectionStyle.paragraphTitle == "正文",
      "Large body text must not be inferred to be a heading")
    model.formatSelection(.heading(2))
    try expect(
      model.selectedBlock?.text.paragraphStyle.kind == .heading(level: 2),
      "Heading must be explicit document semantics")
    model.formatSelection(.size(12))
    try expect(
      model.editorSelectionStyle.paragraphTitle == "标题 2",
      "Changing heading size must preserve its semantic role")
    let native = RichTextBridge.attributedString(from: model.selectedBlock!.text)
    let restored = RichTextBridge.content(from: native)
    try expect(
      restored.paragraphStyle.kind == .heading(level: 2),
      "Native bridge must preserve semantic heading on round trip")
    let paragraph = ParagraphStyle(
      kind: .heading(level: 1), alignment: .right, headIndent: 24, firstLineHeadIndent: 12,
      tailIndent: -8, lineSpacing: 3, paragraphSpacing: 11,
      paragraphSpacingBefore: 4, lineHeightMultiple: 1.6,
      list: ListStyle(marker: .decimal, startingItemNumber: 3))
    let rich = RichTextContent(
      string: "标题",
      defaultStyle: TextStyle(
        bold: true, italic: true, underline: true, strikethrough: true, foreground: .secondary,
        background: .rgba(0.4, 0.3, 0.2, 0.25)), paragraphStyle: paragraph)
    let roundTrip = RichTextBridge.content(from: RichTextBridge.attributedString(from: rich))
    try expect(
      roundTrip.paragraphStyle == paragraph,
      "Paragraph layout and list start must survive bridge conversion")
    try expect(
      roundTrip.defaultStyle.bold && roundTrip.defaultStyle.italic
        && roundTrip.defaultStyle.underline && roundTrip.defaultStyle.strikethrough
        && roundTrip.defaultStyle.foreground == .secondary,
      "Character styles and semantic colors must survive bridge conversion")
  }

  @MainActor
  private static func editorSessionsStayIndependent() throws {
    let first = EditorSession()
    let second = EditorSession()
    let firstEditor = BlockTextView(usingTextLayoutManager: true)
    let secondEditor = BlockTextView(usingTextLayoutManager: true)
    let firstID = UUID()
    let secondID = UUID()
    firstEditor.blockID = firstID
    secondEditor.blockID = secondID
    firstEditor.typingAttributes = [.font: NSFont.boldSystemFont(ofSize: 17)]
    secondEditor.typingAttributes = [.font: NSFont.systemFont(ofSize: 17)]
    first.activate(firstEditor)
    second.activate(secondEditor)
    let caret = NSRange(location: 0, length: 0)
    try expect(
      first.selectionStyle(blockID: firstID, range: caret)?.state(for: .bold) == .on,
      "First window owns its insertion style")
    try expect(
      second.selectionStyle(blockID: secondID, range: caret)?.state(for: .bold) == .off,
      "A second window cannot inherit the first editor's style")
    second.clear()
    try expect(
      first.selectionStyle(blockID: firstID, range: caret) != nil
        && second.selectionStyle(blockID: secondID, range: caret) == nil,
      "Clearing one editor session must leave another intact")
  }

  @MainActor
  private static func nativeCommitRejectsStaleComposition() throws {
    let model = try model(text: NSAttributedString(string: "旧稿"))
    let blockID = model.selectedBlock!.id
    let articleID = model.currentArticle!.id
    let parent = NativeRichText(
      content: { model.selectedBlock!.text },
      onCommit: { text, expected in
        model.updateBlockText(blockID, text: text, expectedContent: expected, articleID: articleID)
      }, measuredHeight: .constant(40), blockID: blockID, session: model.editorSession,
      editable: true, onSelection: { model.updateSelection(blockID: blockID, range: $0) })
    let coordinator = NativeRichText.Coordinator(parent)
    let native = BlockTextView(usingTextLayoutManager: true)
    native.isEditable = true
    native.textStorage?.setAttributedString(
      RichTextBridge.attributedString(from: model.selectedBlock!.text))
    native.setMarkedText(
      "pin", selectedRange: NSRange(location: 3, length: 0),
      replacementRange: NSRange(location: 0, length: 2))
    coordinator.commit(native)
    try expect(
      model.selectedBlock?.plainText == "旧稿", "Input method composition stays in the native buffer")
    model.updateBlockText(blockID, text: NSAttributedString(string: "外部更新"))
    native.unmarkText()
    coordinator.commit(native)
    try expect(
      model.selectedBlock?.plainText == "外部更新" && native.string == "外部更新",
      "A stale composition cannot overwrite a newer document and must restore the authoritative content"
    )
    native.textStorage?.append(NSAttributedString(string: "一"))
    coordinator.commit(native)
    native.textStorage?.append(NSAttributedString(string: "二"))
    coordinator.commit(native)
    try expect(
      model.selectedBlock?.plainText == "外部更新一二",
      "Rapid commits advance their base before the next UI render")
  }

  @MainActor
  private static func mixedFormattingPreservesRuns() throws {
    let source = NSMutableAttributedString(
      string: "甲乙丙丁", attributes: [.font: NSFont.systemFont(ofSize: 17)])
    source.addAttribute(
      .font, value: NSFont.boldSystemFont(ofSize: 21), range: NSRange(location: 0, length: 2))
    let model = try model(text: source)
    let selection = EditorSelectionStyle(text: source, range: model.state.selectedRange)
    try expect(
      selection.state(for: .bold) == .mixed && selection.commonSize == nil,
      "Mixed selections must report mixed styles")
    model.formatSelection(.size(24))
    let resized = RichTextBridge.attributedString(from: model.selectedBlock!.text)
    let first = resized.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
    let last = resized.attribute(.font, at: 3, effectiveRange: nil) as! NSFont
    try expect(first.pointSize == 24 && last.pointSize == 24, "Size applies to every selected run")
    try expect(
      NSFontManager.shared.traits(of: first).contains(.boldFontMask)
        && !NSFontManager.shared.traits(of: last).contains(.boldFontMask),
      "Changing size must preserve each run's emphasis")
    model.formatSelection(.font("Menlo"))
    let mono = RichTextBridge.attributedString(from: model.selectedBlock!.text)
    try expect(
      NSFontManager.shared.traits(of: mono.attribute(.font, at: 0, effectiveRange: nil) as! NSFont)
        .contains(.boldFontMask), "Changing family must preserve bold emphasis")
    model.formatSelection(.bold)
    try expect(
      EditorSelectionStyle(
        text: RichTextBridge.attributedString(from: model.selectedBlock!.text),
        range: model.state.selectedRange
      ).state(
        for: .bold) == .on, "Toggling a mixed selection should enable the style everywhere")
    model.formatSelection(.bold)
    try expect(
      EditorSelectionStyle(
        text: RichTextBridge.attributedString(from: model.selectedBlock!.text),
        range: model.state.selectedRange
      ).state(
        for: .bold) == .off, "Toggling a uniform selection should remove the style")
  }

  @MainActor
  private static func paragraphFormattingPreservesIndependentStyles() throws {
    let source = NSMutableAttributedString(
      string: "One\nTwo", attributes: [.font: NSFont.systemFont(ofSize: 17)])
    let first = NSMutableParagraphStyle()
    first.paragraphSpacing = 8
    let second = NSMutableParagraphStyle()
    second.paragraphSpacing = 22
    source.addAttribute(.paragraphStyle, value: first, range: NSRange(location: 0, length: 4))
    source.addAttribute(.paragraphStyle, value: second, range: NSRange(location: 4, length: 3))
    let model = try model(text: source)
    model.formatSelection(.alignment(.center))
    let text = RichTextBridge.attributedString(from: model.selectedBlock!.text)
    let a = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as! NSParagraphStyle
    let b = text.attribute(.paragraphStyle, at: 4, effectiveRange: nil) as! NSParagraphStyle
    try expect(
      a.alignment == .center && b.alignment == .center && a.paragraphSpacing == 8
        && b.paragraphSpacing == 22, "Alignment must not overwrite unrelated paragraph styles")
    model.formatSelection(.list(false))
    model.formatSelection(.list(true))
    try expect(
      EditorSelectionStyle(
        text: RichTextBridge.attributedString(from: model.selectedBlock!.text),
        range: model.state.selectedRange
      ).state(
        for: .list(true)) == .on, "Numbered list switches from bullets without clearing the list")
  }

  @MainActor
  private static func clearingAtCaretDoesNotEraseDocumentFormatting() throws {
    let source = NSAttributedString(
      string: "保留加粗", attributes: [.font: NSFont.boldSystemFont(ofSize: 20)])
    let model = try model(text: source)
    model.state.selectedRange = NSRange(location: 1, length: 0)
    model.formatSelection(.clear)
    let first =
      RichTextBridge.attributedString(from: model.selectedBlock!.text).attribute(
        .font, at: 0, effectiveRange: nil) as! NSFont
    try expect(
      NSFontManager.shared.traits(of: first).contains(.boldFontMask),
      "Clear formatting at an insertion point must not erase the whole paragraph")
  }

  @MainActor
  private static func tableBoundariesRejectStaleCallbacks() throws {
    let model = try model(text: NSAttributedString(string: ""))
    let table = DocumentBlock(table: TableContent(rows: [["a", "b"], ["c", "d"]]))
    model.insertBlock(table)
    let deletedRow = TableCell(rowID: table.table!.rowIDs[0], columnID: table.table!.columnIDs[1])
    let deletedColumn = TableCell(
      rowID: table.table!.rowIDs[1], columnID: table.table!.columnIDs[0])
    let retained = TableCell(rowID: table.table!.rowIDs[1], columnID: table.table!.columnIDs[1])
    model.deleteTableRow(table.id, at: 0)
    model.updateTableCell(table.id, cell: deletedRow, text: "stale")
    model.deleteTableColumn(table.id, at: 0)
    model.updateTableCell(table.id, cell: deletedColumn, text: "stale")
    try expect(
      model.selectedBlock?.table?.rows == [["d"]],
      "Stale text callbacks cannot access removed cells")
    model.insertTableRow(table.id, at: 0)
    model.insertTableColumn(table.id, at: 0)
    model.updateTableCell(table.id, cell: retained, text: "live")
    try expect(
      model.selectedBlock?.table?.rows[1][1] == "live",
      "Cell edits retain their identity when rows and columns move")
    for _ in 0..<45 { model.insertTableRow(table.id, at: 99) }
    for _ in 0..<12 { model.insertTableColumn(table.id, at: 99) }
    try expect(
      model.selectedBlock?.table?.rows.count == 40 && model.selectedBlock?.table?.columnCount == 8,
      "Table insertion honors the UI's row and column limits")
  }

  @MainActor
  private static func nativeFormattingUndoAndComposition() throws {
    let source = NSAttributedString(
      string: "输入法和撤销", attributes: [.font: NSFont.systemFont(ofSize: 17)])
    let native = BlockTextView(usingTextLayoutManager: true)
    native.isEditable = true
    native.allowsUndo = true
    native.textStorage?.setAttributedString(source)
    let selected = NSRange(location: 0, length: source.length)
    native.setSelectedRange(selected)
    let changed = NSMutableAttributedString(attributedString: source)
    changed.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: selected)
    let undo = native.undoManager!
    undo.groupsByEvent = false
    undo.beginUndoGrouping()
    native.applyFormatting(changed, selection: selected, typing: EditorTypography.bodyAttributes)
    undo.endUndoGrouping()
    try expect(
      undo.canUndo && native.attributedString().isEqual(to: changed),
      "Native formatting must register an undoable edit")
    undo.undo()
    try expect(
      native.attributedString().isEqual(to: source),
      "Undo restores the exact original attributed content")
    undo.redo()
    try expect(native.attributedString().isEqual(to: changed), "Redo restores formatting")
    undo.beginUndoGrouping()
    native.setMarkedText(
      "pin", selectedRange: NSRange(location: 3, length: 0), replacementRange: selected)
    let composition = NSAttributedString(attributedString: native.attributedString())
    native.applyFormatting(source, selection: selected, typing: EditorTypography.bodyAttributes)
    try expect(
      native.hasMarkedText() && native.attributedString().isEqual(to: composition),
      "Formatting must not replace an in-progress input method composition")
    native.unmarkText()
    undo.endUndoGrouping()
  }

  @MainActor
  private static func tableKeyboardNavigationRespectsTextBoundaries() throws {
    let cell = TableCell(rowID: UUID(), columnID: UUID())
    var focus = TableFocus()
    var navigation: (Int, Bool)?
    let parent = TableCellField(
      text: .constant("abc"), cell: cell,
      focus: Binding(get: { focus }, set: { focus = $0 }),
      isHeader: false, editable: true, columnCount: 3,
      onNavigate: { direction, append in
        navigation = (direction, append)
        return true
      })
    let coordinator = TableCellField.Coordinator(parent)
    let field = NSTextField()
    let text = NSTextView(usingTextLayoutManager: true)
    text.string = "abc"
    text.setSelectedRange(NSRange(location: 1, length: 0))
    try expect(
      !coordinator.control(field, textView: text, doCommandBy: #selector(NSResponder.moveUp(_:)))
        && navigation == nil, "Arrow keys inside text must remain native cursor movement")
    text.setSelectedRange(NSRange(location: 0, length: 0))
    try expect(
      coordinator.control(field, textView: text, doCommandBy: #selector(NSResponder.moveUp(_:)))
        && navigation?.0 == -3 && navigation?.1 == false,
      "Up at the start of a cell moves one row without adding rows")
    text.setSelectedRange(NSRange(location: 3, length: 0))
    try expect(
      coordinator.control(field, textView: text, doCommandBy: #selector(NSResponder.moveDown(_:)))
        && navigation?.0 == 3 && navigation?.1 == false, "Down at the end of a cell moves one row")
    try expect(
      coordinator.control(field, textView: text, doCommandBy: #selector(NSResponder.insertTab(_:)))
        && navigation?.0 == 1 && navigation?.1 == true, "Only forward Tab can append a final row")
    coordinator.controlTextDidBeginEditing(
      Notification(name: NSControl.textDidBeginEditingNotification, object: field))
    coordinator.controlTextDidEndEditing(
      Notification(name: NSControl.textDidEndEditingNotification, object: field))
    try expect(
      focus.cell == cell && !focus.isEditing,
      "Leaving a field preserves the selected cell for table menus")
  }

  @MainActor
  private static func selectedBlockShortcutsRespectTextFocus() throws {
    let model = try model(text: NSAttributedString(string: "正文"))
    let table = DocumentBlock(table: TableContent(rows: [["保留输入"]]))
    model.insertBlock(table)
    try expect(
      !model.handleSelectedBlockKey(51, textInputFocused: true)
        && model.selectedBlock?.id == table.id, "Delete while typing must never delete a block")
    try expect(
      model.handleSelectedBlockKey(53, textInputFocused: false) && model.selectedBlock == nil,
      "Escape clears whole-block selection")
    model.selectBlock(table.id)
    try expect(
      model.handleSelectedBlockKey(36, textInputFocused: false)
        && model.selectedBlock?.kind == .text && model.selectedBlock?.text.string.isEmpty == true,
      "Enter after a selected block creates an editable paragraph")
    model.selectBlock(table.id)
    try expect(
      model.handleSelectedBlockKey(117, textInputFocused: false)
        && !model.currentArticle!.blocks.contains(where: { $0.id == table.id }),
      "Forward Delete removes only the selected non-text block")
  }

  @MainActor
  private static func imagePastePreservesRichText() throws {
    let pasteboard = NSPasteboard(name: .init("redraft.image-tests.\(UUID())"))
    defer { pasteboard.releaseGlobally() }
    pasteboard.setData(try pngData(), forType: .png)
    try expect(
      ImageTransfer.imageOnlyPayload(from: pasteboard) != nil,
      "An image-only clipboard exposes an image payload")
    pasteboard.setString("ordinary text", forType: .string)
    try expect(
      ImageTransfer.imageOnlyPayload(from: pasteboard) == nil,
      "Text mixed with an image must use native rich-text paste")
    pasteboard.clearContents()
    pasteboard.setData(try pngData(), forType: .png)
    pasteboard.setData(Data("rtf".utf8), forType: .rtf)
    try expect(
      ImageTransfer.imageOnlyPayload(from: pasteboard) == nil,
      "Formatted clipboard content must not be intercepted")
  }

  @MainActor
  private static func imageImportsKeepTheirOriginalTarget() async throws {
    let data = try pngData()
    let model = try model(text: NSAttributedString(string: "first"))
    let originalArticleID = model.currentArticle!.id
    let anchorID = model.selectedBlock!.id
    let target = model.imageImportTarget(after: anchorID)!
    let second = DocumentBlock(text: RichTextContent(string: "second"))
    model.insertBlock(second)
    model.importImageData(data, target: target)
    try expect(
      model.currentArticle!.blocks[1].kind == .image
        && model.currentArticle!.blocks[2].id == second.id,
      "Image completion uses the original anchor, even after selection changes")
    let count = model.currentArticle!.blocks.count
    model.importImageData(Data(repeating: 0, count: ImageTransfer.maximumBytes + 1), target: target)
    try expect(
      model.currentArticle!.blocks.count == count && model.state.notice == "图片不能超过 20 MB",
      "All image entry points share the size limit")
    model.importImageData(Data("not an image".utf8), target: target)
    try expect(
      model.currentArticle!.blocks.count == count && model.state.notice == "无法读取这张图片",
      "Invalid image bytes do not enter the document")

    let provider = NSItemProvider(item: data as NSData, typeIdentifier: UTType.png.identifier)
    try expect(
      model.receiveImageDrop([provider], after: anchorID), "Image providers are accepted for drop")
    model.newArticle()
    model.importImageData(data, target: target)
    try await Task.sleep(for: .milliseconds(200))
    try expect(
      model.currentArticle!.blocks.allSatisfy { $0.kind == .text }
        && model.articles.first(where: { $0.id == originalArticleID })!.blocks.count == count,
      "An asynchronous drop cannot cross an article switch")
    model.selectArticle(originalArticleID)
    model.deleteBlock(anchorID)
    let remaining = model.currentArticle!.blocks.count
    model.importImageData(data, target: target)
    try expect(
      model.currentArticle!.blocks.count == remaining,
      "A deleted insertion anchor cancels a pending image import")
  }

  @MainActor
  private static func pngData() throws -> Data {
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    return bitmap.representation(using: .png, properties: [:])!
  }

  private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw Failure(message: message) }
  }

  private struct Failure: Error { let message: String }
}
