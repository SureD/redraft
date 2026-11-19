import AppKit
import RedraftCore
import SwiftUI

/// Single-key commands are scoped to this review surface, never to a text field or sheet.
struct ReviewKeyboardNavigation: NSViewRepresentable {
  let model: WorkspaceViewModel

  func makeCoordinator() -> Coordinator { Coordinator(model: model) }

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    context.coordinator.install(in: view)
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.model = model
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.removeMonitor()
  }

  @MainActor
  final class Coordinator {
    var model: WorkspaceViewModel
    private weak var view: NSView?
    private var monitor: Any?

    init(model: WorkspaceViewModel) { self.model = model }

    func install(in view: NSView) {
      self.view = view
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        let handled = MainActor.assumeIsolated {
          guard let self else { return false }
          return self.handle(event) == nil
        }
        return handled ? nil : event
      }
    }

    func removeMonitor() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
      guard model.state.section == .articles,
        model.state.mode == .review,
        model.state.sheet == nil,
        model.currentArticle?.phase == .ready,
        let window = view?.window,
        window.isKeyWindow,
        event.window === window,
        window.attachedSheet == nil,
        event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
      else { return event }

      if let text = window.firstResponder as? NSTextView, text.isEditable { return event }
      if let field = window.firstResponder as? NSTextField, field.isEditable { return event }
      // Picker and button focus keeps its native arrow-key behavior.
      if [125, 126].contains(event.keyCode), window.firstResponder is NSControl { return event }
      if event.keyCode == 125 { return moveSelection(by: 1) ? nil : event }
      if event.keyCode == 126 { return moveSelection(by: -1) ? nil : event }
      switch event.charactersIgnoringModifiers?.lowercased() {
      case "j": return moveSelection(by: 1) ? nil : event
      case "k": return moveSelection(by: -1) ? nil : event
      case "a":
        guard model.currentChange != nil else { return event }
        model.decide(.accept)
      case "o":
        guard model.currentChange != nil else { return event }
        model.decide(.keep)
      case "e":
        guard model.currentChange?.kind == .text else { return event }
        model.decide(.rewrite)
      default: return event
      }
      return nil
    }

    private func moveSelection(by delta: Int) -> Bool {
      guard let changes = model.currentArticle?.changes, !changes.isEmpty else { return false }
      let index = changes.firstIndex { $0.id == model.state.selectedChangeID }
      let next = index.map { min(max($0 + delta, 0), changes.count - 1) } ?? 0
      model.selectChange(changes[next].id)
      return true
    }
  }
}
