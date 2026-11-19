import AppKit
import RedraftCore
import SwiftUI

struct ArticleSidebar: View {
  @ObservedObject var model: WorkspaceViewModel
  var dismissOnSelection = false

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Text("R").font(.system(size: 20, weight: .semibold, design: .serif))
          .foregroundStyle(PaperTheme.paper)
          .frame(width: 30, height: 30)
          .background(Color.primary, in: RoundedRectangle(cornerRadius: 8))
        Text("Redraft").font(.system(size: 17, weight: .semibold))
        Spacer()
      }.padding(.horizontal, 20).frame(height: 52)

      HStack(spacing: 7) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("搜索文章", text: $model.state.articleQuery).textFieldStyle(.plain)
          .accessibilityLabel("搜索文章")
        if !model.state.articleQuery.isEmpty {
          Button {
            model.state.articleQuery = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("清除搜索")
        }
      }
      .padding(8).background(PaperTheme.fill, in: RoundedRectangle(cornerRadius: 7))
      .padding(.horizontal, 16).padding(.top, 9).padding(.bottom, 20)

      ScrollView {
        VStack(alignment: .leading, spacing: 3) {
          sectionLabel("文章")
          ForEach(model.filteredArticles) { article in articleRow(article) }
          if model.filteredArticles.isEmpty {
            Text("没有找到文章").foregroundStyle(.secondary).font(.callout).padding(12)
          }
          sectionLabel("资料库").padding(.top, 25)
          Button {
            model.showExamples()
            dismissDrawer()
          } label: {
            HStack(spacing: 10) {
              Image(systemName: "quote.opening").foregroundStyle(PaperTheme.accent)
              Text("改写范例")
              Spacer()
              Text("\(model.examples.count)").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 11)
            .background(
              model.state.section == .examples ? PaperTheme.fill : .clear,
              in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(Rectangle())
          }.buttonStyle(.plain)
        }.padding(.horizontal, 12)
      }
      VStack(alignment: .leading, spacing: 12) {
        Divider()
        Button {
          model.newArticle()
          dismissDrawer()
        } label: {
          Label("新建文章", systemImage: "square.and.pencil").frame(
            maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(.plain).font(.system(size: 13, weight: .medium))
          .help("新建文章 · ⌘N")
        Text("界面预览 · 内容仅保留本次运行")
          .font(.system(size: 10)).foregroundStyle(.secondary)
      }.padding(.horizontal, 20).padding(.bottom, 18)
    }
    .frame(maxHeight: .infinity)
    .background(NativeMaterial(material: .sidebar).ignoresSafeArea())
  }

  private func sectionLabel(_ title: String) -> some View {
    Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
      .padding(.horizontal, 10).padding(.bottom, 7)
  }

  private func articleRow(_ article: ArticleViewState) -> some View {
    let selected = model.state.section == .articles && model.state.selectedArticleID == article.id
    return Button {
      model.selectArticle(article.id)
      dismissDrawer()
    } label: {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "doc.text").foregroundStyle(selected ? PaperTheme.accent : .secondary)
          .font(.system(size: 15)).padding(.top, 2)
        VStack(alignment: .leading, spacing: 6) {
          Text(article.title.isEmpty ? "未命名文章" : article.title)
            .font(.system(size: 13, weight: .medium)).lineLimit(1)
          Text(article.preview).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
          HStack(spacing: 6) {
            Text(article.updatedAt, format: .dateTime.month().day())
            if article.phase != .idle {
              Text("·")
              Text(article.phase == .running ? "改稿中" : "待审阅").foregroundStyle(PaperTheme.accent)
            }
          }.font(.system(size: 10)).foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
      }
      .padding(10).frame(maxWidth: .infinity, alignment: .leading)
      .background(
        selected ? Color.primary.opacity(0.085) : .clear, in: RoundedRectangle(cornerRadius: 7)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .contextMenu {
      Button("打开文章") { model.selectArticle(article.id) }
      Button("删除文章…", role: .destructive) { confirmDelete(article) }
    }
  }

  private func dismissDrawer() {
    if dismissOnSelection { model.state.sidebarVisible = false }
  }

  private func confirmDelete(_ article: ArticleViewState) {
    guard let window = NSApp.keyWindow else { return }
    let alert = NSAlert()
    alert.messageText = "删除“\(article.title)”？"
    alert.informativeText = "这篇文章及本次运行中的修改会被移除。"
    alert.addButton(withTitle: "取消")
    alert.addButton(withTitle: "删除")
    alert.beginSheetModal(for: window) { response in
      if response == .alertSecondButtonReturn { model.deleteArticle(article.id) }
    }
  }
}
