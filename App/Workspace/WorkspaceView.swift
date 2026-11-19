import AppKit
import RedraftCore
import SwiftUI

struct WorkspaceView: View {
  @ObservedObject var model: WorkspaceViewModel

  var body: some View {
    GeometryReader { geometry in
      let inlineSidebar = geometry.size.width >= 980
      let inlineInspector = geometry.size.width >= 1180
      ZStack {
        HStack(spacing: 0) {
          if model.state.sidebarVisible && inlineSidebar {
            ArticleSidebar(model: model).frame(width: 244)
            Divider()
          }
          VStack(spacing: 0) {
            windowToolbar(width: geometry.size.width)
            Divider()
            if model.state.section == .articles && model.currentArticle != nil {
              if model.state.mode == .writing {
                FormattingToolbar(model: model)
                Divider()
              }
              content
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
          if inspectorVisible && inlineInspector {
            Divider()
            inspector
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
        if inspectorVisible && !inlineInspector {
          Color.black.opacity(0.12).onTapGesture { model.state.inspectorVisible = false }
          HStack(spacing: 0) {
            Spacer(minLength: 0)
            inspector.shadow(color: .black.opacity(0.12), radius: 20, x: -5)
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
      .onAppear { adaptPanels(to: geometry.size.width) }
      .onChange(of: geometry.size.width) { width in adaptPanels(to: width) }
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

  private func adaptPanels(to width: CGFloat) {
    if width < 980 { model.state.sidebarVisible = false }
    if width < 1180 { model.state.inspectorVisible = false }
  }

  private var inspector: some View {
    InspectorView(model: model)
      .frame(width: 302)
      .frame(maxHeight: .infinity)
      .background(NativeMaterial(material: .sidebar))
  }

  @ViewBuilder private var content: some View {
    switch model.state.mode {
    case .writing: WritingView(model: model)
    case .review: ReviewView(model: model)
    case .history: HistoryView(model: model)
    }
  }

  private func windowToolbar(width: CGFloat) -> some View {
    HStack(spacing: 12) {
      ToolbarIcon(
        title: "切换文章库 · ⌃⌘S", symbol: "sidebar.left", selected: model.state.sidebarVisible
      ) {
        model.state.sidebarVisible.toggle()
        if model.state.sidebarVisible && width < 1180 { model.state.inspectorVisible = false }
      }
      Spacer(minLength: 0)
      if model.state.section == .articles {
        Picker("工作模式", selection: Binding(get: { model.state.mode }, set: model.setMode)) {
          Text("写作").tag(WorkspaceMode.writing)
          Text("审阅").tag(WorkspaceMode.review)
          Text("历史").tag(WorkspaceMode.history)
        }
        .pickerStyle(.segmented).labelsHidden().frame(width: 204)
        .disabled(model.currentArticle == nil)
      } else {
        Text("改写范例").font(.headline)
      }
      Spacer(minLength: 0)
      if model.state.section == .articles { primaryAction }
      Menu {
        Button("导出 Markdown…") { model.showNotice("Markdown 导出将在后续版本提供") }
          .disabled(model.currentArticle == nil)
        Button("导出 HTML…") { model.showNotice("HTML 导出将在后续版本提供") }
          .disabled(model.currentArticle == nil)
        Divider()
        Button("字数统计") { model.showSheet(.statistics) }.disabled(model.currentArticle == nil)
        Button("快捷键") { model.showSheet(.shortcuts) }
        Button("关于 Redraft") { model.showSheet(.about) }
      } label: {
        Image(systemName: "ellipsis.circle").font(.system(size: 17))
      }
      .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 26).help("更多")
      .accessibilityLabel("更多")
      ToolbarIcon(title: "切换检查器 · ⌘⌥I", symbol: "sidebar.right", selected: inspectorVisible) {
        model.state.inspectorVisible.toggle()
        if model.state.inspectorVisible && width < 1180 { model.state.sidebarVisible = false }
      }.disabled(model.currentArticle == nil || model.state.section == .examples)
    }
    .padding(.horizontal, 16).frame(height: 52)
    .background(NativeMaterial(material: .headerView))
  }

  @ViewBuilder private var primaryAction: some View {
    if model.currentArticle?.phase == .running {
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Button("取消", action: model.cancelReview).buttonStyle(.borderless)
      }
    } else if model.state.mode == .review && model.currentArticle?.phase == .ready {
      Button("完成", action: model.completeReview)
        .buttonStyle(.borderedProminent).disabled(model.unresolvedCount > 0)
        .help(model.unresolvedCount > 0 ? "请先完成每一处取舍" : "完成本轮审阅预览")
    } else if model.currentArticle?.phase == .ready {
      Button("审阅", action: model.enterReview).buttonStyle(.borderedProminent)
    } else if model.state.mode == .writing && model.markedCount > 0 {
      Button(action: model.beginReview) {
        Label("改稿 \(model.markedCount)", systemImage: "sparkles")
      }.buttonStyle(.borderedProminent).help("预览标记段落的示例改稿 · ⌘↩")
    }
  }
}
