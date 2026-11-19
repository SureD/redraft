import AppKit
import Combine
import RedraftCore

/// Run with the App model and view-model sources, outside the application target.
@main
struct WorkspaceStateTests {
  @MainActor
  static func main() async throws {
    try articleSelectionAndDeletion()
    try unicodeSelectionAndMarking()
    try reviewDecisions()
    try examplesAndSnapshots()
    try sheetActionsStayScoped()
    try await mixedContentDecisionsStayIndependent()
    try await cancellationIsArticleScoped()
    try await unknownTextDoesNotInventSuggestions()
    try injectedSourcesAndSharedOwnership()
    try await sharedReviewLifecycle()
    try sharedReferencesStayValid()
    try await injectedReviewResultsAndFailures()
    print("Workspace UI state: 12 scenarios passed")
  }

  @MainActor
  private static func articleSelectionAndDeletion() throws {
    let model = try TestSupport.demoModel()
    let original = model.currentArticle!
    model.selectBlock(original.blocks[0].id)
    model.showSheet(.customMark)
    model.state.customInstruction = "旧文章的标记"
    model.selectArticle(model.articles[1].id)
    try expect(
      model.state.selectedBlockID == nil && model.state.sheet == nil,
      "Changing articles must clear selection and presented edits")
    try expect(model.state.customInstruction.isEmpty, "Sheet drafts must not leak across articles")
    model.updateBlockText(original.blocks[0].id, text: NSAttributedString(string: "错误修改"))
    try expect(
      model.articles[0].blocks[0].text == original.blocks[0].text,
      "A stale editor callback must not mutate another article")
    model.newArticle()
    let created = model.currentArticle!.id
    model.renameArticle("新的文章")
    try expect(model.currentArticle?.title == "新的文章", "New articles must accept edits")
    model.deleteArticle(created)
    try expect(
      model.currentArticle != nil && model.currentArticle?.id != created,
      "Deleting the selected article must leave a valid selection")
  }

  @MainActor
  private static func unicodeSelectionAndMarking() throws {
    let block = DocumentBlock(text: RichTextContent(string: "写👩🏽‍💻稿"))
    let article = Article(title: "边界", blocks: [block])
    let model = try TestSupport.model(articles: [article])
    let valid = NSRange(location: 1, length: "👩🏽‍💻".utf16.count)
    model.updateSelection(blockID: block.id, range: valid)
    model.updateSelection(blockID: block.id, range: NSRange(location: 2, length: 1))
    try expect(model.state.selectedRange == valid, "Selections cannot split composed characters")
    model.markSelection(instruction: "更具体")
    try expect(model.currentArticle?.marks[block.id] == "更具体", "Marking uses the selected block")
    model.unmarkBlock(block.id)
    try expect(model.markedCount == 0, "Unmarking must update the same source of truth")
    model.markSelection(instruction: "更简洁")
    model.deleteBlock(block.id)
    try expect(
      model.markedCount == 0 && model.state.selectedBlockID == nil,
      "Deleting a block must remove its marks and selection")
    try expect(
      model.currentArticle?.blocks.count == 1,
      "Deleting the last block must preserve an editable blank paragraph")
  }

  @MainActor
  private static func reviewDecisions() throws {
    let model = try TestSupport.demoModel()
    model.selectArticle(model.articles.first(where: { $0.phase == .ready })!.id)
    let source = model.currentArticle!.blocks
    model.enterReview()
    model.completeReview()
    try expect(
      model.state.mode == .review && model.currentArticle?.phase == .ready,
      "Unresolved review decisions must prevent completion")
    let changes = model.currentArticle!.changes
    model.decide(.accept, changeID: changes[0].id)
    model.decide(.keep, changeID: changes[1].id)
    model.decide(.rewrite, changeID: changes[2].id)
    try expect(
      model.state.sheet == .rewrite && model.state.rewriteText == changes[2].after,
      "Rewrite must open with the current suggestion")
    model.state.rewriteText = "这是我自己的表达。"
    model.state.rewriteReason = "更符合我的语气"
    model.submitRewrite()
    try expect(model.unresolvedCount == 0, "All three review choices must resolve a change")
    model.completeReview()
    try expect(
      model.state.mode == .writing && model.currentArticle?.phase == .idle,
      "Completing review must unlock writing")
    try expect(
      model.currentArticle?.blocks == source,
      "UI preview must not pretend to run the unimplemented document merge")
    try expect(
      model.examples.contains { $0.after == "这是我自己的表达。" && $0.decision == .rewrite },
      "The chosen expression must appear in examples")
  }

