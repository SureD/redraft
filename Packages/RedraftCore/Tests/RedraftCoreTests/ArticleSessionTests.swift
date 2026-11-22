import Foundation
import RedraftCore
import XCTest

@MainActor
final class ArticleSessionTests: XCTestCase {
  private func article() -> Article {
    let block = DocumentBlock(text: RichTextContent(string: "Before"))
    return Article(title: "Title", blocks: [block], marks: [block.id: "Shorten"])
  }

  private func change(for article: Article, after: String = "After") -> ReviewChange {
    let block = article.blocks[0]
    var replacement = block
    replacement.text = RichTextContent(string: after)
    return ReviewChange(
      blockID: block.id, before: block.plainText, after: after, explanation: "Suggestion",
      beforeBlock: block, afterBlock: replacement)
  }

  func testAtomicDocumentEditsAndImmutableVersionSnapshots() throws {
    let session = try ArticleSession(document: article())
    let initial = session.document
    let version = session.saveVersion(title: "Initial")
    try session.updateDocument(basedOn: initial.revisionID) { $0.title = "Renamed" }
    XCTAssertNotEqual(session.document.revisionID, initial.revisionID)
    XCTAssertEqual(version.document, initial)
    XCTAssertEqual(session.versions[0].document.title, "Title")
    let committed = session.document
    XCTAssertThrowsError(
      try session.updateDocument(basedOn: initial.revisionID) { $0.title = "Stale" }
    ) {
      XCTAssertEqual($0 as? EditingError, .staleRevision)
    }
    XCTAssertThrowsError(try session.updateDocument { $0.blocks.removeAll() })
    XCTAssertThrowsError(try session.updateDocument { $0.id = UUID() })
    XCTAssertThrowsError(try session.updateDocument { $0.revisionID = UUID() })
    XCTAssertThrowsError(try session.updateDocument { $0.updatedAt = .distantPast })
    XCTAssertEqual(session.document, committed)
    XCTAssertEqual(session.versions, [version])
  }

  func testNativeFormattingRoundTripDoesNotCreateNewRevision() throws {
    let session = try ArticleSession(document: article())
    let initial = session.document
    var notifications = 0
    session.observe { notifications += 1 }
    try session.updateDocument { document in
      var content = document.blocks[0].text
      content.runs = [
        RichTextRun(
          range: NSRange(location: 0, length: content.string.utf16.count),
          style: content.defaultStyle)
      ]
      document.blocks[0].text = content
    }
    XCTAssertEqual(session.document, initial)
    XCTAssertEqual(notifications, 0)
  }

  func testRejectsConflictingDocumentsForCurrentOrHistoricalRevision() {
    let current = article()
    var conflictingCurrent = current
    conflictingCurrent.title = "Different title under the same revision"
    XCTAssertThrowsError(
      try ArticleSession(
        document: current,
        versions: [ArticleVersion(title: "Conflicting current", document: conflictingCurrent)])
    ) {
      XCTAssertEqual($0 as? EditingError, .invalidDocument)
    }

    var historical = current
    historical.revisionID = UUID()
    historical.blocks[0].text = RichTextContent(string: "Earlier draft")
    var conflictingHistory = historical
    conflictingHistory.blocks[0].text = RichTextContent(string: "Another draft")
    XCTAssertThrowsError(
      try ArticleSession(
        document: current,
        versions: [
          ArticleVersion(title: "Earlier", document: historical),
          ArticleVersion(title: "Conflicting earlier", document: conflictingHistory),
        ])
    ) {
      XCTAssertEqual($0 as? EditingError, .invalidDocument)
    }
  }

  func testAllowsNamedSnapshotsOfSameNormalizedRevision() throws {
    let current = article()
    var nativeRepresentation = current
    nativeRepresentation.blocks[0].text.runs = [
      RichTextRun(
        range: NSRange(location: 0, length: current.blocks[0].text.string.utf16.count),
        style: TextStyle())
    ]
    let versions = [
      ArticleVersion(title: "Before review", date: .distantPast, document: current),
      ArticleVersion(
        title: "Named checkpoint", date: .distantFuture, document: nativeRepresentation),
    ]
    let session = try ArticleSession(document: current, versions: versions)
    XCTAssertEqual(session.versions.count, 2)
    XCTAssertEqual(session.versions[0].document, session.document)
    XCTAssertEqual(session.versions[1].document, session.document)
    XCTAssertNotEqual(session.versions[0].id, session.versions[1].id)
  }

