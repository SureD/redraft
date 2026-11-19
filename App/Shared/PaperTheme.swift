import AppKit
import SwiftUI

enum PaperTheme {
  static let paper = Color(adaptive("paper", light: 0xFBFAF6, dark: 0x1E1E1D))
  static let secondaryPaper = Color(adaptive("secondaryPaper", light: 0xF3F1EB, dark: 0x262625))
  static let fill = Color.primary.opacity(0.055)
  static let separator = Color.primary.opacity(0.10)
  static let secondaryText = Color(nsColor: .secondaryLabelColor)
  static let accent = Color(adaptive("accent", light: 0x1667D9, dark: 0x2F86F6))
  static let insertion = Color(adaptive("insertion", light: 0x1B6B42, dark: 0x6CC995))
  static let deletion = Color(adaptive("deletion", light: 0xA8322A, dark: 0xFF8A7F))
  static let textColor = adaptive("text", light: 0x1D1C1A, dark: 0xEDEBE7)

  private static func adaptive(_ name: String, light: UInt32, dark: UInt32) -> NSColor {
    NSColor(name: NSColor.Name("redraft.\(name)")) { appearance in
      let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
      return NSColor(
        srgbRed: Double((value >> 16) & 0xFF) / 255,
        green: Double((value >> 8) & 0xFF) / 255,
        blue: Double(value & 0xFF) / 255, alpha: 1)
    }
  }
}

struct NativeMaterial: View {
  let material: NSVisualEffectView.Material
  var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    Group {
      if reduceTransparency || contrast == .increased {
        Color(nsColor: .windowBackgroundColor)
      } else {
        MaterialBridge(material: material, blendingMode: blendingMode)
      }
    }
    .accessibilityHidden(true)
  }
}

private struct MaterialBridge: NSViewRepresentable {
  let material: NSVisualEffectView.Material
  let blendingMode: NSVisualEffectView.BlendingMode

  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.state = .followsWindowActiveState
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) {
    view.material = material
    view.blendingMode = blendingMode
  }
}

struct WindowAppearance: NSViewRepresentable {
  func makeNSView(context: Context) -> WindowAppearanceView { WindowAppearanceView() }
  func updateNSView(_ nsView: WindowAppearanceView, context: Context) {}
}

final class WindowAppearanceView: NSView {
  override var acceptsFirstResponder: Bool { true }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard let window else { return }
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.backgroundColor = .clear
    window.isOpaque = false
    window.isMovableByWindowBackground = false
    window.minSize = NSSize(width: 780, height: 560)
    window.initialFirstResponder = self
  }
}

struct ToolbarIcon: View {
  let title: String
  let symbol: String
  var selected = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 15, weight: .regular))
        .frame(width: 30, height: 28)
        .background(selected ? PaperTheme.fill : .clear, in: RoundedRectangle(cornerRadius: 5))
    }
    .buttonStyle(.plain)
    .help(title)
    .accessibilityLabel(title)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

struct EmptyWorkspaceView: View {
  let symbol: String
  let title: String
  let detail: String

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: symbol).font(.system(size: 32, weight: .light)).foregroundStyle(.secondary)
      Text(title).font(.title3.weight(.medium))
      Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }
    .padding(36)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
