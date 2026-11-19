import Foundation

/// One open article's writable owner. Views observe immutable value snapshots from this session.
/// This in-memory implementation does not provide persistence, AI or review composition.
@MainActor
public final class ArticleSession {
  public private(set) var document: Article
  public private(set) var versions: [ArticleVersion]
  public private(set) var review: ReviewState

  private var observers: [UUID: @MainActor () -> Void] = [:]
  private var reviewTask: Task<Void, Never>?

  public init(
    document: Article, versions: [ArticleVersion] = [], review: ReviewState = .idle
  ) throws {
    let document = document.normalized()
    let review: ReviewState = {
      if case .ready(let batch) = review { .ready(batch.normalized()) } else { review }
    }()
    try document.validate()
    guard Set(versions.map(\.id)).count == versions.count else {
      throw EditingError.invalidDocument
    }
    var revisions = [document.revisionID: document]
    for version in versions {
      guard version.document.id == document.id else { throw EditingError.invalidDocument }
      try version.document.validate()
      // Snapshot labels may differ; a revision identity must always resolve to one document value.
      if let existing = revisions[version.revisionID], existing != version.document {
        throw EditingError.invalidDocument
      }
      revisions[version.revisionID] = version.document
    }
    switch review {
    case .ready(let batch): try batch.validate(against: document)
    case .running: throw EditingError.invalidReview
    case .idle, .failed: break
    }
    self.document = document
    self.versions = versions
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
    guard !review.isRunning, !review.isReady, !document.marks.isEmpty else {
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
        self.review = changes.isEmpty ? .idle : .ready(batch)
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
    guard review.isRunning else { return }
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

  /// Preview completion records choices only; applying/merging suggestions remains unimplemented.
  public func finishPreviewReview() throws -> [RewriteExample] {
    guard case .ready(let batch) = review, !batch.changes.isEmpty else {
      throw EditingError.invalidReview
    }
    try batch.validate(against: document)
    guard batch.changes.allSatisfy({ $0.decision != nil }) else {
      throw EditingError.unresolvedChanges
    }
    let examples = batch.changes.compactMap { change -> RewriteExample? in
      guard let decision = change.decision else { return nil }
      let after: String
      switch decision {
      case .accept: after = change.after
      case .keep: after = change.before
      case .rewrite: after = change.rewrittenText
      }
      return RewriteExample(
        articleID: document.id, blockID: change.blockID, before: change.before, after: after,
        decision: decision, reason: change.reason.isEmpty ? change.explanation : change.reason,
        tag: change.kind.rawValue)
    }
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
