import Foundation

public enum ChangeKind: String, Equatable, Codable, Sendable {
  case text, image, tableRow, tableColumn
}
public enum ReviewDecision: String, CaseIterable, Equatable, Codable, Sendable {
  case accept, keep, rewrite
}

public struct ReviewChange: Identifiable, Equatable, Codable, Sendable {
  public var id: UUID
  public var blockID: UUID
  public var kind: ChangeKind
  public var before: String
  public var after: String
  public var explanation: String
  public var decision: ReviewDecision?
  public var rewrittenText: String
  public var reason: String
  public var beforeBlock: DocumentBlock?
  public var afterBlock: DocumentBlock?

  public init(
    id: UUID = UUID(), blockID: UUID, kind: ChangeKind = .text, before: String, after: String,
    explanation: String, decision: ReviewDecision? = nil, rewrittenText: String = "",
    reason: String = "", beforeBlock: DocumentBlock? = nil, afterBlock: DocumentBlock? = nil
  ) {
    self.id = id
    self.blockID = blockID
    self.kind = kind
    self.before = before
    self.after = after
    self.explanation = explanation
    self.decision = decision
    self.rewrittenText = rewrittenText
    self.reason = reason
    self.beforeBlock = beforeBlock
    self.afterBlock = afterBlock
  }
}

public struct ReviewRequest: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let article: Article

  public init(id: UUID = UUID(), article: Article) {
    self.id = id
    self.article = article
  }
}

public struct ReviewBatch: Equatable, Codable, Sendable {
  public let articleID: UUID
  public let baseRevisionID: UUID
  public var changes: [ReviewChange]

  public init(articleID: UUID, baseRevisionID: UUID, changes: [ReviewChange]) {
    self.articleID = articleID
    self.baseRevisionID = baseRevisionID
    self.changes = changes
  }

  public func normalized() -> ReviewBatch {
    var result = self
    result.changes = changes.map { change in
      var value = change
      value.beforeBlock = value.beforeBlock?.normalized()
      value.afterBlock = value.afterBlock?.normalized()
      return value
    }
    return result
  }

  public func validate(against article: Article) throws {
    guard articleID == article.id, baseRevisionID == article.revisionID else {
      throw EditingError.staleRevision
    }
    guard Set(changes.map(\.id)).count == changes.count else {
      throw EditingError.invalidReview
    }
    for change in changes {
      guard article.marks.isEmpty || article.marks[change.blockID] != nil,
        let block = article.blocks.first(where: { $0.id == change.blockID })
      else {
        throw EditingError.invalidTarget
      }
      if let before = change.beforeBlock, before != block { throw EditingError.invalidReview }
      if let after = change.afterBlock {
        guard after.id == block.id else { throw EditingError.invalidTarget }
        try after.validate()
      }
      if change.decision == .rewrite,
        change.kind != .text
          || change.rewrittenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        throw EditingError.invalidReview
      }
    }
  }
}

/// A completed reading pass. Source and result stay available even if the author edits again.
public struct AnnotationRound: Identifiable, Equatable, Codable, Sendable {
  public let id: UUID
  public let date: Date
  public let source: Article
  public let result: Article
  public let changes: [ReviewChange]
}

public enum ReviewState: Equatable, Sendable {
  case idle
  case noSuggestions
  case running(ReviewRequest)
  case ready(ReviewBatch)
  case failed(String)

  public var changes: [ReviewChange] {
    if case .ready(let batch) = self { batch.changes } else { [] }
  }
  public var isRunning: Bool { if case .running = self { true } else { false } }
  public var isReady: Bool { if case .ready = self { true } else { false } }
  public var failure: String? { if case .failed(let message) = self { message } else { nil } }
}

public protocol ReviewProviding: Sendable {
  func changes(for request: ReviewRequest) async throws -> [ReviewChange]
}

public struct RewriteExample: Identifiable, Equatable, Codable, Sendable {
  public let id: UUID
  public let articleID: UUID
  public let blockID: UUID?
  public let before: String
  public let after: String
  public let decision: ReviewDecision
  public let reason: String
  public let tag: String

  public init(
    id: UUID = UUID(), articleID: UUID, blockID: UUID? = nil, before: String, after: String,
    decision: ReviewDecision, reason: String, tag: String
  ) {
    self.id = id
    self.articleID = articleID
    self.blockID = blockID
    self.before = before
    self.after = after
    self.decision = decision
    self.reason = reason
    self.tag = tag
  }
}