  func testMultipleObserversShareOneDocumentOwner() throws {
    let session = try ArticleSession(document: article())
    var first: [String] = []
    var second: [String] = []
    let firstToken = session.observe { first.append(session.document.title) }
    let secondToken = session.observe { second.append(session.document.title) }
    try session.updateDocument { $0.title = "Shared" }
    session.removeObserver(firstToken)
    try session.updateDocument { $0.title = "Second" }
    session.removeObserver(secondToken)
    XCTAssertEqual(first, ["Shared"])
    XCTAssertEqual(second, ["Shared", "Second"])
  }

  func testSeedReviewMustMatchArticleRevisionAndContent() throws {
    let document = article()
    let suggestion = change(for: document)
    XCTAssertThrowsError(
      try ArticleSession(
        document: document,
        review: .ready(
          ReviewBatch(
            articleID: document.id, baseRevisionID: UUID(), changes: [suggestion]))))
    var incorrect = suggestion
    incorrect.beforeBlock?.text = RichTextContent(string: "Wrong source")
    XCTAssertThrowsError(
      try ArticleSession(
        document: document,
        review: .ready(
          ReviewBatch(
            articleID: document.id, baseRevisionID: document.revisionID, changes: [incorrect]))))
    XCTAssertThrowsError(
      try ArticleSession(document: document, review: .running(ReviewRequest(article: document))))
  }

  private func pending(_ document: Article, changes: [ReviewChange]) throws -> ArticleSession {
    try ArticleSession(
      document: document,
      review: .ready(
        ReviewBatch(articleID: document.id, baseRevisionID: document.revisionID, changes: changes)))
  }

  func testReadingAndChoosingLeaveTheSourceUntilFinalization() throws {
    let document = article()
    let suggestion = change(for: document)
    let session = try pending(document, changes: [suggestion])
    try session.rewrite(changeID: suggestion.id, text: "My own words", reason: "Voice")
    XCTAssertEqual(session.document, document.normalized())
    XCTAssertTrue(session.rounds.isEmpty)
    let examples = try session.finishReview()
    XCTAssertEqual(examples.first?.after, "My own words")
    XCTAssertEqual(examples.first?.reason, "Voice")
    XCTAssertEqual(session.document.blocks[0].plainText, "My own words")
    XCTAssertTrue(session.document.marks.isEmpty)
    XCTAssertNotEqual(session.document.revisionID, document.revisionID)
    XCTAssertEqual(session.review, .idle)
    XCTAssertThrowsError(try session.finishReview())
    let round = try XCTUnwrap(session.rounds.first)
    XCTAssertEqual(round.source, document.normalized())
    XCTAssertEqual(round.result, session.document)
    XCTAssertEqual(round.changes.first?.after, "After")
    XCTAssertEqual(round.changes.first?.decision, .rewrite)
    try session.updateDocument { $0.blocks[0].text = RichTextContent(string: "Later") }
    XCTAssertEqual(session.rounds[0].result.blocks[0].plainText, "My own words")
  }