  @MainActor
  private static func examplesAndSnapshots() throws {
    let model = try TestSupport.demoModel()
    let diary = model.articles.first { $0.title == "写日记的第一百天" }!
    let originalDiary = diary.versions[0].blocks
    let styledDiary = diary.versions[1].blocks
    try expect(
      originalDiary.map(\.plainText) == styledDiary.map(\.plainText)
        && originalDiary != styledDiary,
      "The diary must demonstrate formatting-only history without inventing text changes")
    let versionCount = model.currentArticle!.versions.count
    model.setMode(.history)
    model.savePreviewVersion()
    try expect(
      model.currentArticle!.versions.count == versionCount + 1,
      "Manual snapshots must work from history as well as writing")
    model.state.exampleFilter = .rewrite
    model.state.exampleQuery = "受潮"
    try expect(
      model.filteredExamples.count == 1 && model.filteredExamples[0].decision == .rewrite,
      "Example search and decision filter must combine")
    let example = model.filteredExamples[0]
    model.selectExample(example.id)
    try expect(
      model.state.selectedArticleID == example.articleID && model.state.mode == .writing,
      "An example must navigate back to its source article")
    try expect(
      model.selectedBlock?.plainText.contains(example.after) == true
        && model.state.inspectorTab == .provenance && model.state.inspectorVisible,
      "An example must select its matching source block and open provenance")
  }

  @MainActor
  private static func sheetActionsStayScoped() throws {
    let model = try TestSupport.demoModel()
    model.showSheet(.customMark)
    try expect(model.state.sheet == nil, "A custom mark needs a selected content block")
    model.selectBlock(model.currentArticle!.blocks[0].id)
    model.showSheet(.customMark)
    model.state.customInstruction = "更具体"
    model.dismissSheet()
    let count = model.markedCount
    model.submitCustomMark()
    try expect(model.markedCount == count, "A dismissed sheet cannot submit a stale custom mark")

    model.selectArticle(model.articles.first { $0.phase == .ready }!.id)
    model.enterReview()
    let first = model.currentChange!
    let other = model.currentArticle!.changes[1]
    try expect(
      model.state.selectedBlockID == first.blockID,
      "Entering review must keep the current change and source block in sync")
    model.decide(.rewrite)
    model.state.rewriteText = " \n "
    model.submitRewrite()
    try expect(
      model.state.sheet == .rewrite && model.currentChange?.decision == nil,
      "Blank rewrites cannot resolve a change or dismiss the editor")
    model.selectChange(other.id)
    model.decide(.accept, changeID: other.id)
    try expect(
      model.state.selectedChangeID == first.id
        && model.currentArticle?.changes.first { $0.id == other.id }?.decision == nil,
      "An open sheet must not retarget its pending rewrite behind the modal")
    model.dismissSheet()
    model.state.rewriteText = "迟到的提交"
    model.submitRewrite()
    try expect(model.currentChange?.decision == nil, "Dismissed rewrite submissions are ignored")
    model.showSheet(.insertTable)
    try expect(model.state.sheet == nil, "Locked review content cannot open an insert sheet")
  }

