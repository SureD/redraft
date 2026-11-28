import Foundation

struct BlockNoteSpan<Attributes: Equatable & Sendable>: Equatable, Sendable {
  var text: String
  var attributes: Attributes

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.attributes == rhs.attributes && lhs.text.utf8.elementsEqual(rhs.text.utf8)
  }
}
extension BlockNoteSpan: Codable where Attributes: Codable {}

struct BlockNoteMarks: Equatable, Codable, Sendable {
  var styles: BlockNoteProps = [:]
  var href: String?
}
typealias BlockNoteInline = [BlockNoteSpan<BlockNoteMarks>]

extension Array where Element == BlockNoteSpan<BlockNoteMarks> {
  init(blockNote json: BlockNoteJSON) throws {
    self = []
    if let text = json.string {
      appendSpan(text, .init(), to: &self)
      return
    }
    guard let nodes = json.array else { throw EditingError.invalidDocument }
    func appendText(_ node: BlockNoteJSON, href: String?) throws {
      if let text = node.string {
        appendSpan(text, .init(href: href), to: &self)
        return
      }
      guard let leaf = node.object, leaf["type"] == .string("text"),
        let text = leaf["text"]?.string,
        leaf.keys.allSatisfy(["type", "text", "styles"].contains)
      else { throw EditingError.invalidDocument }
      let styles = try blockNoteProps(
        leaf["styles"],
        allowed: [
          "bold", "italic", "underline", "strike", "code", "textColor", "backgroundColor",
        ]
      ).filter { $0.value != .bool(false) }
      appendSpan(text, .init(styles: styles, href: href), to: &self)
    }
    for node in nodes {
      if let link = node.object, link["type"] == .string("link") {
        guard let href = link["href"]?.string, let content = link["content"],
          link.keys.allSatisfy(["type", "href", "content"].contains)
        else { throw EditingError.invalidDocument }
        if let text = content.string {
          appendSpan(text, .init(href: href), to: &self)
        } else if let leaves = content.array {
          for leaf in leaves { try appendText(leaf, href: href) }
        } else {
          throw EditingError.invalidDocument
        }
      } else {
        try appendText(node, href: nil)
      }
    }
  }

  // ProseMirror's hardBreak node has no marks. BlockNote serializes it with the preceding leaf's
  // marks (or plain at the start). Mirror that before comparing a legacy block with editor output.
  func normalizingHardBreaks() -> Self {
    guard contains(where: { $0.text.utf8.contains(10) }) else { return self }
    var output: Self = []
    for span in self {
      let pieces = span.text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
      for (i, piece) in pieces.enumerated() {
        if i > 0 { appendSpan("\n", output.last?.attributes ?? .init(), to: &output) }
        appendSpan(String(piece), span.attributes, to: &output)
      }
    }
    return output
  }

  var json: BlockNoteJSON {
    var nodes: [BlockNoteJSON] = []
    var linked: [BlockNoteJSON] = []
    var link: String?
    func finishLink() {
      if let link {
        nodes.append(
          .object(["type": .string("link"), "href": .string(link), "content": .array(linked)]))
        linked.removeAll(keepingCapacity: true)
      }
    }
    for span in self {
      let marks = span.attributes
      if marks.href != link {
        finishLink()
        link = marks.href
      }
      let text: BlockNoteJSON = .object([
        "type": .string("text"), "text": .string(span.text), "styles": .object(marks.styles),
      ])
      if link == nil { nodes.append(text) } else { linked.append(text) }
    }
    finishLink()
    return .array(nodes)
  }
}

func appendSpan<A>(_ text: String, _ attributes: A, to result: inout [BlockNoteSpan<A>]) {
  guard !text.isEmpty else { return }
  if let last = result.indices.last, result[last].attributes == attributes {
    result[last].text += text
  } else {
    result.append(.init(text: text, attributes: attributes))
  }
}

/// Move formatting, not text. For native edits, only surviving scalars retain editor-only marks
/// (links are never accidentally extended over a replacement). Browser edits may inherit native
/// font/paragraph details at the edit. UTF-16 ranges still come exclusively from RichTextContent.
func overlaySpans<A, B, C>(
  _ old: [BlockNoteSpan<A>], onto new: [BlockNoteSpan<B>], inherit: Bool = false,
  _ combine: (A?, B) -> C
) -> [BlockNoteSpan<C>] {
  if old.isEmpty || (inherit && old.count == 1) {
    return new.map {
      .init(text: $0.text, attributes: combine(old.first?.attributes, $0.attributes))
    }
  }
  func scalars<T>(_ spans: [BlockNoteSpan<T>]) -> (text: [Unicode.Scalar], spans: [Int]) {
    var text: [Unicode.Scalar] = []
    var indices: [Int] = []
    for (i, span) in spans.enumerated() {
      for scalar in span.text.unicodeScalars {
        text.append(scalar)
        indices.append(i)
      }
    }
    return (text, indices)
  }
  let lhs = scalars(old)
  let rhs = scalars(new)
  guard !lhs.text.isEmpty else {
    return new.map { .init(text: $0.text, attributes: combine(nil, $0.attributes)) }
  }
  // Most typing changes only a small middle; never run a quadratic diff on a large pasted replacement.
  var prefix = 0
  var a = lhs.text.count
  var b = rhs.text.count
  while prefix < min(a, b), lhs.text[prefix] == rhs.text[prefix] { prefix += 1 }
  while a > prefix, b > prefix, lhs.text[a - 1] == rhs.text[b - 1] {
    a -= 1
    b -= 1
  }
  var removed = IndexSet()
  var inserted = IndexSet()
  if a - prefix <= 2048, b - prefix <= 2048 {
    for change in rhs.text[prefix..<b].difference(from: lhs.text[prefix..<a]) {
      switch change {
      case .remove(let i, _, _): removed.insert(prefix + i)
      case .insert(let i, _, _): inserted.insert(prefix + i)
      }
    }
  } else {
    removed.insert(integersIn: prefix..<a)
    inserted.insert(integersIn: prefix..<b)
  }
  var result: [BlockNoteSpan<C>] = []
  var source = 0
  for dest in rhs.text.indices {
    let atEdit = source
    while removed.contains(source) { source += 1 }
    let origin: Int?
    if inserted.contains(dest) {
      origin = inherit ? min(atEdit, lhs.text.count - 1) : nil
    } else {
      origin = source
      source += 1
    }
    let attributes = combine(
      origin.map { old[lhs.spans[$0]].attributes }, new[rhs.spans[dest]].attributes)
    if let last = result.indices.last, result[last].attributes == attributes {
      result[last].text.unicodeScalars.append(rhs.text[dest])
    } else {
      result.append(.init(text: String(rhs.text[dest]), attributes: attributes))
    }
  }
  return result
}

