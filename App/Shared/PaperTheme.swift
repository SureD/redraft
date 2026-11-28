import AppKit
import SwiftUI

enum PaperTheme {
  static let paper = Color(adaptive("paper", light: 0xFCFBF8, dark: 0x1C1D1F))
  static let librarySurface = Color(adaptive("library", light: 0xF3F0EB, dark: 0x242528))
  static let reviewSurface = Color(adaptive("review", light: 0xF7F5F0, dark: 0x222326))
  static let secondaryPaper = librarySurface
  static let fill = Color.primary.opacity(0.065)
  static let separator = Color(adaptive("separator", light: 0xDEDAD3, dark: 0x3A3A3D))
  static let selection = Color(adaptive("selection", light: 0xEBE0D2, dark: 0x3B3028))
  static let ink = Color(textColor)
  static let secondaryText = Color(adaptive("secondaryText", light: 0x65615B, dark: 0xAEA9A2))
  static let accent = Color(adaptive("accent", light: 0x855333, dark: 0xE2AC81))
  static let insertion = Color(adaptive("insertion", light: 0x1B6B42, dark: 0x6CC995))
  static let deletion = Color(adaptive("deletion", light: 0xA8322A, dark: 0xFF8A7F))
  static let textColor = adaptive("text", light: 0x262421, dark: 0xF1EEE9)

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

struct WindowAppearance: NSViewRepresentable {
  func makeNSView(context: Context) -> WindowAppearanceView { WindowAppearanceView() }
  func updateNSView(_ nsView: WindowAppearanceView, context: Context) {}
}

final class WindowAppearanceView: NSView {
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard let window else { return }
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.backgroundColor = .clear
    window.isOpaque = false
    window.isMovableByWindowBackground = false
    window.minSize = NSSize(width: 780, height: 560)
  }
}

struct ToolbarIcon: View {
  let title: String
  let symbol: String
  var text: String? = nil
  var selected = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 7) {
        Image(systemName: symbol).font(.system(size: 15))
        if let text { Text(text).font(.system(size: 13, weight: .medium)) }
      }
      .padding(.horizontal, 9)
      .frame(minWidth: 36, minHeight: 32)
      .foregroundStyle(selected ? PaperTheme.accent : PaperTheme.ink)
      .background(selected ? PaperTheme.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(title)
    .accessibilityLabel(title)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}
