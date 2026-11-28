import Combine
import Foundation
import RedraftCore

/// Owns the article collection, not copies of the sessions' writable current documents.
@MainActor
final class WorkspaceStore: ObservableObject {
  @Published private(set) var sessions: [ArticleSession] = []
  @Published private var orderedExamples: [LibraryArticle.Example] = []
  var examples: [RewriteExample] { orderedExamples.map(\.value) }
  /// Unlike objectWillChange, this signal always sees the committed collection/session values.
  let changes = PassthroughSubject<Void, Never>()
  private var observations: [UUID: UUID] = [:]
  private var finishingReview: UUID?

  private let library: SQLiteLibrary?
  private var saved: [UUID: SQLiteLibrary.Commit] = [:]
  private var dirty: Set<UUID> = []
  private var saveTask: Task<Void, Never>?
  private var saveFailures: [UUID: String] = [:]
  var persistenceNotice: String? { saveFailures.values.first }

  /// Explicitly in-memory for previews, injected sources and tests.
  init() { library = nil }

  /// Fail the entire open on an unreadable record. No empty writable replacement is returned.
  init(libraryAt url: URL) throws {
    let library = try SQLiteLibrary(at: url)
    self.library = library
    var exampleIDs: Set<UUID> = []
    for commit in try library.load() {
      let article = commit.article
      let session = try ArticleSession(
        document: article.document, versions: article.history.versions,
        rounds: article.history.rounds,
        review: article.pending.map(ReviewState.ready) ?? .idle)
      let id = session.document.id
      guard saved[id] == nil else { throw WorkspaceStoreError.duplicateArticle }
      for example in article.history.examples {
        guard exampleIDs.insert(example.value.id).inserted else {
          throw WorkspaceStoreError.duplicateExample
        }
      }
      saved[id] = commit
      sessions.append(session)
      orderedExamples.append(contentsOf: article.history.examples)
      attach(session)
    }
    orderedExamples.sort { lhs, rhs in
      lhs.position == rhs.position ? lhs.value.id < rhs.value.id : lhs.position < rhs.position
    }
  }

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
    orderedExamples = seed.examples.filter { ids.contains($0.articleID) }.enumerated().map {
      .init(position: $0.offset, value: $0.element)
    }
  }

  func session(for id: UUID?) -> ArticleSession? {
    sessions.first { $0.document.id == id }
  }

  func insert(_ document: Article) throws {
    guard session(for: document.id) == nil else { throw WorkspaceStoreError.duplicateArticle }
    let session = try ArticleSession(document: document)
    attach(session)
    sessions.insert(session, at: 0)
    sessionChanged(session)
  }

  func delete(_ id: UUID) throws {
    guard let session = session(for: id) else { return }
    // A failed delete must leave both the last disk version and unsaved session available.
    if let commit = saved[id] { try library?.delete(commit) }
    saved.removeValue(forKey: id)
    dirty.remove(id)
    saveFailures.removeValue(forKey: id)
    if let token = observations.removeValue(forKey: id) { session.removeObserver(token) }
    session.cancelReview()
    sessions.removeAll { $0.document.id == id }
    orderedExamples.removeAll { $0.value.articleID == id }
    changes.send()
  }

  func finishReview(articleID: UUID, acceptRemaining: Bool) throws {
    guard let session = session(for: articleID) else { return }
    // The session notifies before it returns the examples. Publish and persist them together.
    finishingReview = articleID
    defer { finishingReview = nil }
    let last = orderedExamples.last?.position ?? -1
    guard last <= Int.max - session.review.changes.count else {
      throw WorkspaceStoreError.invalidExampleOrder
    }
    let additions = try session.finishReview(acceptRemaining: acceptRemaining)
    orderedExamples.append(
      contentsOf: additions.enumerated().map {
        .init(position: last + $0.offset + 1, value: $0.element)
      })
    sessionChanged(session)
  }

  private func attach(_ session: ArticleSession) {
    observations[session.document.id] = session.observe { [weak self, weak session] in
      guard let self, let session, finishingReview != session.document.id else { return }
      sessionChanged(session)
    }
  }

  private func sessionChanged(_ session: ArticleSession) {
    let id = session.document.id
    if library != nil, saved[id] != nil || dirty.contains(id) || !isBlankPaper(session) {
      dirty.insert(id)
      // Throttle rather than debounce indefinitely: continuous typing still reaches disk.
      if saveTask == nil {
        saveTask = Task { [weak self] in
          do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
          try? self?.flush()
        }
      }
    }
    objectWillChange.send()
    changes.send()
  }

  private func isBlankPaper(_ session: ArticleSession) -> Bool {
    let document = session.document
    return document.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && document.blocks.count == 1
      && document.blocks[0] == DocumentBlock(id: document.blocks[0].id)
      && document.marks.isEmpty && session.versions.isEmpty && session.rounds.isEmpty
      && !session.review.isReady
  }

  /// Synchronous lifecycle barrier. A failed article stays dirty for retry, other articles
  /// still save, and every failure remains visible until that article saves or is deleted.
  func flush() throws {
    saveTask?.cancel()
    saveTask = nil
    guard let library, !dirty.isEmpty else { return }
    let previousFailures = saveFailures
    var firstError: (any Error)?
    for session in sessions.reversed() where dirty.contains(session.document.id) {
      let id = session.document.id
      let pending: ReviewBatch? = if case .ready(let batch) = session.review { batch } else { nil }
      let article = LibraryArticle(
        document: session.document, pending: pending,
        history: .init(
          versions: session.versions, rounds: session.rounds,
          examples: orderedExamples.filter { $0.value.articleID == id }))
      do {
        if saved[id]?.article != article {
          saved[id] = try library.save(article, replacing: saved[id])
        }
        dirty.remove(id)
        saveFailures.removeValue(forKey: id)
      } catch {
        let title = session.document.title.isEmpty ? "未命名文章" : session.document.title
        saveFailures[id] = "「\(title)」尚未保存到本机：\(error.localizedDescription)"
        firstError = firstError ?? error
      }
    }
    if previousFailures != saveFailures {
      objectWillChange.send()
      changes.send()
    }
    if let firstError { throw firstError }
  }
}

enum WorkspaceStoreError: Error { case duplicateArticle, duplicateExample, invalidExampleOrder }
