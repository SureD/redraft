import AppKit
import SwiftUI

/// Sample illustrations are demo resources, never a fallback for a missing document image.
@MainActor
final class DemoImageResolver: DocumentImageResolving {
  private var images: [String: NSImage] = [:]

  func image(for assetName: String) -> NSImage? {
    if let image = images[assetName] { return image }
    guard ["sample-balcony", "sample-basil", "sample-tomato"].contains(assetName) else {
      return NSImage(named: assetName)
    }
    let size =
      assetName == "sample-basil"
      ? CGSize(width: 1000, height: 750) : CGSize(width: 1200, height: 800)
    let renderer = ImageRenderer(
      content: SamplePlantIllustration(asset: assetName).frame(
        width: size.width, height: size.height))
    guard let image = renderer.nsImage else { return nil }
    images[assetName] = image
    return image
  }
}

/// The prototype's own illustrations, drawn with the same neutral paper and leaf palette.
private struct SamplePlantIllustration: View {
  let asset: String

  var body: some View {
    Canvas { context, size in
      let basil = asset == "sample-basil"
      let width: CGFloat = basil ? 1000 : 1200
      let height: CGFloat = basil ? 750 : 800
      context.scaleBy(x: size.width / width, y: size.height / height)

      func color(_ rgb: UInt32) -> Color {
        Color(
          red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255,
          blue: Double(rgb & 255) / 255)
      }
      func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ rgb: UInt32) {
        context.fill(Path(CGRect(x: x, y: y, width: w, height: h)), with: .color(color(rgb)))
      }
      func leaf(
        _ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ rotation: Double, _ rgb: UInt32
      ) {
        var leafContext = context
        leafContext.translateBy(x: x, y: y)
        leafContext.rotate(by: .degrees(rotation))
        leafContext.fill(
          Path(ellipseIn: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2)),
          with: .color(color(rgb)))
      }
      func line(_ points: [CGPoint], _ stroke: CGFloat, _ rgb: UInt32) {
        var path = Path()
        if let first = points.first { path.move(to: first) }
        for point in points.dropFirst() { path.addLine(to: point) }
        context.stroke(
          path, with: .color(color(rgb)), style: StrokeStyle(lineWidth: stroke, lineCap: .round))
      }
      func pot(
        _ x: CGFloat, _ bottom: CGFloat, _ w: CGFloat, _ h: CGFloat, _ body: UInt32, _ rim: UInt32
      ) {
        var shape = Path()
        shape.move(to: CGPoint(x: x - w / 2, y: bottom - h))
        shape.addLine(to: CGPoint(x: x + w / 2, y: bottom - h))
        shape.addLine(to: CGPoint(x: x + w * 0.38, y: bottom))
        shape.addLine(to: CGPoint(x: x - w * 0.38, y: bottom))
        shape.closeSubpath()
        context.fill(shape, with: .color(color(body)))
        rect(x - w / 2 - 8, bottom - h - 16, w + 16, 22, rim)
      }

      if basil {
        rect(0, 0, 1000, 750, 0xEEE9E0)
        leaf(500, 700, 300, 60, 0, 0xD9CFC1)
        line([CGPoint(x: 500, y: 700), CGPoint(x: 504, y: 420)], 12, 0x7C937A)
        leaf(420, 470, 92, 50, -30, 0x8AA287)
        leaf(590, 470, 92, 50, 30, 0x7D977B)
        leaf(440, 360, 74, 40, -46, 0x98AE95)
        leaf(570, 360, 74, 40, 46, 0x8AA287)
        leaf(505, 300, 34, 60, 0, 0xA4B8A1)
      } else if asset == "sample-tomato" {
        rect(0, 0, 1200, 800, 0xE9E3D8)
        leaf(980, 150, 230, 230, 0, 0xF0EBE1)
        line(
          [CGPoint(x: 600, y: 800), CGPoint(x: 610, y: 520), CGPoint(x: 652, y: 340)], 16, 0x7C937A)
        line([CGPoint(x: 626, y: 470), CGPoint(x: 400, y: 470)], 10, 0x7C937A)
        line([CGPoint(x: 634, y: 420), CGPoint(x: 860, y: 410)], 10, 0x7C937A)
        leaf(420, 450, 80, 34, -18, 0x8EA48B)
        leaf(360, 520, 70, 30, 24, 0x7E977C)
        leaf(500, 520, 64, 28, -40, 0x9AB098)
        leaf(840, 390, 84, 34, 16, 0x8EA48B)
        leaf(900, 470, 70, 30, -26, 0x7E977C)
        leaf(760, 460, 60, 26, 36, 0x9AB098)
        leaf(560, 640, 90, 36, -30, 0x87A085)
        leaf(700, 660, 90, 34, 28, 0x93A891)
        for angle in stride(from: 0.0, to: 360.0, by: 72) {
          let radians = angle * .pi / 180
          leaf(
            652 + CGFloat(sin(radians)) * 34, 340 - CGFloat(cos(radians)) * 34, 16, 34, angle,
            0xE4CF8F)
        }
        leaf(652, 340, 14, 14, 0, 0xC9AD62)
        rect(0, 740, 1200, 60, 0xC3A083)
        rect(0, 728, 1200, 18, 0xB5916F)
      } else {
        rect(0, 0, 1200, 800, 0xECE6DC)
        rect(120, 70, 960, 460, 0xE2E8EA)
        rect(170, 300, 150, 230, 0xD2D9DC)
        rect(340, 250, 110, 280, 0xD8DEE0)
        rect(760, 280, 170, 250, 0xD2D9DC)
        rect(950, 340, 90, 190, 0xD8DEE0)
        leaf(880, 160, 46, 46, 0, 0xF1EDE4)
        context.stroke(
          Path(CGRect(x: 120, y: 70, width: 960, height: 460)), with: .color(color(0xCBC2B4)),
          lineWidth: 18)
        rect(591, 70, 18, 460, 0xCBC2B4)
        rect(0, 640, 1200, 160, 0xD8CDBD)
        rect(60, 548, 1080, 12, 0xB5AB9D)
        for index in 0..<19 { rect(CGFloat(86 + index * 58), 556, 6, 88, 0xBFB6A9) }
        rect(0, 636, 1200, 8, 0xC6BBAB)
        pot(300, 720, 150, 120, 0xC39B7E, 0xB58D70)
        leaf(270, 520, 26, 62, -24, 0x93A891)
        leaf(330, 515, 24, 58, 22, 0x829A80)
        leaf(300, 490, 22, 60, 0, 0x9CB09A)
        pot(600, 724, 170, 128, 0xB98F72, 0xAB8366)
        rect(597, 440, 6, 150, 0x7F967D)
        leaf(560, 470, 30, 14, -30, 0x879D84)
        leaf(640, 500, 32, 14, 28, 0x93A891)
        leaf(565, 540, 28, 13, -18, 0x7B937A)
        leaf(636, 440, 26, 12, 24, 0x9CB09A)
        pot(890, 720, 140, 110, 0xC6A386, 0xB8957A)
        leaf(860, 560, 20, 40, -40, 0x9CB09A)
        leaf(920, 560, 20, 40, 40, 0x879D84)
        leaf(890, 545, 18, 44, 0, 0x93A891)
        rect(1010, 614, 96, 86, 0xA3A39F)
        line([CGPoint(x: 1020, y: 640), CGPoint(x: 964, y: 600)], 12, 0xA3A39F)
      }
    }
  }
}
