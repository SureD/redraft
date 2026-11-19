import Combine
import Foundation
import RedraftCore

@MainActor
final class WorkspaceViewModel: ObservableObject {
  @Published var state: WorkspaceState
  let editorSession = EditorSession()
  private let store: WorkspaceStore
  private let reviewProvider: any ReviewProviding
  private var subscriptions: Set<AnyCancellable> = []

  init(store: WorkspaceStore, reviewProvider: any ReviewProviding) {
    self.store = store
    self.reviewProvider = reviewProvider
    var state = WorkspaceState()
    state.selectedArticleID = store.sessions.first?.document.id
    self.state = state
    store.changes.sink { [weak self] _ in
      self?.reconcileState()
      self?.objectWillChange.send()
    }.store(in: &subscriptions)
    editorSession.objectWillChange.sink { [weak self] _ in
      self?.objectWillChange.send()
    }.store(in: &subscriptions)
    resetHistorySelection()
  }

  convenience init(source: any WorkspaceContentSource, reviewProvider: any ReviewProviding) throws {
    try self.init(store: WorkspaceStore(seed: source.load()), reviewProvider: reviewProvider)
  }

  var articles: [ArticleViewState] { store.sessions.map(ArticleViewState.init(session:)) }
  var examples: [RewriteExample] { store.examples }
  private var currentSession: ArticleSession? { store.session(for: state.selectedArticleID) }
  var currentArticle: ArticleViewState? { currentSession.map(ArticleViewState.init(session:)) }

  var notice: String? {
    if let notice = state.notice { return notice }
    if case .failed(let message) = currentSession?.review,
      state.dismissedReviewError != message
    {
      return "改稿失败：\(message)"
    }
    return nil
  }

  var selectedBlock: DocumentBlock? {
    currentArticle?.blocks.first { $0.id == state.selectedBlockID }
  }

  var currentChange: ReviewChange? {
    currentArticle?.changes.first { $0.id == state.selectedChangeID }
  }

  var filteredArticles: [ArticleViewState] {
    let query = state.articleQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    return articles.filter {
      query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
        || $0.blocks.contains { $0.plainText.localizedCaseInsensitiveContains(query) }
    }
  }

  var filteredExamples: [RewriteExample] {
    let query = state.exampleQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    return examples.filter { example in
      let matchesDecision =
        state.exampleFilter == .all
        || state.exampleFilter.rawValue == example.decision.rawValue
      let title = articles.first { $0.id == example.articleID }?.title ?? ""
      return matchesDecision
        && (query.isEmpty
          || [example.before, example.after, example.reason, example.displayTag, title].contains {
            $0.localizedCaseInsensitiveContains(query)
          })
    }
  }

  var isEditorLocked: Bool {
    state.section != .articles || state.mode != .writing || currentArticle?.phase != .idle
  }
  var markedCount: Int { currentArticle?.marks.count ?? 0 }
  var unresolvedCount: Int { currentArticle?.changes.filter { $0.decision == nil }.count ?? 0 }
  var historyFrom: ArticleVersion? {
    currentArticle?.versions.first { $0.id == state.historyFromID }
  }
  var historyTo: ArticleVersion? {
    currentArticle?.versions.first { $0.id == state.historyToID }
  }

  func selectArticle(_ id: UUID) {
    guard articles.contains(where: { $0.id == id }) else { return }
    state.selectedArticleID = id
    state.section = .articles
    state.mode = .writing
    clearSelection()
    resetHistorySelection()
  }

  func newArticle() {
    let article = Article(title: "未命名文章", blocks: [DocumentBlock(text: RichTextContent())])
    do {
      try store.insert(article)
      state.articleQuery = ""
      selectArticle(article.id)
    } catch { report(error) }
  }

  func deleteArticle(_ id: UUID) {
    store.delete(id)
    if state.selectedArticleID == id {
      state.selectedArticleID = articles.first?.id
      state.mode = .writing
      clearSelection()
      resetHistorySelection()
    }
  }

  func renameArticle(_ title: String) {
    guard !isEditorLocked else { return }
    mutateSelectedArticle { $0.title = title }
  }

