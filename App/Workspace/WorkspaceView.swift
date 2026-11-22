import AppKit
import RedraftCore
import SwiftUI

struct WorkspaceView: View {
  @ObservedObject var model: WorkspaceViewModel

  var body: some View {
    GeometryReader { geometry in
      let inlineSidebar = geometry.size.width >= 1100
      ZStack {
        HStack(spacing: 0) {
          if model.state.sidebarVisible && inlineSidebar {
            ArticleSidebar(model: model).frame(width: 224)
            Divider()
          }
          VStack(spacing: 0) {
            windowToolbar
            Divider()
            if model.state.section == .articles && model.currentArticle != nil {
              if model.state.formattingVisible && !model.isEditorLocked {
                FormattingToolbar(model: model)
                Divider()
              }
              WritingView(model: model)
            } else if model.state.section == .examples {
              ExamplesView(model: model)
            } else {
              VStack {
                EmptyWorkspaceView(
                  symbol: "square.and.pencil", title: "从一篇新文章开始", detail: "写下想法，再慢慢打磨。")
                Button("新建文章", action: model.newArticle).buttonStyle(.borderedProminent)
                  .padding(.bottom, 100)
              }
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(PaperTheme.paper)
          if inspectorVisible {
            Divider()
            InspectorView(model: model)
              .frame(width: geometry.size.width < 920 ? 280 : 316)
          }
        }

        if model.state.sidebarVisible && !inlineSidebar {
          Color.black.opacity(0.12).onTapGesture { model.state.sidebarVisible = false }
          HStack(spacing: 0) {
            ArticleSidebar(model: model, dismissOnSelection: true).frame(width: 260)
              .shadow(color: .black.opacity(0.12), radius: 20, x: 5)
            Spacer(minLength: 0)
          }
        }
      }
      .overlay(alignment: .bottom) {
        if let notice = model.notice {
          HStack(spacing: 16) {
            Text(notice).font(.callout).fixedSize(horizontal: false, vertical: true)
            Button {
              model.dismissNotice()
            } label: {
              Image(systemName: "xmark")
            }
            .buttonStyle(.plain).accessibilityLabel("关闭提示")
          }
          .padding(.horizontal, 16).padding(.vertical, 12)
          .background {
            NativeMaterial(material: .popover).clipShape(RoundedRectangle(cornerRadius: 10))
          }
          .overlay(RoundedRectangle(cornerRadius: 10).stroke(PaperTheme.separator))
          .shadow(color: .black.opacity(0.12), radius: 14, y: 4)
          .padding(20).frame(maxWidth: 600)
          .accessibilityElement(children: .combine)
        }
      }
      .onChange(of: inlineSidebar) { inline in
        if !inline { model.state.sidebarVisible = false }
      }
    }
    .frame(minWidth: 780, minHeight: 532)
    .tint(PaperTheme.accent)
    .environment(\.locale, Locale(identifier: "zh_CN"))
    .background(NativeMaterial(material: .underWindowBackground).ignoresSafeArea())
    .background(WindowAppearance())
    .sheet(item: $model.state.sheet) { sheet in WorkspaceSheetView(model: model, sheet: sheet) }
  }

  private var inspectorVisible: Bool {
    model.state.inspectorVisible && model.state.section == .articles && model.currentArticle != nil
  }

  private var windowToolbar: some View {
    HStack(spacing: 10) {
      ToolbarIcon(
        title: "文章库 · ⌃⌘S", symbol: "sidebar.left", selected: model.state.sidebarVisible
      ) {
        model.state.sidebarVisible.toggle()
      }
      ToolbarIcon(title: "新建文章 · ⌘N", symbol: "square.and.pencil", action: model.newArticle)
      Spacer(minLength: 0)
      if model.currentArticle != nil && model.state.section == .articles {
        if !model.isEditorLocked {
          ToolbarIcon(
            title: "排版", symbol: "textformat", selected: model.state.formattingVisible
          ) {
            model.state.formattingVisible.toggle()
          }
        }
        annotationAction
      }
      Menu {
        if model.currentArticle != nil && model.state.section == .articles {
          Button("批注范围") {
            model.state.inspectorTab = .marks
            model.state.inspectorVisible = true
          }
          Button("段落轨迹", action: model.showProvenance).disabled(model.selectedBlock == nil)
          Divider()
        }
        Button("字数统计") { model.showSheet(.statistics) }.disabled(model.currentArticle == nil)
        Button("快捷键") { model.showSheet(.shortcuts) }
        Button("关于 Redraft") { model.showSheet(.about) }
      } label: {
        Image(systemName: "ellipsis.circle").font(.system(size: 17))
      }
      .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 26).help("更多")
      .accessibilityLabel("更多")
    }
    .padding(.horizontal, 16).frame(height: 52)
    .background(NativeMaterial(material: .headerView))
  }

  @ViewBuilder private var annotationAction: some View {
    if let article = model.currentArticle {
      switch article.phase {
      case .running:
        HStack(spacing: 8) {
          ProgressView().controlSize(.small).accessibilityLabel("正在批注")
          Button("取消批注", action: model.cancelReview).buttonStyle(.borderless)
        }
      case .ready:
        Button {
          if inspectorVisible && model.state.inspectorTab == .annotations {
            model.state.inspectorVisible = false
          } else {
            model.enterReview()
          }
        } label: {
          Label("\(article.changes.count) 条批注", systemImage: "text.bubble")
        }
        .buttonStyle(.bordered)
        .help("查看本轮批注 · ⌘↩")
      case .idle:
        if model.canRequestAnnotations {
          Button(action: model.beginReview) {
            Label("请 AI 批注", systemImage: "text.bubble")
          }
          .buttonStyle(.borderless)
          .help(model.markedCount == 0 ? "为全文生成示例批注 · ⌘↩" : "为标记的内容生成示例批注 · ⌘↩")
        }
      }
    }
  }
}
