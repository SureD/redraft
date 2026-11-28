import AppKit
import RedraftCore
import SwiftUI

struct ArticleSidebar: View {
  @ObservedObject var model: WorkspaceViewModel
  var dismissOnSelection = false
  @FocusState private var searchFocused: Bool

  var body: some View {
    let results = model.filteredArticles
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 12) {
        Text("所有文章")
          .font(.system(size: 17, weight: .semibold))
          .accessibilityAddTraits(.isHeader)
        searchField
      }
      .padding(.horizontal, 16)
      .padding(.top, 18)
      .padding(.bottom, 12)

      if results.isEmpty {
        emptyState
      } else {
        ScrollView {
          LazyVStack(spacing: 2) {
            ForEach(results) { article in articleRow(article) }
          }
          .padding(.horizontal, 8)
          .padding(.bottom, 8)
        }
      }

      Divider()
      examplesLink
        .padding(8)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .foregroundStyle(PaperTheme.ink)
    .background(PaperTheme.librarySurface)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("文章库")
  }

  private var searchField: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(PaperTheme.secondaryText)
        .accessibilityHidden(true)
      TextField(
        "搜索文章", text: $model.state.articleQuery,
        prompt: Text("搜索标题或正文").foregroundStyle(PaperTheme.secondaryText)
      )
      .textFieldStyle(.plain)
      .focused($searchFocused)
      .accessibilityLabel("搜索文章")
      if !model.state.articleQuery.isEmpty {
        Button {
          model.state.articleQuery = ""
        } label: {
          Image(systemName: "xmark.circle.fill").frame(width: 22, height: 26)
        }
        .buttonStyle(.plain)
        .foregroundStyle(PaperTheme.secondaryText)
        .help("清除搜索")
        .accessibilityLabel("清除搜索")
      }
    }
    .font(.system(size: 13))
    .padding(.horizontal, 9)
    .frame(height: 32)
    .background(PaperTheme.fill, in: RoundedRectangle(cornerRadius: 8))
    .overlay {
      if searchFocused {
        RoundedRectangle(cornerRadius: 8).strokeBorder(PaperTheme.accent)
          .allowsHitTesting(false)
      }
    }
  }

  private var emptyState: some View {
    let isSearching = !model.state.articleQuery
      .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    return VStack(alignment: .leading, spacing: 10) {
      Text(isSearching ? "没有匹配的文章" : "还没有文章")
        .font(.callout)
        .foregroundStyle(PaperTheme.secondaryText)
      if isSearching {
        Button("清除搜索") {
          model.state.articleQuery = ""
          searchFocused = true
        }
        .buttonStyle(.plain)
        .foregroundStyle(PaperTheme.accent)
      } else {
        Button("新建文章", action: model.newArticle)
          .buttonStyle(.plain)
          .foregroundStyle(PaperTheme.accent)
      }
    }
    .font(.callout)
    .padding(16)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var examplesLink: some View {
    let selected = model.state.section == .examples
    return Button {
      model.showExamples()
      dismissDrawer()
    } label: {
      Label("改写范例", systemImage: "quote.opening")
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(selected ? PaperTheme.accent : PaperTheme.secondaryText)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .background(selected ? PaperTheme.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private func articleRow(_ article: ArticleViewState) -> some View {
    let selected = model.state.section == .articles && model.state.selectedArticleID == article.id
    return Button {
      model.selectArticle(article.id)
      dismissDrawer()
    } label: {
      VStack(alignment: .leading, spacing: 4) {
        Text(article.displayTitle)
          .font(.system(size: 14, weight: selected ? .semibold : .medium))
          .foregroundStyle(PaperTheme.ink)
          .lineLimit(1)
        if let excerpt = excerpt(for: article) {
          Text(excerpt)
            .font(.system(size: 12))
            .foregroundStyle(PaperTheme.secondaryText)
            .lineLimit(1)
        }
        HStack(spacing: 6) {
          Text(article.updatedAt, format: .dateTime.month().day())
            .monospacedDigit()
          if article.phase != .idle {
            Text("·").accessibilityHidden(true)
            Text(article.phase == .running ? "正在批注" : "\(article.changes.count) 条批注")
              .foregroundStyle(PaperTheme.accent)
          }
        }
        .font(.system(size: 11))
        .foregroundStyle(PaperTheme.secondaryText)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
      .background(selected ? PaperTheme.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .contextMenu {
      Button("打开文章") {
        model.selectArticle(article.id)
        dismissDrawer()
      }
      Button("删除文章…", role: .destructive) { confirmDelete(article) }
    }
  }

  private func excerpt(for article: ArticleViewState) -> String? {
    let lines = article.blocks.lazy
      .flatMap { $0.plainText.split(whereSeparator: \.isNewline) }
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    if article.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return lines.dropFirst().first
    }
    return lines.first
  }

  private func dismissDrawer() {
    if dismissOnSelection { model.state.sidebarVisible = false }
  }

  private func confirmDelete(_ article: ArticleViewState) {
    guard let window = NSApp.keyWindow else { return }
    let alert = NSAlert()
    alert.messageText = "删除“\(article.displayTitle)”？"
    alert.informativeText = "这篇文章及其改稿历史会从本地文章库中删除。"
    alert.addButton(withTitle: "取消")
    alert.addButton(withTitle: "删除")
    alert.beginSheetModal(for: window) { response in
      if response == .alertSecondButtonReturn { model.deleteArticle(article.id) }
    }
  }
}
