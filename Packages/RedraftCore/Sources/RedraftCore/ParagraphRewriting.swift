public protocol ParagraphRewriting: Sendable {
  /// 返回送审稿中这一段的改写文本。
  func rewrite(_ paragraph: String, instruction: String) async throws -> String
}
