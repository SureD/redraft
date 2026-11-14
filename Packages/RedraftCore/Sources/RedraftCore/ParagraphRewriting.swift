public protocol ParagraphRewriting: Sendable {
  /// 返回完整的改写段落。
  func rewrite(_ paragraph: String, instruction: String) async throws -> String
}
