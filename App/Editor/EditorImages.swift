import AppKit
import ImageIO
import RedraftCore
import UniformTypeIdentifiers
import WebKit

/// The page sees only editor-local asset handles. Image bytes cross the message bridge once, not per keystroke.
@MainActor final class EditorImages: NSObject, WKURLSchemeHandler {
  private let resolver: any DocumentImageResolving
  // Keep removed images while this editor's undo history can still reference them.
  private var assets: [UUID: ImageContent] = [:]
  private static let mimeTypes = ["image/png", "image/jpeg", "image/gif", "image/webp"]
  private static let limit = 12 * 1024 * 1024

  init(resolver: any DocumentImageResolving) { self.resolver = resolver }

  func reset(to blocks: [DocumentBlock]) {
    assets.removeAll()
    remember(blocks)
  }

  func remember(_ blocks: [DocumentBlock]) {
    // The original handle can reappear on undo after a replacement gets a new upload handle.
    for block in blocks where assets[block.id] == nil {
      if let image = block.image, image.data != nil || image.assetName != nil {
        assets[block.id] = image
      }
    }
  }

  func stage(_ input: String) -> URL? {
    guard input.utf8.count <= Self.limit / 3 * 4 + 64, let comma = input.firstIndex(of: ","),
      let declared = Self.mimeTypes.first(where: { input[..<comma] == "data:\($0);base64" }),
      let bytes = Data(base64Encoded: String(input[input.index(after: comma)...])),
      bytes.count <= Self.limit,
      Self.mime(of: bytes) == declared
    else { return nil }
    let id = UUID()
    assets[id] = ImageContent(data: bytes)
    return URL(string: "redraft-image://asset/\(id.uuidString.lowercased())")
  }

  func data(for url: URL) -> Data? {
    guard url.scheme == "redraft-image", url.host == "asset", url.pathComponents.count == 2,
      let id = UUID(uuidString: url.lastPathComponent), let image = assets[id]
    else { return nil }
    return data(for: image)
  }

  func data(for image: ImageContent) -> Data? {
    if let bytes = image.data { return bytes }
    guard let name = image.assetName, let tiff = resolver.image(for: name)?.tiffRepresentation
    else { return nil }
    return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
  }

  static func mime(of bytes: Data) -> String? {
    guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
      CGImageSourceGetCount(source) > 0,
      let identifier = CGImageSourceGetType(source)
    else { return nil }
    return UTType(identifier as String)?.preferredMIMEType
  }

  func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
    guard let url = task.request.url, let bytes = data(for: url), let mime = Self.mime(of: bytes)
    else {
      task.didFailWithError(URLError(.resourceUnavailable))
      return
    }
    task.didReceive(
      URLResponse(
        url: url, mimeType: mime, expectedContentLength: bytes.count, textEncodingName: nil))
    task.didReceive(bytes)
    task.didFinish()
  }

  func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
