import AppKit
import RedraftCore
import SwiftUI

/// AppKit owns only the live input session; document content is written back through the binding.
struct NativeRichText: NSViewRepresentable {
  var content: () -> RichTextContent
  var onCommit: (NSAttributedString, RichTextContent) -> Bool
  @Binding var measuredHeight: CGFloat
  var blockID: UUID
  var session: EditorSession
  var selection: NSRange? = nil
  var editable: Bool
  var onSelection: (NSRange) -> Void
  var onImageTransfer: (ImageTransferPayload) -> Void = { _ in }
  var focusOnMount = false
  var focusRequest: UUID? = nil

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> BlockTextView {
    let layout = WritingTextLayoutManager()
    let container = NSTextContainer()
    context.coordinator.textContentStorage.addTextLayoutManager(layout)
    layout.textContainer = container
    let view = BlockTextView(frame: .zero, textContainer: container)
    view.delegate = context.coordinator
    view.blockID = blockID
    view.editorSession = session
    view.drawsBackground = false
    view.isRichText = true
    view.isEditable = editable
    view.isSelectable = true
    view.allowsUndo = true
    view.isAutomaticQuoteSubstitutionEnabled = true
    view.isAutomaticDashSubstitutionEnabled = true
    view.isContinuousSpellCheckingEnabled = true
    view.isAutomaticSpellingCorrectionEnabled = false
    view.isHorizontallyResizable = false
    view.isVerticallyResizable = true
    view.textContainerInset = .zero
    view.textContainer?.lineFragmentPadding = 0
    view.textContainer?.widthTracksTextView = true
    view.minSize = .zero
    view.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    let initial = context.coordinator.baseContent
    view.textStorage?.setAttributedString(RichTextBridge.attributedString(from: initial))
    if initial.string.isEmpty { view.restoreEmptyParagraphStyle(initial) }
    view.setAccessibilityLabel("正文段落")
    view.heightChanged = { [weak coordinator = context.coordinator] height in
      coordinator?.updateHeight(height)
    }
    view.selectionChanged = { [weak coordinator = context.coordinator] range in
      coordinator?.parent.onSelection(range)
    }
    view.imageTransferred = { [weak coordinator = context.coordinator] payload in
      coordinator?.parent.onImageTransfer(payload)
    }
    view.compositionCommitted = { [weak coordinator = context.coordinator, weak view] in
      guard let view else { return }
      coordinator?.commit(view)
    }
    view.didMount = { [weak coordinator = context.coordinator, weak view] in
      guard let coordinator, let view else { return }
      coordinator.focusIfRequested(view, onMount: true)
    }
    return view
  }

  func updateNSView(_ view: BlockTextView, context: Context) {
    context.coordinator.parent = self
    view.isEditable = editable
    view.blockID = blockID
    view.editorSession = session
    view.presentedHeight = measuredHeight
    if !view.hasMarkedText() {
      let current = content()
      let contentChanged = current != context.coordinator.baseContent
      context.coordinator.baseContent = current
      let displayed = RichTextBridge.attributedString(from: current)
      context.coordinator.isSynchronizing = true
      if !view.attributedString().isEqual(to: displayed) {
        view.textStorage?.setAttributedString(displayed)
      }
      if current.string.isEmpty && contentChanged { view.restoreEmptyParagraphStyle(current) }
      if let requested = selection {
        let location = min(max(0, requested.location), displayed.length)
        let bounded = NSRange(
          location: location, length: min(max(0, requested.length), displayed.length - location))
        if view.selectedRange() != bounded { view.setSelectedRange(bounded) }
      }
      context.coordinator.isSynchronizing = false
      DispatchQueue.main.async { [weak view, weak coordinator = context.coordinator] in
        guard let view, let coordinator else { return }
        coordinator.focusIfRequested(view)
        view.editorSession?.refresh(from: view)
      }
    }
    view.needsLayout = true
  }

  @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
    let textContentStorage = NSTextContentStorage()
    var parent: NativeRichText
    var isSynchronizing = false
    var baseContent: RichTextContent
    private var handledFocusRequest: UUID?

    init(_ parent: NativeRichText) {
      self.parent = parent
      baseContent = parent.content()
    }

