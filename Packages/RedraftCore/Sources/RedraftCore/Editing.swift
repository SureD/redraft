import Foundation

public struct Draft: Equatable, Sendable {
  public let articleID: UUID
  public let revisionID: UUID
  public let text: String
  public let source: EditSource

  public init(articleID: UUID, revisionID: UUID, text: String, source: EditSource) {
    self.articleID = articleID
    self.revisionID = revisionID
    self.text = text
    self.source = source
  }

  /// 选区越界或截断完整字符时抛出 invalidRange。
  public func range(forUTF16 selection: NSRange) throws -> Range<String.Index> {
    let count = text.utf16.count
    guard selection.location >= 0, selection.location <= count,
      selection.length >= 0, selection.length <= count - selection.location,
      let range = Range(selection, in: text),
      range.lowerBound.samePosition(in: text) != nil,
      range.upperBound.samePosition(in: text) != nil
    else { throw EditingError.invalidRange }
    return range
  }
}

public enum EditingError: Error {
  case invalidRange
  case staleRevision
}

public struct TextEdit: Equatable, Sendable {
  public let range: NSRange
  public let replacement: String

  public init(range: NSRange, replacement: String) {
    self.range = range
    self.replacement = replacement
  }
}

public enum EditSource: Equatable, Sendable {
  case author
  case ai
}

public protocol ArticleEditing {
  init(articleID: UUID)
  init(snapshot: Data) throws

  var current: Draft { get }

  /// 从初稿到当前稿的版本编号。
  var revisionIDs: [UUID] { get }
  func draft(at revisionID: UUID) throws -> Draft

  /// 修改后产生新的当前版本并保留原稿，失败时正文与历史保持原状。
  /// 所有范围使用基准稿的 UTF-16 坐标。基准版本过期时抛出 staleRevision。
  /// 范围越界、截断完整字符、重叠或起点相同时抛出 invalidRange。
  mutating func apply(_ edits: [TextEdit], basedOn revisionID: UUID, source: EditSource) throws
    -> Draft

  /// 归档包含当前稿及完整版本历史。
  func archive() throws -> ArticleArchive
}
