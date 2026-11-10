public enum DiffSegment: Equatable, Sendable {
  case unchanged(String)
  case inserted(String)
  case removed(String)
  case replaced(before: String, after: String)
}

public protocol TextDiffing {
  /// 按阅读顺序覆盖两稿全文，保留空白和标点。
  func compare(_ before: String, to after: String) -> [DiffSegment]
}