  @MainActor
  private static func mixedContentDecisionsStayIndependent() async throws {
    let model = try TestSupport.demoModel()
    let article = model.currentArticle!
    let changes = try await DemoReviewProvider(delay: .zero).changes(
      for: ReviewRequest(article: article.document))
    let table = article.blocks.first { $0.kind == .table }!
    let tableChanges = changes.filter { $0.blockID == table.id }
    for change in tableChanges {
      if let before = change.beforeBlock?.table, let after = change.afterBlock?.table {
        try expect(
          after.rowIDs.count == after.rows.count && after.columnIDs.count == after.columnCount,
          "Table preview structures must preserve a valid identity for every cell")
        if change.kind == .text {
          try expect(
            before.rowIDs == after.rowIDs && before.columnIDs == after.columnIDs,
            "Cell text changes must preserve row and column identity")
        }
      }
    }
    try expect(
      tableChanges.filter { $0.kind == .text }.count == 2
        && tableChanges.filter { $0.kind == .tableColumn }.count == 1
        && tableChanges.filter { $0.kind == .tableRow }.count == 1,
      "Cell text, column removal, and row insertion need independent review decisions")
    let image = article.blocks.first { $0.kind == .image }!
    try expect(
      changes.filter { $0.blockID == image.id }.count == 2,
      "Replacing a picture and rewriting its caption are separate choices")
    let reviewModel = try WorkspaceViewModel(
      source: TestSupport.Source(
        seed: WorkspaceSeed(articles: [
          ArticleSeed(
            document: article.document,
            review: ReviewBatch(
              articleID: article.id, baseRevisionID: article.document.revisionID, changes: changes))
        ])), reviewProvider: NoReviewProvider())
    reviewModel.enterReview()
    let column = tableChanges.first { $0.kind == .tableColumn }!
    let row = tableChanges.first { $0.kind == .tableRow }!
    reviewModel.decide(.rewrite, changeID: column.id)
    try expect(reviewModel.state.sheet == nil, "Structural changes do not offer text rewriting")
    reviewModel.decide(.keep, changeID: column.id)
    reviewModel.decide(.accept, changeID: row.id)
    try expect(
      reviewModel.currentArticle?.changes.first { $0.id == column.id }?.decision == .keep
        && reviewModel.currentArticle?.changes.first { $0.id == row.id }?.decision == .accept,
      "Keeping a column must not undo the choice to accept a new row")
    for change in reviewModel.currentArticle!.changes where change.decision == nil {
      reviewModel.decide(.accept, changeID: change.id)
    }
    reviewModel.completeReview()
    let imageExample = reviewModel.examples.first { $0.blockID == image.id }!
    reviewModel.selectExample(imageExample.id)
    try expect(
      reviewModel.state.selectedBlockID == image.id,
      "Image examples must navigate by stable block identity, even without matching text")
  }

  @MainActor
  private static func cancellationIsArticleScoped() async throws {
    let model = try TestSupport.demoModel()
    let first = model.articles[0].id
    let second = model.articles[1].id
    model.beginReview()
    model.selectArticle(second)
    model.beginReview()
    model.cancelReview()
    try await Task.sleep(for: .milliseconds(1300))
    try expect(
      model.articles.first { $0.id == first }?.phase == .ready,
      "Switching articles must preserve the first article's request")
    try expect(
      model.articles.first { $0.id == second }?.phase == .idle,
      "Cancelling must affect only the selected article")
    try expect(
      model.state.notice == "已取消，标记保持原样",
      "A background completion must not replace another article's notice")
    model.beginReview()
    model.deleteArticle(second)
    try await Task.sleep(for: .milliseconds(1300))
    try expect(
      !model.articles.contains { $0.id == second },
      "A deleted article must not reappear when its pending request ends")
  }

  @MainActor
  private static func unknownTextDoesNotInventSuggestions() async throws {
    let model = try TestSupport.demoModel()
    model.newArticle()
    let block = model.currentArticle!.blocks[0]
    model.updateBlockText(block.id, text: NSAttributedString(string: "这是一段新的文字。"))
    model.markBlock(block.id, instruction: "更简洁")
    model.beginReview()
    try await Task.sleep(for: .milliseconds(1300))
    try expect(
      model.currentArticle?.phase == .idle && model.currentArticle?.changes.isEmpty == true,
      "Unknown text must not receive fabricated service results")
    try expect(model.markedCount == 1, "Unmatched previews must preserve the user's marks")
  }