  func testIndependentTextSuggestionsKeepUnchangedUnicodeAndFormatting() throws {
    let heading = ParagraphStyle(kind: .heading(level: 2))
    let original = "天刚亮👩🏽‍🚀，我已经在等他们了。"
    let marked = (original as NSString).range(of: "👩🏽‍🚀")
    let expectedStyle = TextStyle(bold: true)
    let block = DocumentBlock(
      text: RichTextContent(
        string: original,
        runs: [RichTextRun(range: marked, style: expectedStyle, paragraphStyle: heading)],
        paragraphStyle: heading))
    let article = Article(title: "日记", blocks: [block])
    let changes = [
      ReviewChange(
        blockID: block.id, before: original,
        after: "天亮👩🏽‍🚀，我已经在等他们了。", explanation: ""),
      ReviewChange(blockID: block.id, before: "他们了", after: "他", explanation: ""),
    ]
    for includeRemaining in [false, true] {
      let session = try pending(article, changes: changes)
      try session.decide(.accept, changeID: changes[0].id)
      _ = try session.finishReview(acceptRemaining: includeRemaining)
      let text = session.document.blocks[0].text
      XCTAssertEqual(text.string, includeRemaining ? "天亮👩🏽‍🚀，我已经在等他。" : changes[0].after)
      XCTAssertEqual(text.runs.first?.range, (text.string as NSString).range(of: "👩🏽‍🚀"))
      XCTAssertEqual(text.runs.first?.style, expectedStyle)
      XCTAssertEqual(text.paragraphStyle, heading)
      XCTAssertEqual(session.rounds[0].changes[1].decision, includeRemaining ? .accept : .keep)
    }
    let kept = try pending(article, changes: changes)
    try kept.decide(.keep, changeID: changes[0].id)
    _ = try kept.finishReview(acceptRemaining: true)
    XCTAssertEqual(kept.document.blocks[0].plainText, "天刚亮👩🏽‍🚀，我已经在等他。")
  }

  func testTableAndImageSuggestionsComposePerTarget() throws {
    let table = DocumentBlock(
      table: TableContent(rows: [["Day", "Unused", "Note"], ["Fri", "x", "Long"]]))
    let image = DocumentBlock(image: ImageContent(assetName: "before", caption: "Old caption"))
    let document = Article(title: "", blocks: [image, table])
    var newImage = image
    newImage.image?.assetName = "new"
    var newRow = table
    newRow.table?.rowIDs.append(UUID())
    newRow.table?.rows.append(["Sat", "y", "Second"])
    var newColumns = table
    newColumns.table?.columnIDs.remove(at: 1)
    newColumns.table?.rows = [["Day", "Note"], ["Fri", "Long"]]
    var newText = table
    newText.table?.rows[1][2] = "Short"
    let changes = [
      ReviewChange(
        blockID: image.id, kind: .image, before: "before", after: "new", explanation: "",
        afterBlock: newImage),
      ReviewChange(blockID: image.id, before: "Old caption", after: "New caption", explanation: ""),
      ReviewChange(
        blockID: table.id, kind: .tableColumn, before: "3 columns", after: "2 columns",
        explanation: "", afterBlock: newColumns),
      ReviewChange(
        blockID: table.id, kind: .tableRow, before: "2 rows", after: "3 rows", explanation: "",
        afterBlock: newRow),
      ReviewChange(
        blockID: table.id, before: "Long", after: "Short", explanation: "", afterBlock: newText),
    ]
    for choices in [changes, Array(changes.reversed())] {
      let session = try pending(document, changes: choices)
      try session.rewrite(changeID: changes[4].id, text: "My note", reason: "")
      _ = try session.finishReview(acceptRemaining: true)
      XCTAssertEqual(
        session.document.blocks[0].image, ImageContent(assetName: "new", caption: "New caption"))
      XCTAssertEqual(
        session.document.blocks[1].table?.rows,
        [["Day", "Note"], ["Fri", "My note"], ["Sat", "Second"]])
      XCTAssertEqual(session.document.blocks[1].table?.rowIDs, newRow.table?.rowIDs)
      XCTAssertEqual(session.document.blocks[1].table?.columnIDs, newColumns.table?.columnIDs)
    }
  }

  func testConflictingChoicesLeaveTheReviewIntactAndRetryable() throws {
    let document = article()
    let first = change(for: document, after: "Now")
    let second = change(for: document, after: "Then")
    let session = try pending(document, changes: [first, second])
    let initialReview = session.review
    XCTAssertThrowsError(try session.finishReview(acceptRemaining: true))
    XCTAssertEqual(session.document, document.normalized())
    XCTAssertEqual(session.review, initialReview)
    XCTAssertTrue(session.rounds.isEmpty)
    try session.decide(.keep, changeID: second.id)
    _ = try session.finishReview(acceptRemaining: true)
    XCTAssertEqual(session.document.blocks[0].plainText, "Now")
  }