    func focusIfRequested(_ view: BlockTextView, onMount: Bool = false) {
      guard view.isEditable, let window = view.window else { return }
      let request = parent.focusRequest
      guard (request != nil && request != handledFocusRequest) || (onMount && parent.focusOnMount)
      else { return }
      if window.makeFirstResponder(view) {
        handledFocusRequest = request
        view.revealInsertionPointAfterLayout()
      }
    }

    func textDidChange(_ notification: Notification) {
      guard !isSynchronizing, let view = notification.object as? BlockTextView else { return }
      commit(view)
    }

    func commit(_ view: BlockTextView) {
      guard !isSynchronizing, !view.hasMarkedText() else { return }
      let accepted = parent.onCommit(
        NSAttributedString(attributedString: view.attributedString()), baseContent)
      // Read the authoritative result immediately: rapid consecutive keystrokes need not wait
      // for SwiftUI's next render before submitting against the new base.
      baseContent = parent.content()
      if !accepted {
        isSynchronizing = true
        let displayed = RichTextBridge.attributedString(from: baseContent)
        let location = min(view.selectedRange().location, displayed.length)
        view.textStorage?.setAttributedString(displayed)
        view.setSelectedRange(NSRange(location: location, length: 0))
        if displayed.length == 0 { view.restoreEmptyParagraphStyle(baseContent) }
        isSynchronizing = false
      }
      parent.onSelection(view.selectedRange())
      parent.session.refresh(from: view)
      if accepted { view.revealInsertionPointAfterLayout() }
      view.needsLayout = true
    }

    func textViewDidChangeSelection(_ notification: Notification) {
      guard !isSynchronizing, let view = notification.object as? BlockTextView,
        view.window?.firstResponder === view
      else { return }
      guard !view.hasMarkedText() else { return }
      parent.onSelection(view.selectedRange())
      parent.session.refresh(from: view)
    }

    func updateHeight(_ height: CGFloat) {
      guard abs(parent.measuredHeight - height) > 0.5 else { return }
      DispatchQueue.main.async { [weak self] in self?.parent.measuredHeight = height }
    }
  }
}

/// Keep the system insertion point on the typing font's baseline when the rest
/// of its line is taller, for example in mixed sizes or a double-spaced paragraph.
private final class WritingTextLayoutManager: NSTextLayoutManager {
  private let fontMetrics = NSLayoutManager()

  override func enumerateTextSegments(
    in range: NSTextRange, type: SegmentType, options: SegmentOptions,
    using block: (NSTextRange?, CGRect, CGFloat, NSTextContainer) -> Bool
  ) {
    guard range.isEmpty, type == .selection || type == .standard,
      let selection = textSelections.first(where: { $0.textRanges.contains(range) }),
      let font = selection.typingAttributes[.font] as? NSFont
    else {
      super.enumerateTextSegments(in: range, type: type, options: options, using: block)
      return
    }
    let height = fontMetrics.defaultLineHeight(for: font)
    let ascent = fontMetrics.defaultBaselineOffset(for: font)
    super.enumerateTextSegments(in: range, type: type, options: options) {
      segment, frame, baseline, container in
      guard height < frame.height else { return block(segment, frame, baseline, container) }
      var caret = frame
      let offset = min(frame.height - height, max(0, baseline - ascent))
      caret.origin.y += offset
      caret.size.height = height
      return block(segment, caret, baseline - offset, container)
    }
  }
}

@MainActor final class BlockTextView: NSTextView {
  var blockID: UUID?
  weak var editorSession: EditorSession?
  var compositionCommitted: (() -> Void)?
  var heightChanged: ((CGFloat) -> Void)?
  var selectionChanged: ((NSRange) -> Void)?
  var imageTransferred: ((ImageTransferPayload) -> Void)?
  var didMount: (() -> Void)?
  var presentedHeight: CGFloat = 0
  private let editingUndoManager = UndoManager()
  private var shouldRevealInsertionPoint = false

