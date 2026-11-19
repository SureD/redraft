import Foundation
import RedraftCore

/// A read-only projection, computed from a session; never a second writable document.
struct ArticleViewState: Identifiable {
  let document: Article
  let versions: [ArticleVersion]
  let review: ReviewState

  var id: UUID { document.id }
  var title: String { document.title }
  var updatedAt: Date { document.updatedAt }
  var blocks: [DocumentBlock] { document.blocks }
  var marks: [UUID: String] { document.marks }
  var changes: [ReviewChange] { review.changes }
  var characterCount: Int { blocks.reduce(0) { $0 + $1.plainText.count } }
  var preview: String { blocks.first(where: { $0.kind == .text })?.plainText ?? "空白文章" }
  var phase: ArticlePhase {
    switch review {
    case .idle, .failed: .idle
    case .running: .running
    case .ready: .ready
    }
  }

  @MainActor
  init(session: ArticleSession) {
    document = session.document
    versions = session.versions
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
