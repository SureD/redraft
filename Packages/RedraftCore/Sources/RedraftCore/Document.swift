import Foundation

/// A value snapshot of one structured document. ArticleSession owns the writable current snapshot.
public struct Article: Identifiable, Equatable, Sendable {
  public var id: UUID
  public var revisionID: UUID
  public var title: String
  public var updatedAt: Date
  public var blocks: [DocumentBlock]
  public var marks: [UUID: String]
  public var source: EditSource

  public init(
    id: UUID = UUID(), revisionID: UUID = UUID(), title: String,
    updatedAt: Date = Date(), blocks: [DocumentBlock], marks: [UUID: String] = [:],
    source: EditSource = .author
  ) {
    self.id = id
    self.revisionID = revisionID
    self.title = title
    self.updatedAt = updatedAt
    self.blocks = blocks
    self.marks = marks
    self.source = source
  }

  public var characterCount: Int { blocks.reduce(0) { $0 + $1.plainText.count } }

  /// A title alone has no paragraph to annotate.
  public var canRequestAnnotations: Bool {
    blocks.contains { block in
      block.kind != .text
        || !block.text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  public func normalized() -> Article {
    var result = self
    result.blocks = blocks.map { $0.normalized() }
    return result
  }

  /// Text selections are block-local UTF-16 coordinates in this exact revision.
  public func range(forUTF16 selection: NSRange, in blockID: UUID) throws -> Range<String.Index> {
    guard let block = blocks.first(where: { $0.id == blockID }), block.kind == .text else {
      throw EditingError.invalidTarget
    }
    return try block.text.range(forUTF16: selection)
  }

  public func validate() throws {
    let ids = Set(blocks.map(\.id))
    guard !blocks.isEmpty, ids.count == blocks.count,
      marks.keys.allSatisfy({ ids.contains($0) })
    else { throw EditingError.invalidDocument }
    for block in blocks { try block.validate() }
  }
}

public enum BlockKind: String, Equatable, Sendable { case text, image, table }

public enum BlockContent: Equatable, Sendable {
  case text(RichTextContent)
  case image(ImageContent)
  case table(TableContent)
}

public struct DocumentBlock: Identifiable, Equatable, Sendable {
  public var id: UUID
  public var content: BlockContent

  public init(id: UUID = UUID(), content: BlockContent = .text(RichTextContent())) {
    self.id = id
    self.content = content
  }

  public init(id: UUID = UUID(), text: RichTextContent) { self.init(id: id, content: .text(text)) }
  public init(id: UUID = UUID(), image: ImageContent) { self.init(id: id, content: .image(image)) }
  public init(id: UUID = UUID(), table: TableContent) { self.init(id: id, content: .table(table)) }

  public var kind: BlockKind {
    switch content {
    case .text: .text
    case .image: .image
    case .table: .table
    }
  }

  /// Convenience accessors never change a block's content case implicitly.
  public var text: RichTextContent {
    get { if case .text(let value) = content { value } else { RichTextContent() } }
    set { if case .text = content { content = .text(newValue) } }
  }

  public var image: ImageContent? {
    get { if case .image(let value) = content { value } else { nil } }
    set { if case .image = content, let newValue { content = .image(newValue) } }
  }

  public var table: TableContent? {
    get { if case .table(let value) = content { value } else { nil } }
    set { if case .table = content, let newValue { content = .table(newValue) } }
  }

  /// Search/export text only; this projection cannot reconstruct a structured document.
  public var plainText: String {
    switch content {
    case .text(let value): value.string
    case .image(let value): value.caption
    case .table(let value): value.rows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
    }
  }

  public func normalized() -> DocumentBlock {
    var result = self
    if case .text(let value) = content { result.content = .text(value.normalized()) }
    return result
  }

  public func validate() throws {
    switch content {
    case .text(let value): try value.validate()
    case .image(let value):
      guard value.width.isFinite, value.width > 0, value.width <= 1 else {
        throw EditingError.invalidDocument
      }
    case .table(let value): try value.validate()
    }
  }
}

public struct ImageContent: Equatable, Sendable {
  public var assetName: String?
  public var data: Data?
  public var caption: String
  public var altText: String
  public var width: Double

  public init(
    assetName: String? = nil, data: Data? = nil, caption: String = "", altText: String = "",
    width: Double = 1
  ) {
    self.assetName = assetName
    self.data = data
    self.caption = caption
    self.altText = altText
    self.width = width
  }
}

public struct TableContent: Equatable, Sendable {
  public var rows: [[String]]
  public var hasHeader: Bool
  public var rowIDs: [UUID]
  public var columnIDs: [UUID]
  public var columnCount: Int { rows.first?.count ?? 0 }

  public init(rows: [[String]], hasHeader: Bool = true) {
    self.rows = rows
    self.hasHeader = hasHeader
    rowIDs = rows.map { _ in UUID() }
    columnIDs = (0..<(rows.first?.count ?? 0)).map { _ in UUID() }
  }

  public func validate() throws {
    guard !rows.isEmpty, columnCount > 0,
      rows.allSatisfy({ $0.count == columnCount }),
      rowIDs.count == rows.count, Set(rowIDs).count == rowIDs.count,
      columnIDs.count == columnCount, Set(columnIDs).count == columnIDs.count
    else { throw EditingError.invalidDocument }
  }
}

/// Immutable, explicitly identified history. It is not another writable current document.
public struct ArticleVersion: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let title: String
  public let date: Date
  public let document: Article
  public var revisionID: UUID { document.revisionID }
  public var blocks: [DocumentBlock] { document.blocks }

  public init(id: UUID = UUID(), title: String, date: Date = Date(), document: Article) {
    self.id = id
    self.title = title
    self.date = date
    self.document = document.normalized()
  }
}
