import Foundation
import RedraftCore
import SQLite3

/// Only ready batches are durable. A request, its task and transient provider status are not.
struct LibraryArticle: Equatable {
  struct Example: Codable, Equatable {
    let position: Int
    let value: RewriteExample
  }

  struct History: Codable, Equatable {
    var versions: [ArticleVersion]
    var rounds: [AnnotationRound]
    var examples: [Example]
  }

  var document: Article
  var pending: ReviewBatch?
  var history: History
}

/// One commit per article. Unchanged blocks (especially imported images) and history live in
/// separate rows, so ordinary typing only encodes the header and the blocks that changed.
final class SQLiteLibrary {
  struct Commit {
    let article: LibraryArticle
    // Document revision alone cannot detect concurrent review decisions or history changes.
    let token: UUID
  }

  private struct Header: Codable {
    var metadata: Article
    var blockIDs: [UUID]
    var pending: ReviewBatch?

    init(_ article: LibraryArticle) {
      metadata = article.document
      blockIDs = metadata.blocks.map(\.id)
      metadata.blocks = []
      pending = article.pending
    }
  }

  static func location() throws -> URL {
    if let path = ProcessInfo.processInfo.environment["REDRAFT_LIBRARY_PATH"] {
      guard path.hasPrefix("/") else { throw LibraryError("REDRAFT_LIBRARY_PATH 必须是绝对文件路径。") }
      return URL(fileURLWithPath: path)
    }
    return try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    ).appendingPathComponent("Redraft", isDirectory: true).appendingPathComponent("Library.sqlite3")
  }

  private let db: OpaquePointer
  // PropertyListDecoder treats the literal author text "$null" as a null sentinel.
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  init(at url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var connection: OpaquePointer?
    let result = sqlite3_open_v2(
      url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
    guard result == SQLITE_OK, let connection else {
      let message = String(cString: sqlite3_errmsg(connection))
      sqlite3_close(connection)
      throw LibraryError(message)
    }
    db = connection
    encoder.outputFormatting = [.withoutEscapingSlashes]
    guard sqlite3_db_readonly(db, "main") == 0 else { throw LibraryError("文章库为只读。") }
    sqlite3_busy_timeout(db, 150)
    try query("PRAGMA foreign_keys = ON")
    try openSchema()
  }

  deinit { sqlite3_close(db) }

  private func openSchema() throws {
    let application = try integer("PRAGMA application_id")
    let version = try integer("PRAGMA user_version")
    if application == 0x5244_4654, version == 1 { return }
    guard application == 0, version == 0 else { throw LibraryError("无法识别此文章库或数据库版本。") }
    try transaction("BEGIN IMMEDIATE") {
      // Never initialize an unrelated or partially damaged database as a fresh library.
      guard try integer("SELECT count(*) FROM sqlite_schema") == 0 else {
        throw LibraryError("已有数据库不是空白的 Redraft 文章库。")
      }
      try query(
        "CREATE TABLE articles (id TEXT PRIMARY KEY NOT NULL, token TEXT NOT NULL, header BLOB NOT NULL)"
      )
      try query(
        """
        CREATE TABLE blocks (
          article_id TEXT NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
          id TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY (article_id, id))
        """)
      try query(
        """
        CREATE TABLE history (
          article_id TEXT PRIMARY KEY NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
          payload BLOB NOT NULL)
        """)
      try query("PRAGMA application_id = 0x52444654")  // RDFT
      try query("PRAGMA user_version = 1")
    }
  }

  func load() throws -> [Commit] {
    try transaction("BEGIN") {
      var blocks: [UUID: [UUID: DocumentBlock]] = [:]
      try query("PRAGMA foreign_key_check") { _ in throw LibraryError.invalidArchive }
      try query("SELECT article_id, id, payload FROM blocks") { row in
        let articleID = try uuid(row, 0)
        let block = try decoder.decode(DocumentBlock.self, from: blob(row, 2))
        guard try uuid(row, 1) == block.id,
          blocks[articleID, default: [:]].updateValue(block, forKey: block.id) == nil
        else { throw LibraryError.invalidArchive }
      }
      var commits: [Commit] = []
      try query(
        """
        SELECT a.id, a.token, a.header, h.payload FROM articles AS a
        LEFT JOIN history AS h ON h.article_id = a.id ORDER BY a.rowid DESC
        """
      ) { row in
        let id = try uuid(row, 0)
        let header = try decoder.decode(Header.self, from: blob(row, 2))
        var document = header.metadata
        var parts = blocks.removeValue(forKey: id) ?? [:]
        guard document.id == id, document.blocks.isEmpty else { throw LibraryError.invalidArchive }
        document.blocks = try header.blockIDs.map {
          guard let block = parts.removeValue(forKey: $0) else { throw LibraryError.invalidArchive }
          return block
        }
        guard parts.isEmpty else { throw LibraryError.invalidArchive }
        let history = try decoder.decode(LibraryArticle.History.self, from: blob(row, 3))
        guard history.examples.allSatisfy({ $0.position >= 0 && $0.value.articleID == id }) else {
          throw LibraryError.invalidArchive
        }
        let article = LibraryArticle(document: document, pending: header.pending, history: history)
        commits.append(Commit(article: article, token: try uuid(row, 1)))
      }
      guard blocks.isEmpty else { throw LibraryError.invalidArchive }
      return commits
    }
  }

  func save(_ article: LibraryArticle, replacing previous: Commit?) throws -> Commit {
    let token = UUID()
    let id = Binding.id(article.document.id)
    let header = Binding.bytes(try encoder.encode(Header(article)))
    try transaction("BEGIN IMMEDIATE") {
      if let previous {
        try query(
          "UPDATE articles SET token = ?, header = ? WHERE id = ? AND token = ?",
          [
            .id(token), header, id, .id(previous.token),
          ])
        guard sqlite3_changes(db) == 1 else { throw LibraryError.conflict }
      } else {
        try query(
          "INSERT INTO articles (id, token, header) VALUES (?, ?, ?)", [id, .id(token), header])
      }
      var old = Dictionary(
        uniqueKeysWithValues: (previous?.article.document.blocks ?? []).map { ($0.id, $0) })
      for block in article.document.blocks {
        if old.removeValue(forKey: block.id) == block { continue }
        try query(
          """
          INSERT INTO blocks (article_id, id, payload) VALUES (?, ?, ?)
          ON CONFLICT(article_id, id) DO UPDATE SET payload = excluded.payload
          """, [id, .id(block.id), .bytes(try encoder.encode(block))])
      }
      for removed in old.keys {
        try query("DELETE FROM blocks WHERE article_id = ? AND id = ?", [id, .id(removed)])
      }
      if previous?.article.history != article.history {
        try query(
          """
          INSERT INTO history (article_id, payload) VALUES (?, ?)
          ON CONFLICT(article_id) DO UPDATE SET payload = excluded.payload
          """, [id, .bytes(try encoder.encode(article.history))])
      }
    }
    return Commit(article: article, token: token)
  }

  func delete(_ commit: Commit) throws {
    try query(
      "DELETE FROM articles WHERE id = ? AND token = ?",
      [.id(commit.article.document.id), .id(commit.token)])
    guard sqlite3_changes(db) == 1 else { throw LibraryError.conflict }
  }

  private enum Binding {
    case id(UUID)
    case bytes(Data)
  }

  private func query(
    _ sql: String, _ values: [Binding] = [], row: (OpaquePointer) throws -> Void = { _ in }
  ) throws {
    var statement: OpaquePointer?
    try check(sqlite3_prepare_v2(db, sql, -1, &statement, nil))
    guard let statement else { throw LibraryError.invalidArchive }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (offset, value) in values.enumerated() {
      let index = Int32(offset + 1)
      switch value {
      case .id(let id):
        try check(sqlite3_bind_text(statement, index, id.uuidString, -1, transient))
      case .bytes(let data):
        try data.withUnsafeBytes { bytes in
          try check(
            sqlite3_bind_blob64(statement, index, bytes.baseAddress, UInt64(bytes.count), transient)
          )
        }
      }
    }
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW: try row(statement)
      case SQLITE_DONE: return
      default: throw LibraryError(String(cString: sqlite3_errmsg(db)))
      }
    }
  }

  private func transaction<T>(_ begin: String, _ body: () throws -> T) throws -> T {
    try query(begin)
    do {
      let result = try body()
      try query("COMMIT")
      return result
    } catch {
      try? query("ROLLBACK")
      throw error
    }
  }

  private func check(_ result: Int32) throws {
    if result != SQLITE_OK { throw LibraryError(String(cString: sqlite3_errmsg(db))) }
  }

  private func integer(_ sql: String) throws -> Int64 {
    var result: Int64?
    try query(sql) { result = sqlite3_column_int64($0, 0) }
    guard let result else { throw LibraryError.invalidArchive }
    return result
  }

  private func uuid(_ row: OpaquePointer, _ column: Int32) throws -> UUID {
    guard sqlite3_column_type(row, column) == SQLITE_TEXT,
      let text = sqlite3_column_text(row, column),
      let id = UUID(uuidString: String(cString: text))
    else { throw LibraryError.invalidArchive }
    return id
  }

  private func blob(_ row: OpaquePointer, _ column: Int32) throws -> Data {
    guard sqlite3_column_type(row, column) == SQLITE_BLOB,
      let bytes = sqlite3_column_blob(row, column)
    else { throw LibraryError.invalidArchive }
    return Data(bytes: bytes, count: Int(sqlite3_column_bytes(row, column)))
  }
}

private struct LibraryError: LocalizedError {
  let errorDescription: String?
  init(_ message: String) { errorDescription = message }
  static let invalidArchive = Self("文章库中的记录不完整或已损坏。")
  static let conflict = Self("磁盘上的文章已被其他窗口或进程更新，未覆盖该版本。")
}
