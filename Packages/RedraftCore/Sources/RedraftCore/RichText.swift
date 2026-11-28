import Foundation

public enum TextColor: Hashable, Codable, Sendable {
  case primary, secondary, accent, highlight
  case rgba(Double, Double, Double, Double)
}

public struct TextStyle: Hashable, Codable, Sendable {
  public var fontFamily: String?
  public var fontSize: Double?
  public var bold: Bool
  public var italic: Bool
  public var underline: Bool
  public var strikethrough: Bool
  public var foreground: TextColor
  public var background: TextColor?

  public init(
    fontFamily: String? = nil, fontSize: Double? = nil, bold: Bool = false, italic: Bool = false,
    underline: Bool = false, strikethrough: Bool = false, foreground: TextColor = .primary,
    background: TextColor? = nil
  ) {
    self.fontFamily = fontFamily
    self.fontSize = fontSize
    self.bold = bold
    self.italic = italic
    self.underline = underline
    self.strikethrough = strikethrough
    self.foreground = foreground
    self.background = background
  }
}

public enum ParagraphKind: Hashable, Codable, Sendable {
  case body
  case heading(level: Int)
}
public enum TextAlignment: String, Equatable, Codable, Sendable {
  case natural, left, center, right, justified
}
public enum ListMarker: String, Equatable, Codable, Sendable { case bullet, decimal }

public struct ListStyle: Hashable, Codable, Sendable {
  public var marker: ListMarker
  public var startingItemNumber: Int

  public init(marker: ListMarker = .bullet, startingItemNumber: Int = 1) {
    self.marker = marker
    self.startingItemNumber = startingItemNumber
  }
}

public struct ParagraphStyle: Hashable, Codable, Sendable {
  public var kind: ParagraphKind
  public var alignment: TextAlignment
  public var headIndent: Double
  public var firstLineHeadIndent: Double
  public var tailIndent: Double
  public var lineSpacing: Double
  public var paragraphSpacing: Double
  public var paragraphSpacingBefore: Double
  public var lineHeightMultiple: Double
  public var list: ListStyle?

  public init(
    kind: ParagraphKind = .body, alignment: TextAlignment = .natural, headIndent: Double = 0,
    firstLineHeadIndent: Double = 0, tailIndent: Double = 0, lineSpacing: Double = 0,
    paragraphSpacing: Double = 0, paragraphSpacingBefore: Double = 0,
    lineHeightMultiple: Double = 0, list: ListStyle? = nil
  ) {
    self.kind = kind
    self.alignment = alignment
    self.headIndent = headIndent
    self.firstLineHeadIndent = firstLineHeadIndent
    self.tailIndent = tailIndent
    self.lineSpacing = lineSpacing
    self.paragraphSpacing = paragraphSpacing
    self.paragraphSpacingBefore = paragraphSpacingBefore
    self.lineHeightMultiple = lineHeightMultiple
    self.list = list
  }
}

public struct RichTextRun: Equatable, Codable, Sendable {
  public var range: NSRange
  public var style: TextStyle
  public var paragraphStyle: ParagraphStyle

  public init(range: NSRange, style: TextStyle, paragraphStyle: ParagraphStyle = ParagraphStyle()) {
    self.range = range
    self.style = style
    self.paragraphStyle = paragraphStyle
  }
}

public struct RichTextContent: Equatable, Codable, Sendable {
  public var string: String
  public var runs: [RichTextRun]
  public var defaultStyle: TextStyle
  public var paragraphStyle: ParagraphStyle

  public init(
    string: String = "", runs: [RichTextRun] = [], defaultStyle: TextStyle = TextStyle(),
    paragraphStyle: ParagraphStyle = ParagraphStyle()
  ) {
    self.string = string
    self.runs = runs
    self.defaultStyle = defaultStyle
    self.paragraphStyle = paragraphStyle
  }

  /// Editing coordinates must include complete user-perceived characters, including CRLF.
  public func range(forUTF16 selection: NSRange) throws -> Range<String.Index> {
    let range = try scalarRange(selection)
    guard range.lowerBound.samePosition(in: string) != nil,
      range.upperBound.samePosition(in: string) != nil
    else { throw EditingError.invalidRange }
    return range
  }

  /// Canonical formatting representation shared by native adapters and the document owner.
  /// Missing runs use the defaults; adjacent identical runs merge, including default spans.
  public func normalized() -> RichTextContent {
    guard !string.isEmpty, (try? validate()) != nil else { return self }
    var spans: [RichTextRun] = []
    var offset = 0
    for run in runs {
      if offset < run.range.location {
        spans.append(
          RichTextRun(
            range: NSRange(location: offset, length: run.range.location - offset),
            style: defaultStyle, paragraphStyle: paragraphStyle))
      }
      spans.append(run)
      offset = run.range.location + run.range.length
    }
    if offset < string.utf16.count {
      spans.append(
        RichTextRun(
          range: NSRange(location: offset, length: string.utf16.count - offset),
          style: defaultStyle, paragraphStyle: paragraphStyle))
    }
    guard let first = spans.first else { return self }
    var merged: [RichTextRun] = []
    for span in spans {
      if let last = merged.last, last.style == span.style,
        last.paragraphStyle == span.paragraphStyle
      {
        merged[merged.count - 1].range.length += span.range.length
      } else {
        merged.append(span)
      }
    }
    return RichTextContent(
      string: string,
      runs: merged.filter { $0.style != first.style || $0.paragraphStyle != first.paragraphStyle },
      defaultStyle: first.style, paragraphStyle: first.paragraphStyle)
  }

  public func validate() throws {
    try validate(defaultStyle)
    try validate(paragraphStyle)
    var previousEnd = 0
    for run in runs {
      // Formatting may split a composed character, but never a UTF-16 surrogate pair.
      _ = try scalarRange(run.range)
      guard run.range.length > 0, run.range.location >= previousEnd else {
        throw EditingError.invalidRange
      }
      previousEnd = run.range.location + run.range.length
      try validate(run.style)
      try validate(run.paragraphStyle)
    }
  }

  private func scalarRange(_ range: NSRange) throws -> Range<String.Index> {
    let count = string.utf16.count
    guard range.location >= 0, range.location <= count,
      range.length >= 0, range.length <= count - range.location,
      let indices = Range(range, in: string),
      indices.lowerBound.samePosition(in: string.unicodeScalars) != nil,
      indices.upperBound.samePosition(in: string.unicodeScalars) != nil
    else { throw EditingError.invalidRange }
    return indices
  }

  private func validate(_ style: TextStyle) throws {
    if let size = style.fontSize, !size.isFinite || size <= 0 {
      throw EditingError.invalidDocument
    }
    for color in [style.foreground, style.background].compactMap({ $0 }) {
      if case .rgba(let r, let g, let b, let a) = color,
        ![r, g, b, a].allSatisfy({ $0.isFinite && (0...1).contains($0) })
      {
        throw EditingError.invalidDocument
      }
    }
  }

  private func validate(_ style: ParagraphStyle) throws {
    guard
      [
        style.headIndent, style.firstLineHeadIndent, style.tailIndent, style.lineSpacing,
        style.paragraphSpacing, style.paragraphSpacingBefore, style.lineHeightMultiple,
      ].allSatisfy(\.isFinite)
    else { throw EditingError.invalidDocument }
    if case .heading(let level) = style.kind, !(1...6).contains(level) {
      throw EditingError.invalidDocument
    }
  }
}
