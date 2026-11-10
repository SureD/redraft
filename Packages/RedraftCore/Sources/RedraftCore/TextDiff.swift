public enum DiffSegment: Equatable, Sendable {
  case unchanged(String)
  case inserted(String)
  case removed(String)
  case replaced(before: String, after: String)
}

public protocol TextDiffing: Sendable {
  /// 按阅读顺序分段，拼回两侧应分别得到两稿的原始 UTF-8。
  func compare(_ before: String, to after: String) -> [DiffSegment]
}
