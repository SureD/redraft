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

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> BlockTextView {
    let view = BlockTextView(usingTextLayoutManager: true)
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
    view.minSize = NSSize(width: 0, height: 34)
    view.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    view.typingAttributes = EditorTypography.bodyAttributes
    view.textStorage?.setAttributedString(RichTextBridge.attributedString(from: content()))
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
    view.shouldFocusOnMount = { [weak coordinator = context.coordinator] in
      coordinator?.parent.focusOnMount == true
    }
    return view
  }

  func updateNSView(_ view: BlockTextView, context: Context) {
    context.coordinator.parent = self
    view.isEditable = editable
    view.blockID = blockID
    view.editorSession = session
    if !view.hasMarkedText() {
      context.coordinator.baseContent = content()
      let displayed = RichTextBridge.attributedString(from: context.coordinator.baseContent)
      context.coordinator.isSynchronizing = true
      if !view.attributedString().isEqual(to: displayed) {
        view.textStorage?.setAttributedString(displayed)
      }
      if let requested = selection {
        let location = min(max(0, requested.location), displayed.length)
        let bounded = NSRange(
          location: location, length: min(max(0, requested.length), displayed.length - location))
        if view.selectedRange() != bounded { view.setSelectedRange(bounded) }
      }
      context.coordinator.isSynchronizing = false
      DispatchQueue.main.async { [weak view] in
        guard let view else { return }
        view.editorSession?.refresh(from: view)
      }
    }
    view.needsLayout = true
  }

  @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: NativeRichText
    var isSynchronizing = false
    var baseContent: RichTextContent

    init(_ parent: NativeRichText) {
      self.parent = parent
      baseContent = parent.content()
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
        isSynchronizing = false
      }
      parent.onSelection(view.selectedRange())
      parent.session.refresh(from: view)
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

@MainActor final class BlockTextView: NSTextView {
  var blockID: UUID?
  weak var editorSession: EditorSession?
  var compositionCommitted: (() -> Void)?
  var heightChanged: ((CGFloat) -> Void)?
  var selectionChanged: ((NSRange) -> Void)?
  var imageTransferred: ((ImageTransferPayload) -> Void)?
  var shouldFocusOnMount: (() -> Bool)?
  private let editingUndoManager = UndoManager()

  // A detached paragraph must never leave undo actions targeting another article's editor.
  override var undoManager: UndoManager? { editingUndoManager }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil else {
      editorSession?.detach(self)
      return
    }
    DispatchQueue.main.async { [weak self] in
      guard let self, self.isEditable, self.shouldFocusOnMount?() == true else { return }
      self.window?.makeFirstResponder(self)
    }
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

  override func layout() {
    super.layout()
    guard let manager = textLayoutManager, let content = manager.textContentManager else { return }
    textContainer?.containerSize = NSSize(
      width: max(1, bounds.width), height: CGFloat.greatestFiniteMagnitude)
    manager.ensureLayout(for: content.documentRange)
    heightChanged?(max(34, ceil(manager.usageBoundsForTextContainer.height) + 6))
  }
}

@MainActor enum EditorTypography {
  static var bodyAttributes: [NSAttributedString.Key: Any] {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineHeightMultiple = 1.7
    paragraph.paragraphSpacing = 7
    return [
      .font: NSFont.systemFont(ofSize: 17), .foregroundColor: PaperTheme.textColor,
      .paragraphStyle: paragraph,
    ]
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
