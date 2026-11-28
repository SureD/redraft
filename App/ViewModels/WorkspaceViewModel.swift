import AppKit
import Combine
import Foundation
import RedraftCore

@MainActor
final class WorkspaceViewModel: ObservableObject {
  @Published var state: WorkspaceState {
    didSet {
      if oldValue.selectedArticleID != state.selectedArticleID || oldValue.section != state.section
      {
        pendingProofreadingEdit = nil
        proofreadingApplyingID = nil
        refreshProofreading()
      }
    }
  }
  var composingInEditor = false
  let exportMarkdown = PassthroughSubject<Void, Never>()
  let proofreadingEditRequested = PassthroughSubject<ProofreadingEdit, Never>()
  @Published private(set) var proofreadingApplyingID: UUID?
  private let store: WorkspaceStore
  private let reviewProvider: any ReviewProviding
  private let proofreading: ProofreadingSession
  private var pendingProofreadingEdit: ProofreadingEdit?
  private var subscriptions: Set<AnyCancellable> = []
  // A BlockNote undo can bring a removed block ID and its annotation scope back.
  private var removedMarks: [UUID: String] = [:]

  init(
    store: WorkspaceStore, reviewProvider: any ReviewProviding,
    proofreadingProvider: (any ProofreadingProviding)? = nil,
    proofreadingDelay: Duration = .milliseconds(750)
  ) {
    self.store = store
    self.reviewProvider = reviewProvider
    proofreading = ProofreadingSession(provider: proofreadingProvider, delay: proofreadingDelay)
    var state = WorkspaceState()
    state.selectedArticleID = store.sessions.first?.document.id
    self.state = state
    store.changes.sink { [weak self] _ in
      self?.reconcileState()
      self?.refreshProofreading()
      self?.objectWillChange.send()
    }.store(in: &subscriptions)
    proofreading.objectWillChange.sink { [weak self] _ in
      self?.objectWillChange.send()
    }.store(in: &subscriptions)
    refreshProofreading()
  }

  convenience init(
    source: any WorkspaceContentSource, reviewProvider: any ReviewProviding,
    proofreadingProvider: (any ProofreadingProviding)? = nil,
    proofreadingDelay: Duration = .milliseconds(750)
  ) throws {
    try self.init(
      store: WorkspaceStore(seed: source.load()), reviewProvider: reviewProvider,
      proofreadingProvider: proofreadingProvider, proofreadingDelay: proofreadingDelay)
  }

  var articles: [ArticleViewState] { store.sessions.map(ArticleViewState.init(session:)) }
  var examples: [RewriteExample] { store.examples }
  private var currentSession: ArticleSession? { store.session(for: state.selectedArticleID) }
  var currentArticle: ArticleViewState? { currentSession.map(ArticleViewState.init(session:)) }

  var proofreadingStatus: ProofreadingStatus { proofreading.status }
  var proofreadingSuggestions: [ProofreadingSuggestion] { proofreading.suggestions }
  var proofreadingSource: ProofreadingSource? { proofreading.source }

  func retryProofreading() { proofreading.retry() }

  func dismissProofreadingSuggestion(_ suggestion: ProofreadingSuggestion) {
    proofreading.dismiss(suggestion)
  }

  func applyProofreadingSuggestion(_ suggestion: ProofreadingSuggestion) {
    guard pendingProofreadingEdit == nil, !isEditorLocked, let document = currentSession?.document
    else { return }
    guard !composingInEditor else {
      showNotice("请先确认正在输入的文字，再应用建议。")
      return
    }
    guard let edit = proofreading.edit(for: suggestion, in: document) else {
      showNotice("这段文字已有改动，正在检查最新正文。")
      return
    }
    pendingProofreadingEdit = edit
    proofreadingApplyingID = suggestion.id
    proofreadingEditRequested.send(edit)
  }

  func proofreadingEditFinished(_ edit: ProofreadingEdit, applied: Bool) {
    guard pendingProofreadingEdit == edit else { return }
    pendingProofreadingEdit = nil
    proofreadingApplyingID = nil
    if !applied { showNotice("未能应用这条建议，请查看当前正文后重试。") }
  }

  private func refreshProofreading() {
    let shouldRead = state.section == .articles && !isEditorLocked
    proofreading.update(shouldRead ? currentSession?.document : nil)
  }

  var notice: String? {
    store.persistenceNotice ?? state.notice
      ?? (state.dismissedAnnotationNotice == annotationNotice ? nil : annotationNotice)
  }

