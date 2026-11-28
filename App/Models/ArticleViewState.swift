import Foundation
import RedraftCore

/// A read-only projection, computed from a session; never a second writable document.
struct ArticleViewState: Identifiable {
  let document: Article
  let versions: [ArticleVersion]
  let rounds: [AnnotationRound]
  let review: ReviewState

  var id: UUID { document.id }
  var title: String { document.title }
  var displayTitle: String {
    if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
    // A library of untitled drafts should still be recognizable without opening each one.
    for block in blocks where block.kind == .text {
      for raw in block.plainText.split(whereSeparator: \.isNewline) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if !line.isEmpty { return String(line.prefix(36)) }
      }
    }
    return "未命名文章"
  }
  var updatedAt: Date { document.updatedAt }
  var blocks: [DocumentBlock] { document.blocks }
  var marks: [UUID: String] { document.marks }
  var changes: [ReviewChange] { review.changes }
  var characterCount: Int { blocks.reduce(0) { $0 + $1.plainText.count } }
  var phase: ArticlePhase {
    switch review {
    case .idle, .noSuggestions, .failed: .idle
    case .running: .running
    case .ready: .ready
    }
  }

  @MainActor
  init(session: ArticleSession) {
    document = session.document
    versions = session.versions
    rounds = session.rounds
    review = session.review
  }
}

extension ReviewDecision {
  var title: String {
    switch self {
    case .accept: "采用"
    case .keep: "保留原文"
    case .rewrite: "自己改写"
    }
  }
}
