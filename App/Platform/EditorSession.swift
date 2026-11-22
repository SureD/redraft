import AppKit
import Combine
import RedraftCore

/// One window's transient native input session; never an owner of document content.
@MainActor
final class EditorSession: ObservableObject {
  private weak var current: BlockTextView?
  private var selectedBlockID: UUID?
  private var selectedRange: NSRange?
  private var style: EditorSelectionStyle?

  /// TextKit keeps the input method's unconfirmed characters outside the document snapshot.
  var hasMarkedText: Bool {
    if current?.hasMarkedText() == true { return true }
    let window = current?.window ?? NSApp?.keyWindow
    return (window?.firstResponder as? NSTextView)?.hasMarkedText() == true
  }

  func activate(_ editor: BlockTextView) {
    current = editor
    refresh(from: editor)
  }

  func refresh(from editor: BlockTextView) {
    guard current === editor else { return }
    let next = EditorSelectionStyle(
      text: editor.attributedString(), range: editor.selectedRange(),
      typing: editor.typingAttributes)
    guard
      selectedBlockID != editor.blockID || selectedRange != editor.selectedRange()
        || style?.isEqual(to: next) != true
    else { return }
    objectWillChange.send()
    selectedBlockID = editor.blockID
    selectedRange = editor.selectedRange()
    style = next
  }

  func selectionStyle(blockID: UUID, range: NSRange) -> EditorSelectionStyle? {
    guard selectedBlockID == blockID, selectedRange == range else { return nil }
    return style
  }

  func detach(_ editor: BlockTextView) {
    if current === editor { clear() }
  }

  func clear() {
    guard current != nil || style != nil else { return }
    objectWillChange.send()
    current = nil
    selectedBlockID = nil
    selectedRange = nil
    style = nil
  }

  fileprivate func nativeEditor(for blockID: UUID) -> BlockTextView? {
    guard let current, current.blockID == blockID, current.window != nil else { return nil }
    return current
  }
}

