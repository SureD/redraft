import Foundation
import RedraftCore
import UniformTypeIdentifiers

/// Markdown and its attachments leave the app together. A previous export is never overwritten.
struct MarkdownExport {
  let title: String
  let paths: [String: String]
  private let files: [String: Data]

  @MainActor init(article: Article, images: EditorImages) throws {
    title = article.title.components(separatedBy: .newlines).joined(separator: " ")
    var names: [String: String] = [:]
    var bytes: [String: Data] = [:]
    for block in article.blocks {
      guard let image = block.image, image.data != nil || image.assetName != nil else { continue }
      let id = block.id.uuidString.lowercased()
      guard let data = images.data(for: image), let mime = EditorImages.mime(of: data),
        let ext = UTType(mimeType: mime)?.preferredFilenameExtension
      else { throw CocoaError(.fileReadCorruptFile) }
      let path = "assets/\(id).\(ext)"
      names[id] = path
      bytes[path] = data
    }
    paths = names
    files = bytes
  }

  @discardableResult func write(_ markdown: String, in parent: URL) throws -> URL {
    let fm = FileManager.default
    let staging = parent.appendingPathComponent(".redraft-\(UUID())", isDirectory: true)
    try fm.createDirectory(at: staging, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: staging) }
    let text = title.isEmpty ? markdown : "# \(title)\n\n" + markdown
    try text.write(to: staging.appendingPathComponent("稿件.md"), atomically: true, encoding: .utf8)
    if !files.isEmpty {
      try fm.createDirectory(
        at: staging.appendingPathComponent("assets"), withIntermediateDirectories: false)
      for (name, data) in files { try data.write(to: staging.appendingPathComponent(name)) }
    }
    let safeTitle = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(
      of: ":", with: "-"
    )
    .trimmingCharacters(
      in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    let name = safeTitle.isEmpty ? "未命名文章" : String(safeTitle.prefix(40))
    var folder = parent.appendingPathComponent(name, isDirectory: true)
    var counter = 1
    while fm.fileExists(atPath: folder.path) {
      counter += 1
      folder = parent.appendingPathComponent("\(name) \(counter)", isDirectory: true)
    }
    try fm.moveItem(at: staging, to: folder)
    return folder
  }
}
