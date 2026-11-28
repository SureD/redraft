import Foundation

/// BlockNote's supported document JSON is a tree; the Core lists the same UUIDs in reading order
/// so search, marks, and reviews can target every block. The JSON embeds neither HTML nor images.
public enum BlockNoteDocument {
  /// Produces a BlockNote block array. Image URLs identify the block, never a file path or a
  /// transient upload. The host serves bytes (including named assets) at that local URL.
  public static func encode(_ blocks: [DocumentBlock]) throws -> Data {
    try validate(blocks)
    var index = 0
    func children(of parent: UUID?, depth: Int) throws -> [BlockNoteJSON] {
      var result: [BlockNoteJSON] = []
      while index < blocks.count, blocks[index].blockNote?.parent == parent {
        guard depth < 64 else { throw EditingError.invalidDocument }
        let block = blocks[index]
        let form = BlockNoteForm(block)
        index += 1
        var node: BlockNoteProps = [
          "id": .string(block.id.uuidString.lowercased()), "type": .string(form.type.rawValue),
          "props": .object(form.props),
          "children": .array(try children(of: block.id, depth: depth + 1)),
        ]
        switch form.body {
        case .inline(let inline): node["content"] = inline.json
        case .table(let table): node["content"] = table.json
        case .image: break  // BlockNote omits undefined `content` for media.
        }
        result.append(.object(node))
      }
      return result
    }
    let root = try children(of: nil, depth: 0)
    guard index == blocks.count else { throw EditingError.invalidDocument }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(root)
  }

  /// Reconcile a complete editor snapshot, or throw without publishing any part. An unmodified
  /// named image need not be available now; copying or uploading an image requires actual bytes.
  /// Empty image placeholders use `url: ""`. During live undo, a canonical handle can resolve to
  /// its original bytes even after a replacement. A resolver is never called for a network/file URL.
  /// BlockNote has no table-axis UUIDs: ambiguous edits retire cell targets, and swaps between
  /// indistinguishable rows/columns cannot be observed. Merged or ragged tables are rejected.
  public static func decode(
    _ data: Data, previous: [DocumentBlock], imageData: (URL) -> Data?
  ) throws -> [DocumentBlock] {
    if !previous.isEmpty { try validate(previous) }
    let original = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
    let nodes = try JSONDecoder().decode([BlockNoteJSON].self, from: data)
    guard !nodes.isEmpty else { throw EditingError.invalidDocument }
    var result: [DocumentBlock] = []
    var ids: Set<UUID> = []
    func visit(_ nodes: [BlockNoteJSON], parent: UUID?, depth: Int) throws {
      for node in nodes {
        guard depth < 64, let object = node.object,
          object.keys.allSatisfy(["id", "type", "props", "content", "children"].contains),
          let name = object["id"]?.string, let id = uuid(name), ids.insert(id).inserted,
          let name = object["type"]?.string, let type = BlockNoteType(rawValue: name)
        else { throw EditingError.invalidDocument }
        let form = try BlockNoteForm(type: type, props: object["props"], content: object["content"])
        let block = try form.block(
          id: id, parent: parent, original: original[id], imageData: imageData)
        try block.validate()
        result.append(block)
        if let children = object["children"] {
          guard let children = children.array else { throw EditingError.invalidDocument }
          try visit(children, parent: id, depth: depth + 1)
        }
      }
    }
    try visit(nodes, parent: nil, depth: 0)
    return result
  }

  private static func validate(_ blocks: [DocumentBlock]) throws {
    guard !blocks.isEmpty, Set(blocks.map(\.id)).count == blocks.count else {
      throw EditingError.invalidDocument
    }
    try validateHierarchy(blocks)
    for block in blocks { try block.validate() }
  }

  // A snapshot cannot silently orphan or reorder a nested block outside its parent's subtree.
  static func validateHierarchy(_ blocks: [DocumentBlock]) throws {
    var ancestors: [UUID] = []
    for block in blocks {
      if let parent = block.blockNote?.parent {
        guard let i = ancestors.lastIndex(of: parent), i < 63 else {
          throw EditingError.invalidDocument
        }
        ancestors.removeSubrange((i + 1)...)
      } else {
        ancestors.removeAll(keepingCapacity: true)
      }
      ancestors.append(block.id)
    }
  }
}

