import Foundation

extension DocumentBlock {
  /// All suggestions describe the same source block. Merge their individual edits, never snapshots.
  func applyingAnnotations(_ changes: [ReviewChange]) throws -> DocumentBlock {
    var result = self
    switch content {
    case .text(let text):
      result.text = try text.applyingAnnotations(changes)
    case .image(var image):
      let replacements = changes.filter { $0.kind == .image }
      guard replacements.count <= 1, changes.allSatisfy({ $0.kind == .text || $0.kind == .image })
      else { throw EditingError.invalidReview }
      if let replacement = replacements.first {
        guard let proposed = replacement.afterBlock?.image else { throw EditingError.invalidTarget }
        let caption = image.caption
        image = proposed
        image.caption = caption
      }
      let captions = changes.filter { $0.kind == .text }
      image.caption = try RichTextContent(string: image.caption).applyingAnnotations(captions)
        .string
      result.image = image
    case .table(let table):
      result.table = try table.applyingAnnotations(changes)
    }
    return result
  }
}

extension RichTextContent {
  fileprivate func applyingAnnotations(_ changes: [ReviewChange]) throws -> RichTextContent {
    let edits = try changes.flatMap { change -> [TextEdit] in
      guard change.kind == .text else { throw EditingError.invalidTarget }
      let sourceRange: NSRange
      if string == change.before {
        sourceRange = NSRange(location: 0, length: string.utf16.count)
      } else {
        // A plain-string fragment is a usable anchor only when it identifies exactly one place.
        let source = string as NSString
        let first = source.range(of: change.before, options: .literal)
        let last = source.range(of: change.before, options: [.literal, .backwards])
        guard !change.before.isEmpty, first.location != NSNotFound, first == last else {
          throw EditingError.invalidTarget
        }
        _ = try range(forUTF16: first)
        sourceRange = first
      }
      let fragment = (string as NSString).substring(with: sourceRange)
      return change.characterEdits(in: fragment, startingAt: sourceRange.location)
    }.sorted { $0.range.location > $1.range.location }

    var result = self
    var previous: NSRange?
    for edit in edits {
      if let previous,
        NSMaxRange(edit.range) > previous.location || edit.range.location == previous.location
      {
        throw EditingError.invalidReview
      }
      try result.replace(edit.range, with: edit.replacement)
      previous = edit.range
    }
    return result.normalized()
  }

  private mutating func replace(_ range: NSRange, with replacement: String) throws {
    let indices = try self.range(forUTF16: range)
    // New text inherits the formatting at the edit; unaffected runs keep their original styling.
    let inheritedOffset = min(range.location, max(0, string.utf16.count - 1))
    let inherited = runs.first { NSLocationInRange(inheritedOffset, $0.range) }
    let end = NSMaxRange(range)
    let insertedLength = replacement.utf16.count
    let delta = insertedLength - range.length
    var updated: [RichTextRun] = []
    for run in runs {
      let start = run.range.location
      let stop = NSMaxRange(run.range)
      if start < range.location {
        var left = run
        left.range.length = min(stop, range.location) - start
        updated.append(left)
      }
      if stop > end {
        var right = run
        let surviving = max(start, end)
        right.range = NSRange(location: surviving + delta, length: stop - surviving)
        updated.append(right)
      }
    }
    if var inserted = inherited, insertedLength > 0 {
      inserted.range = NSRange(location: range.location, length: insertedLength)
      updated.append(inserted)
    }
    string.replaceSubrange(indices, with: replacement)
    runs = updated.sorted { $0.range.location < $1.range.location }
  }
}

extension ReviewChange {
  fileprivate var chosenText: String { decision == .rewrite ? rewrittenText : after }

