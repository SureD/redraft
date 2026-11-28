import Foundation
import RedraftCore
import SQLite3

/// Standalone integration tests: every open creates a new SQLite connection; no production path
/// or demo seed is used. Faults are injected by a separate SQLite client, not a mock store.
@main
@MainActor
struct LibraryPersistenceTests {
  static func main() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    try await blankPaperAndAutosave(folder.appendingPathComponent("scratch.sqlite3"))
    try await archiveAndReview(folder.appendingPathComponent("review.sqlite3"))
    try incrementalAndAtomicWrites(folder.appendingPathComponent("faults.sqlite3"))
    try staleWriters(folder.appendingPathComponent("conflicts.sqlite3"))
    try unreadableLibraries(folder.appendingPathComponent("invalid.sqlite3"))
    print("SQLite library: 5 scenarios passed")
  }

  private static func blankPaperAndAutosave(_ url: URL) async throws {
    for _ in 0..<3 {
      let launch = try WorkspaceStore(libraryAt: url)
      try expect(
        launch.sessions.isEmpty && launch.examples.isEmpty,
        "Blank launches must not accumulate drafts or examples")
      try launch.insert(Article(title: "", blocks: [DocumentBlock()]))
      try launch.flush()
    }
    let store = try WorkspaceStore(libraryAt: url)
    let paper = Article(title: "", blocks: [DocumentBlock()])
    try store.insert(paper)
    let session = try requireSession(paper.id, in: store)
    try session.updateDocument { $0.blocks[0].text.string = "正文里可找回的第一句话。" }
    // Exercise the timer, not just the lifecycle barrier. No explicit title or save action.
    try await eventually("First edit was not autosaved") {
      try WorkspaceStore(libraryAt: url).session(for: paper.id)?.document == session.document
    }
    let titled = Article(title: "", blocks: [DocumentBlock()])
    try store.insert(titled)
    let second = try requireSession(titled.id, in: store)
    try second.updateDocument { $0.title = "只有标题" }
    try store.flush()
    let restored = try WorkspaceStore(libraryAt: url)
    try expect(
      restored.sessions.map(\.document) == [second.document, session.document],
      "Keep titles, searchable bodies, IDs, timestamps and revisions")
    try session.updateDocument { $0.blocks[0].text = RichTextContent() }
    try store.flush()
    try expect(
      try requireSession(paper.id, in: WorkspaceStore(libraryAt: url)).document == session.document,
      "Clearing an existing draft is not deletion")
  }

  private static func archiveAndReview(_ url: URL) async throws {
    let root = UUID()
    let child = UUID()
    let nested = Data(
      """
      [{"id":"\(root)","type":"checkListItem","props":{"checked":true},
        "content":[{"type":"link","href":"https://example.org/","content":[{"type":"text","text":"起稿 👩🏽‍💻","styles":{"code":true}}]}],
        "children":[{"id":"\(child)","type":"quote","content":"子段"}]}]
      """.utf8)
    var blocks = try BlockNoteDocument.decode(nested, previous: []) { _ in nil }
    blocks.append(
      DocumentBlock(
        image: ImageContent(
          data: Data([0, 1, 127, 255]), caption: "插图", altText: "本机图片", width: 0.5)))
    blocks.append(DocumentBlock(table: TableContent(rows: [["地区", "温度"], ["$null", "20"]])))
    let article = Article(title: "混排稿", blocks: blocks, marks: [root: "更具体"])
    let store = try WorkspaceStore(libraryAt: url)
    try store.insert(article)
    let session = try requireSession(article.id, in: store)
    let version = session.saveVersion(title: "初稿")
    try session.beginReview(using: SuggestionFixture(block: root, delay: .seconds(60)))
    try store.flush()
    let cold = try requireSession(article.id, in: WorkspaceStore(libraryAt: url))
    try expect(
      cold.review == .idle && cold.document == session.document && cold.versions == [version],
      "Never resurrect an in-flight request or manufacture a revision")
    try expect(
      try BlockNoteDocument.encode(cold.document.blocks)
        == BlockNoteDocument.encode(session.document.blocks),
      "Nested types, editor metadata, cell IDs and inline marks survive SQLite")
    session.cancelReview()
    try session.beginReview(using: SuggestionFixture(block: root))
    try await eventually("Review fixture did not become ready") { session.review.isReady }
    let change = session.review.changes[0]
    try session.rewrite(changeID: change.id, text: "我的表达", reason: "保留作者的语气")
    try store.flush()
    let resumed = try WorkspaceStore(libraryAt: url)
    let editing = try requireSession(article.id, in: resumed)
    try expect(
      editing.document == session.document && editing.review == session.review,
      "Pending decisions, reason and suggestion IDs must remain editable")
    try resumed.finishReview(articleID: article.id, acceptRemaining: false)
    try resumed.flush()
    let next = try WorkspaceStore(libraryAt: url)
    let finished = try requireSession(article.id, in: next)
    try expect(
      finished.document == editing.document && finished.versions == [version]
        && finished.review == .idle,
      "Finishing a restored review preserves its actual resulting revision")
    try expect(
      finished.rounds == editing.rounds && finished.rounds.count == 1
        && next.examples == resumed.examples && next.examples.count == 1,
      "Round source, result, suggestions and examples must commit together")
    let later = Article(title: "第二份", blocks: [DocumentBlock(text: RichTextContent(string: "成稿"))])
    try next.insert(later)
    let second = try requireSession(later.id, in: next)
    try second.beginReview(using: SuggestionFixture(block: later.blocks[0].id))
    try await eventually("Second fixture did not finish") { second.review.isReady }
    try next.finishReview(articleID: later.id, acceptRemaining: true)
    try next.flush()
    try expect(
      try WorkspaceStore(libraryAt: url).examples == next.examples,
      "Preserve global example order, not article load order")
    try finished.updateDocument { $0.title = "未立即落盘的改名" }
    try next.delete(article.id)
    try next.flush()
    let remaining = try WorkspaceStore(libraryAt: url)
    try expect(
      remaining.sessions.map(\.document) == [second.document] && remaining.examples.count == 1
        && remaining.examples.first?.articleID == later.id,
      "Deleting a dirty article removes just its blocks, history and examples without resurrection")
  }

  private static func incrementalAndAtomicWrites(_ url: URL) throws {
    let image = DocumentBlock(image: ImageContent(data: Data(repeating: 0xFA, count: 256 * 1024)))
    let text = DocumentBlock(text: RichTextContent(string: "原文"))
    let article = Article(title: "附图", blocks: [text, image])
    let other = Article(title: "另一篇", blocks: [DocumentBlock()])
    let store = try WorkspaceStore(libraryAt: url)
    try store.insert(article)
    try store.insert(other)
    let session = try requireSession(article.id, in: store)
    session.saveVersion(title: "带图初稿")
    try store.flush()
    try sql(
      url,
      """
      CREATE TRIGGER protect_image BEFORE UPDATE ON blocks WHEN old.id = '\(image.id)' BEGIN SELECT RAISE(ABORT, 'rewrote image'); END;
      CREATE TRIGGER protect_history BEFORE UPDATE ON history BEGIN SELECT RAISE(ABORT, 'rewrote history'); END;
      CREATE TRIGGER protect_other BEFORE UPDATE ON articles WHEN old.id = '\(other.id)' BEGIN SELECT RAISE(ABORT, 'rewrote another article'); END;
      """)
    try session.updateDocument { $0.blocks[0].text.string += "。" }
    try store.flush()
    let durable = session.document
    try sql(
      url,
      "CREATE TRIGGER full_disk BEFORE UPDATE ON blocks BEGIN SELECT RAISE(ABORT, 'simulated write failure'); END"
    )
    try session.updateDocument { $0.blocks[0].text.string += "不会静默丢失。" }
    try expectFailure("Failed transaction must throw") { try store.flush() }
    try expect(
      store.persistenceNotice != nil && session.document != durable,
      "Keep failed edits in memory and tell the UI")
    try expect(
      try requireSession(article.id, in: WorkspaceStore(libraryAt: url)).document == durable,
      "A failed block write must roll back the revision and the entire edit")
    try sql(url, "DROP TRIGGER full_disk")
    try store.flush()
    try expect(
      store.persistenceNotice == nil
        && (try requireSession(article.id, in: WorkspaceStore(libraryAt: url))).document
          == session.document,
      "Retry saves without another edit")
    try sql(
      url,
      "CREATE TRIGGER refuse_delete BEFORE DELETE ON articles BEGIN SELECT RAISE(ABORT, 'simulated delete failure'); END"
    )
    try expectFailure("Failed deletion must throw") { try store.delete(article.id) }
    try expect(
      store.session(for: article.id) != nil
        && (try WorkspaceStore(libraryAt: url)).sessions.count == 2,
      "A failed delete keeps both the local and disk copies")
  }

  private static func staleWriters(_ url: URL) throws {
    let current = try WorkspaceStore(libraryAt: url)
    let article = Article(title: "原稿", blocks: [DocumentBlock()])
    try current.insert(article)
    try current.flush()
    let stale = try WorkspaceStore(libraryAt: url)
    let editor = try requireSession(article.id, in: current)
    editor.saveVersion(title: "新增版本，不改变正文修订号")
    try current.flush()
    try requireSession(article.id, in: stale).updateDocument { $0.title = "旧窗口" }
    try expectFailure("Stale writer must not erase a new version") { try stale.flush() }
    try expectFailure("Stale writer must not delete a newer entry") { try stale.delete(article.id) }
    let intact = try requireSession(article.id, in: WorkspaceStore(libraryAt: url))
    try expect(
      intact.versions == editor.versions && intact.document == editor.document,
      "CAS conflicts preserve the winning commit")
  }

  private static func unreadableLibraries(_ url: URL) throws {
    let article = Article(
      title: "已有稿件", blocks: [DocumentBlock(text: RichTextContent(string: "不要覆盖"))])
    do {
      let store = try WorkspaceStore(libraryAt: url)
      try store.insert(article)
      try store.flush()
    }
    try sql(url, "PRAGMA user_version = 2")
    try expectFailure("Reject unsupported schema") { _ = try WorkspaceStore(libraryAt: url) }
    try sql(url, "PRAGMA user_version = 1")
    try expect(
      try requireSession(article.id, in: WorkspaceStore(libraryAt: url)).document == article,
      "Rejecting a newer library must not initialize over existing drafts")
    try sql(url, "UPDATE blocks SET payload = X'F00D'")
    let damaged = try Data(contentsOf: url)
    try expectFailure("Bad payload must not present an empty writable store") {
      _ = try WorkspaceStore(libraryAt: url)
    }
    try expect(
      try Data(contentsOf: url) == damaged, "Decoder failure leaves existing evidence untouched")
    let unrelated = url.deletingLastPathComponent().appendingPathComponent("unrelated.sqlite3")
    try sql(unrelated, "CREATE TABLE existing (id INTEGER)")
    let existing = try Data(contentsOf: unrelated)
    try expectFailure("Reject unrelated SQLite schemas") {
      _ = try WorkspaceStore(libraryAt: unrelated)
    }
    try expect(
      try Data(contentsOf: unrelated) == existing,
      "Do not initialize over another application's database")
  }

  private struct SuggestionFixture: ReviewProviding {
    var block: UUID
    var delay: Duration = .zero
    func changes(for request: ReviewRequest) async throws -> [ReviewChange] {
      try await Task.sleep(for: delay)
      guard let original = request.article.blocks.first(where: { $0.id == block }) else {
        return []
      }
      return [
        ReviewChange(
          blockID: block, before: original.plainText, after: "编辑建议", explanation: "取舍",
          beforeBlock: original)
      ]
    }
  }

  private static func requireSession(_ id: UUID, in store: WorkspaceStore) throws -> ArticleSession
  {
    guard let session = store.session(for: id) else {
      throw Failure("Missing restored article \(id)")
    }
    return session
  }

  private struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
  }

  private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws
  {
    guard try condition() else { throw Failure(message) }
  }

  private static func expectFailure(_ message: String, _ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw Failure(message)
  }

  private static func eventually(_ message: String, _ condition: () throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !(try condition()) {
      guard ContinuousClock.now < deadline else { throw Failure(message) }
      try await Task.sleep(for: .milliseconds(30))
    }
  }

  private static func sql(_ url: URL, _ statement: String) throws {
    var db: OpaquePointer?
    let rc = sqlite3_open(url.path, &db)
    defer { sqlite3_close(db) }
    guard rc == SQLITE_OK, sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK else {
      throw Failure(String(cString: sqlite3_errmsg(db)))
    }
  }
}