// Only fields not reconstructible from the Core projection need a supplement. In particular,
// image URLs, captions and table/text values are always generated from the live DocumentBlock.
struct BlockNoteMetadata: Equatable, Codable, Sendable {
  var parent: UUID?
  var variant: BlockNoteType?
  var props: BlockNoteProps = [:]
  var inline: BlockNoteInline?
  var table: BlockNoteTableFormat?
}

private let columnWidth = 692.0  // reference CSS pixels for the legacy relative image width
private let imagePrefix = "redraft-image://asset/"

private func uuid(_ s: String) -> UUID? {
  guard let id = UUID(uuidString: s), id.uuidString.lowercased() == s.lowercased() else {
    return nil
  }
  return id
}

private enum BlockNoteBody: Equatable {
  case inline(BlockNoteInline)
  case image
  case table(BlockNoteGrid)
}

private struct BlockNoteForm: Equatable {
  let type: BlockNoteType
  var props: BlockNoteProps
  let body: BlockNoteBody

  init(type: BlockNoteType, props: BlockNoteJSON?, content: BlockNoteJSON?) throws {
    self.type = type
    self.props = try type.properties(props)
    switch type {
    case .image:
      guard content == nil || content == .null, let url = self.props["url"]?.string else {
        throw EditingError.invalidDocument
      }
      if !url.isEmpty {
        guard url.hasPrefix(imagePrefix), let id = uuid(String(url.dropFirst(imagePrefix.count)))
        else {
          throw EditingError.invalidDocument
        }
        self.props["url"] = .string(imagePrefix + id.uuidString.lowercased())
      }
      body = .image
    case .table:
      guard let content else { throw EditingError.invalidDocument }
      body = .table(try BlockNoteGrid(content))
    default:
      guard let content else { throw EditingError.invalidDocument }
      body = .inline(try BlockNoteInline(blockNote: content))
    }
  }

  init(_ block: DocumentBlock) {
    let metadata = block.blockNote
    switch block.content {
    case .text(let text):
      let paragraph = text.paragraphStyle
      if let list = paragraph.list {
        type =
          list.marker == .decimal
          ? .numberedListItem
          : (metadata?.variant == .checkListItem ? .checkListItem : .bulletListItem)
      } else if case .heading = paragraph.kind {
        type = .heading
      } else {
        type = metadata?.variant == .quote ? .quote : .paragraph
      }
      body = .inline(editorInline(text, overlay: metadata?.inline))
      props = type.defaults
      if type != .quote {
        switch paragraph.alignment {
        case .natural, .left: break
        case .center, .right: props["textAlignment"] = .string(paragraph.alignment.rawValue)
        case .justified: props["textAlignment"] = .string("justify")
        }
      }
      if type == .heading, case .heading(let level) = paragraph.kind {
        props["level"] = .number(Double(level))
      }
      if type == .numberedListItem, let start = paragraph.list?.startingItemNumber,
        start != 1 || metadata?.props["start"] == .number(1)
      {
        props["start"] = .number(Double(start))
      }
    case .image(let image):
      type = .image
      body = .image
      props = type.defaults
      if image.assetName != nil || image.data?.isEmpty == false {
        props["url"] = .string(imagePrefix + block.id.uuidString.lowercased())
      }
      props["name"] = .string(image.altText)
      props["caption"] = .string(image.caption)
      if let pixels = metadata?.props["previewWidth"]?.number,
        min(1, pixels / columnWidth) == image.width
      {
        props["previewWidth"] = .number(pixels)
      } else if image.width != 1 {
        props["previewWidth"] = .number(image.width * columnWidth)
      }
    case .table(let table):
      type = .table
      body = .table(BlockNoteGrid(table: table, decoration: metadata?.table))
      props = type.defaults
    }
    // Apply only properties the native content does not own, even if a block changes kind.
    for (key, value) in metadata?.props ?? [:] {
      if type.defaults[key] != nil
        && ["textColor", "backgroundColor", "checked", "showPreview"].contains(key)
        || type == .image && key == "textAlignment"
      {
        props[key] = value
      }
    }
  }

