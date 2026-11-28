import Foundation
import RedraftCore
import XCTest

final class BlockNoteDocumentTests: XCTestCase {
  typealias JSON = [String: Any]

  private func id() -> String { UUID().uuidString.lowercased() }
  private func text(_ value: String, _ styles: JSON = [:]) -> JSON {
    ["type": "text", "text": value, "styles": styles]
  }
  private func link(_ url: String, _ content: [JSON]) -> JSON {
    ["type": "link", "href": url, "content": content]
  }
  private func node(
    _ type: String, id: String, props: JSON = [:], content: Any? = nil, children: [JSON] = []
  ) -> JSON {
    var result: JSON = ["id": id, "type": type, "props": props, "children": children]
    result["content"] = content
    return result
  }
  private func cell(_ text: [JSON], props: JSON = [:]) -> JSON {
    ["type": "tableCell", "props": props, "content": text]
  }
  private func table(_ rows: [[Any]], widths: [Any]? = nil, headers: Int = 0, headerCols: Int = 0)
    -> JSON
  {
    var content: JSON = ["type": "tableContent", "rows": rows.map { ["cells": $0] }]
    content["columnWidths"] = widths
    if headers > 0 { content["headerRows"] = headers }
    if headerCols > 0 { content["headerCols"] = headerCols }
    return content
  }
  private func decode(
    _ nodes: [JSON], previous: [DocumentBlock] = [], resolver: (URL) -> Data? = { _ in nil }
  ) throws -> [DocumentBlock] {
    try BlockNoteDocument.decode(
      JSONSerialization.data(withJSONObject: nodes), previous: previous, imageData: resolver)
  }
  private func encode(_ blocks: [DocumentBlock]) throws -> [JSON] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: BlockNoteDocument.encode(blocks)) as? [JSON])
  }

  func testActualBlockNoteTypesNestingStylesAndLinksSurviveArchiveAndReopen() throws {
    let ids = (0..<6).map { _ in id() }
    let linked = link(
      "https://example.org/写作",
      [text("手", ["code": true, "textColor": "purple"]), text("册", ["underline": true])])
    let quote = node("quote", id: ids[2], props: ["textColor": "red"], content: [text("子块")])
    let checked = node(
      "checkListItem", id: ids[1], props: ["checked": true],
      content: [text("看 ", ["bold": true]), linked], children: [quote])
    let heading = node(
      "heading", id: ids[0],
      props: ["level": 6, "backgroundColor": "gray", "textAlignment": "right"],
      content: [text("草稿")], children: [checked])
    let bullet = node("bulletListItem", id: ids[3], content: [text("收集")])
    let numbered = node(
      "numberedListItem", id: ids[4], props: ["start": 4],
      content: [text("记录", ["italic": true, "strike": true, "backgroundColor": "yellow"])])
    let paragraph = node("paragraph", id: ids[5], content: [text("最后一段")])
    let blocks = try decode([heading, bullet, numbered, paragraph])
    XCTAssertEqual(blocks.map { $0.id.uuidString.lowercased() }, ids)
    XCTAssertEqual(blocks.map(\.plainText), ["草稿", "看 手册", "子块", "收集", "记录", "最后一段"])
    XCTAssertEqual(blocks[0].text.paragraphStyle.kind, .heading(level: 6))
    XCTAssertEqual(blocks[0].text.paragraphStyle.alignment, .right)
    XCTAssertEqual(blocks[3].text.paragraphStyle.list?.marker, .bullet)
    XCTAssertEqual(
      blocks[4].text.paragraphStyle.list, ListStyle(marker: .decimal, startingItemNumber: 4))
    XCTAssertTrue(blocks[4].text.defaultStyle.italic && blocks[4].text.defaultStyle.strikethrough)
    var article = Article(title: "Nested", blocks: blocks, marks: [blocks[2].id: "核对"])
    try article.validate()
    XCTAssertNoThrow(try article.range(forUTF16: NSRange(location: 0, length: 1), in: blocks[2].id))
    let reopened = try JSONDecoder().decode(Article.self, from: JSONEncoder().encode(article))
    let json = try encode(reopened.blocks)
    XCTAssertEqual(json.count, 4)
    let child = try XCTUnwrap((json[0]["children"] as? [JSON])?.first)
    XCTAssertEqual(child["content"] as? NSArray, [text("看 ", ["bold": true]), linked] as NSArray)
    XCTAssertEqual((child["props"] as? JSON)?["checked"] as? Bool, true)
    XCTAssertEqual(((child["children"] as? [JSON])?.first?["type"] as? String), "quote")
    XCTAssertEqual((json[0]["props"] as? JSON)?["backgroundColor"] as? String, "gray")
    XCTAssertEqual(try decode(json, previous: reopened.blocks), blocks)
    article.blocks.removeFirst()
    XCTAssertThrowsError(try article.validate())
    XCTAssertThrowsError(try BlockNoteDocument.encode(article.blocks))
  }

  func testLegacyNativeFormattingAndTableIdentitySurviveUnrelatedWebEdits() throws {
    let legacy = TextStyle(
      fontFamily: "Kaiti SC", fontSize: 19, foreground: .rgba(0.31, 0.19, 0.1, 0.9))
    let paper = ParagraphStyle(
      headIndent: 17, firstLineHeadIndent: 8, lineSpacing: 13, paragraphSpacingBefore: 5)
    let special = TextStyle(
      fontFamily: "Songti SC", fontSize: 24, bold: true, background: .highlight)
    let original = DocumentBlock(
      text: RichTextContent(
        string: "甲\n乙",
        runs: [
          RichTextRun(
            range: NSRange(location: 1, length: 1), style: special, paragraphStyle: paper),
          RichTextRun(
            range: NSRange(location: 2, length: 1), style: special,
            paragraphStyle: ParagraphStyle(kind: .heading(level: 3), lineSpacing: 8)),
        ], defaultStyle: legacy, paragraphStyle: paper))
    let grid = DocumentBlock(table: .init(rows: [["左", "右"]]))
    let image = DocumentBlock(
      image: .init(assetName: "unavailable", caption: "图注", altText: "旧描述", width: 0.72))
    let other = DocumentBlock(text: .init(string: "备注"))
    let source = [original, grid, image, other]
    var wire = try encode(source)
    let legacyInline = try XCTUnwrap(wire[0]["content"] as? [JSON])
    // The web's markless hardBreak is serialized with the preceding marks, not its native bold run.
    XCTAssertEqual(legacyInline.first?["text"] as? String, "甲\n")
    XCTAssertEqual(try decode(wire, previous: source), source)
    // BlockNote also marks all columns as headers in a single-row all-header table.
    var t = try XCTUnwrap(wire[1]["content"] as? JSON)
    t["headerCols"] = 2
    wire[1]["content"] = t
    wire[3]["content"] = [text("新的备注")]
    let changed = try decode(wire, previous: source)
    XCTAssertEqual(Array(changed.prefix(3)), [original, grid, image])
    XCTAssertEqual(changed.last?.plainText, "新的备注")
    // A block background change shouldn't strip a font from a manual line break either.
    var props = try XCTUnwrap(wire[0]["props"] as? JSON)
    props["backgroundColor"] = "blue"
    wire[0]["props"] = props
    let recolored = try decode(wire, previous: changed)
    XCTAssertEqual(recolored[0].text, original.text)
    let inserted = [text("新")] + legacyInline
    wire[0]["content"] = inserted
    let edited = try decode(wire, previous: recolored)
    let end = edited[0].text.runs.last
    XCTAssertEqual(end?.style, special)
    XCTAssertEqual(end?.paragraphStyle.kind, .heading(level: 3))
    XCTAssertEqual(edited[0].text.defaultStyle.fontFamily, "Kaiti SC")
  }

  @MainActor
  func testCanonicallyEquivalentSpellingChangesTheRevisionAndItsUTF16Coordinates() throws {
    let block = DocumentBlock(text: RichTextContent(string: "é"))
    let session = try ArticleSession(document: Article(title: "Unicode", blocks: [block]))
    let oldRevision = session.document.revisionID
    let composed = "e\u{301}"
    let next = try decode(
      [node("paragraph", id: block.id.uuidString, content: [text(composed)])], previous: [block])
    try session.updateDocument { $0.blocks = next }
    XCTAssertNotEqual(session.document.revisionID, oldRevision)
    XCTAssertEqual(Array(session.document.blocks[0].plainText.utf8), Array(composed.utf8))
    XCTAssertNoThrow(
      try session.document.range(forUTF16: NSRange(location: 0, length: 2), in: block.id))
  }

  func testImageOwnershipCanonicalURLCaptionAndExactEditorWidth() throws {
    let key = id()
    let upload = "redraft-image://asset/" + id()
    let bytes = Data([1, 2, 3, 4])
    let original = DocumentBlock(
      id: UUID(uuidString: key)!,
      image: ImageContent(assetName: "missing", caption: "原图", width: 0.75))
    let canonical = "redraft-image://asset/" + key
    var props = try XCTUnwrap(try encode([original])[0]["props"] as? JSON)
    XCTAssertEqual(props["url"] as? String, canonical)
    XCTAssertEqual(props["previewWidth"] as? Double, 519)
    props["caption"] = "新图注"
    props["name"] = "替代文本"
    let named = try decode([node("image", id: key, props: props)], previous: [original]) { _ in
      XCTFail()
      return nil
    }
    XCTAssertEqual(
      named[0].image, .init(assetName: "missing", caption: "新图注", altText: "替代文本", width: 0.75))
    props["url"] = upload
    props["previewWidth"] = 941.25
    props["showPreview"] = false
    props["textAlignment"] = "center"
    let live = [node("image", id: key, props: props)]
    let imported = try decode(live, previous: named) { url in
      XCTAssertEqual(url.absoluteString, upload)
      return bytes
    }
    XCTAssertEqual(imported[0].image, .init(data: bytes, caption: "新图注", altText: "替代文本", width: 1))
    XCTAssertThrowsError(try decode(live, previous: named))
    let canonicalForm = try encode(imported)
    let reprops = try XCTUnwrap(canonicalForm[0]["props"] as? JSON)
    XCTAssertEqual(reprops["url"] as? String, canonical)
    XCTAssertEqual(reprops["previewWidth"] as? Double, 941.25)
    XCTAssertEqual(reprops["textAlignment"] as? String, "center")
    XCTAssertEqual(reprops["showPreview"] as? Bool, false)
    XCTAssertEqual(try decode(canonicalForm, previous: imported), imported)
    XCTAssertEqual(try decode(live, previous: imported) { _ in bytes }, imported)
    XCTAssertThrowsError(try decode([node("image", id: id(), props: reprops)], previous: named))
    XCTAssertThrowsError(try decode([node("image", id: id(), props: reprops)]) { _ in Data() })
    let copyID = id()
    let copied = try decode([node("image", id: copyID, props: reprops)], previous: imported) { _ in
      bytes
    }
    XCTAssertEqual(copied.first?.image?.data, bytes)
    XCTAssertEqual(
      (try encode(copied)[0]["props"] as? JSON)?["url"] as? String,
      "redraft-image://asset/" + copyID)
    let placeholder = try decode([node("image", id: key, props: ["url": ""])], previous: named)
    XCTAssertNil(placeholder[0].image?.assetName)
    XCTAssertNil(placeholder[0].image?.data)
    XCTAssertThrowsError(try decode(canonicalForm, previous: placeholder))
  }

  func testUndoToOriginalImageHandleAndRedoRetainTheRightBytesEvenWithIdenticalProps() throws {
    let block = DocumentBlock(image: ImageContent(data: Data([1]), caption: "旧图注"))
    let key = block.id.uuidString.lowercased()
    let original = "redraft-image://asset/" + key
    let upload = "redraft-image://asset/" + id()
    func resolve(_ url: URL) -> Data? {
      [original: Data([1]), upload: Data([2])][url.absoluteString]
    }
    func picture(_ url: String, caption: String = "旧图注") -> [JSON] {
      [node("image", id: key, props: ["url": url, "caption": caption])]
    }
    let replaced = try decode(picture(upload), previous: [block], resolver: resolve)
    XCTAssertEqual(replaced[0].image?.data, Data([2]))
    let captioned = try decode(
      picture(upload, caption: "新图注"), previous: replaced, resolver: resolve)
    XCTAssertEqual(captioned[0].image, ImageContent(data: Data([2]), caption: "新图注"))
    let undo = try decode(picture(original, caption: "新图注"), previous: captioned, resolver: resolve)
    XCTAssertEqual(undo[0].image, ImageContent(data: Data([1]), caption: "新图注"))
    XCTAssertEqual(
      try decode(picture(upload, caption: "新图注"), previous: undo, resolver: resolve), captioned)
    XCTAssertEqual(
      try BlockNoteDocument.encode(undo), try BlockNoteDocument.encode(captioned),
      "The local handle is stable, even though undo changed its backing bytes")
    // After a true reopen the canonical handle is rebound to the archived image, not the old token.
    XCTAssertEqual(try decode(encode(captioned), previous: captioned) { _ in Data([2]) }, captioned)
  }

  func testStructuralSnapshotsRetireAmbiguousCellCoordinatesRatherThanRetargeting() throws {
    let block = DocumentBlock(table: .init(rows: [["a", "b"], ["c", "d"], ["c", "d"]]))
    let base = try XCTUnwrap(block.table)
    let key = block.id.uuidString
    func change(_ rows: [[String]]) throws -> TableContent {
      try XCTUnwrap(
        decode([node("table", id: key, content: table(rows, headers: 1))], previous: [block]).first?
          .table)
    }
    XCTAssertEqual(try change(base.rows), base)
    let inserted = try change([["new", "new"]] + base.rows)
    XCTAssertTrue(Set(inserted.rowIDs).isDisjoint(with: base.rowIDs))
    XCTAssertEqual(inserted.columnIDs, base.columnIDs)
    let columns = try change(base.rows.map { ["new"] + $0 })
    XCTAssertTrue(Set(columns.columnIDs).isDisjoint(with: base.columnIDs))
    XCTAssertEqual(columns.rowIDs, base.rowIDs)
    let replaced = try change([["a", "b"], ["new", "d"], ["c", "d"]])
    XCTAssertEqual(replaced.rowIDs[0], base.rowIDs[0])
    XCTAssertNotEqual(replaced.rowIDs[1], base.rowIDs[1])
    XCTAssertNotEqual(
      replaced.rowIDs[2], base.rowIDs[2], "duplicate row content gives no identity evidence")
    let reordered = try change([["c", "d"], ["a", "b"], ["c", "d"]])
    XCTAssertTrue(Set(reordered.rowIDs).isDisjoint(with: base.rowIDs))
    let moved = try change(base.rows.map { Array($0.reversed()) })
    XCTAssertTrue(Set(moved.columnIDs).isDisjoint(with: base.columnIDs))
    let resizedAndSwapped = try change([["new", "new"]] + base.rows.map { Array($0.reversed()) })
    XCTAssertTrue(Set(resizedAndSwapped.columnIDs).isDisjoint(with: base.columnIDs))
    let colored = cell([text("same", ["textColor": "red"])])
    let plain = cell([text("same")])
    let before = try decode([node("table", id: key, content: table([[colored], [plain]]))])
    let after = try decode(
      [node("table", id: key, content: table([[plain], [colored]]))], previous: before)
    XCTAssertTrue(
      Set(try XCTUnwrap(after[0].table).rowIDs).isDisjoint(
        with: try XCTUnwrap(before[0].table).rowIDs))
  }

  @MainActor
  func testNativeReviewReconcilesLiveTextImagesAndTablesWithoutResurrectingOldJSON() throws {
    let parent = id()
    let nested = id()
    let image = id()
    let grid = id()
    let upload = "redraft-image://asset/" + id()
    let marked = link("https://example.org", [text("指南", ["code": true, "textColor": "purple"])])
    let richCell = cell([marked], props: ["textAlignment": "center", "backgroundColor": "pink"])
    let nodes = [
      node(
        "quote", id: parent, content: [text("来源")],
        children: [
          node(
            "checkListItem", id: nested, props: ["checked": true], content: [marked, text(" 旧结尾")])
        ]),
      node(
        "image", id: image,
        props: ["url": upload, "caption": "旧图注", "name": "照片", "showPreview": false]),
      node(
        "table", id: grid, props: ["textColor": "blue"],
        content: table(
          [["列一", "列二"], [richCell, cell([text("旧单元格", ["bold": true])])]], widths: [170, 53],
          headers: 1, headerCols: 1)),
    ]
    let source = try decode(nodes) { _ in Data([1]) }
    let initialJSON = try encode(source)
    var editedImage = source[2]
    editedImage.image = .init(data: Data([2, 3]), altText: "新图", width: 0.5)
    var editedCell = source[3]
    editedCell.table?.rows[1][1] = "新单元格"
    var columns = source[3]
    columns.table?.columnIDs.insert(UUID(), at: 0)
    columns.table?.rows = [["加列", "列一", "列二"], ["补充", "指南", "旧单元格"]]
    let article = Article(title: "审阅", blocks: source)
    let changes = [
      ReviewChange(blockID: source[1].id, before: "旧结尾", after: "新结尾", explanation: ""),
      ReviewChange(
        blockID: source[2].id, kind: .image, before: "照片", after: "新图", explanation: "",
        afterBlock: editedImage),
      ReviewChange(blockID: source[2].id, before: "旧图注", after: "新图注", explanation: ""),
      ReviewChange(
        blockID: source[3].id, before: "旧单元格", after: "新单元格", explanation: "",
        afterBlock: editedCell),
      ReviewChange(
        blockID: source[3].id, kind: .tableColumn, before: "两列", after: "三列", explanation: "",
        afterBlock: columns),
    ]
    let session = try ArticleSession(
      document: article,
      review: .ready(
        .init(articleID: article.id, baseRevisionID: article.revisionID, changes: changes)))
    _ = try session.finishReview(acceptRemaining: true)
    let final = session.document.blocks
    let json = try encode(final)
    XCTAssertEqual(final.map(\.id), source.map(\.id))
    XCTAssertEqual(try encode(session.rounds[0].source.blocks) as NSArray, initialJSON as NSArray)
    let child = try XCTUnwrap((json[0]["children"] as? [JSON])?.first)
    XCTAssertEqual(child["content"] as? NSArray, [marked, text(" 新结尾")] as NSArray)
    XCTAssertEqual((child["props"] as? JSON)?["checked"] as? Bool, true)
    XCTAssertEqual(final[2].image?.data, Data([2, 3]))
    let picture = try XCTUnwrap(json[1]["props"] as? JSON)
    XCTAssertEqual(picture["name"] as? String, "新图")
    XCTAssertEqual(picture["caption"] as? String, "新图注")
    XCTAssertEqual(picture["previewWidth"] as? Double, 346)
    XCTAssertEqual(picture["showPreview"] as? Bool, false)
    let content = try XCTUnwrap(json[2]["content"] as? JSON)
    XCTAssertEqual(content["columnWidths"] as? NSArray, [NSNull(), 170, 53] as NSArray)
    XCTAssertEqual(content["headerRows"] as? Int, 1)
    XCTAssertEqual(content["headerCols"] as? Int, 1)
    let row = try XCTUnwrap((content["rows"] as? [JSON])?.last?["cells"] as? [JSON])
    XCTAssertEqual(row[1]["content"] as? NSArray, [marked] as NSArray)
    XCTAssertEqual((row[1]["props"] as? JSON)?["backgroundColor"] as? String, "pink")
    XCTAssertEqual(
      (row[2]["content"] as? [JSON])?.compactMap { $0["text"] as? String }.joined(), "新单元格")
    XCTAssertEqual(try decode(json, previous: final), final)
  }

  func testRejectsInvalidIDsPayloadsAndNonlocalImagesBeforePublishing() throws {
    let key = id()
    let paragraph = node("paragraph", id: key, content: [text("OK")])
    let malformed: [[JSON]] = [
      [], [node("paragraph", id: "initialBlockId", content: [])], [paragraph, paragraph],
      [node("paragraph", id: key, content: [], children: [paragraph])],
      [node("video", id: key)], [node("heading", id: key, props: ["level": 7], content: [])],
      [node("heading", id: key, props: ["isToggleable": true], content: [])],
      [node("checkListItem", id: key, props: ["checked": "yes"], content: [])],
      [node("paragraph", id: key, content: [["type": "mention", "text": "@author"]])],
      [node("paragraph", id: key, content: [text("x", ["bold": 1])])],
      [node("paragraph", id: key, content: [text("x", ["unsupportedStyle": true])])],
      [node("paragraph", id: key, content: [["type": "link", "href": 3, "content": []]])],
      [node("table", id: key, content: table([["A"], ["B", "C"]]))],
      [node("table", id: key, content: table([["A"]], widths: [1, 2]))],
      [node("table", id: key, content: table([["A"]], headers: 2))],
      [node("table", id: key, content: table([[cell([text("A")], props: ["colspan": 2])]]))],
      [node("image", id: key, props: ["previewWidth": -1])],
      [node("image", id: key, content: [text("unexpected")])],
    ]
    for items in malformed { XCTAssertThrowsError(try decode(items), "\(items)") }
    for url in [
      "https://example.org/img.png", "file:///tmp/img.png", "data:image/png;base64,AAAA",
      "redraft-image://other/\(key)", "redraft-image://asset/\(key)?copy=1",
      "redraft-image://asset/not-a-uuid",
    ] {
      XCTAssertThrowsError(
        try decode([node("image", id: key, props: ["url": url])]) { _ in
          XCTFail("Must not resolve \(url)")
          return nil
        })
    }
    let existing = DocumentBlock()
    XCTAssertThrowsError(try decode([paragraph], previous: [existing, existing]))
    XCTAssertThrowsError(try BlockNoteDocument.encode([existing, existing]))
    XCTAssertThrowsError(try BlockNoteDocument.decode(Data("{}".utf8), previous: []) { _ in nil })
  }
}
