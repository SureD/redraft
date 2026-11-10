import Foundation

/// 文档在同一版本生成的完整快照和导出文本。
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

  /// 整份归档一起提交。失败时保留上次成功保存的内容。
  func save(_ archive: ArticleArchive) async throws
}
