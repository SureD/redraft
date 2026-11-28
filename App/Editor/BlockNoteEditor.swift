import Combine
import RedraftCore
import SwiftUI
import WebKit

/// The bundled page owns the live selection, composition and undo stack, not the article library.
struct BlockNoteEditor: NSViewRepresentable {
  @ObservedObject var model: WorkspaceViewModel
  let focusRequest: Int
  @Environment(\.documentImageResolver) private var imageResolver

  func makeCoordinator() -> Coordinator { Coordinator(model: model, resolver: imageResolver) }

  func makeNSView(context: Context) -> WKWebView {
    let bridge = context.coordinator
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.preferences.javaScriptCanOpenWindowsAutomatically = false
    config.setURLSchemeHandler(bridge.images, forURLScheme: "redraft-image")
    config.userContentController.add(bridge, name: "redraft")
    config.userContentController.addScriptMessageHandler(
      bridge, contentWorld: .page, name: "redraftImage")
    let web = WKWebView(frame: .zero, configuration: config)
    web.navigationDelegate = bridge
    web.uiDelegate = bridge
    web.setAccessibilityLabel("文章正文")
    web.underPageBackgroundColor = NSColor(PaperTheme.paper)
    bridge.web = web
    bridge.load()
    return web
  }

  func updateNSView(_ web: WKWebView, context: Context) {
    context.coordinator.synchronize(focusRequest: focusRequest)
  }