  private var annotationNotice: String? {
    switch currentSession?.review {
    case .noSuggestions: "本轮暂无批注"
    case .failed(let message): "批注失败：\(message)"
    default: nil
    }
  }

  var selectedBlock: DocumentBlock? {
    currentArticle?.blocks.first { $0.id == state.selectedBlockID }
  }

  var currentChange: ReviewChange? {
    currentArticle?.changes.first { $0.id == state.selectedChangeID }
  }

  var filteredArticles: [ArticleViewState] {
    let query = state.articleQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    return store.librarySessions.map(ArticleViewState.init(session:)).filter {
      query.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(query)
        || $0.blocks.contains { $0.plainText.localizedCaseInsensitiveContains(query) }
    }
  }

  var filteredExamples: [RewriteExample] {
    let query = state.exampleQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    return examples.filter { example in
      let matchesDecision =
        state.exampleFilter == .all
        || state.exampleFilter.rawValue == example.decision.rawValue
      let title = articles.first { $0.id == example.articleID }?.displayTitle ?? ""
      return matchesDecision
        && (query.isEmpty
          || [example.before, example.after, example.reason, example.displayTag, title].contains {
            $0.localizedCaseInsensitiveContains(query)
          })
    }
  }

  var isEditorLocked: Bool {
    state.section != .articles || currentArticle?.phase != .idle
  }
  var canRequestAnnotations: Bool {
    !isEditorLocked && state.sheet == nil && currentSession?.document.canRequestAnnotations == true
  }
  var markedCount: Int { currentArticle?.marks.count ?? 0 }
  var unresolvedCount: Int { currentArticle?.changes.filter { $0.decision == nil }.count ?? 0 }

  func selectArticle(_ id: UUID) {
    guard articles.contains(where: { $0.id == id }) else { return }
    if state.selectedArticleID != id { removedMarks.removeAll() }
    state.selectedArticleID = id
    state.section = .articles
    clearSelection()
  }

  func newArticle() {
    let article = Article(title: "", blocks: [DocumentBlock()])
    do {
      try store.insert(article)
      state.articleQuery = ""
      selectArticle(article.id)
      state.sidebarVisible = false
      selectBlock(article.blocks.first?.id)
    } catch { report(error) }
  }

  func deleteArticle(_ id: UUID) {
    do { try store.delete(id) } catch { report(error) }
  }

  func renameArticle(_ title: String) {
    guard !isEditorLocked else { return }
    mutateSelectedArticle { $0.title = title }
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
    if state.selectedBlockID != blockID { state.selectedBlockID = blockID }
    if state.selectedRange != range { state.selectedRange = range }
  }

  /// A delayed WebKit message must not overwrite a different draft, an external edit or a review.
  @discardableResult
  func commitEditorBlocks(_ blocks: [DocumentBlock], articleID: UUID, basedOn revision: UUID)
    -> Bool
  {
    guard !isEditorLocked, let session = currentSession, session.document.id == articleID,
      session.document.revisionID == revision
    else { return false }
    let ids = Set(blocks.map(\.id))
    let previousMarks = session.document.marks
    do {
      try session.updateDocument(basedOn: revision) { article in
        article.blocks = blocks
        article.marks = previousMarks.filter { ids.contains($0.key) }
        for (id, mark) in removedMarks where ids.contains(id) { article.marks[id] = mark }
      }
      removedMarks = removedMarks.filter { !ids.contains($0.key) }
      for (id, mark) in previousMarks where !ids.contains(id) { removedMarks[id] = mark }
      return true
    } catch {
      report(error)
      return false
    }
  }