private struct NativeAttributes: Equatable, Sendable {
  var style: TextStyle
  var paragraph: ParagraphStyle
}

extension RichTextContent {
  fileprivate var nativeSpans: [BlockNoteSpan<NativeAttributes>] {
    let s = string as NSString
    var spans: [BlockNoteSpan<NativeAttributes>] = []
    var start = 0
    let defaults = NativeAttributes(style: defaultStyle, paragraph: paragraphStyle)
    for run in runs {
      if run.range.location > start {
        appendSpan(
          s.substring(with: NSRange(location: start, length: run.range.location - start)), defaults,
          to: &spans)
      }
      appendSpan(
        s.substring(with: run.range), .init(style: run.style, paragraph: run.paragraphStyle),
        to: &spans)
      start = NSMaxRange(run.range)
    }
    if s.length > start { appendSpan(s.substring(from: start), defaults, to: &spans) }
    return spans
  }
}

private func palette(_ color: TextColor?) -> String? {
  switch color {
  case nil, .primary: return nil
  case .secondary: return "gray"
  case .accent: return "blue"
  case .highlight: return "yellow"
  case .rgba(let r, let g, let b, let a): return "rgba(\(r * 255), \(g * 255), \(b * 255), \(a))"
  }
}

private func nativeColor(_ value: String?) -> TextColor? {
  switch value {
  case "gray": .secondary
  case "blue": .accent
  case "yellow": .highlight
  default: nil  // Other palette/CSS values are retained exactly on the editor mark.
  }
}

func editorInline(_ text: RichTextContent, overlay: BlockNoteInline?) -> BlockNoteInline {
  overlaySpans(overlay ?? [], onto: text.nativeSpans) { old, native in
    let style = native.style
    var props: BlockNoteProps = [:]
    if style.bold { props["bold"] = .bool(true) }
    if style.italic { props["italic"] = .bool(true) }
    if style.underline { props["underline"] = .bool(true) }
    if style.strikethrough { props["strike"] = .bool(true) }
    if old?.styles["code"] == .bool(true) { props["code"] = .bool(true) }
    for (key, color) in [
      ("textColor", Optional(style.foreground)), ("backgroundColor", style.background),
    ] {
      if let original = old?.styles[key]?.string,
        nativeColor(original) == (color == .primary ? nil : color)
      {
        props[key] = .string(original)
      } else if let value = palette(color) {
        props[key] = .string(value)
      }
    }
    return BlockNoteMarks(styles: props, href: old?.href)
  }.reduce(into: []) { appendSpan($1.text, $1.attributes, to: &$0) }.normalizingHardBreaks()
}

func redraftText(
  inline: BlockNoteInline, previous: RichTextContent?,
  paragraph: (ParagraphStyle) -> ParagraphStyle
) -> RichTextContent {
  let old = previous ?? RichTextContent()
  let spans = overlaySpans(old.nativeSpans, onto: inline, inherit: true) { inherited, mark in
    var style = inherited?.style ?? old.defaultStyle
    style.bold = mark.styles["bold"] == .bool(true)
    style.italic = mark.styles["italic"] == .bool(true)
    style.underline = mark.styles["underline"] == .bool(true)
    style.strikethrough = mark.styles["strike"] == .bool(true)
    let foreground = mark.styles["textColor"]?.string
    let background = mark.styles["backgroundColor"]?.string
    if palette(style.foreground) != foreground {
      style.foreground = nativeColor(foreground) ?? .primary
    }
    if palette(style.background) != background { style.background = nativeColor(background) }
    return NativeAttributes(
      style: style, paragraph: paragraph(inherited?.paragraph ?? old.paragraphStyle))
  }
  let first =
    spans.first?.attributes
    ?? .init(style: old.defaultStyle, paragraph: paragraph(old.paragraphStyle))
  var text = RichTextContent(defaultStyle: first.style, paragraphStyle: first.paragraph)
  var offset = 0
  for span in spans {
    let length = span.text.utf16.count
    if span.attributes != first {
      text.runs.append(
        .init(
          range: NSRange(location: offset, length: length), style: span.attributes.style,
          paragraphStyle: span.attributes.paragraph))
    }
    text.string += span.text
    offset += length
  }
  return text
}
