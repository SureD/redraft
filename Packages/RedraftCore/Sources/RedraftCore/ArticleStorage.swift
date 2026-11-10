import Foundation

public protocol ArticleStorage: Sendable {
  func articleIDs() async throws -> [UUID]

  /// 文章不存在时返回 nil，读取失败时抛错。
  func loadSnapshot(for articleID: UUID) async throws -> Data?

  /// 保存同一版本的完整历史快照与 Markdown 导出。
  func save(snapshot: Data, markdown: String, for articleID: UUID) async throws
}
