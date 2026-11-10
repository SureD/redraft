import Foundation
import RedraftCore
import XCTest

final class EditingTests: XCTestCase {
  private let draft = Draft(articleID: UUID(), revisionID: UUID(), text: "写👩🏽‍💻稿", source: .author)

  func testConvertsUTF16SelectionToCompleteCharacters() throws {
    let emojiLength = "👩🏽‍💻".utf16.count
    let range = try draft.range(forUTF16: NSRange(location: 1, length: emojiLength))
    XCTAssertEqual(draft.text[range], "👩🏽‍💻")

    let end = draft.text.endIndex
    XCTAssertEqual(
      try draft.range(forUTF16: NSRange(location: draft.text.utf16.count, length: 0)), end..<end)
  }

  func testRejectsPartialCharactersAndInvalidOffsets() {
    let invalidSelections = [
      NSRange(location: 2, length: 0),
      NSRange(location: 1, length: 2),
      NSRange(location: -1, length: 0),
      NSRange(location: 0, length: -1),
      NSRange(location: draft.text.utf16.count, length: 1),
      NSRange(location: NSNotFound, length: 0),
      NSRange(location: 1, length: Int.max),
    ]
    for selection in invalidSelections {
      XCTAssertThrowsError(try draft.range(forUTF16: selection)) { error in
        XCTAssertEqual(error as? EditingError, .invalidRange)
      }
    }
  }
}
