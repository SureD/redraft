import RedraftCore
import SwiftUI

struct InspectorView: View {
  @ObservedObject var model: WorkspaceViewModel

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Menu {
          Button("批注范围") { model.state.inspectorTab = .marks }
          if model.currentArticle?.phase == .ready {
            Button("本轮批注", action: model.enterReview)
          }
          Button("段落轨迹", action: model.showProvenance)
        } label: {
          Text(title).font(.headline)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        Spacer()
        Button {
          model.state.inspectorVisible = false
        } label: {
          Image(systemName: "xmark").frame(width: 24, height: 24)
        }
        .buttonStyle(.plain).foregroundStyle(.secondary)
        .help("收起侧栏").accessibilityLabel("收起侧栏")
      }
      .padding(.horizontal, 18).frame(height: 52)
      Divider()
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
    .accessibilityElement(children: .contain)
    .accessibilityLabel(title)
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
        VStack(alignment: .leading, spacing: 18) {
          if article.marks.isEmpty {
            Text("全文").font(.headline)
            Text("也可以在段落的快捷菜单中标记想讨论的地方。")
              .font(.callout).foregroundStyle(.secondary).lineSpacing(4)
          } else {
            Text("已标记 \(article.marks.count) 处").font(.subheadline).foregroundStyle(.secondary)
            ForEach(article.blocks.filter { article.marks[$0.id] != nil }) { block in
              if let instruction = article.marks[block.id] {
                markRow(block, instruction: instruction)
              }
            }
          }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
      }
      Divider()
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
          Button("阅读 \(article.changes.count) 条批注", action: model.enterReview)
            .buttonStyle(.borderedProminent)
        case .idle:
          Button(article.marks.isEmpty ? "给全文加批注" : "给标记处加批注", action: model.beginReview)
            .buttonStyle(.borderedProminent).disabled(!model.canRequestAnnotations)
        }
      }
      .frame(maxWidth: .infinity)
      .padding(16)
    }
  }

  private func markRow(_ block: DocumentBlock, instruction: String) -> some View {
    VStack(alignment: .leading, spacing: 9) {
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
    .padding(.leading, 10)
    .overlay(alignment: .leading) {
      Rectangle().fill(
        model.state.selectedBlockID == block.id ? PaperTheme.accent : PaperTheme.separator
      )
      .frame(width: 2)
    }
  }
}