  // A detached paragraph must never leave undo actions targeting another article's editor.
  override var undoManager: UndoManager? { editingUndoManager }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil else {
      editorSession?.detach(self)
      return
    }
    DispatchQueue.main.async { [weak self] in self?.didMount?() }
  }

  override func paste(_ sender: Any?) {
    if isEditable, !hasMarkedText(), let payload = ImageTransfer.imageOnlyPayload(from: .general) {
      imageTransferred?(payload)
    } else {
      super.paste(sender)
    }
  }

  override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
    if isEditable, ImageTransfer.imageOnlyPayload(from: sender.draggingPasteboard) != nil {
      return .copy
    }
    return super.draggingEntered(sender)
  }

  override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
    if isEditable, ImageTransfer.imageOnlyPayload(from: sender.draggingPasteboard) != nil {
      return .copy
    }
    return super.draggingUpdated(sender)
  }

  override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    if isEditable, !hasMarkedText(),
      let payload = ImageTransfer.imageOnlyPayload(from: sender.draggingPasteboard)
    {
      imageTransferred?(payload)
      return true
    }
    return super.performDragOperation(sender)
  }

  override func becomeFirstResponder() -> Bool {
    let result = super.becomeFirstResponder()
    if result {
      editorSession?.activate(self)
      selectionChanged?(selectedRange())
    }
    return result
  }

  // An empty attributed string carries no font. TextKit uses the typing attributes
  // to lay out its insertion line and to style the first character that fills it.
  func restoreEmptyParagraphStyle(_ content: RichTextContent) {
    typingAttributes = RichTextBridge.attributes(
      style: content.defaultStyle, paragraph: content.paragraphStyle)
  }

  func applyFormatting(
    _ value: NSAttributedString, selection: NSRange, typing: [NSAttributedString.Key: Any]
  ) {
    guard isEditable, !hasMarkedText() else { return }
    let previous = NSAttributedString(attributedString: attributedString())
    let previousSelection = selectedRange()
    let previousTyping = typingAttributes
    guard !previous.isEqual(to: value) else {
      typingAttributes = typing
      editorSession?.refresh(from: self)
      return
    }
    breakUndoCoalescing()
    editingUndoManager.registerUndo(withTarget: self) { target in
      target.applyFormatting(previous, selection: previousSelection, typing: previousTyping)
    }
    editingUndoManager.setActionName("排版")
    editingUndoManager.disableUndoRegistration()
    textStorage?.setAttributedString(value)
    setSelectedRange(selection)
    typingAttributes = typing
    didChangeText()
    editingUndoManager.enableUndoRegistration()
    editorSession?.refresh(from: self)
  }

  override func unmarkText() {
    super.unmarkText()
    compositionCommitted?()
  }

  func revealInsertionPointAfterLayout() {
    guard window?.firstResponder === self, selectedRange().length == 0 else { return }
    shouldRevealInsertionPoint = true
    needsLayout = true
  }

  override func layout() {
    super.layout()
    guard let manager = textLayoutManager, let content = manager.textContentManager else { return }
    textContainer?.containerSize = NSSize(
      width: max(1, bounds.width), height: CGFloat.greatestFiniteMagnitude)
    manager.ensureLayout(for: content.documentRange)
    let height = ceil(manager.usageBoundsForTextContainer.height)
    heightChanged?(height)
    // SwiftUI sizes the surrounding scroll document from our measured height.
    // Wait until it has made space for the new line before consuming this edit.
    if shouldRevealInsertionPoint, abs(presentedHeight - height) <= 0.5 {
      shouldRevealInsertionPoint = false
      DispatchQueue.main.async { [weak self] in self?.revealInsertionPoint() }
    }
  }

  private func revealInsertionPoint() {
    guard window?.firstResponder === self, let document = enclosingScrollView?.documentView,
      let manager = textLayoutManager, let selection = manager.textSelections.first,
      let range = selection.textRanges.first,
      range.isEmpty
    else { return }
    window?.contentView?.layoutSubtreeIfNeeded()
    let options: NSTextLayoutManager.SegmentOptions =
      selection.affinity == .upstream
      ? [.rangeNotRequired, .upstreamAffinity] : [.rangeNotRequired]
    manager.enumerateTextSegments(in: range, type: .selection, options: options) {
      _, frame, _, _ in
      var rect = frame.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y)
      rect.size.width = max(1, rect.width)
      document.scrollToVisible(self.convert(rect, to: document))
      return false
    }
  }
}

@MainActor enum EditorTypography {
  static var bodyAttributes: [NSAttributedString.Key: Any] {
    RichTextBridge.attributes(style: TextStyle(), paragraph: ParagraphStyle())
  }

