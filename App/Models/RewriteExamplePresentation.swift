import RedraftCore

extension RewriteExample {
  /// Core classification stays language-neutral; user-authored tags keep their original text.
  var displayTag: String {
    guard let kind = ChangeKind(rawValue: tag) else { return tag }
    return switch kind {
    case .text: "表达"
    case .image: "图片"
    case .tableRow: "表格行"
    case .tableColumn: "表格列"
    }
  }
}
