import AppKit
import RedraftCore

/// Native read-only rendering for the review inspector; editing belongs to BlockNote.
@MainActor
enum RichTextBridge {
  static func attributedString(from content: RichTextContent) -> NSAttributedString {
    let result = NSMutableAttributedString(
      string: content.string,
      attributes: attributes(style: content.defaultStyle, paragraph: content.paragraphStyle))
    for run in content.runs
    where run.range.location >= 0 && run.range.length >= 0
      && run.range.location <= result.length
      && run.range.length <= result.length - run.range.location
    {
      result.setAttributes(
        attributes(style: run.style, paragraph: run.paragraphStyle), range: run.range)
    }
    return result
  }

  private static func attributes(style: TextStyle, paragraph: ParagraphStyle) -> [NSAttributedString
    .Key:
    Any]
  {
    let size = style.fontSize ?? defaultSize(for: paragraph.kind)
    let base =
      style.fontFamily.flatMap { NSFont(name: $0, size: size) }
      ?? NSFont.systemFont(ofSize: size)
    var traits: NSFontTraitMask = []
    if style.bold { traits.insert(.boldFontMask) }
    if style.italic { traits.insert(.italicFontMask) }
    let font = NSFontManager.shared.convert(base, toHaveTrait: traits)
    let nativeParagraph = NSMutableParagraphStyle()
    nativeParagraph.alignment = nativeAlignment(paragraph.alignment)
    nativeParagraph.headIndent = paragraph.headIndent
    nativeParagraph.firstLineHeadIndent = paragraph.firstLineHeadIndent
    nativeParagraph.tailIndent = paragraph.tailIndent
    nativeParagraph.lineSpacing = paragraph.lineSpacing
    nativeParagraph.lineHeightMultiple = paragraph.lineHeightMultiple
    nativeParagraph.paragraphSpacing = paragraph.paragraphSpacing
    nativeParagraph.paragraphSpacingBefore = paragraph.paragraphSpacingBefore
    if let list = paragraph.list {
      let nativeList = NSTextList(
        markerFormat: list.marker == .decimal ? .decimal : .disc, options: 0)
      nativeList.startingItemNumber = list.startingItemNumber
      nativeParagraph.textLists = [nativeList]
    }
    var result: [NSAttributedString.Key: Any] = [
      .font: font, .foregroundColor: color(style.foreground), .paragraphStyle: nativeParagraph,
    ]
    if style.underline { result[.underlineStyle] = NSUnderlineStyle.single.rawValue }
    if style.strikethrough { result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
    if let background = style.background { result[.backgroundColor] = color(background) }
    return result
  }

  private static func defaultSize(for kind: ParagraphKind) -> Double {
    switch kind {
    case .body: 17
    case .heading(let level): [28.0, 23.0, 19.0][min(2, max(0, level - 1))]
    }
  }

  private static func color(_ value: TextColor) -> NSColor {
    switch value {
    case .primary: PaperTheme.textColor
    case .secondary: .secondaryLabelColor
    case .accent: .controlAccentColor
    case .highlight: .systemYellow
    case .rgba(let red, let green, let blue, let alpha):
      NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
  }

  private static func nativeAlignment(_ value: TextAlignment) -> NSTextAlignment {
    switch value {
    case .natural: .natural
    case .left: .left
    case .center: .center
    case .right: .right
    case .justified: .justified
    }
  }

}
