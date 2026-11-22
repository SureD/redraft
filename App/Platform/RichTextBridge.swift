import AppKit
import RedraftCore

extension NSAttributedString.Key {
  /// Paragraph semantics survive native editing without inferring meaning from font size.
  static let redraftHeadingLevel = NSAttributedString.Key("dev.redraft.headingLevel")
}

/// AppKit is a rendering/input representation. Only Core values cross the document boundary.
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

  static func content(from value: NSAttributedString) -> RichTextContent {
    var runs: [RichTextRun] = []
    value.enumerateAttributes(in: NSRange(location: 0, length: value.length)) {
      attributes, range, _ in
      runs.append(
        RichTextRun(
          range: range, style: textStyle(from: attributes),
          paragraphStyle: paragraphStyle(from: attributes)))
    }
    return RichTextContent(
      string: value.string, runs: runs,
      defaultStyle: runs.first?.style ?? TextStyle(),
      paragraphStyle: runs.first?.paragraphStyle ?? ParagraphStyle()
    ).normalized()
  }

  static func attributes(style: TextStyle, paragraph: ParagraphStyle) -> [NSAttributedString.Key:
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
      .redraftHeadingLevel: headingLevel(paragraph.kind),
    ]
    if style.underline { result[.underlineStyle] = NSUnderlineStyle.single.rawValue }
    if style.strikethrough { result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
    if let background = style.background { result[.backgroundColor] = color(background) }
    return result
  }

  static func textStyle(from attributes: [NSAttributedString.Key: Any]) -> TextStyle {
    let paragraph = paragraphStyle(from: attributes)
    let font = attributes[.font] as? NSFont ?? .systemFont(ofSize: defaultSize(for: paragraph.kind))
    let traits = NSFontManager.shared.traits(of: font)
    let systemFamily = NSFont.systemFont(ofSize: font.pointSize).familyName
    return TextStyle(
      fontFamily: font.familyName == systemFamily ? nil : font.familyName,
      fontSize: font.pointSize == defaultSize(for: paragraph.kind) ? nil : font.pointSize,
      bold: traits.contains(.boldFontMask), italic: traits.contains(.italicFontMask),
      underline: (attributes[.underlineStyle] as? Int ?? 0) != 0,
      strikethrough: (attributes[.strikethroughStyle] as? Int ?? 0) != 0,
      foreground: semanticColor(attributes[.foregroundColor] as? NSColor ?? PaperTheme.textColor),
      background: (attributes[.backgroundColor] as? NSColor).map(semanticColor))
  }

  static func paragraphStyle(from attributes: [NSAttributedString.Key: Any]) -> ParagraphStyle {
    let native = attributes[.paragraphStyle] as? NSParagraphStyle ?? NSParagraphStyle()
    let level = attributes[.redraftHeadingLevel] as? Int ?? 0
    let list = native.textLists.first.map {
      ListStyle(
        marker: $0.markerFormat == .decimal ? .decimal : .bullet,
        startingItemNumber: $0.startingItemNumber)
    }
    return ParagraphStyle(
      kind: level > 0 ? .heading(level: level) : .body,
      alignment: semanticAlignment(native.alignment), headIndent: native.headIndent,
      firstLineHeadIndent: native.firstLineHeadIndent, tailIndent: native.tailIndent,
      lineSpacing: native.lineSpacing, paragraphSpacing: native.paragraphSpacing,
      paragraphSpacingBefore: native.paragraphSpacingBefore,
      lineHeightMultiple: native.lineHeightMultiple,
      list: list)
  }

  static func headingLevel(_ kind: ParagraphKind) -> Int {
    if case .heading(let level) = kind { return level }
    return 0
  }

  static func defaultSize(for kind: ParagraphKind) -> Double {
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

  private static func semanticColor(_ value: NSColor) -> TextColor {
    if value.isEqual(PaperTheme.textColor) || value.isEqual(NSColor.labelColor) { return .primary }
    if value.isEqual(NSColor.secondaryLabelColor) { return .secondary }
    if value.isEqual(NSColor.controlAccentColor) { return .accent }
    if value.isEqual(NSColor.systemYellow) { return .highlight }
    guard let rgb = value.usingColorSpace(.sRGB) else { return .primary }
    return .rgba(rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent)
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

  private static func semanticAlignment(_ value: NSTextAlignment) -> TextAlignment {
    switch value {
    case .left: .left
    case .center: .center
    case .right: .right
    case .justified: .justified
    default: .natural
    }
  }
}