  static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
    web.configuration.userContentController.removeAllScriptMessageHandlers()
    web.stopLoading()
    coordinator.detach()
  }

  @MainActor
  final class Coordinator: NSObject, WKScriptMessageHandler, WKScriptMessageHandlerWithReply,
    WKNavigationDelegate, WKUIDelegate
  {
    let model: WorkspaceViewModel
    let images: EditorImages
    weak var web: WKWebView?
    private let entry = Bundle.main.url(
      forResource: "index", withExtension: "html", subdirectory: "dist")?
      .resolvingSymlinksInPath()
    private var ready = false
    private var recoveredProcess = false
    private var needsReload = false
    private var token = UUID().uuidString
    // A page can have queued changes that native has not accepted yet.
    private var pageVersion = 0
    private var base: Article?
    private var editable: Bool?
    private var highlighted: UUID?
    private var lastFocusRequest = 0
    private var exportSubscription: AnyCancellable?
    private var proofreadingSubscription: AnyCancellable?
    private var proofreading: (id: String, edit: ProofreadingEdit)?

    init(model: WorkspaceViewModel, resolver: any DocumentImageResolving) {
      self.model = model
      images = EditorImages(resolver: resolver)
      super.init()
      exportSubscription = model.exportMarkdown.sink { [weak self] in
        Task { @MainActor in await self?.export() }
      }
      proofreadingSubscription = model.proofreadingEditRequested.sink { [weak self] edit in
        self?.applyProofreading(edit)
      }
    }

    private func applyProofreading(_ edit: ProofreadingEdit) {
      if proofreading?.edit == edit { return }
      guard proofreading == nil, ready, let web, isEntry(web.url), !model.isEditorLocked,
        !model.composingInEditor, let article = model.currentArticle?.document,
        article.id == edit.articleID, article.revisionID == edit.revisionID,
        base?.id == article.id, base?.blocks == article.blocks,
        let block = article.blocks.first(where: { $0.id == edit.blockID }), block.kind == .text,
        block.plainText.utf8.elementsEqual(edit.paragraph.utf8)
      else {
        model.proofreadingEditFinished(edit, applied: false)
        return
      }
      let id = UUID().uuidString
      proofreading = (id, edit)
      let payload: [String: Any] = [
        "requestID": id, "token": token, "version": pageVersion,
        "blockID": edit.blockID.uuidString.lowercased(), "paragraph": edit.paragraph,
        "original": edit.original, "replacement": edit.replacement,
      ]
      web.callAsyncJavaScript(
        "return window.redraft.applyProofreading(payload)", arguments: ["payload": payload],
        in: nil, in: .page
      ) { [weak self] result in
        if case .success(let value) = result, value as? Bool == true { return }
        self?.finishProofreading(id, applied: false)
      }
    }

    private func finishProofreading(_ id: String, applied: Bool) {
      guard let proofreading, proofreading.id == id else { return }
      self.proofreading = nil
      if applied, let web {
        web.window?.makeFirstResponder(web)
        call("window.redraft.focus()")
      }
      Task { @MainActor [model] in
        model.proofreadingEditFinished(proofreading.edit, applied: applied)
      }
    }

    private func cancelProofreading() {
      if let proofreading { finishProofreading(proofreading.id, applied: false) }
    }

    private func export() async {
      guard ready, let web, let window = web.window, let article = model.currentArticle?.document,
        !model.composingInEditor, base?.revisionID == article.revisionID
      else {
        model.showNotice("请先确认输入的文字，等稿件就绪后再导出。")
        return
      }
      do {
        let snapshot = try MarkdownExport(article: article, images: images)
        let value = try await web.callAsyncJavaScript(
          "return window.redraft.markdown(paths)", arguments: ["paths": snapshot.paths],
          contentWorld: .page)
        guard let text = value as? String,
          model.currentArticle?.document.revisionID == article.revisionID
        else {
          model.showNotice("稿件已变化，请重新导出。")
          return
        }
        let panel = NSOpenPanel()
        panel.message = "选择保存位置。Redraft 会新建文件夹，存放稿件.md 和本地图片。"
        panel.prompt = "导出"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard await panel.beginSheetModal(for: window) == .OK, let parent = panel.url else {
          return
        }
        let folder = try snapshot.write(text, in: parent)
        model.showNotice("已导出到「\(folder.lastPathComponent)」。")
      } catch { model.showNotice("导出失败：\(error.localizedDescription)") }
    }

    func load() {
      guard let entry else {
        Task { @MainActor in model.showNotice("缺少随应用发布的写作资源，请重新构建 Redraft。") }
        return
      }
      web?.loadFileURL(entry, allowingReadAccessTo: entry.deletingLastPathComponent())
    }

    func detach() {
      web = nil
      ready = false
      proofreadingSubscription?.cancel()
      cancelProofreading()
      model.composingInEditor = false
    }

    private func call(_ script: String, _ arguments: [String: Any] = [:]) {
      let generation = token
      web?.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) {
        [weak self] result in
        guard let self, web != nil, generation == token, case .failure(let error) = result else {
          return
        }
        model.showNotice("写作界面未能完成操作：\(error.localizedDescription)")
      }
    }

    func synchronize(focusRequest: Int? = nil) {
      guard ready, let article = model.currentArticle?.document else { return }
      let newArticle = base?.id != article.id
      let canWrite = !model.isEditorLocked
      if newArticle || needsReload
        || (base?.revisionID != article.revisionID && base?.blocks != article.blocks)
      {
        // Do not tear the candidate window out from under the author. Its stale commit is rejected below.
        if !newArticle && model.composingInEditor { return }
        do {
          let blocks = try JSONSerialization.jsonObject(
            with: BlockNoteDocument.encode(article.blocks))
          cancelProofreading()
          token = UUID().uuidString
          pageVersion = 0
          base = article
          needsReload = false
          images.reset(to: article.blocks)
          editable = canWrite
          highlighted = nil
          let focus = canWrite && newArticle && model.state.sheet == nil
          if focus { web?.window?.makeFirstResponder(web) }
          call(
            "window.redraft.open(payload)",
            ["payload": ["token": token, "blocks": blocks, "editable": canWrite, "focus": focus]])
        } catch {
          model.showNotice("无法打开这份正文：\(error.localizedDescription)")
          return
        }
      } else {
        // Title, marks and review decisions change outside the editor, without changing its undo history.
        base = article
      }
      let highlight = model.state.inspectorVisible ? model.state.selectedBlockID : nil
      if editable != canWrite || highlighted != highlight {
        editable = canWrite
        highlighted = highlight
        call(
          "window.redraft.configure(payload)",
          [
            "payload": [
              "editable": canWrite,
              "highlight": highlight?.uuidString.lowercased() as Any? ?? NSNull(),
            ]
          ])
      }
      if let focusRequest, focusRequest != lastFocusRequest {
        lastFocusRequest = focusRequest
        if canWrite {
          web?.window?.makeFirstResponder(web)
          call("window.redraft.focus()")
        }
      }
    }

    private func isEntry(_ url: URL?) -> Bool {
      guard let url, let entry, url.isFileURL else { return false }
      return url.resolvingSymlinksInPath().standardizedFileURL == entry.standardizedFileURL
    }

    private func trusted(_ message: WKScriptMessage) -> Bool {
      message.webView === web && message.frameInfo.isMainFrame
        && isEntry(message.frameInfo.request.url)
    }

    func userContentController(
      _ controller: WKUserContentController, didReceive message: WKScriptMessage
    ) {
      guard trusted(message), let body = message.body as? [String: Any],
        let kind = body["kind"] as? String
      else { return }
      if kind == "ready" {
        ready = true
        base = nil
        synchronize()
        return
      }
      guard body["token"] as? String == token, let base, base.id == model.currentArticle?.id else {
        return
      }
      switch kind {
      case "composition":
        model.composingInEditor = body["active"] as? Bool == true
        if !model.composingInEditor { synchronize() }
      case "selection":
        guard let rawID = body["id"] as? String, let id = UUID(uuidString: rawID) else { return }
        if let location = body["location"] as? Int, let length = body["length"] as? Int {
          model.updateSelection(blockID: id, range: NSRange(location: location, length: length))
        } else {
          model.selectBlock(id)
          if model.state.selectedBlockID == id
            && model.state.selectedRange != NSRange(location: 0, length: 0)
          {
            model.state.selectedRange = NSRange(location: 0, length: 0)
          }
        }
      case "change":
        let proofreadingID = body["proofreadingID"] as? String
        var applied = false
        defer {
          if let proofreadingID { finishProofreading(proofreadingID, applied: applied) }
        }
        guard !model.isEditorLocked, let current = model.currentArticle?.document,
          base.revisionID == current.revisionID || base.blocks == current.blocks,
          let version = body["version"] as? Int, version == pageVersion + 1
        else {
          model.showNotice("稿件已更新，未用旧的输入覆盖原文。")
          needsReload = true
          synchronize()
          return
        }
        if let proofreadingID {
          guard let proofreading, proofreading.id == proofreadingID,
            proofreading.edit.revisionID == current.revisionID, !model.composingInEditor
          else {
            needsReload = true
            synchronize()
            return
          }
        }
        do {
          guard let blocks = body["blocks"] as? [[String: Any]] else {
            throw EditingError.invalidDocument
          }
          let next = try BlockNoteDocument.decode(
            JSONSerialization.data(withJSONObject: blocks), previous: current.blocks,
            imageData: images.data(for:))
          guard model.commitEditorBlocks(next, articleID: current.id, basedOn: current.revisionID)
          else { throw EditingError.invalidDocument }
          pageVersion = version
          self.base = model.currentArticle?.document
          images.remember(next)
          applied = true
        } catch {
          model.showNotice("这次编辑无法保存，已恢复最近一次有效的正文：\(error.localizedDescription)")
          needsReload = true
          synchronize()
        }
      case "error": model.showNotice(body["message"] as? String ?? "写作界面遇到了问题")
      default: break
      }
    }

    func userContentController(
      _ controller: WKUserContentController, didReceive message: WKScriptMessage,
      replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
      guard trusted(message), let body = message.body as? [String: Any],
        body["token"] as? String == token,
        base?.id == model.currentArticle?.id, !model.isEditorLocked,
        let input = body["dataURL"] as? String,
        let url = images.stage(input)
      else {
        replyHandler(nil, "不能在此稿插入该图片（支持 PNG、JPEG、GIF、WebP，最大 12 MiB）。")
        return
      }
      replyHandler(url.absoluteString, nil)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async
      -> WKNavigationActionPolicy
    {
      action.targetFrame?.isMainFrame == true && isEntry(action.request.url)
        && action.navigationType != .linkActivated ? .allow : .cancel
    }

    func webView(
      _ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
      initiatedByFrame frame: WKFrameInfo
    ) async -> [URL]? {
      guard frame.isMainFrame, isEntry(frame.request.url), !model.isEditorLocked,
        let window = webView.window
      else { return nil }
      let panel = NSOpenPanel()
      panel.allowedContentTypes = [.png, .jpeg, .gif, .webP]
      panel.allowsMultipleSelection = parameters.allowsMultipleSelection
      panel.canChooseDirectories = false
      return await panel.beginSheetModal(for: window) == .OK ? panel.urls : nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
      ready = false
      base = nil
      cancelProofreading()
      model.composingInEditor = false
      model.showNotice("写作进程中断，已提交的正文仍在文章库。")
      if !recoveredProcess {
        recoveredProcess = true
        load()
      }
    }
  }
}
