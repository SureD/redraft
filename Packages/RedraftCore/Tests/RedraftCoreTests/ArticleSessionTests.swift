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

  func testReviewDecisionsAreSessionStateAndPreviewDoesNotRewriteDocument() throws {
    let document = article()
    let suggestion = change(for: document)
    let session = try ArticleSession(
      document: document,
      review: .ready(
        ReviewBatch(
          articleID: document.id, baseRevisionID: document.revisionID, changes: [suggestion])))
    XCTAssertThrowsError(try session.finishPreviewReview()) {
      XCTAssertEqual($0 as? EditingError, .unresolvedChanges)
    }
    try session.rewrite(changeID: suggestion.id, text: "My own words", reason: "Voice")
    let result = try session.finishPreviewReview()
    XCTAssertEqual(result.count, 1)
    XCTAssertEqual(result[0].after, "My own words")
    XCTAssertEqual(result[0].reason, "Voice")
    XCTAssertEqual(session.document, document.normalized())
    XCTAssertEqual(session.review, .idle)
    XCTAssertThrowsError(try session.finishPreviewReview())
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
