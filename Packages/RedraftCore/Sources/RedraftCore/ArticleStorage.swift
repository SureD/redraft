import Foundation

/// 快照与 Markdown 对应同一文章版本。
public struct ArticleArchive: Sendable {
  public let articleID: UUID
  public let snapshot: Data
  public let markdown: String

  public init(articleID: UUID, snapshot: Data, markdown: String) {
    self.articleID = articleID
    self.snapshot = snapshot
    self.markdown = markdown
  }
}

public protocol ArticleStorage: Sendable {
  func articleIDs() async throws -> [UUID]

  /// 文章不存在时返回 nil，读取失败时抛错。
  func loadSnapshot(for articleID: UUID) async throws -> Data?

  /// 保存失败时保留上次成功保存的完整归档。
  func save(_ archive: ArticleArchive) async throws
}
