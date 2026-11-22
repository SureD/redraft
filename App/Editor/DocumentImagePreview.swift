import AppKit
import RedraftCore
import SwiftUI

protocol DocumentImageResolving: Sendable {
  @MainActor func image(for assetName: String) -> NSImage?
}

struct BundleImageResolver: DocumentImageResolving {
  @MainActor func image(for assetName: String) -> NSImage? {
    NSImage(named: NSImage.Name(assetName))
  }
}

private struct DocumentImageResolverKey: EnvironmentKey {
  static let defaultValue: any DocumentImageResolving = BundleImageResolver()
}

extension EnvironmentValues {
  var documentImageResolver: any DocumentImageResolving {
    get { self[DocumentImageResolverKey.self] }
    set { self[DocumentImageResolverKey.self] = newValue }
  }
}

struct DocumentImagePreview: View {
  let content: ImageContent
  @Environment(\.documentImageResolver) private var imageResolver

  @MainActor static func image(for content: ImageContent, resolver: any DocumentImageResolving)
    -> NSImage?
  {
    // Invalid imported bytes are a missing image, never a request for a sample fallback.
    if let data = content.data { return NSImage(data: data) }
    return content.assetName.flatMap { resolver.image(for: $0) }
  }

  @MainActor static func ratio(for content: ImageContent, resolver: any DocumentImageResolving)
    -> CGFloat
  {
    guard let image = image(for: content, resolver: resolver), image.size.height > 0 else {
      return 3 / 2
    }
    return image.size.width / image.size.height
  }

  var body: some View {
    Group {
      if let image = Self.image(for: content, resolver: imageResolver) {
        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
      } else {
        ZStack {
          PaperTheme.secondaryPaper
          Label("图片无法显示", systemImage: "photo.badge.exclamationmark")
            .font(.callout).foregroundStyle(.secondary)
        }
        .aspectRatio(3 / 2, contentMode: .fit)
      }
    }
    .accessibilityLabel(content.altText.isEmpty ? "文章插图" : content.altText)
  }
}