  func block(
    id: UUID, parent: UUID?, original: DocumentBlock?, imageData: (URL) -> Data?
  ) throws -> DocumentBlock {
    let expected = original.map(Self.init)
    let canonical = imagePrefix + id.uuidString.lowercased()
    // The editor can undo an upload back to its immutable original handle. The normalized
    // URL and even every other prop may be identical, while the actual bytes have changed.
    var restoredBytes: Data?
    if type == .image, props["url"] == .string(canonical), let current = original?.image?.data,
      let url = URL(string: canonical), let resolved = imageData(url), !resolved.isEmpty,
      resolved != current
    {
      restoredBytes = resolved
    }
    if var original, self == expected, restoredBytes == nil {
      var meta = original.blockNote ?? .init()
      meta.parent = parent
      original.blockNote = meta == .init() ? nil : meta
      return original
    }
    var meta = BlockNoteMetadata(parent: parent)
    var block: DocumentBlock
    switch body {
    case .inline(let inline):
      let prior = original?.kind == .text ? original?.text : nil
      let kindChanged =
        expected?.type != type || expected?.props["level"] != props["level"]
        || expected?.props["start"] != props["start"]
      let alignmentChanged = expected?.props["textAlignment"] != props["textAlignment"]
      let text: RichTextContent
      if let prior, expected?.body == body, !kindChanged, !alignmentChanged {
        text = prior
      } else {
        text = redraftText(inline: inline, previous: prior) { old in
          var style = old
          if kindChanged {
            style.kind = type == .heading ? .heading(level: props["level"]!.integer!) : .body
            switch type {
            case .bulletListItem, .checkListItem: style.list = ListStyle()
            case .numberedListItem:
              style.list = ListStyle(
                marker: .decimal, startingItemNumber: props["start"]?.integer ?? 1)
            default: style.list = nil
            }
          }
          if alignmentChanged {
            switch props["textAlignment"]?.string {
            case "center": style.alignment = .center
            case "right": style.alignment = .right
            case "justify": style.alignment = .justified
            default: style.alignment = .natural
            }
          }
          return style
        }
      }
      block = .init(id: id, text: text)
      if type == .quote || type == .checkListItem { meta.variant = type }
      if editorInline(text, overlay: nil) != inline { meta.inline = inline }
    case .image:
      let url = props["url"]!.string!
      let pixels = props["previewWidth"]?.number
      var image = original?.image ?? .init()
      if url.isEmpty {
        image.assetName = nil
        image.data = nil
      } else if let restoredBytes {
        image.data = restoredBytes
        image.assetName = nil
      } else if !(url == canonical && (image.data?.isEmpty == false || image.assetName != nil)) {
        guard let local = URL(string: url), let bytes = imageData(local), !bytes.isEmpty else {
          throw EditingError.invalidDocument
        }
        image.data = bytes
        image.assetName = nil
      }
      image.caption = props["caption"]!.string!
      image.altText = props["name"]!.string!
      // Preserve exact legacy fractions when a caption is the only changed field.
      if original?.image == nil || expected?.props["previewWidth"] != props["previewWidth"] {
        image.width = pixels.map { min(1, $0 / columnWidth) } ?? 1
      }
      block = .init(id: id, image: image)
    case .table(let grid):
      let previousGrid: BlockNoteGrid? =
        if case .table(let prior) = expected?.body { prior } else { nil }
      let (table, format) = grid.project(previous: original?.table, previousGrid: previousGrid)
      block = .init(id: id, table: table)
      meta.table = format
    }
    // Store deviations only; default props added by BlockNote must not dirty a legacy document.
    let defaults = type.defaults
    for key in ["textColor", "backgroundColor", "checked", "showPreview", "textAlignment"] {
      if key == "textAlignment" && type != .image { continue }
      if let value = props[key], value != defaults[key] { meta.props[key] = value }
    }
    if props["start"] == .number(1) { meta.props["start"] = .number(1) }
    if let width = props["previewWidth"], let image = block.image,
      image.width == 1 || width != .number(image.width * columnWidth)
    {
      meta.props["previewWidth"] = width
    }
    block.blockNote = meta == .init() ? nil : meta
    return block
  }
}
