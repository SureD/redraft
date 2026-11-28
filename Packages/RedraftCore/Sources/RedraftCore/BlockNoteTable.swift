import Foundation

struct BlockNoteCell: Equatable, Codable, Sendable {
  var content: BlockNoteInline
  var props: BlockNoteProps = [:]

  static let defaults: BlockNoteProps = [
    "colspan": .number(1), "rowspan": .number(1), "textAlignment": .string("left"),
    "textColor": .string("default"), "backgroundColor": .string("default"),
  ]

  init(_ json: BlockNoteJSON) throws {
    if let cell = json.object {
      guard cell["type"] == .string("tableCell"), let inline = cell["content"],
        cell.keys.allSatisfy(["type", "props", "content"].contains)
      else { throw EditingError.invalidDocument }
      content = try BlockNoteInline(blockNote: inline)
      props = try blockNoteProps(cell["props"], allowed: Set(Self.defaults.keys)).filter {
        $0.value != Self.defaults[$0.key]
      }
    } else {
      content = try BlockNoteInline(blockNote: json)
    }
  }

  init(text: String, decoration: Self?) {
    self = decoration ?? Self(content: [])
    guard !text.utf8.elementsEqual(content.map(\.text).joined().utf8) else { return }
    content = overlaySpans(content, onto: [.init(text: text, attributes: BlockNoteMarks())]) {
      $0 ?? $1
    }
    .filter { !$0.text.isEmpty }
  }

  private init(content: BlockNoteInline) { self.content = content }

  var json: BlockNoteJSON {
    .object([
      "type": .string("tableCell"), "content": content.json,
      "props": .object(Self.defaults.merging(props) { _, supplied in supplied }),
    ])
  }
  var isDecorated: Bool { !props.isEmpty || content.contains { $0.attributes != .init() } }
}

// Decorations are attached to actual Redraft axis UUIDs, never reused by array index when a
// native review inserts/removes a row or column. Only decorated cells carry an inline anchor.
struct BlockNoteTableFormat: Equatable, Codable, Sendable {
  var cells: [UUID: [UUID: BlockNoteCell]] = [:]
  var widths: [UUID: Double] = [:]
  var headerRows = 0
  var headerCols = 0
}

struct BlockNoteGrid: Equatable {
  var rows: [[BlockNoteCell]]
  var widths: [Double?]
  var headerRows: Int
  var headerCols: Int

  init(_ raw: BlockNoteJSON) throws {
    guard let table = raw.object, table["type"] == .string("tableContent"),
      table.keys.allSatisfy(["type", "columnWidths", "headerRows", "headerCols", "rows"].contains),
      let data = table["rows"]?.array, !data.isEmpty
    else { throw EditingError.invalidDocument }
    rows = try data.map { row in
      guard let object = row.object, object.count == 1, let cells = object["cells"]?.array else {
        throw EditingError.invalidDocument
      }
      return try cells.map(BlockNoteCell.init(_:))
    }
    let columns = rows[0].count
    guard columns > 0, rows.allSatisfy({ $0.count == columns }) else {
      throw EditingError.invalidDocument
    }
    if let supplied = table["columnWidths"] {
      guard let values = supplied.array, values.count == columns else {
        throw EditingError.invalidDocument
      }
      widths = try values.map {
        if $0 == .null { return nil }
        guard let width = $0.number, width > 0 else { throw EditingError.invalidDocument }
        return width
      }
    } else {
      widths = Array(repeating: nil, count: columns)
    }
    func header(_ key: String, limit: Int) throws -> Int {
      guard let value = table[key] else { return 0 }
      guard let n = value.integer, (0...limit).contains(n) else {
        throw EditingError.invalidDocument
      }
      return n
    }
    headerRows = try header("headerRows", limit: rows.count)
    headerCols = try header("headerCols", limit: columns)
    normalizeHeaders()
  }

  init(table: TableContent, decoration: BlockNoteTableFormat?) {
    rows = table.rows.enumerated().map { r, row in
      row.enumerated().map { c, text in
        BlockNoteCell(
          text: text, decoration: decoration?.cells[table.rowIDs[r]]?[table.columnIDs[c]])
      }
    }
    widths = table.columnIDs.map { decoration?.widths[$0] }
    headerRows = table.hasHeader ? min(rows.count, max(1, decoration?.headerRows ?? 0)) : 0
    headerCols = min(widths.count, decoration?.headerCols ?? 0)
    normalizeHeaders()
  }

