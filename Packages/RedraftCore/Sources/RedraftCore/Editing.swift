import Foundation

/// Editing and display share a single structured snapshot contract.
public typealias Draft = Article

public enum EditingError: Error, Equatable, Sendable {
  case invalidRange, invalidTarget, invalidDocument, staleRevision, invalidReview, unresolvedChanges
}

public struct TextEdit: Equatable, Sendable {
  public let blockID: UUID
  public let range: NSRange
  public let replacement: String

  public init(blockID: UUID, range: NSRange, replacement: String) {
    self.blockID = blockID
    self.range = range
    self.replacement = replacement
  }
}

public enum EditSource: Equatable, Sendable { case author, ai }

/// A future persistent document engine exposes the same snapshots as ArticleSession.
public protocol ArticleEditing {
  init(articleID: UUID)
  init(snapshot: Data) throws
  var current: Article { get }
  var revisionIDs: [UUID] { get }
  func draft(at revisionID: UUID) throws -> Article

  /// Coordinates are block-local UTF-16 in the base revision, never flattened-document offsets.
  /// Invalid/overlapping ranges or stale revisions fail atomically without changing content/history.
  mutating func apply(_ edits: [TextEdit], basedOn revisionID: UUID, source: EditSource) throws
    -> Article
  func archive() throws -> ArticleArchive
}
