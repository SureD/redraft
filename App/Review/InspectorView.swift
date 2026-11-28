import RedraftCore
import SwiftUI

struct InspectorView: View {
  @ObservedObject var model: WorkspaceViewModel

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 4) {
        tab(.marks, label: "范围", title: "批注范围") { model.state.inspectorTab = .marks }
        tab(
          .annotations, label: "本轮", title: "本轮批注", enabled: model.currentArticle?.phase == .ready
        ) {
          model.enterReview()
        }
        tab(.provenance, label: "轨迹", title: "段落轨迹", action: model.showProvenance)
        Spacer(minLength: 4)
        Button {
          model.state.inspectorVisible = false
        } label: {
          Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(PaperTheme.secondaryText)
        .help("收起侧栏").accessibilityLabel("收起侧栏")
      }
      .padding(.horizontal, 16).frame(height: 52)
      Rectangle().fill(PaperTheme.separator).frame(height: 1)
      if let article = model.currentArticle {
        switch model.state.inspectorTab {
        case .annotations:
          AnnotationPanel(model: model, article: article)
        case .provenance:
          BlockTrailPanel(
            article: article, block: model.selectedBlock, selectBlock: model.selectBlock
          )
          .id(article.id)
        case .marks:
          marksInspector(article)
        }
      } else {
        ReviewEmptyState(symbol: "doc.text", title: "选择一篇文章", detail: "")
      }
    }
    .frame(maxHeight: .infinity, alignment: .top)
    .foregroundStyle(PaperTheme.ink)
    .background(PaperTheme.reviewSurface)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(title)
  }

  private func tab(
    _ tab: InspectorTab, label: String, title: String, enabled: Bool = true,
    action: @escaping () -> Void
  ) -> some View {
    let selected = model.state.inspectorTab == tab
    return Button(action: action) {
      Text(label).font(.system(size: 13, weight: selected ? .semibold : .medium))
        .foregroundStyle(selected ? PaperTheme.ink : PaperTheme.secondaryText)
        .padding(.horizontal, 12).frame(height: 32)
        .background(selected ? PaperTheme.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .opacity(enabled ? 1 : 0.5)
    .disabled(!enabled)
    .help(title).accessibilityLabel(title)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private var title: String {
    switch model.state.inspectorTab {
    case .marks: "批注范围"
    case .annotations: "本轮批注"
    case .provenance: "段落轨迹"
    }
  }

  private func marksInspector(_ article: ArticleViewState) -> some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          VStack(alignment: .leading, spacing: 8) {
            Text(article.marks.isEmpty ? "全文" : "已标记 \(article.marks.count) 处")
              .font(.system(size: 17, weight: .semibold))
              .accessibilityAddTraits(.isHeader)
            if !model.isEditorLocked {
              Button("批注这段…") { model.showSheet(.customMark) }
                .buttonStyle(.link).font(.callout)
                .disabled(model.selectedBlock == nil)
            }
          }
          ForEach(article.blocks.filter { article.marks[$0.id] != nil }) { block in
            if let instruction = article.marks[block.id] {
              markRow(block, instruction: instruction)
            }
          }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
      }
      Rectangle().fill(PaperTheme.separator).frame(height: 1)
      Group {
        switch article.phase {
        case .running:
          HStack {
            ProgressView().controlSize(.small)
            Text("正在生成批注").font(.callout)
            Spacer()
            Button("取消", action: model.cancelReview)
          }
        case .ready:
          Button(action: model.enterReview) {
            Text("阅读 \(article.changes.count) 条批注").foregroundStyle(PaperTheme.paper)
          }
          .buttonStyle(.borderedProminent)
        case .idle:
          Button(action: model.beginReview) {
            Text(article.marks.isEmpty ? "试读全文示例批注" : "试读标记处的示例批注")
              .foregroundStyle(PaperTheme.paper)
          }
          .buttonStyle(.borderedProminent).disabled(!model.canRequestAnnotations)
        }
      }
      .frame(maxWidth: .infinity)
      .padding(16)
    }
  }

  private func markRow(_ block: DocumentBlock, instruction: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Button {
        model.selectBlock(block.id)
      } label: {
        Text(block.plainText.isEmpty ? "所选内容" : block.plainText)
          .font(.callout).lineSpacing(4).lineLimit(3)
          .multilineTextAlignment(.leading)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .buttonStyle(.plain)
      HStack {
        Menu {
          ForEach(["更简洁", "更具体", "更顺口", "语气更自然"], id: \.self) { option in
            Button(option) { model.markBlock(block.id, instruction: option) }
          }
          Divider()
          Button("自定义要求…") {
            model.selectBlock(block.id)
            model.showSheet(.customMark)
            model.state.customInstruction = instruction
          }
        } label: {
          Text(instruction).font(.caption).lineLimit(1)
        }
        .menuStyle(.borderlessButton).fixedSize()
        Spacer()
        Button {
          model.unmarkBlock(block.id)
        } label: {
          Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain).help("取消标记").accessibilityLabel("取消标记")
      }
      .disabled(model.isEditorLocked)
    }
    .padding(.leading, 12)
    .overlay(alignment: .leading) {
      Rectangle().fill(
        model.state.selectedBlockID == block.id ? PaperTheme.accent : PaperTheme.separator
      )
      .frame(width: 2)
    }
  }
}