  func setMode(_ mode: WorkspaceMode) {
    guard currentArticle != nil else { return }
    if mode == .review {
      enterReview()
      return
    }
    state.mode = mode
    state.section = .articles
    state.sheet = nil
    if mode == .history { resetHistorySelectionIfNeeded() }
  }

  func showExamples() {
    state.section = .examples
    state.sheet = nil
    state.notice = nil
  }

  func selectBlock(_ id: UUID?) {
    guard id == nil || currentArticle?.blocks.contains(where: { $0.id == id }) == true else {
      return
    }
    if state.selectedBlockID != id {
      state.selectedBlockID = id
      state.selectedRange = NSRange(location: 0, length: 0)
    }
  }

  func updateSelection(blockID: UUID, range: NSRange) {
    guard let block = currentArticle?.blocks.first(where: { $0.id == blockID }),
      block.kind == .text,
      isValid(range, in: block.text.string)
    else { return }
    state.selectedBlockID = blockID
    state.selectedRange = range
  }

  @discardableResult
  func updateBlockText(
    _ id: UUID, text: NSAttributedString, expectedContent: RichTextContent? = nil,
    articleID: UUID? = nil
  ) -> Bool {
    guard !isEditorLocked, let session = currentSession,
      articleID == nil || articleID == session.document.id,
      var block = currentArticle?.blocks.first(where: { $0.id == id }), block.kind == .text
    else { return false }
    if let expectedContent, block.text.normalized() != expectedContent.normalized() {
      showNotice("这段内容已在其他位置更新，请基于最新内容继续编辑")
      return false
    }
    block.text = RichTextBridge.content(from: text)
    do {
      try session.updateDocument { article in
        guard let index = article.blocks.firstIndex(where: { $0.id == id }) else { return }
        article.blocks[index] = block
      }
    } catch {
      report(error)
      return false
    }
    if state.selectedBlockID == id && !isValid(state.selectedRange, in: text.string) {
      state.selectedRange = NSRange(location: text.length, length: 0)
    }
    return true
  }

  func mutateSelectedArticle(_ mutate: (inout Article) -> Void) {
    guard !isEditorLocked, let session = currentSession else { return }
    do { try session.updateDocument(mutate) } catch { report(error) }
  }

  func updateBlock(_ block: DocumentBlock) {
    mutateSelectedArticle { article in
      guard let index = article.blocks.firstIndex(where: { $0.id == block.id }) else { return }
      article.blocks[index] = block
    }
  }

  func insertBlock(_ block: DocumentBlock) {
    guard !isEditorLocked else { return }
    let selection = state.selectedBlockID
    mutateSelectedArticle { article in
      let index =
        article.blocks.firstIndex(where: { $0.id == selection }).map { $0 + 1 }
        ?? article.blocks.endIndex
      article.blocks.insert(block, at: index)
    }
    selectBlock(block.id)
  }

  func deleteBlock(_ id: UUID) {
    guard !isEditorLocked, currentArticle?.blocks.contains(where: { $0.id == id }) == true else {
      return
    }
    mutateSelectedArticle {
      $0.blocks.removeAll { $0.id == id }
      $0.marks.removeValue(forKey: id)
      if $0.blocks.isEmpty { $0.blocks = [DocumentBlock(text: RichTextContent())] }
    }
    if state.selectedBlockID == id { selectBlock(nil) }
  }

  func markBlock(_ id: UUID, instruction: String) {
    let value = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, currentArticle?.blocks.contains(where: { $0.id == id }) == true else {
      return
    }
    mutateSelectedArticle { $0.marks[id] = value }
  }

  func unmarkBlock(_ id: UUID) {
    mutateSelectedArticle { $0.marks.removeValue(forKey: id) }
  }

  func markSelection(instruction: String) {
    guard let id = state.selectedBlockID else {
      showNotice("先选择一个段落、图片或表格")
      return
    }
    markBlock(id, instruction: instruction)
  }

  func clearMarks() {
    mutateSelectedArticle { $0.marks.removeAll() }
  }

  func beginReview() {
    guard state.section == .articles, state.mode == .writing, state.sheet == nil else { return }
    guard let session = currentSession, currentArticle?.phase == .idle,
      !session.document.marks.isEmpty
    else {
      showNotice("先标记想修改的内容")
      return
    }
    state.selectedChangeID = nil
    state.notice = nil
    state.dismissedReviewError = nil
    do { try session.beginReview(using: reviewProvider) } catch { report(error) }
  }

