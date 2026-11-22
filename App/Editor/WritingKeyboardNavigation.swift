import AppKit
import RedraftCore
import SwiftUI

/// Block shortcuts only run after the user leaves a native text input.
struct WritingKeyboardNavigation: NSViewRepresentable {
  let model: WorkspaceViewModel

  func makeCoordinator() -> Coordinator { Coordinator(model: model) }

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    context.coordinator.install(in: view)
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.model = model }

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
          guard let self, let window = self.view?.window, window.isKeyWindow,
            event.window === window, window.attachedSheet == nil,
            event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
          else { return false }
          let editing = window.firstResponder is NSTextView || window.firstResponder is NSTextField
          return self.model.handleSelectedBlockKey(event.keyCode, textInputFocused: editing)
        }
        return handled ? nil : event
      }
    }

    func removeMonitor() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }
  }
}

extension WorkspaceViewModel {
  func handleSelectedBlockKey(_ keyCode: UInt16, textInputFocused: Bool) -> Bool {
    guard !textInputFocused, !isEditorLocked, state.sheet == nil,
      let block = selectedBlock, block.kind != .text
    else { return false }
    switch keyCode {
    case 51, 117:
      deleteBlock(block.id)
    case 53:
      selectBlock(nil)
    case 36, 76:
      insertBlock(DocumentBlock())
    default:
      return false
    }
    return true
  }
}
