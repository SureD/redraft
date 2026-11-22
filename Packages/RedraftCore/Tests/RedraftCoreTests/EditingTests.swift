import Foundation
import RedraftCore
import XCTest

final class EditingTests: XCTestCase {
  private let text = RichTextContent(string: "写👩🏽‍💻稿")

  func testConvertsBlockLocalUTF16SelectionToCompleteCharacters() throws {
    let block = DocumentBlock(text: text)
    let article = Article(title: "Draft", blocks: [block])
    let range = try article.range(
      forUTF16: NSRange(location: 1, length: "👩🏽‍💻".utf16.count), in: block.id)
    XCTAssertEqual(text.string[range], "👩🏽‍💻")
    let end = text.string.endIndex
    XCTAssertEqual(
      try text.range(forUTF16: NSRange(location: text.string.utf16.count, length: 0)), end..<end)
    XCTAssertThrowsError(try article.range(forUTF16: NSRange(location: 0, length: 1), in: UUID())) {
      XCTAssertEqual($0 as? EditingError, .invalidTarget)
    }
  }

  func testRejectsEditingInsideCombinedCharacters() {
    for string in ["e\u{301}", "\r\n"] {
      let content = RichTextContent(string: string)
      for selection in [NSRange(location: 0, length: 1), NSRange(location: 1, length: 1)] {
        XCTAssertThrowsError(try content.range(forUTF16: selection)) { error in
          XCTAssertEqual(error as? EditingError, .invalidRange)
        }
      }
    }
  }

  func testRejectsPartialCharactersAndInvalidOffsets() {
    let selections = [
      NSRange(location: 2, length: 0), NSRange(location: 1, length: 2),
      NSRange(location: -1, length: 0), NSRange(location: 0, length: -1),
      NSRange(location: text.string.utf16.count, length: 1),
      NSRange(location: NSNotFound, length: 0), NSRange(location: 1, length: Int.max),
    ]
    for selection in selections {
      XCTAssertThrowsError(try text.range(forUTF16: selection)) {
        XCTAssertEqual($0 as? EditingError, .invalidRange)
      }
    }
  }

  func testFormattingCanSplitGraphemesButNotSurrogatePairs() throws {
    let combining = RichTextContent(
      string: "e\u{301}",
      runs: [RichTextRun(range: NSRange(location: 0, length: 1), style: .init(bold: true))])
    try combining.validate()
    let surrogate = RichTextContent(
      string: "😀",
      runs: [RichTextRun(range: NSRange(location: 0, length: 1), style: .init(bold: true))])
    XCTAssertThrowsError(try surrogate.validate())
  }

  func testRejectsInvalidStructuredDocuments() {
    let block = DocumentBlock(text: RichTextContent(string: "text"))
    XCTAssertThrowsError(try Article(title: "duplicate", blocks: [block, block]).validate())
    XCTAssertThrowsError(
      try Article(title: "mark", blocks: [block], marks: [UUID(): "shorten"]).validate())
    XCTAssertThrowsError(try TableContent(rows: [["one", "two"], ["ragged"]]).validate())
    var table = TableContent(rows: [["a"], ["b"]])
    table.rowIDs[1] = table.rowIDs[0]
    XCTAssertThrowsError(try table.validate())
    var overlap = RichTextContent(string: "abcd")
    overlap.runs = [
      RichTextRun(range: NSRange(location: 0, length: 3), style: TextStyle()),
      RichTextRun(range: NSRange(location: 2, length: 2), style: TextStyle(bold: true)),
    ]
    XCTAssertThrowsError(try overlap.validate())
  }

  func testCanonicalFormattingPreservesSemanticsWithoutDuplicateRuns() throws {
    let body = ParagraphStyle(lineSpacing: 8)
    let bold = TextStyle(bold: true)
    let partial = RichTextContent(
      string: "abcd",
      runs: [
        RichTextRun(range: NSRange(location: 0, length: 2), style: bold, paragraphStyle: body)
      ],
      paragraphStyle: body)
    let explicit = RichTextContent(
      string: "abcd",
      runs: [
        RichTextRun(range: NSRange(location: 0, length: 1), style: bold, paragraphStyle: body),
        RichTextRun(range: NSRange(location: 1, length: 1), style: bold, paragraphStyle: body),
        RichTextRun(
          range: NSRange(location: 2, length: 2), style: TextStyle(), paragraphStyle: body),
      ], paragraphStyle: body)
    XCTAssertEqual(partial.normalized(), explicit.normalized())
    XCTAssertEqual(partial.normalized().normalized(), partial.normalized())
    XCTAssertEqual(partial.normalized().defaultStyle, bold)
    XCTAssertEqual(partial.normalized().runs.count, 1)
    try partial.normalized().validate()
  }
}