  // BlockNote infers headers from cell roles; an all-header row in a one-row table is also
  // a header for every column. Canonicalizing both directions avoids a spurious legacy edit.
  private mutating func normalizeHeaders() {
    if headerRows == rows.count || headerCols == widths.count {
      headerRows = rows.count
      headerCols = widths.count
    }
  }

  func project(previous: TableContent?, previousGrid: Self?) -> (
    TableContent, BlockNoteTableFormat?
  ) {
    let strings = rows.map { $0.map { $0.content.map(\.text).joined() } }
    var table = TableContent(rows: strings, hasHeader: headerRows > 0)
    if let old = previous, let source = previousGrid {
      func columns<T>(_ rows: [[T]]) -> [[T]] { rows[0].indices.map { c in rows.map { $0[c] } } }
      if old.rowIDs.count != table.rowIDs.count || old.columnIDs.count != table.columnIDs.count {
        // The resized axis has no trustworthy IDs. Keep the other one only for a pure insertion/
        // deletion, not e.g. a resize combined with reordering columns or replacing the table.
        func isInsertionOrDeletion<T: Equatable>(_ a: [T], _ b: [T]) -> Bool {
          let (short, long) = a.count < b.count ? (a, b) : (b, a)
          var index = 0
          for value in long where index < short.count && short[index] == value { index += 1 }
          return index == short.count
        }
        if old.columnIDs.count == table.columnIDs.count, source.widths == widths,
          isInsertionOrDeletion(source.rows, rows)
        {
          table.columnIDs = old.columnIDs
        }
        if old.rowIDs.count == table.rowIDs.count,
          isInsertionOrDeletion(columns(source.rows), columns(rows))
        {
          table.rowIDs = old.rowIDs
        }
      } else {
        // A same-sized replacement/reorder is not evidence of identity. Only unique unchanged
        // text at its original position is an anchor. Identical grids are stable, but a swap
        // among duplicate vectors can also be observable in their marks, props or column widths.
        let sameText = old.rows == strings
        func retained(
          _ before: [[String]], _ after: [[String]], _ ids: [UUID], changed: (Int) -> Bool
        ) -> [UUID] {
          let counts = Dictionary(before.map { ($0, 1) }, uniquingKeysWith: +)
          let afterCounts = Dictionary(after.map { ($0, 1) }, uniquingKeysWith: +)
          let ambiguous = Set(
            after.indices.compactMap { i in
              sameText && counts[after[i]] != 1 && changed(i) ? after[i] : nil
            })
          return after.indices.map { i in
            if sameText { return ambiguous.contains(after[i]) ? UUID() : ids[i] }
            return before[i] == after[i] && counts[after[i]] == 1 && afterCounts[after[i]] == 1
              ? ids[i] : UUID()
          }
        }
        table.rowIDs = retained(old.rows, strings, old.rowIDs) { source.rows[$0] != rows[$0] }
        table.columnIDs = retained(columns(old.rows), columns(strings), old.columnIDs) { c in
          source.widths[c] != widths[c]
            || rows.indices.contains { source.rows[$0][c] != rows[$0][c] }
        }
      }
    }
    var format = BlockNoteTableFormat()
    if headerRows > 1 { format.headerRows = headerRows }
    // A grid consisting entirely of header rows generates headerCols automatically.
    if headerRows != rows.count { format.headerCols = headerCols }
    for (c, width) in widths.enumerated() { format.widths[table.columnIDs[c]] = width }
    for (r, row) in rows.enumerated() {
      for (c, cell) in row.enumerated() where cell.isDecorated {
        format.cells[table.rowIDs[r], default: [:]][table.columnIDs[c]] = cell
      }
    }
    return (table, format == .init() ? nil : format)
  }

  var json: BlockNoteJSON {
    var table: BlockNoteProps = [
      "type": .string("tableContent"),
      "columnWidths": .array(widths.map { $0.map(BlockNoteJSON.number) ?? .null }),
      "rows": .array(rows.map { .object(["cells": .array($0.map(\.json))]) }),
    ]
    if headerRows > 0 { table["headerRows"] = .number(Double(headerRows)) }
    if headerCols > 0 { table["headerCols"] = .number(Double(headerCols)) }
    return .object(table)
  }
}