  @MainActor
  private static func injectedSourcesAndSharedOwnership() throws {
    let empty = try WorkspaceViewModel(
      source: EmptyWorkspaceContentSource(), reviewProvider: NoReviewProvider())
    try expect(
      empty.articles.isEmpty && empty.currentArticle == nil,
      "An empty source must never silently load demo articles")
    empty.newArticle()
    try expect(
      empty.articles.count == 1 && empty.currentArticle?.blocks.first?.plainText == "",
      "Creating a document must use the Core model, not sample content")

    let original = Article(
      title: "共享文档", blocks: [DocumentBlock(text: RichTextContent(string: "初稿"))])
    let store = try WorkspaceStore(seed: WorkspaceSeed(articles: [ArticleSeed(document: original)]))
    let first = WorkspaceViewModel(store: store, reviewProvider: NoReviewProvider())
    let second = WorkspaceViewModel(store: store, reviewProvider: NoReviewProvider())
    var secondNotifications = 0
    let subscription = second.objectWillChange.sink { secondNotifications += 1 }
    defer { subscription.cancel() }
    first.state.inspectorVisible = true
    first.savePreviewVersion()
    let snapshot = first.historyTo!
    let initialRevision = original.revisionID
    first.renameArticle("修改后的标题")
    first.updateBlockText(original.blocks[0].id, text: NSAttributedString(string: "新的正文"))
    try expect(
      second.currentArticle?.title == "修改后的标题"
        && second.currentArticle?.blocks.first?.plainText == "新的正文",
      "Two view models must project the same canonical document")
    try expect(
      second.currentArticle?.document.revisionID != initialRevision && secondNotifications > 0,
      "Session edits must publish a new revision to every subscribed window")
    try expect(
      second.state.inspectorVisible == false,
      "Sharing documents must not share window-local UI state")
    try expect(
      snapshot.blocks.first?.plainText == "初稿"
        && second.currentArticle?.versions.last?.blocks.first?.plainText == "初稿",
      "Saved snapshots are immutable historical values, not another writable current document")
    var detached = second.currentArticle!.document
    detached.title = "不能写穿投影"
    try expect(
      first.currentArticle?.title == "修改后的标题",
      "Mutating a detached snapshot must not bypass the session")
    first.deleteArticle(original.id)
    try expect(
      second.articles.isEmpty && second.currentArticle == nil,
      "Deleting a shared article must invalidate every derived view")
  }

  @MainActor
  private static func sharedReviewLifecycle() async throws {
    let source = DemoWorkspaceContentSource().load()
    let store = try WorkspaceStore(seed: source)
    let first = WorkspaceViewModel(
      store: store, reviewProvider: DemoReviewProvider(delay: .seconds(10)))
    let second = WorkspaceViewModel(store: store, reviewProvider: NoReviewProvider())
    first.beginReview()
    try expect(
      second.currentArticle?.phase == .running && second.isEditorLocked,
      "Review workflow state must belong to the shared article session")
    second.cancelReview()
    try expect(
      first.currentArticle?.phase == .idle && !first.isEditorLocked,
      "A second consumer must cancel the same request, not a separate view-model task")
    try await Task.sleep(for: .milliseconds(10))
    try expect(
      first.currentArticle?.changes.isEmpty == true,
      "Cancelled work must not republish suggestions")
  }