  func cancelReview() {
    guard let session = currentSession, currentArticle?.phase == .running else { return }
    session.cancelReview()
    state.notice = "已取消，标记保持原样"
  }

  func enterReview() {
    guard let article = currentArticle, article.phase == .ready, !article.changes.isEmpty else {
      showNotice("先送审标记的内容，再开始审阅")
      return
    }
    state.section = .articles
    state.mode = .review
    state.sheet = nil
    if let change = article.changes.first(where: { $0.decision == nil }) ?? article.changes.first {
      selectChange(change.id)
    }
    state.inspectorVisible = true
  }

  func selectChange(_ id: UUID) {
    guard state.section == .articles, state.mode == .review, state.sheet == nil,
      currentArticle?.phase == .ready
    else { return }
    guard let change = currentArticle?.changes.first(where: { $0.id == id }) else { return }
    state.selectedChangeID = id
    state.selectedBlockID = change.blockID
    state.selectedRange = NSRange(location: 0, length: 0)
  }

  func decide(_ decision: ReviewDecision) {
    guard let id = state.selectedChangeID else { return }
    decide(decision, changeID: id)
  }

  func decide(_ decision: ReviewDecision, changeID: UUID) {
    guard canEditReview, currentArticle?.changes.contains(where: { $0.id == changeID }) == true
    else { return }
    selectChange(changeID)
    if decision == .rewrite {
      startRewrite()
      return
    }
    do { try currentSession?.decide(decision, changeID: changeID) } catch { report(error) }
  }

  func startRewrite() {
    guard state.section == .articles, state.mode == .review, state.sheet == nil,
      currentArticle?.phase == .ready, let change = currentChange, change.kind == .text
    else { return }
    state.rewriteText = change.rewrittenText.isEmpty ? change.after : change.rewrittenText
    state.rewriteReason = change.reason
    state.sheet = .rewrite
  }

  func updateChangeReason(_ text: String, changeID: UUID) {
    guard canEditReview else { return }
    do { try currentSession?.updateReason(text, changeID: changeID) } catch { report(error) }
  }

  func cancelRewrite() { dismissSheet() }

