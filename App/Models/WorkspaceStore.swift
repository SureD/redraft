import Combine
import Foundation
import RedraftCore

/// Owns the article collection, not copies of the sessions' current documents.
/// Multiple windows can share this store while keeping independent WorkspaceState values.
@MainActor
final class WorkspaceStore: ObservableObject {
  @Published private(set) var sessions: [ArticleSession] = []
  @Published private(set) var examples: [RewriteExample] = []
  /// Unlike objectWillChange, this signal always sees the committed collection/session values.
  let changes = PassthroughSubject<Void, Never>()
  private var observations: [UUID: UUID] = [:]

  init() {}

  convenience init(seed: WorkspaceSeed) throws {
    self.init()
    var ids = Set<UUID>()
    for item in seed.articles {
      guard ids.insert(item.document.id).inserted else {
        throw WorkspaceStoreError.duplicateArticle
      }
      let session = try ArticleSession(
        document: item.document, versions: item.versions,
        review: item.review.map(ReviewState.ready) ?? .idle)
      attach(session)
      sessions.append(session)
    }
    examples = seed.examples.filter { ids.contains($0.articleID) }
  }

  func session(for id: UUID?) -> ArticleSession? {
    sessions.first { $0.document.id == id }
  }

  func insert(_ document: Article) throws {
    guard session(for: document.id) == nil else { throw WorkspaceStoreError.duplicateArticle }
    let session = try ArticleSession(document: document)
    attach(session)
    sessions.insert(session, at: 0)
    changes.send()
  }

  func delete(_ id: UUID) {
    guard let session = session(for: id) else { return }
    if let token = observations.removeValue(forKey: id) { session.removeObserver(token) }
    session.cancelReview()
    sessions.removeAll { $0.document.id == id }
    examples.removeAll { $0.articleID == id }
    changes.send()
  }

  func finishPreviewReview(articleID: UUID) throws {
    guard let session = session(for: articleID) else { return }
    examples.append(contentsOf: try session.finishPreviewReview())
    changes.send()
  }

  private func attach(_ session: ArticleSession) {
    observations[session.document.id] = session.observe { [weak self] in
      self?.objectWillChange.send()
      self?.changes.send()
    }
  }
}

enum WorkspaceStoreError: Error { case duplicateArticle }