  func testUnmarkedDraftCanRequestAnnotationsAndGetAnEmptyResult() async throws {
    var document = article()
    document.marks = [:]
    let session = try ArticleSession(document: document)
    let provider = ControlledReviewProvider()
    try session.beginReview(using: provider)
    let request = await provider.nextRequest()
    XCTAssertTrue(request.article.marks.isEmpty)
    await provider.resolve(request.id, changes: [])
    let completed = await eventually { session.review == .noSuggestions }
    XCTAssertTrue(completed)
    XCTAssertEqual(session.document, document.normalized())
    let blank = try ArticleSession(
      document: Article(title: "Only a title", blocks: [DocumentBlock()]))
    XCTAssertThrowsError(try blank.beginReview(using: provider))
  }

  func testCancelledNonCooperativeResultCannotReplaceNewRequest() async throws {
    let provider = ControlledReviewProvider()
    let session = try ArticleSession(document: article())
    try session.beginReview(using: provider)
    let first = await provider.nextRequest()
    session.cancelReview()
    try session.beginReview(using: provider)
    let second = await provider.nextRequest()
    await provider.resolve(first.id, changes: [change(for: first.article, after: "Old")])
    for _ in 0..<30 { await Task.yield() }
    XCTAssertEqual(session.review, .running(second))
    await provider.resolve(second.id, changes: [change(for: second.article, after: "New")])
    let ready = await eventually { session.review.isReady }
    XCTAssertTrue(ready)
    XCTAssertEqual(session.review.changes.first?.after, "New")
  }

  func testDocumentEditInvalidatesInFlightReview() async throws {
    let provider = ControlledReviewProvider()
    let session = try ArticleSession(document: article())
    try session.beginReview(using: provider)
    let request = await provider.nextRequest()
    try session.updateDocument { $0.blocks[0].text = RichTextContent(string: "Changed locally") }
    await provider.resolve(request.id, changes: [change(for: request.article)])
    for _ in 0..<30 { await Task.yield() }
    XCTAssertEqual(session.review, .idle)
    XCTAssertEqual(session.document.blocks[0].plainText, "Changed locally")
  }

  func testProviderCannotInjectDecisionsOrForeignTargets() async throws {
    for foreignTarget in [false, true] {
      let provider = ControlledReviewProvider()
      let session = try ArticleSession(document: article())
      try session.beginReview(using: provider)
      let request = await provider.nextRequest()
      var suggestion = change(for: request.article)
      if foreignTarget { suggestion.blockID = UUID() } else { suggestion.decision = .accept }
      await provider.resolve(request.id, changes: [suggestion])
      let failed = await eventually { session.review.failure != nil }
      XCTAssertTrue(failed)
      XCTAssertEqual(session.document, request.article)
    }
  }

  private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<1000 {
      if condition() { return true }
      await Task.yield()
    }
    return condition()
  }
}

private actor ControlledReviewProvider: ReviewProviding {
  private var queued: [ReviewRequest] = []
  private var waiting: [CheckedContinuation<ReviewRequest, Never>] = []
  private var results: [UUID: CheckedContinuation<[ReviewChange], Never>] = [:]

  func changes(for request: ReviewRequest) async throws -> [ReviewChange] {
    await withCheckedContinuation { continuation in
      results[request.id] = continuation
      if waiting.isEmpty {
        queued.append(request)
      } else {
        waiting.removeFirst().resume(returning: request)
      }
    }
  }

  func nextRequest() async -> ReviewRequest {
    if !queued.isEmpty { return queued.removeFirst() }
    return await withCheckedContinuation { waiting.append($0) }
  }

  func resolve(_ id: UUID, changes: [ReviewChange]) {
    results.removeValue(forKey: id)?.resume(returning: changes)
  }
}
