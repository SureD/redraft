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
    try partialAndBulkAdoption()
    try examplesAndSnapshots()
    try sheetActionsStayScoped()
    try await mixedContentDecisionsStayIndependent()
    try await cancellationIsArticleScoped()
    try await writingThroughAdoption()
    try await unknownTextDoesNotInventSuggestions()
    try injectedSourcesAndSharedOwnership()
    try documentEditsAcrossWindows()
    try await sharedReviewLifecycle()
    try sharedReferencesStayValid()
    try await injectedReviewResultsAndFailures()
    try await proofreadingFollowsCurrentDraft()
    print("Workspace UI state: 16 scenarios passed")
  }

  @MainActor
  private static func proofreadingFollowsCurrentDraft() async throws {
    let prior = Article(title: "旧稿", blocks: [DocumentBlock(text: .init(string: "旧稿独有。"))])
    let fresh = Article(title: "新稿", blocks: [DocumentBlock()])
    let model = try WorkspaceViewModel(
      source: TestSupport.Source(
        seed: WorkspaceSeed(
          articles: [prior, fresh].map {
            ArticleSeed(document: $0)
          })),
      reviewProvider: NoReviewProvider(), proofreadingProvider: DelayedProofreader(),
      proofreadingDelay: .milliseconds(5))
    try expect(model.state.proofreadingVisible, "The live proofreading pane starts open")
    try await awaitProofreading("Old draft never started reading", model, status: .checking)
    model.selectArticle(fresh.id)
    try expect(
      model.proofreadingStatus == .waitingForText, "Switching clears the old draft's reading")
    let blockID = fresh.blocks[0].id
    TestSupport.replaceText(model, blockID, "新稿独有。")
    try expect(!model.isEditorLocked, "The author can keep writing while the text is checked")
    try await awaitProofreading("Fresh draft never finished reading", model, status: .upToDate)
    guard let suggestion = model.proofreadingSuggestions.first else {
      throw PaperTestFailure(message: "Fresh suggestion missing")
    }
    try expect(
      suggestion.blockID == blockID && model.proofreadingSuggestions.count == 1,
      "A superseded asynchronous result must not appear in another article")

    var requested: [ProofreadingEdit] = []
    let observation = model.proofreadingEditRequested.sink { requested.append($0) }
    defer { observation.cancel() }
    model.composingInEditor = true
    model.applyProofreadingSuggestion(suggestion)
    try expect(requested.isEmpty, "Active IME blocks applying a suggestion")
    model.composingInEditor = false
    model.applyProofreadingSuggestion(suggestion)
    guard let edit = requested.last else {
      throw PaperTestFailure(message: "A current suggestion must be sent to the editor")
    }
    try expect(
      edit.articleID == fresh.id && edit.paragraph == "新稿独有。"
        && model.currentArticle?.blocks[0].plainText == edit.paragraph,
      "Only the editor transaction can modify the document, after an explicit apply")
    model.proofreadingEditFinished(edit, applied: false)
    TestSupport.replaceText(model, blockID, "作者改了这句话。")
    try expect(
      model.proofreadingSuggestions.isEmpty, "An edited paragraph invalidates its suggestions")
    model.applyProofreadingSuggestion(suggestion)
    try expect(requested.count == 1, "The stale suggestion cannot mutate current text")
    try await awaitProofreading("Edited draft never finished reading", model, status: .upToDate)
    guard let refreshed = model.proofreadingSuggestions.first else {
      throw PaperTestFailure(message: "Updated suggestion missing")
    }
    model.dismissProofreadingSuggestion(refreshed)
    try expect(
      model.proofreadingSuggestions.isEmpty
        && model.currentArticle?.blocks[0].plainText == "作者改了这句话。",
      "Ignoring a suggestion leaves the original unchanged")
  }

  @MainActor
  private static func awaitProofreading(
    _ message: String, _ model: WorkspaceViewModel, status: ProofreadingStatus
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while model.proofreadingStatus != status, clock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    try expect(model.proofreadingStatus == status, message)
  }

  private struct DelayedProofreader: ProofreadingProviding {
    func suggestions(for paragraphs: [ProofreadingParagraph]) async throws -> ProofreadingResult {
      // Deliberately return a reply even if the enclosing task is cancelled.
      try? await Task.sleep(for: .milliseconds(45))
      return ProofreadingResult(
        source: .localRules,
        suggestions: paragraphs.map {
          ProofreadingSuggestion(
            blockID: $0.id, original: $0.text, replacement: "这是校对后的句子。", reason: "测试建议")
        })
    }
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
    try expect(
      !model.commitEditorBlocks(
        [DocumentBlock()], articleID: original.id, basedOn: original.document.revisionID),
      "A late change from the old page must be rejected")
    try expect(
      model.articles[0].blocks[0].text == original.blocks[0].text,
      "A stale editor callback must not mutate another article")
    model.state.sidebarVisible = true
    model.state.inspectorVisible = true
    model.newArticle()
    let created = model.currentArticle!.id
    try expect(
      model.currentArticle?.title == "" && model.currentArticle?.displayTitle == "未命名文章"
        && model.state.selectedBlockID == model.currentArticle?.blocks.first?.id,
      "A new article must start in its empty body and use a fallback name only for display")
    try expect(
      !model.state.inspectorVisible && !model.state.sidebarVisible
        && !model.canRequestAnnotations,
      "Blank writing must have no open panels, formatting row, or annotation request")
    model.state.articleQuery = "未命名"
    try expect(
      !model.filteredArticles.contains { $0.id == created }, "Blank paper stays out of the library")
    let firstLine = "正在写的文章"
    TestSupport.replaceText(model, model.currentArticle!.blocks[0].id, firstLine)
    model.state.articleQuery = firstLine
    try expect(
      model.filteredArticles.contains { $0.id == created && $0.displayTitle == firstLine },
      "Untitled drafts appear as soon as the author writes and can be found by their first line")
    model.renameArticle("新的文章")
    try expect(model.currentArticle?.title == "新的文章", "New articles must accept edits")
    model.deleteArticle(created)
    try expect(
      model.currentArticle != nil && model.currentArticle?.id != created
        && model.state.selectedBlockID == nil,
      "Deleting the selected article must leave a valid selection")
  }

  @MainActor
  private static func unicodeSelectionAndMarking() throws {
    let block = DocumentBlock(text: RichTextContent(string: "写👩🏽‍💻稿"))
    let article = Article(title: "", blocks: [block])
    let model = try TestSupport.model(articles: [article])
    let valid = NSRange(location: 1, length: "👩🏽‍💻".utf16.count)
    model.updateSelection(blockID: block.id, range: valid)
    model.updateSelection(blockID: block.id, range: NSRange(location: 2, length: 1))
    try expect(model.state.selectedRange == valid, "Selections cannot split composed characters")
    try expect(
      model.agentExcerpt?.hasSuffix("👩🏽‍💻") == true
        && model.agentExcerpt?.contains(article.revisionID.uuidString) == true
        && model.agentExcerpt?.contains("写👩🏽‍💻稿") == false,
      "An explicit Agent excerpt contains exactly the selected text and identifies its source revision"
    )
    model.markSelection(instruction: "更具体")
    try expect(model.currentArticle?.marks[block.id] == "更具体", "Marking uses the selected block")
    model.unmarkBlock(block.id)
    try expect(model.markedCount == 0, "Unmarking must update the same source of truth")
    model.markSelection(instruction: "更简洁")
    TestSupport.edit(model) { $0 = [DocumentBlock()] }
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
    try expect(
      model.state.section == .articles && model.state.inspectorTab == .annotations
        && model.state.inspectorVisible && model.currentArticle?.blocks == source,
      "Reading must open the annotations beside the original article")
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
    try expect(
      model.currentArticle?.blocks == source && model.currentArticle?.rounds.isEmpty == true,
      "Choosing or rewriting a suggestion must leave the active draft unchanged")
    model.completeReview()
    try expect(
      !model.state.inspectorVisible && !model.isEditorLocked,
      "Completing review must unlock writing")
    let round = model.currentArticle!.rounds.last!
    try expect(
      round.source.blocks == source && round.result.blocks == model.currentArticle?.blocks
        && round.result.blocks[0].plainText == changes[0].after
        && round.result.blocks[1] == source[1]
        && round.result.blocks[2].plainText == "这是我自己的表达。",
      "The final draft and its trajectory must record the selected, kept and rewritten text")
    try expect(
      model.examples.contains { $0.after == "这是我自己的表达。" && $0.decision == .rewrite },
      "The chosen expression must appear in examples")
  }

  @MainActor
  private static func partialAndBulkAdoption() throws {
    for acceptRemaining in [false, true] {
      let model = try TestSupport.demoModel()
      model.selectArticle(model.articles.first(where: { $0.phase == .ready })!.id)
      let changes = model.currentArticle!.changes
      model.showAnnotations(for: changes[1].blockID)
      try expect(
        model.currentChange?.id == changes[1].id && model.selectedBlock?.id == changes[1].blockID,
        "A paragraph annotation must target its own suggestion")
      model.decide(.keep)
      model.decide(.accept, changeID: changes[0].id)
      model.completeReview(acceptRemaining: acceptRemaining)
      let round = model.currentArticle!.rounds.last!
      try expect(
        round.result.blocks[0].plainText == changes[0].after
          && round.result.blocks[1].plainText == changes[1].before
          && round.result.blocks[2].plainText
            == (acceptRemaining ? changes[2].after : changes[2].before),
        "Finishing a round must preserve explicit decisions and apply only the requested defaults")
    }
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
    model.state.exampleFilter = .rewrite
    model.state.exampleQuery = "受潮"
    try expect(
      model.filteredExamples.count == 1 && model.filteredExamples[0].decision == .rewrite,
      "Example search and decision filter must combine")
    let example = model.filteredExamples[0]
    model.selectExample(example.id)
    try expect(
      model.state.selectedArticleID == example.articleID && model.state.section == .articles,
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
    model.showSheet(.customMark)
    try expect(model.state.sheet == nil, "Locked review content cannot open a mark sheet")
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
    reviewModel.completeReview(acceptRemaining: true)
    let finalTable = reviewModel.currentArticle!.blocks.first { $0.id == table.id }!.table!
    try expect(
      finalTable.rows.count == table.table!.rows.count + 1
        && finalTable.columnIDs == table.table!.columnIDs
        && finalTable.rows[1][3] == "长得很慢" && finalTable.rows[2][3] == "每天浇水",
      "Applying the batch must compose cell and row edits while preserving the kept column")
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
      model.state.notice == "已取消本轮批注",
      "A background completion must not replace another article's notice")
    model.beginReview()
    model.deleteArticle(second)
    try await Task.sleep(for: .milliseconds(1300))
    try expect(
      !model.articles.contains { $0.id == second },
      "A deleted article must not reappear when its pending request ends")
    model.selectArticle(first)
    model.enterReview()
    let source = model.currentArticle!.document
    model.decide(.accept)
    model.cancelReview()
    try expect(
      !model.isEditorLocked && !model.state.inspectorVisible
        && model.currentArticle?.document == source
        && model.currentArticle?.rounds.isEmpty == true,
      "Returning to the original from a ready batch must leave staged changes unapplied")
  }

  @MainActor
  private static func writingThroughAdoption() async throws {
    let model = try TestSupport.demoModel()
    model.newArticle()
    let paragraph = model.selectedBlock!
    let draft = "院子里的薄荷长得非常非常慢。"
    let adopted = "院子里的薄荷长得非常慢。"
    TestSupport.replaceText(model, paragraph.id, draft)
    try expect(
      model.canRequestAnnotations && model.markedCount == 0 && !model.state.inspectorVisible,
      "A writer can request annotations directly after ordinary typing")
    model.beginReview()
    for _ in 0..<100 where model.currentArticle?.phase == .running {
      try await Task.sleep(for: .milliseconds(5))
    }
    try expect(
      model.currentArticle?.phase == .ready && !model.state.inspectorVisible
        && model.selectedBlock?.plainText == draft,
      "The demo response must keep the original text and not open a pane automatically")
    model.showAnnotations(for: paragraph.id)
    try expect(
      model.currentChange?.after == adopted && model.currentChange?.explanation.isEmpty == false,
      "Opening the paragraph note must present a suggestion and its explanation")
    model.completeReview(acceptRemaining: true)
    model.showProvenance()
    try expect(
      model.state.inspectorTab == .provenance && model.selectedBlock?.plainText == adopted
        && model.currentArticle?.rounds.last?.source.blocks.first?.plainText == draft
        && model.currentArticle?.rounds.last?.changes.first?.blockID == paragraph.id,
      "The adopted draft must retain a paragraph-linked record of the original and AI suggestion")
  }

  @MainActor
  private static func unknownTextDoesNotInventSuggestions() async throws {
    let model = try TestSupport.demoModel()
    model.newArticle()
    let block = model.currentArticle!.blocks[0]
    TestSupport.replaceText(model, block.id, "今天去看海。")
    model.markBlock(block.id, instruction: "更简洁")
    model.beginReview()
    try await Task.sleep(for: .milliseconds(1300))
    try expect(
      model.currentArticle?.phase == .idle && model.currentArticle?.changes.isEmpty == true
        && model.canRequestAnnotations && model.notice == "本轮暂无批注",
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
    let snapshot = store.session(for: original.id)!.saveVersion(title: "初稿")
    let initialRevision = original.revisionID
    first.renameArticle("修改后的标题")
    TestSupport.replaceText(first, original.blocks[0].id, "新的正文")
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
  private static func documentEditsAcrossWindows() throws {
    let first = DocumentBlock(text: RichTextContent(string: "薄荷"))
    let second = DocumentBlock(text: RichTextContent(string: "罗勒"))
    let image = DocumentBlock(image: ImageContent(caption: "阳台"))
    let article = Article(
      title: "香草", blocks: [first, second, image], marks: [second.id: "写具体些"])
    let store = try WorkspaceStore(seed: WorkspaceSeed(articles: [ArticleSeed(document: article)]))
    let writer = WorkspaceViewModel(store: store, reviewProvider: NoReviewProvider())
    let peer = WorkspaceViewModel(store: store, reviewProvider: NoReviewProvider())
    let before = writer.currentArticle!.document
    TestSupport.edit(peer) { $0[2].image?.caption = "清晨的阳台" }
    let merged = DocumentBlock(id: first.id, text: RichTextContent(string: "薄荷和罗勒"))
    try expect(
      !writer.commitEditorBlocks(
        [merged, image], articleID: before.id, basedOn: before.revisionID),
      "Stale whole-page input cannot overwrite another window's photo change")
    let latest = writer.currentArticle!.document
    let updatedImage = latest.blocks[2]
    try expect(
      writer.commitEditorBlocks(
        [merged, updatedImage], articleID: latest.id, basedOn: latest.revisionID)
        && peer.currentArticle?.marks[second.id] == nil
        && peer.currentArticle?.blocks.last?.image?.caption == "清晨的阳台",
      "A fresh transaction replaces the page once and removes only missing block marks")
    let joined = writer.currentArticle!.document
    try expect(
      writer.commitEditorBlocks(
        [first, second, updatedImage], articleID: joined.id, basedOn: joined.revisionID)
        && peer.currentArticle?.marks[second.id] == "写具体些",
      "Undo restores a surviving block's scope by ID")
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
    second.showSheet(.customMark)
    TestSupport.edit(first) { $0.removeAll { $0.id == image.id } }
    try expect(
      second.state.selectedBlockID == nil && second.state.sheet == nil,
      "Removing a shared block must close editors targeting that block")
    second.updateSelection(blockID: paragraph.id, range: NSRange(location: 2, length: 4))
    TestSupport.replaceText(first, paragraph.id, "短")
    try expect(
      second.state.selectedRange == NSRange(location: 1, length: 0),
      "External text changes must repair a now-invalid local selection")
    second.showSheet(.customMark)
    first.deleteArticle(article.id)
    try expect(
      second.state.selectedArticleID == nil && second.state.selectedBlockID == nil
        && second.state.sheet == nil && !second.state.inspectorVisible,
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
    reviewer.completeReview(acceptRemaining: true)
    try expect(
      !peer.state.inspectorVisible && peer.state.sheet == nil && !peer.isEditorLocked
        && peer.state.selectedChangeID == nil && peer.state.rewriteText.isEmpty
        && peer.currentArticle?.rounds.count == 1
        && peer.currentArticle?.blocks == reviewer.currentArticle?.blocks,
      "Finishing a shared review must dismiss another window's obsolete rewrite draft")
  }

  @MainActor
  private static func injectedReviewResultsAndFailures() async throws {
    let block = DocumentBlock(text: RichTextContent(string: "独立的测试输入"))
    let document = Article(title: "接口测试", blocks: [block])
    let source = TestSupport.Source(
      seed: WorkspaceSeed(articles: [ArticleSeed(document: document)]))
    let model = try WorkspaceViewModel(source: source, reviewProvider: InjectedReviewProvider())
    model.beginReview()
    for _ in 0..<100 where model.currentArticle?.phase == .running {
      try await Task.sleep(for: .milliseconds(2))
    }
    try expect(
      model.currentChange == nil && !model.state.inspectorVisible
        && model.currentArticle?.document == document
        && model.currentArticle?.changes.first?.after == "注入接口的结果",
      "An unmarked draft can request whole-article feedback without moving focus or changing text")
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