  @MainActor
  private static func sharedReferencesStayValid() throws {
    let paragraph = DocumentBlock(text: RichTextContent(string: "原来的较长正文"))
    let image = DocumentBlock(image: ImageContent(altText: "原来的描述"))
    let article = Article(title: "引用校正", blocks: [paragraph, image])
    let store = try WorkspaceStore(seed: WorkspaceSeed(articles: [ArticleSeed(document: article)]))
    let first = WorkspaceViewModel(store: store, reviewProvider: NoReviewProvider())
    let second = WorkspaceViewModel(store: store, reviewProvider: NoReviewProvider())
    second.selectBlock(image.id)
    second.showSheet(.imageDescription)
    first.deleteBlock(image.id)
    try expect(
      second.state.selectedBlockID == nil && second.state.sheet == nil,
      "Removing a shared block must close editors targeting that block")
    second.updateSelection(blockID: paragraph.id, range: NSRange(location: 2, length: 4))
    first.updateBlockText(paragraph.id, text: NSAttributedString(string: "短"))
    try expect(
      second.state.selectedRange == NSRange(location: 1, length: 0),
      "External text changes must repair a now-invalid local selection")
    second.showSheet(.customMark)
    first.deleteArticle(article.id)
    try expect(
      second.state.selectedArticleID == nil && second.state.selectedBlockID == nil
        && second.state.sheet == nil && second.state.mode == .writing,
      "Removing an article must reconcile selection and sheets in all consumers")

    let reviewStore = try WorkspaceStore(seed: DemoWorkspaceContentSource().load())
    let reviewer = WorkspaceViewModel(store: reviewStore, reviewProvider: NoReviewProvider())
    let peer = WorkspaceViewModel(store: reviewStore, reviewProvider: NoReviewProvider())
    let ready = reviewer.articles.first { $0.phase == .ready }!
    reviewer.selectArticle(ready.id)
    peer.selectArticle(ready.id)
    reviewer.enterReview()
    peer.enterReview()
    peer.startRewrite()
    for change in ready.changes { reviewer.decide(.keep, changeID: change.id) }
    reviewer.completeReview()
    try expect(
      peer.state.mode == .writing && peer.state.sheet == nil
        && peer.state.selectedChangeID == nil && peer.state.rewriteText.isEmpty,
      "Finishing a shared review must dismiss another window's obsolete rewrite draft")
  }

  @MainActor
  private static func injectedReviewResultsAndFailures() async throws {
    let block = DocumentBlock(text: RichTextContent(string: "独立的测试输入"))
    let document = Article(title: "接口测试", blocks: [block], marks: [block.id: "修改"])
    let source = TestSupport.Source(
      seed: WorkspaceSeed(articles: [ArticleSeed(document: document)]))
    let model = try WorkspaceViewModel(source: source, reviewProvider: InjectedReviewProvider())
    model.beginReview()
    for _ in 0..<100 where model.currentArticle?.phase == .running {
      try await Task.sleep(for: .milliseconds(2))
    }
    try expect(
      model.currentChange == nil && model.currentArticle?.changes.first?.after == "注入接口的结果",
      "Review content must come from the injected provider, including non-demo articles")
    let failure = try WorkspaceViewModel(source: source, reviewProvider: FailingReviewProvider())
    failure.beginReview()
    for _ in 0..<100 where failure.currentArticle?.phase == .running {
      try await Task.sleep(for: .milliseconds(2))
    }
    try expect(
      failure.notice?.contains("可重试的错误") == true && !failure.isEditorLocked,
      "Provider errors must be projected into visible retryable UI state")
    failure.dismissNotice()
    try expect(failure.notice == nil, "Dismissing a projected error is local UI state")
  }

  private struct InjectedReviewProvider: ReviewProviding {
    func changes(for request: ReviewRequest) async throws -> [ReviewChange] {
      let block = request.article.blocks[0]
      return [
        ReviewChange(
          blockID: block.id, before: block.plainText,
          after: "注入接口的结果", explanation: "测试接口")
      ]
    }
  }

  private struct FailingReviewProvider: ReviewProviding {
    struct Failure: LocalizedError {
      var errorDescription: String? { "可重试的错误" }
    }
    func changes(for request: ReviewRequest) async throws -> [ReviewChange] { throw Failure() }
  }

  private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(message: message) }
  }

  private struct TestFailure: Error {
    let message: String
  }
}
