import Foundation

/// One open article's writable owner. Views observe immutable value snapshots from this session.
@MainActor
public final class ArticleSession {
  public private(set) var document: Article
  public private(set) var versions: [ArticleVersion]
  public private(set) var rounds: [AnnotationRound]
  public private(set) var review: ReviewState

  private var observers: [UUID: @MainActor () -> Void] = [:]
  private var reviewTask: Task<Void, Never>?

  public init(
    document: Article, versions: [ArticleVersion] = [], rounds: [AnnotationRound] = [],
    review: ReviewState = .idle
  ) throws {
    let document = document.normalized()
    let review: ReviewState = {
      if case .ready(let batch) = review { .ready(batch.normalized()) } else { review }
    }()
    try document.validate()
    guard Set(versions.map(\.id)).count == versions.count,
      Set(rounds.map(\.id)).count == rounds.count
    else { throw EditingError.invalidDocument }
    var revisions = [document.revisionID: document]
    func checkSnapshot(_ snapshot: Article) throws {
      guard snapshot.id == document.id else { throw EditingError.invalidDocument }
      try snapshot.validate()
      // Snapshot labels may differ; a revision identity must always resolve to one document value.
      if let existing = revisions[snapshot.revisionID], existing != snapshot {
        throw EditingError.invalidDocument
      }
      revisions[snapshot.revisionID] = snapshot
    }
    for version in versions { try checkSnapshot(version.document) }
    for round in rounds {
      try checkSnapshot(round.source)
      try checkSnapshot(round.result)
      guard !round.changes.isEmpty, round.changes.allSatisfy({ $0.decision != nil }) else {
        throw EditingError.invalidReview
      }
      try ReviewBatch(
        articleID: document.id, baseRevisionID: round.source.revisionID, changes: round.changes
      ).validate(against: round.source)
    }
    switch review {
    case .ready(let batch): try batch.validate(against: document)
    case .running: throw EditingError.invalidReview
    case .idle, .noSuggestions, .failed: break
    }
    self.document = document
    self.versions = versions
    self.rounds = rounds
    self.review = review
  }

  deinit { reviewTask?.cancel() }

  @discardableResult
  public func observe(_ observer: @escaping @MainActor () -> Void) -> UUID {
    let token = UUID()
    observers[token] = observer
    return token
  }

  public func removeObserver(_ token: UUID) { observers.removeValue(forKey: token) }

  /// Stage and validate a value before publishing it. Document edits invalidate previous review.
  public func updateDocument(
    basedOn revisionID: UUID? = nil, _ mutate: (inout Article) -> Void
  ) throws {
    if let revisionID, revisionID != document.revisionID { throw EditingError.staleRevision }
    var next = document
    mutate(&next)
    next = next.normalized()
    guard next.id == document.id, next.revisionID == document.revisionID,
      next.updatedAt == document.updatedAt
    else { throw EditingError.invalidDocument }
    try next.validate()
    guard next != document else { return }
    next.revisionID = UUID()
    next.updatedAt = Date()
    reviewTask?.cancel()
    reviewTask = nil
    review = .idle
    document = next
    notify()
  }

  @discardableResult
  public func saveVersion(title: String, date: Date = Date()) -> ArticleVersion {
    let version = ArticleVersion(title: title, date: date, document: document)
    versions.append(version)
    notify()
    return version
  }

  public func beginReview(using provider: any ReviewProviding) throws {
    guard !review.isRunning, !review.isReady, document.canRequestAnnotations else {
      throw EditingError.invalidReview
    }
    let request = ReviewRequest(article: document)
    review = .running(request)
    notify()
    reviewTask = Task { [weak self] in
      do {
        let changes = try await provider.changes(for: request)
        guard !Task.isCancelled, let self, self.isCurrent(request) else { return }
        let batch = ReviewBatch(
          articleID: request.article.id, baseRevisionID: request.article.revisionID,
          changes: changes
        ).normalized()
        try batch.validate(against: self.document)
        guard changes.allSatisfy({ $0.decision == nil && $0.rewrittenText.isEmpty }) else {
          throw EditingError.invalidReview
        }
        self.review = changes.isEmpty ? .noSuggestions : .ready(batch)
        self.reviewTask = nil
        self.notify()
      } catch {
        guard !Task.isCancelled, let self, self.isCurrent(request) else { return }
        self.review = .failed(error.localizedDescription)
        self.reviewTask = nil
        self.notify()
      }
    }
  }

  public func cancelReview() {
    guard review.isRunning || review.isReady else { return }
    reviewTask?.cancel()
    reviewTask = nil
    review = .idle
    notify()
  }

  public func decide(_ decision: ReviewDecision, changeID: UUID) throws {
    guard decision != .rewrite else { throw EditingError.invalidReview }
    try updateChange(changeID) {
      $0.decision = decision
      $0.rewrittenText = ""
    }
  }

  public func updateReason(_ reason: String, changeID: UUID) throws {
    try updateChange(changeID) { $0.reason = reason }
  }

  public func rewrite(changeID: UUID, text: String, reason: String) throws {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw EditingError.invalidReview
    }
    try updateChange(changeID) {
      $0.decision = .rewrite
      $0.rewrittenText = text
      $0.reason = reason
    }
  }

  /// Apply the entire selection once. A failed merge leaves the document and pending batch intact.
  public func finishReview(acceptRemaining: Bool = false) throws -> [RewriteExample] {
    guard case .ready(var batch) = review, !batch.changes.isEmpty else {
      throw EditingError.invalidReview
    }
    try batch.validate(against: document)
    for index in batch.changes.indices where batch.changes[index].decision == nil {
      batch.changes[index].decision = acceptRemaining ? .accept : .keep
    }
    let source = document
    let selected = Dictionary(
      grouping: batch.changes.filter { $0.decision != .keep }, by: \.blockID)
    var result = source
    result.blocks = try source.blocks.map { block in
      guard let changes = selected[block.id] else { return block }
      return try block.applyingAnnotations(changes)
    }
    result.marks.removeAll()
    let now = Date()
    if result != source {
      result.revisionID = UUID()
      result.updatedAt = now
    }
    try result.validate()

    let examples = batch.changes.compactMap { change -> RewriteExample? in
      guard let decision = change.decision else { return nil }
      let after: String
      switch decision {
      case .accept: after = change.after
      case .keep: after = change.before
      case .rewrite: after = change.rewrittenText
      }
      return RewriteExample(
        articleID: source.id, blockID: change.blockID, before: change.before, after: after,
        decision: decision, reason: change.reason.isEmpty ? change.explanation : change.reason,
        tag: change.kind.rawValue)
    }
    rounds.append(
      AnnotationRound(id: UUID(), date: now, source: source, result: result, changes: batch.changes)
    )
    document = result
    review = .idle
    notify()
    return examples
  }

  private func updateChange(_ id: UUID, _ mutate: (inout ReviewChange) -> Void) throws {
    guard case .ready(var batch) = review,
      let index = batch.changes.firstIndex(where: { $0.id == id })
    else { throw EditingError.invalidReview }
    mutate(&batch.changes[index])
    try batch.validate(against: document)
    review = .ready(batch)
    notify()
  }

  private func isCurrent(_ request: ReviewRequest) -> Bool {
    guard case .running(let active) = review else { return false }
    return active.id == request.id && document.id == request.article.id
      && document.revisionID == request.article.revisionID
  }

  private func notify() {
    for observer in Array(observers.values) { observer() }
  }
}
