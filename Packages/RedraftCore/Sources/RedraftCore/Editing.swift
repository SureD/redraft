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

  /// 选区以 UTF-16 计数，两端必须落在完整字符的边界。
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

  /// 以原稿坐标原子提交一轮修改，保留原稿并返回新的当前版本。
  /// 过期稿抛出 staleRevision，越界、重叠或同起点的编辑抛出 invalidRange。
  mutating func apply(_ edits: [TextEdit], basedOn revisionID: UUID, source: EditSource) throws
    -> Draft

  /// 快照包含当前稿和完整版本历史。
  func snapshot() throws -> Data
}
