public enum DiffSegment: Equatable, Sendable {
  case unchanged(String)
  case inserted(String)
  case removed(String)
  case replaced(before: String, after: String)
}

public protocol TextDiffing: Sendable {
  /// 片段按阅读顺序排列，拼接两侧应分别还原各稿的原始 UTF-8。
  func compare(_ before: String, to after: String) -> [DiffSegment]
}