extension EditorSession {
  func format(
    _ command: EditorFormat, block: DocumentBlock, range selectedRange: NSRange,
    onCommit: (NSAttributedString) -> Void
  ) {
    let native = nativeEditor(for: block.id)
    guard native?.hasMarkedText() != true else { return }
    let source = native?.attributedString() ?? RichTextBridge.attributedString(from: block.text)
    let originalRange = native?.selectedRange() ?? selectedRange
    let location = min(originalRange.location, source.length)
    var range = NSRange(
      location: location, length: min(originalRange.length, source.length - location))
    let result = NSMutableAttributedString(attributedString: source)
    var typing = native?.typingAttributes ?? EditorTypography.bodyAttributes
    let attributes =
      range.length == 0 && native != nil
      ? typing
      : source.length > 0
        ? source.attributes(at: min(location, source.length - 1), effectiveRange: nil) : typing
    let font = attributes[.font] as? NSFont ?? .systemFont(ofSize: 17)
    let selectionStyle = EditorSelectionStyle(text: source, range: range, typing: typing)

    func set(_ key: NSAttributedString.Key, _ value: Any?) {
      if let value {
        if range.length > 0 { result.addAttribute(key, value: value, range: range) }
        typing[key] = value
      } else {
        if range.length > 0 { result.removeAttribute(key, range: range) }
        typing.removeValue(forKey: key)
      }
    }

    func paragraph(_ change: (NSMutableParagraphStyle) -> Void) {
      range = (source.string as NSString).paragraphRange(for: range)
      if range.length > 0 {
        source.enumerateAttribute(.paragraphStyle, in: range) { value, run, _ in
          let style =
            (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
            ?? NSMutableParagraphStyle()
          change(style)
          result.addAttribute(.paragraphStyle, value: style, range: run)
        }
      }
      let style =
        (typing[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
        ?? NSMutableParagraphStyle()
      change(style)
      typing[.paragraphStyle] = style
    }

    func transformFonts(_ change: (NSFont) -> NSFont) {
      if range.length > 0 {
        source.enumerateAttribute(.font, in: range) { value, run, _ in
          result.addAttribute(
            .font, value: change(value as? NSFont ?? .systemFont(ofSize: 17)), range: run)
        }
      }
      typing[.font] = change(font)
    }

    switch command {
    case .bold, .italic:
      let trait: NSFontTraitMask =
        if case .bold = command { .boldFontMask } else { .italicFontMask }
      let removing = selectionStyle.state(for: command) == .on
      transformFonts { current in
        removing
          ? NSFontManager.shared.convert(current, toNotHaveTrait: trait)
          : NSFontManager.shared.convert(current, toHaveTrait: trait)
      }
    case .underline:
      set(
        .underlineStyle,
        selectionStyle.state(for: command) == .on ? nil : NSUnderlineStyle.single.rawValue)
    case .strikethrough:
      set(
        .strikethroughStyle,
        selectionStyle.state(for: command) == .on ? nil : NSUnderlineStyle.single.rawValue
      )
    case .font(let name):
      transformFonts { current in
        let base =
          name == "系统"
          ? NSFont.systemFont(ofSize: current.pointSize)
          : NSFont(name: name, size: current.pointSize)
            ?? NSFont.systemFont(ofSize: current.pointSize)
        return NSFontManager.shared.convert(
          base,
          toHaveTrait: NSFontManager.shared.traits(of: current).intersection([
            .boldFontMask, .italicFontMask,
          ]))
      }
    case .size(let size): transformFonts { NSFontManager.shared.convert($0, toSize: size) }
    case .color(let color): set(.foregroundColor, color)
    case .highlight(let color): set(.backgroundColor, color)
    case .alignment(let alignment): paragraph { $0.alignment = alignment }
    case .spacing(let spacing): paragraph { $0.lineHeightMultiple = spacing }
    case .indent(let direction):
      paragraph { style in
        style.headIndent = min(144, max(0, style.headIndent + CGFloat(direction * 24)))
        style.firstLineHeadIndent = style.headIndent
      }
    case .heading(let level):
      paragraph { $0.paragraphSpacing = level == 0 ? 7 : 10 }
      set(.redraftHeadingLevel, min(3, max(0, level)))
      let sizes: [CGFloat] = [17, 28, 23, 19]
      set(
        .font,
        NSFont.systemFont(
          ofSize: sizes[min(3, max(0, level))], weight: level == 0 ? .regular : .semibold))
    case .list(let numbered):
      let removing = selectionStyle.state(for: command) == .on
      paragraph { style in
        style.textLists =
          removing ? [] : [NSTextList(markerFormat: numbered ? .decimal : .disc, options: 0)]
        style.headIndent = style.textLists.isEmpty ? 0 : 24
        style.firstLineHeadIndent = 0
      }
    case .quote:
      paragraph { style in
        style.headIndent = 24
        style.firstLineHeadIndent = 24
      }
      set(.foregroundColor, NSColor.secondaryLabelColor)
    case .clear:
      if range.length > 0 {
        source.enumerateAttributes(in: range) { value, run, _ in
          var clean = EditorTypography.bodyAttributes
          clean[.paragraphStyle] = value[.paragraphStyle]
          clean[.redraftHeadingLevel] = value[.redraftHeadingLevel]
          result.setAttributes(clean, range: run)
        }
      }
      let paragraphStyle = typing[.paragraphStyle]
      let heading = typing[.redraftHeadingLevel]
      typing = EditorTypography.bodyAttributes
      typing[.paragraphStyle] = paragraphStyle
      typing[.redraftHeadingLevel] = heading
    }

    if let native {
      native.window?.makeFirstResponder(native)
      native.applyFormatting(
        result,
        selection: NSRange(
          location: location, length: min(originalRange.length, result.length - location)),
        typing: typing)
      refresh(from: native)
    } else {
      onCommit(result)
    }
  }
}