  static func displayText(_ value: NSAttributedString) -> NSAttributedString {
    let result = NSMutableAttributedString(attributedString: value)
    let full = NSRange(location: 0, length: result.length)
    result.enumerateAttributes(in: full) { attributes, range, _ in
      for (key, defaultValue) in bodyAttributes where attributes[key] == nil {
        result.addAttribute(key, value: defaultValue, range: range)
      }
    }
    return result
  }
}

enum EditorFormat {
  case bold, italic, underline, strikethrough, clear
  case font(String)
  case size(CGFloat)
  case color(NSColor)
  case highlight(NSColor?)
  case heading(Int)
  case alignment(NSTextAlignment)
  case spacing(CGFloat)
  case indent(Int)
  case list(Bool)
  case quote
}

enum EditorToggleState {
  case off, on, mixed
}

@MainActor
struct EditorSelectionStyle {
  let attributes: [[NSAttributedString.Key: Any]]

  init(text: NSAttributedString, range: NSRange, typing: [NSAttributedString.Key: Any]? = nil) {
    guard range.length > 0, range.location <= text.length,
      range.length <= text.length - range.location
    else {
      attributes = [
        typing
          ?? (text.length > 0
            ? text.attributes(at: min(max(0, range.location), text.length - 1), effectiveRange: nil)
            : EditorTypography.bodyAttributes)
      ]
      return
    }
    var values: [[NSAttributedString.Key: Any]] = []
    text.enumerateAttributes(in: range) { value, _, _ in values.append(value) }
    attributes = values
  }

  var fonts: [NSFont] { attributes.map { $0[.font] as? NSFont ?? .systemFont(ofSize: 17) } }
  var commonSize: CGFloat? {
    let values = fonts.map(\.pointSize)
    return values.allSatisfy { $0 == values.first } ? values.first : nil
  }
  var paragraphTitle: String {
    let levels = attributes.map { $0[.redraftHeadingLevel] as? Int ?? 0 }
    guard levels.allSatisfy({ $0 == levels.first }) else { return "混合" }
    return (levels.first ?? 0) > 0 ? "标题 \(levels.first!)" : "正文"
  }

  func isEqual(to other: EditorSelectionStyle) -> Bool {
    attributes.count == other.attributes.count
      && zip(attributes, other.attributes).allSatisfy {
        NSDictionary(dictionary: $0).isEqual(to: $1)
      }
  }

  var commonFamily: String? {
    let values = fonts.map { $0.familyName ?? "系统" }
    return values.allSatisfy { $0 == values.first } ? values.first : nil
  }
  func state(for command: EditorFormat) -> EditorToggleState {
    let flags = attributes.map { value -> Bool in
      let font = value[.font] as? NSFont ?? .systemFont(ofSize: 17)
      switch command {
      case .bold: return NSFontManager.shared.traits(of: font).contains(.boldFontMask)
      case .italic: return NSFontManager.shared.traits(of: font).contains(.italicFontMask)
      case .underline: return (value[.underlineStyle] as? Int ?? 0) != 0
      case .strikethrough: return (value[.strikethroughStyle] as? Int ?? 0) != 0
      case .list(let numbered):
        return (value[.paragraphStyle] as? NSParagraphStyle)?.textLists.first?.markerFormat
          == (numbered ? .decimal : .disc)
      default: return false
      }
    }
    if flags.allSatisfy({ $0 }) { return .on }
    return flags.contains(true) ? .mixed : .off
  }
}

extension WorkspaceViewModel {
  var editorSelectionStyle: EditorSelectionStyle {
    guard let block = selectedBlock, block.kind == .text else {
      return EditorSelectionStyle(
        text: NSAttributedString(string: ""), range: .init(location: 0, length: 0))
    }
    return editorSession.selectionStyle(blockID: block.id, range: state.selectedRange)
      ?? EditorSelectionStyle(
        text: RichTextBridge.attributedString(from: block.text), range: state.selectedRange)
  }

  func formatSelection(_ command: EditorFormat) {
    guard !isEditorLocked, let block = selectedBlock, block.kind == .text else { return }
    editorSession.format(command, block: block, range: state.selectedRange) { text in
      updateBlockText(block.id, text: text)
    }
  }
}