  /// Keep common characters and their style runs when a provider returns a whole new paragraph.
  fileprivate func characterEdits(in source: String, startingAt offset: Int) -> [TextEdit] {
    let original = Array(source)
    let suggested = Array(chosenText)
    let difference = suggested.difference(from: original)
    var removed: Set<Int> = []
    var inserted: Set<Int> = []
    for change in difference {
      switch change {
      case .remove(let offset, _, _): removed.insert(offset)
      case .insert(let offset, _, _): inserted.insert(offset)
      }
    }
    var old = 0
    var new = 0
    var location = offset
    var edits: [TextEdit] = []
    while old < original.count || new < suggested.count {
      if !removed.contains(old), !inserted.contains(new) {
        location += original[old].utf16.count
        old += 1
        new += 1
        continue
      }
      let start = location
      let replacementStart = new
      while removed.contains(old) {
        location += original[old].utf16.count
        old += 1
      }
      while inserted.contains(new) { new += 1 }
      edits.append(
        TextEdit(
          blockID: blockID, range: NSRange(location: start, length: location - start),
          replacement: String(suggested[replacementStart..<new])))
    }
    return edits
  }
}

extension TableContent {
  fileprivate func applyingAnnotations(_ changes: [ReviewChange]) throws -> TableContent {
    var result = self
    var modifiedCells: Set<[UUID]> = []
    // Apply independent cell changes before structural changes, so their coordinates refer to source.
    for change in changes where change.kind == .text {
      guard let proposed = change.afterBlock?.table, proposed.rowIDs == rowIDs,
        proposed.columnIDs == columnIDs
      else { throw EditingError.invalidTarget }
      var cells: [(Int, Int)] = []
      for row in rows.indices {
        for col in columnIDs.indices where rows[row][col] != proposed.rows[row][col] {
          cells.append((row, col))
        }
      }
      guard cells.count == 1, let (row, col) = cells.first, rows[row][col] == change.before,
        proposed.rows[row][col] == change.after,
        modifiedCells.insert([rowIDs[row], columnIDs[col]]).inserted
      else { throw EditingError.invalidReview }
      result.rows[row][col] = change.chosenText
    }
    for change in changes where change.kind != .text {
      guard let proposal = change.afterBlock?.table else { throw EditingError.invalidTarget }
      switch change.kind {
      case .tableRow:
        guard proposal.columnIDs == columnIDs else { throw EditingError.invalidTarget }
        let ids = try Self.mergedIDs(
          base: rowIDs, proposal: proposal.rowIDs, current: result.rowIDs)
        result.rows = ids.map { rowID in
          if let existing = result.rowIDs.firstIndex(of: rowID) { return result.rows[existing] }
          return result.columnIDs.map { proposal.value(row: rowID, column: $0) ?? "" }
        }
        result.rowIDs = ids
      case .tableColumn:
        guard proposal.rowIDs == rowIDs else { throw EditingError.invalidTarget }
        let ids = try Self.mergedIDs(
          base: columnIDs, proposal: proposal.columnIDs, current: result.columnIDs)
        result.rows = result.rowIDs.map { rowID in
          ids.map { columnID in
            result.value(row: rowID, column: columnID)
              ?? proposal.value(row: rowID, column: columnID) ?? ""
          }
        }
        result.columnIDs = ids
      default: throw EditingError.invalidTarget
      }
    }
    try result.validate()
    return result
  }

  private func value(row: UUID, column: UUID) -> String? {
    guard let r = rowIDs.firstIndex(of: row), let c = columnIDs.firstIndex(of: column) else {
      return nil
    }
    return rows[r][c]
  }

  /// Each structural annotation adds or removes rows or columns relative to the original IDs.
  private static func mergedIDs(base: [UUID], proposal: [UUID], current: [UUID]) throws -> [UUID] {
    let baseIDs = Set(base)
    let proposedIDs = Set(proposal)
    guard base != proposal, base.filter(proposedIDs.contains) == proposal.filter(baseIDs.contains)
    else { throw EditingError.invalidReview }
    let removed = baseIDs.subtracting(proposedIDs)
    guard removed.isSubset(of: Set(current)) else { throw EditingError.invalidReview }
    var result = current.filter { !removed.contains($0) }
    for (index, id) in proposal.enumerated() where !baseIDs.contains(id) {
      guard !result.contains(id) else { throw EditingError.invalidReview }
      let following = proposal[(index + 1)...].first(where: result.contains)
      let position = following.flatMap { result.firstIndex(of: $0) } ?? result.endIndex
      result.insert(id, at: position)
    }
    return result
  }
}
