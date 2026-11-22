import AppKit
import RedraftCore
import UniformTypeIdentifiers

struct ImageImportTarget: Sendable {
  let articleID: UUID
  let afterBlockID: UUID?
  let replacingBlockID: UUID?
}

enum ImageTransferPayload: Sendable {
  case data(Data)
  case file(URL)
}

@MainActor
enum ImageTransfer {
  static let maximumBytes = 20 * 1024 * 1024

  static func imageOnlyPayload(from pasteboard: NSPasteboard) -> ImageTransferPayload? {
    guard pasteboard.data(forType: .rtf) == nil, pasteboard.data(forType: .rtfd) == nil,
      pasteboard.data(forType: .html) == nil
    else { return nil }
    if let urls = pasteboard.readObjects(
      forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
      urls.count == 1, let url = urls.first,
      UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    {
      return .file(url)
    }
    guard pasteboard.string(forType: .string)?.isEmpty != false else { return nil }
    if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
      return .data(data)
    }
    return nil
  }
}

/// Native file picking and decoding stay outside document actions and Core models.
@MainActor
enum NativeImageImport {
  enum Failure: Error {
    case unsupportedType, tooLarge, invalidImage, unreadableFile
    var message: String {
      switch self {
      case .unsupportedType: "只能插入图片文件"
      case .tooLarge: "图片不能超过 20 MB"
      case .invalidImage: "无法读取这张图片"
      case .unreadableFile: "无法打开这张图片"
      }
    }
  }

  static func chooseFile(replacing: Bool) -> URL? {
    let panel = NSOpenPanel()
    panel.title = replacing ? "替换图片" : "插入图片"
    panel.allowedContentTypes = [.image]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    return panel.runModal() == .OK ? panel.url : nil
  }

  static func load(_ payload: ImageTransferPayload, altText: String = "") throws -> ImageContent {
    switch payload {
    case .data(let data): return try decode(data, altText: altText)
    case .file(let url):
      guard url.isFileURL else { throw Failure.unsupportedType }
      let scoped = url.startAccessingSecurityScopedResource()
      defer { if scoped { url.stopAccessingSecurityScopedResource() } }
      do {
        let resources = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        guard
          resources.contentType?.conforms(to: .image) == true
            || UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
        else { throw Failure.unsupportedType }
        guard (resources.fileSize ?? 0) <= ImageTransfer.maximumBytes else {
          throw Failure.tooLarge
        }
        return try decode(
          try Data(contentsOf: url), altText: url.deletingPathExtension().lastPathComponent)
      } catch let failure as Failure {
        throw failure
      } catch {
        throw Failure.unreadableFile
      }
    }
  }

  private static func decode(_ data: Data, altText: String) throws -> ImageContent {
    guard data.count <= ImageTransfer.maximumBytes else { throw Failure.tooLarge }
    guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else {
      throw Failure.invalidImage
    }
    return ImageContent(data: data, altText: altText)
  }
}

extension WorkspaceViewModel {
  func chooseImage(replacing blockID: UUID? = nil) {
    guard let target = imageImportTarget(after: state.selectedBlockID, replacing: blockID),
      let url = NativeImageImport.chooseFile(replacing: blockID != nil)
    else { return }
    receiveImage(.file(url), target: target)
  }

  func imageImportTarget(after blockID: UUID?, replacing replacementID: UUID? = nil)
    -> ImageImportTarget?
  {
    guard !isEditorLocked, let article = currentArticle,
      blockID == nil || article.blocks.contains(where: { $0.id == blockID }),
      replacementID == nil
        || article.blocks.contains(where: { $0.id == replacementID && $0.kind == .image })
    else { return nil }
    return ImageImportTarget(
      articleID: article.id, afterBlockID: blockID, replacingBlockID: replacementID)
  }

  func receiveImage(_ payload: ImageTransferPayload, target: ImageImportTarget) {
    guard imageTargetIsCurrent(target) else { return }
    do {
      commitImportedImage(try NativeImageImport.load(payload), target: target)
    } catch let failure as NativeImageImport.Failure {
      showNotice(failure.message)
    } catch {
      showNotice("无法读取这张图片")
    }
  }

  func importImageData(_ data: Data, target: ImageImportTarget, altText: String = "") {
    guard imageTargetIsCurrent(target) else { return }
    do {
      commitImportedImage(try NativeImageImport.load(.data(data), altText: altText), target: target)
    } catch let failure as NativeImageImport.Failure {
      showNotice(failure.message)
    } catch {
      showNotice("无法读取这张图片")
    }
  }

  private func commitImportedImage(_ image: ImageContent, target: ImageImportTarget) {
    guard imageTargetIsCurrent(target) else { return }
    if let id = target.replacingBlockID {
      editImage(id) { content in
        content.data = image.data
        content.assetName = nil
      }
      return
    }
    let block = DocumentBlock(image: image)
    mutateSelectedArticle { article in
      let position =
        article.blocks.firstIndex { $0.id == target.afterBlockID }.map { $0 + 1 }
        ?? article.blocks.endIndex
      article.blocks.insert(block, at: position)
    }
    selectBlock(block.id)
  }

  func receiveImageDrop(_ providers: [NSItemProvider], after blockID: UUID?) -> Bool {
    guard let target = imageImportTarget(after: blockID),
      let provider = providers.first(where: {
        $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
          || $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
      })
    else { return false }
    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
      provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) {
        [weak self] data, _ in
        guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else {
          Task { @MainActor [weak self] in self?.imageImportFailed(target: target) }
          return
        }
        Task { @MainActor [weak self] in self?.receiveImage(.file(url), target: target) }
      }
    } else if let type = provider.registeredTypeIdentifiers.first(where: {
      UTType($0)?.conforms(to: .image) == true
    }) {
      provider.loadDataRepresentation(forTypeIdentifier: type) { [weak self] data, _ in
        guard let data else {
          Task { @MainActor [weak self] in self?.imageImportFailed(target: target) }
          return
        }
        Task { @MainActor [weak self] in self?.receiveImage(.data(data), target: target) }
      }
    }
    return true
  }

  private func imageImportFailed(target: ImageImportTarget) {
    guard imageTargetIsCurrent(target) else { return }
    showNotice("无法读取这张图片")
  }

  private func imageTargetIsCurrent(_ target: ImageImportTarget) -> Bool {
    guard !isEditorLocked, let article = currentArticle, article.id == target.articleID else {
      return false
    }
    if let id = target.afterBlockID, !article.blocks.contains(where: { $0.id == id }) {
      return false
    }
    if let id = target.replacingBlockID,
      !article.blocks.contains(where: { $0.id == id && $0.kind == .image })
    {
      return false
    }
    return true
  }
}
