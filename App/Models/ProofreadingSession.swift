import Combine
import Foundation
import RedraftCore

enum ProofreadingStatus: Equatable {
  case waitingForText, waiting, checking, upToDate, failed
}

struct ProofreadingEdit: Equatable, Sendable {
  let articleID: UUID
  let revisionID: UUID
  let blockID: UUID
  let paragraph: String
  let original: String
  let replacement: String
}

@MainActor
final class ProofreadingSession: ObservableObject {
  @Published private(set) var status: ProofreadingStatus = .waitingForText
  @Published private(set) var suggestions: [ProofreadingSuggestion] = []
  @Published private(set) var source: ProofreadingSource?

  private struct CheckedParagraph: Sendable {
    let source: ProofreadingSource
    var suggestions: [ProofreadingSuggestion]
  }

  private let provider: (any ProofreadingProviding)?
  private let delay: Duration
  private var articleID: UUID?
  private var revisionID: UUID?
  private var paragraphs: [ProofreadingParagraph] = []
  private var checked: [UUID: CheckedParagraph] = [:]
  private var checkID = UUID()
  private var task: Task<Void, Never>?

  init(provider: (any ProofreadingProviding)?, delay: Duration) {
    self.provider = provider
    self.delay = delay
  }

  deinit { task?.cancel() }

  func update(_ document: Article?) {
    guard articleID != document?.id || revisionID != document?.revisionID else { return }
    let sameArticle = articleID == document?.id
    articleID = document?.id
    revisionID = document?.revisionID
    let next =
      document?.blocks.compactMap { block -> ProofreadingParagraph? in
        guard block.kind == .text,
          !block.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return ProofreadingParagraph(id: block.id, text: block.plainText)
      } ?? []
    let prior = Dictionary(uniqueKeysWithValues: paragraphs.map { ($0.id, $0.text) })
    if sameArticle, paragraphs.count == next.count,
      zip(paragraphs, next).allSatisfy({
        $0.id == $1.id && $0.text.utf8.elementsEqual($1.text.utf8)
      })
    {
      return
    }

    if sameArticle {
      let unchanged = Set(
        next.filter { paragraph in
          prior[paragraph.id]?.utf8.elementsEqual(paragraph.text.utf8) == true
        }.map(\.id))
      checked = checked.filter { unchanged.contains($0.key) }
    } else {
      checked = [:]
    }
    paragraphs = next
    publishResults()
    schedule()
  }

  func retry() { schedule() }

  func dismiss(_ suggestion: ProofreadingSuggestion) {
    checked[suggestion.blockID]?.suggestions.removeAll { $0.id == suggestion.id }
    publishResults()
  }

  func edit(for suggestion: ProofreadingSuggestion, in document: Article) -> ProofreadingEdit? {
    guard articleID == document.id, revisionID == document.revisionID,
      checked[suggestion.blockID]?.suggestions.contains(suggestion) == true,
      let block = document.blocks.first(where: { $0.id == suggestion.blockID }),
      Self.valid(suggestion, in: block.plainText)
    else { return nil }
    return ProofreadingEdit(
      articleID: document.id, revisionID: document.revisionID, blockID: block.id,
      paragraph: block.plainText, original: suggestion.original, replacement: suggestion.replacement
    )
  }

  private func schedule() {
    task?.cancel()
    task = nil
    checkID = UUID()
    guard !paragraphs.isEmpty else {
      status = .waitingForText
      return
    }
    guard let provider else { return }
    guard paragraphs.contains(where: { checked[$0.id] == nil }) else {
      status = .upToDate
      return
    }

    status = .waiting
    let id = checkID
    let delay = delay
    task = Task { [weak self] in
      do {
        try await Task.sleep(for: delay)
        while let batch = self?.nextBatch(id) {
          self?.status = .checking
          let results = try await Self.check(batch, using: provider)
          try Task.checkCancellation()
          self?.receive(results, for: id)
        }
      } catch {
        if !Task.isCancelled { self?.finish(id, failed: true) }
        return
      }
      self?.finish(id, failed: false)
    }
  }

  private func nextBatch(_ id: UUID) -> [ProofreadingParagraph]? {
    guard checkID == id else { return nil }
    var batch: [ProofreadingParagraph] = []
    var bytes = 0
    for paragraph in paragraphs where checked[paragraph.id] == nil {
      let length = paragraph.text.utf8.count
      guard batch.isEmpty || (batch.count < 6 && bytes + length <= 2400) else { break }
      batch.append(paragraph)
      bytes += length
    }
    return batch.isEmpty ? nil : batch
  }

  private nonisolated static func check(
    _ batch: [ProofreadingParagraph], using provider: any ProofreadingProviding
  ) async throws -> [UUID: CheckedParagraph] {
    if let paragraph = batch.first, batch.count == 1, paragraph.text.utf8.count > 2400 {
      // Cut at nearby sentence boundaries when a pasted paragraph exceeds the model window.
      var remaining = paragraph.text[...]
      var source: ProofreadingSource = .appleIntelligence
      var collected: [ProofreadingSuggestion] = []
      while !remaining.isEmpty {
        try Task.checkCancellation()
        var end = remaining.startIndex
        var boundary: String.Index?
        var bytes = 0
        while end < remaining.endIndex, bytes < 1800 {
          let start = end
          remaining.formIndex(after: &end)
          bytes += remaining[start..<end].utf8.count
          if bytes > 900, "。！？.!?\n".contains(remaining[start]) { boundary = end }
        }
        if end < remaining.endIndex, let boundary { end = boundary }
        let excerpt = ProofreadingParagraph(id: paragraph.id, text: String(remaining[..<end]))
        let result = try await provider.suggestions(for: [excerpt])
        if result.source == .localRules { source = .localRules }
        collected += result.suggestions.filter { $0.blockID == paragraph.id }
        remaining = remaining[end...]
      }
      return [
        paragraph.id: makeRecord(paragraph: paragraph, source: source, suggestions: collected)
      ]
    }

    let result = try await provider.suggestions(for: batch)
    return Dictionary(
      uniqueKeysWithValues: batch.map { paragraph in
        (
          paragraph.id,
          makeRecord(paragraph: paragraph, source: result.source, suggestions: result.suggestions)
        )
      })
  }

  private nonisolated static func makeRecord(
    paragraph: ProofreadingParagraph, source: ProofreadingSource,
    suggestions: [ProofreadingSuggestion]
  ) -> CheckedParagraph {
    CheckedParagraph(
      source: source,
      suggestions: suggestions.filter {
        $0.blockID == paragraph.id && valid($0, in: paragraph.text)
      })
  }

  private nonisolated static func valid(_ suggestion: ProofreadingSuggestion, in text: String)
    -> Bool
  {
    !suggestion.original.utf8.elementsEqual(suggestion.replacement.utf8)
      && !suggestion.original.contains(where: \.isNewline)
      && !suggestion.replacement.contains(where: \.isNewline)
      && uniqueProofreadingRange(of: suggestion.original, in: text) != nil
  }

  private func receive(_ results: [UUID: CheckedParagraph], for id: UUID) {
    guard checkID == id else { return }
    checked.merge(results) { _, latest in latest }
    publishResults()
  }

  private func finish(_ id: UUID, failed: Bool) {
    guard checkID == id else { return }
    task = nil
    status = failed ? .failed : .upToDate
  }

  private func publishResults() {
    let ordered = paragraphs.compactMap { checked[$0.id] }
    suggestions = ordered.flatMap(\.suggestions)
    source = ordered.contains { $0.source == .localRules } ? .localRules : ordered.first?.source
  }
}
