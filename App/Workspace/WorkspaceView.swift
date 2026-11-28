import AppKit
import RedraftCore
import SwiftUI

struct WorkspaceView: View {
  @ObservedObject var model: WorkspaceViewModel

  var body: some View {
    GeometryReader { geometry in
      let inlineLibrary = geometry.size.width >= 1080
      let showsDrawer = model.state.sidebarVisible && !inlineLibrary
      VStack(spacing: 0) {
        windowToolbar
        Divider()

        ZStack(alignment: .leading) {
          HStack(spacing: 0) {
            if model.state.sidebarVisible && inlineLibrary {
              ArticleSidebar(model: model).frame(width: 248)
              Divider()
            }
            manuscript
            if let article = model.currentArticle, inspectorVisible || proofreadingVisible {
              Divider()
              Group {
                if inspectorVisible {
                  InspectorView(model: model)
                } else {
                  ProofreadingPanel(model: model, article: article)
                }
              }
              .frame(width: geometry.size.width >= 1200 ? 328 : 304)
            }
          }
          .accessibilityHidden(showsDrawer)

          if showsDrawer {
            Button {
              model.state.sidebarVisible = false
            } label: {
              Color.black.opacity(0.20)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityHidden(true)

            ArticleSidebar(model: model, dismissOnSelection: true)
              .frame(width: 264)
              .shadow(color: .black.opacity(0.14), radius: 14, x: 4)
          }
        }
      }
      .onChange(of: inlineLibrary) { _, inline in
        if !inline { model.state.sidebarVisible = false }
      }
    }
    .frame(minWidth: 780, minHeight: 532)
    .foregroundStyle(PaperTheme.ink)
    .tint(PaperTheme.accent)
    .environment(\.locale, Locale(identifier: "zh_CN"))
    .background(PaperTheme.paper.ignoresSafeArea())
    .background(WindowAppearance())
    .sheet(item: $model.state.sheet) { sheet in WorkspaceSheetView(model: model, sheet: sheet) }
  }

  private var manuscript: some View {
    Group {
      if model.state.section == .examples {
        ExamplesView(model: model)
      } else if model.currentArticle != nil {
        WritingView(model: model)
      } else {
        VStack(spacing: 16) {
          Text("选择一篇文章或开始写作").font(.title3.weight(.medium))
          Button("新建文章", action: model.newArticle).buttonStyle(.borderedProminent)
        }
        .padding(24)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(PaperTheme.paper)
    .overlay(alignment: .bottom) {
      if let notice = model.notice {
        noticeBanner(notice)
      }
    }
  }

  private func noticeBanner(_ message: String) -> some View {
    HStack(spacing: 12) {
      Text(message)
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
      Button(action: model.dismissNotice) {
        Image(systemName: "xmark").frame(width: 24, height: 24)
      }
      .buttonStyle(.plain)
      .foregroundStyle(PaperTheme.secondaryText)
      .accessibilityLabel("关闭提示")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(PaperTheme.reviewSurface, in: RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(PaperTheme.separator))
    .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
    .frame(maxWidth: 540)
    .padding(16)
  }

  private var inspectorVisible: Bool {
    model.state.inspectorVisible && model.state.section == .articles && model.currentArticle != nil
  }

  private var proofreadingVisible: Bool {
    model.state.proofreadingVisible && !inspectorVisible && model.state.section == .articles
      && model.currentArticle != nil
  }

  private var windowToolbar: some View {
    HStack(spacing: 8) {
      ToolbarIcon(
        title: "文章库 · ⌃⌘S", symbol: "sidebar.left", text: "文章库",
        selected: model.state.sidebarVisible
      ) {
        model.state.sidebarVisible.toggle()
      }
      ToolbarIcon(title: "新建文章 · ⌘N", symbol: "square.and.pencil", action: model.newArticle)
      Spacer(minLength: 12)
      if model.currentArticle != nil && model.state.section == .articles {
        ToolbarIcon(
          title: proofreadingVisible ? "收起 Redraft 助手" : "展开 Redraft 助手",
          symbol: "sidebar.right", text: "Redraft 助手", selected: proofreadingVisible
        ) {
          let showsProofreading = !proofreadingVisible
          model.state.inspectorVisible = false
          model.state.proofreadingVisible = showsProofreading
        }
      }
      moreMenu
    }
    .padding(.horizontal, 16)
    .frame(height: 48)
    .background(PaperTheme.paper)
  }

  private var moreMenu: some View {
    Menu {
      if let article = model.currentArticle, model.state.section == .articles {
        if article.phase == .ready {
          Button("查看本轮批注", action: model.enterReview)
        }
        Button("批注这段…") { model.showSheet(.customMark) }
          .disabled(model.selectedBlock == nil || model.isEditorLocked)
        Button("批注范围") {
          model.state.inspectorTab = .marks
          model.state.inspectorVisible = true
        }
        Button("段落轨迹", action: model.showProvenance).disabled(model.selectedBlock == nil)
        Divider()
        Button("复制摘录给 Agent", action: model.copyExcerptForAgent)
          .disabled(model.agentExcerpt == nil)
        Button("导出 Markdown 和附件…") { model.exportMarkdown.send() }
        Divider()
      }
      Button("字数统计") { model.showSheet(.statistics) }.disabled(model.currentArticle == nil)
      Button("快捷键") { model.showSheet(.shortcuts) }
      Button("关于 Redraft") { model.showSheet(.about) }
    } label: {
      Image(systemName: "ellipsis").font(.system(size: 16, weight: .medium))
        .frame(width: 34, height: 32)
        .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("更多")
    .accessibilityLabel("更多")
  }

}