  func submitRewrite() {
    guard state.sheet == .rewrite, state.section == .articles, state.mode == .review,
      currentArticle?.phase == .ready, let change = currentChange, change.kind == .text,
      !state.rewriteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return }
    do {
      try currentSession?.rewrite(
        changeID: change.id, text: state.rewriteText, reason: state.rewriteReason)
      dismissSheet()
    } catch { report(error) }
  }

  func completeReview() {
    guard canEditReview, let article = currentArticle, !article.changes.isEmpty else { return }
    guard unresolvedCount == 0 else {
      showNotice("还有 \(unresolvedCount) 处修改等待取舍")
      return
    }
    do {
      try store.finishPreviewReview(articleID: article.id)
      state.mode = .writing
      state.selectedChangeID = nil
      state.sheet = nil
      showNotice("已完成本轮预览，正文保持原样")
    } catch { report(error) }
  }

  func selectExample(_ id: UUID) {
    guard let example = examples.first(where: { $0.id == id }),
      articles.contains(where: { $0.id == example.articleID })
    else { return }
    selectArticle(example.articleID)
    let identifiedSource = currentArticle?.blocks.first { $0.id == example.blockID }
    let source =
      identifiedSource
      ?? currentArticle?.blocks.first { block in
        (!example.before.isEmpty && block.plainText.contains(example.before))
          || (!example.after.isEmpty && block.plainText.contains(example.after))
      }
    selectBlock(source?.id)
    state.inspectorTab = .provenance
    state.inspectorVisible = true
  }

  func showProvenance() {
    state.inspectorTab = .provenance
    state.inspectorVisible = true
  }

  func savePreviewVersion() {
    guard state.section == .articles, state.sheet == nil,
      let session = currentSession, currentArticle?.phase == .idle
    else { return }
    _ = session.saveVersion(title: "手动快照 \(session.versions.count + 1)")
    resetHistorySelection()
    showNotice("已添加本次预览快照")
  }

  func saveVersion() { savePreviewVersion() }

  func swapHistoryVersions() {
    let from = state.historyFromID
    state.historyFromID = state.historyToID
    state.historyToID = from
  }

  func showSheet(_ sheet: WorkspaceSheet) {
    switch sheet {
    case .customMark:
      guard !isEditorLocked else { return }
      guard selectedBlock != nil else {
        showNotice("先选择一个段落、图片或表格")
        return
      }
      state.customInstruction = ""
    case .rewrite:
      startRewrite()
      return
    case .insertTable:
      guard !isEditorLocked else { return }
    case .imageDescription:
      guard !isEditorLocked, let image = selectedBlock?.image else { return }
      state.imageDescription = image.altText
    case .statistics:
      guard currentArticle != nil else { return }
    case .shortcuts, .about:
      break
    }
    state.sheet = sheet
  }

  func dismissSheet() { state.sheet = nil }

  func submitCustomMark() {
    guard state.sheet == .customMark, !isEditorLocked, selectedBlock != nil,
      !state.customInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return
    }
    markSelection(instruction: state.customInstruction)
    dismissSheet()
  }

  func showNotice(_ message: String) { state.notice = message }
  func dismissNotice() {
    state.notice = nil
    if case .failed(let message) = currentSession?.review { state.dismissedReviewError = message }
  }

  private func clearSelection() {
    editorSession.clear()
    state.selectedBlockID = nil
    state.selectedRange = NSRange(location: 0, length: 0)
    state.selectedChangeID = nil
    state.sheet = nil
    state.notice = nil
    state.dismissedReviewError = nil
    state.customInstruction = ""
    state.rewriteText = ""
    state.rewriteReason = ""
    state.imageDescription = ""
  }

  private func resetHistorySelection() {
    state.historyFromID = currentArticle?.versions.first?.id
    state.historyToID = currentArticle?.versions.last?.id
  }

  private func resetHistorySelectionIfNeeded() {
    let ids = Set(currentArticle?.versions.map(\.id) ?? [])
    if state.historyFromID.map({ !ids.contains($0) }) ?? true {
      state.historyFromID = currentArticle?.versions.first?.id
    }
    if state.historyToID.map({ !ids.contains($0) }) ?? true {
      state.historyToID = currentArticle?.versions.last?.id
    }
  }

  /// Shared documents can change in another window while this window keeps its own selection.
  private func reconcileState() {
    guard let article = currentArticle else {
      state.selectedArticleID = articles.first?.id
      state.mode = .writing
      clearSelection()
      resetHistorySelection()
      return
    }
    if let id = state.selectedBlockID {
      if let block = article.blocks.first(where: { $0.id == id }) {
        if block.kind == .text, !isValid(state.selectedRange, in: block.text.string) {
          state.selectedRange = NSRange(location: block.text.string.utf16.count, length: 0)
        }
      } else {
        editorSession.clear()
        state.selectedBlockID = nil
        state.selectedRange = NSRange(location: 0, length: 0)
        if state.sheet == .customMark || state.sheet == .imageDescription {
          dismissSheet()
          state.customInstruction = ""
          state.imageDescription = ""
        }
      }
    }
    if article.phase != .ready {
      if state.mode == .review { state.mode = .writing }
      if state.selectedChangeID != nil { state.selectedChangeID = nil }
      if state.sheet == .rewrite {
        dismissSheet()
        state.rewriteText = ""
        state.rewriteReason = ""
      }
    } else if let id = state.selectedChangeID,
      !article.changes.contains(where: { $0.id == id })
    {
      state.selectedChangeID = nil
      if state.sheet == .rewrite { dismissSheet() }
    }
    resetHistorySelectionIfNeeded()
  }

  private var canEditReview: Bool {
    state.section == .articles && state.mode == .review && state.sheet == nil
      && currentArticle?.phase == .ready
  }

  private func report(_ error: Error) {
    showNotice("无法完成操作：\(error.localizedDescription)")
  }

  private func isValid(_ range: NSRange, in text: String) -> Bool {
    guard range.location >= 0, range.length >= 0, range.location <= text.utf16.count,
      range.length <= text.utf16.count - range.location, let indices = Range(range, in: text)
    else { return false }
    return indices.lowerBound.samePosition(in: text) != nil
      && indices.upperBound.samePosition(in: text) != nil
  }
}