  private func mutateSelectedArticle(_ mutate: (inout Article) -> Void) {
    guard !isEditorLocked, let session = currentSession else { return }
    do { try session.updateDocument(mutate) } catch { report(error) }
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

  /// An explicit, read-only handoff. Never includes other drafts, image bytes or past versions.
  var agentExcerpt: String? {
    guard !composingInEditor, let article = currentArticle, let block = selectedBlock else {
      return nil
    }
    let text: String
    if block.kind == .text, state.selectedRange.length > 0,
      let range = try? block.text.range(forUTF16: state.selectedRange)
    {
      text = String(block.text.string[range])
    } else if let image = block.image {
      text = [image.altText, image.caption].filter { !$0.isEmpty }.joined(separator: "\n")
    } else {
      text = block.plainText
    }
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return """
      Redraft · \(article.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名文章" : article.title)
      文章：\(article.id)　基准版本：\(article.document.revisionID)　内容块：\(block.id)
      要求：\(article.marks[block.id] ?? "请阅读以下摘录，区分建议和需要查证的事实；查证时附上出处。")

      \(text)
      """
  }

  func copyExcerptForAgent() {
    guard let text = agentExcerpt else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    let copied = pasteboard.setString(text, forType: .string)
    showNotice(copied ? "摘录已复制。粘贴到你选用的 Agent 会话即可；Redraft 没有发送稿件。" : "未能写入剪贴板。")
  }

  func beginReview() {
    guard !composingInEditor else {
      showNotice("先确认正在输入的文字，再请求批注")
      return
    }
    guard canRequestAnnotations, let session = currentSession else { return }
    state.selectedChangeID = nil
    state.notice = nil
    state.dismissedAnnotationNotice = nil
    do { try session.beginReview(using: reviewProvider) } catch { report(error) }
  }

  func cancelReview() {
    guard state.section == .articles, state.sheet == nil, let session = currentSession,
      session.review.isRunning || session.review.isReady
    else { return }
    session.cancelReview()
    state.notice = "已取消本轮批注"
  }

  func enterReview() {
    guard let article = currentArticle,
      let change = currentChange ?? article.changes.first(where: {
        $0.blockID == state.selectedBlockID
      })
        ?? article.changes.first
    else { return }
    selectChange(change.id)
  }

  func showAnnotations(for blockID: UUID) {
    guard let change = currentArticle?.changes.first(where: { $0.blockID == blockID }) else {
      return
    }
    selectChange(change.id)
  }

  func selectChange(_ id: UUID) {
    guard state.section == .articles, state.sheet == nil,
      currentArticle?.phase == .ready
    else { return }
    guard let change = currentArticle?.changes.first(where: { $0.id == id }) else { return }
    state.selectedChangeID = id
    selectBlock(change.blockID)
    state.inspectorTab = .annotations
    state.inspectorVisible = true
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
    guard canEditReview, let change = currentChange, change.kind == .text
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
    guard state.sheet == .rewrite, state.section == .articles,
      currentArticle?.phase == .ready, let change = currentChange, change.kind == .text,
      !state.rewriteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return }
    do {
      try currentSession?.rewrite(
        changeID: change.id, text: state.rewriteText, reason: state.rewriteReason)
      dismissSheet()
    } catch { report(error) }
  }

  func completeReview(acceptRemaining: Bool = false) {
    guard canEditReview, let article = currentArticle, !article.changes.isEmpty else { return }
    do {
      try store.finishReview(articleID: article.id, acceptRemaining: acceptRemaining)
      showNotice("本轮改稿已完成")
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
    guard state.section == .articles, state.sheet == nil, currentArticle != nil else { return }
    state.inspectorTab = .provenance
    state.inspectorVisible = true
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
    state.dismissedAnnotationNotice = annotationNotice
  }

  private func clearSelection() {
    composingInEditor = false
    state.inspectorVisible = false
    state.inspectorTab = .marks
    state.selectedBlockID = nil
    state.selectedRange = NSRange(location: 0, length: 0)
    state.selectedChangeID = nil
    state.sheet = nil
    state.notice = nil
    state.dismissedAnnotationNotice = nil
    state.customInstruction = ""
    state.rewriteText = ""
    state.rewriteReason = ""
  }

  /// Shared documents can change in another window while this window keeps its own selection.
  private func reconcileState() {
    guard let article = currentArticle else {
      removedMarks.removeAll()
      state.selectedArticleID = articles.first?.id
      clearSelection()
      return
    }
    if let id = state.selectedBlockID {
      if let block = article.blocks.first(where: { $0.id == id }) {
        if block.kind == .text, !isValid(state.selectedRange, in: block.text.string) {
          state.selectedRange = NSRange(location: block.text.string.utf16.count, length: 0)
        }
      } else {
        state.selectedBlockID = nil
        state.selectedRange = NSRange(location: 0, length: 0)
        if state.sheet == .customMark {
          dismissSheet()
          state.customInstruction = ""
        }
      }
    }
    if article.phase != .ready {
      if state.inspectorTab == .annotations {
        state.inspectorVisible = false
        state.inspectorTab = .marks
      }
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
  }

  private var canEditReview: Bool {
    state.section == .articles && state.inspectorVisible && state.inspectorTab == .annotations
      && state.sheet == nil
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
