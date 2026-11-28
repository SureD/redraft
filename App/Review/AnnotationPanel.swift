import RedraftCore
import SwiftUI

/// Stages choices beside the manuscript. Only the footer sends those choices to the document.
struct AnnotationPanel: View {
  @ObservedObject var model: WorkspaceViewModel
  let article: ArticleViewState

  var body: some View {
    if let change = model.currentChange,
      let index = article.changes.firstIndex(where: { $0.id == change.id })
    {
      VStack(spacing: 0) {
        HStack(spacing: 4) {
          Text("第 \(index + 1) 条，共 \(article.changes.count) 条")
            .font(.system(size: 13, weight: .medium)).monospacedDigit()
            .foregroundStyle(PaperTheme.secondaryText)
          Spacer()
          navigationButton(from: index, offset: -1)
          navigationButton(from: index, offset: 1)
        }
        .padding(.horizontal, 16).padding(.top, 8)
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            if let instruction = article.marks[change.blockID] {
              Label(instruction, systemImage: "bookmark")
                .font(.caption).foregroundStyle(PaperTheme.secondaryText)
                .accessibilityLabel("你的要求，\(instruction)")
            }
            LabeledPassage(title: "原文") {
              passage(text: change.before, block: change.beforeBlock, kind: change.kind)
            }
            LabeledPassage(title: change.kind == .text ? "建议写法" : "建议") {
              passage(text: change.after, block: change.afterBlock, kind: change.kind)
            }
            .padding(12)
            .background(PaperTheme.selection, in: RoundedRectangle(cornerRadius: 8))
            if !change.explanation.isEmpty {
              Text(change.explanation)
                .font(.callout).lineSpacing(4)
                .foregroundStyle(PaperTheme.secondaryText)
                .textSelection(.enabled)
            }
            if change.decision == .rewrite {
              LabeledPassage(title: "你的改写") {
                Text(change.rewrittenText).textSelection(.enabled)
              }
            }
            VStack(alignment: .leading, spacing: 8) {
              Text("你的取舍").font(.caption.weight(.medium))
                .foregroundStyle(PaperTheme.secondaryText)
                .accessibilityAddTraits(.isHeader)
              ReviewDecisionButtons(model: model, change: change)
            }
            if change.decision != nil {
              DisclosureGroup("取舍说明") {
                TextField(
                  "给自己留一句话",
                  text: Binding(
                    get: { model.currentChange?.reason ?? "" },
                    set: { model.updateChangeReason($0, changeID: change.id) }
                  ), axis: .vertical
                )
                .textFieldStyle(.roundedBorder).lineLimit(1...4).padding(.top, 8)
              }
              .font(.caption)
            }
          }
          .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(change.id)
        Rectangle().fill(PaperTheme.separator).frame(height: 1)
        finishControls
      }
    } else if article.phase == .ready {
      Button("阅读本轮批注", action: model.enterReview)
        .padding(16)
    } else {
      ReviewEmptyState(symbol: "text.bubble", title: "暂无批注", detail: "")
    }
  }

  private func navigationButton(from index: Int, offset: Int) -> some View {
    let target = index + offset
    let title = offset < 0 ? "上一条批注" : "下一条批注"
    return Button {
      if article.changes.indices.contains(target) {
        model.selectChange(article.changes[target].id)
      }
    } label: {
      Image(systemName: offset < 0 ? "chevron.left" : "chevron.right")
        .font(.system(size: 12, weight: .semibold))
        .frame(width: 32, height: 32)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain).disabled(!article.changes.indices.contains(target))
    .help(title).accessibilityLabel(title)
  }

  @ViewBuilder private func passage(text: String, block: DocumentBlock?, kind: ChangeKind)
    -> some View
  {
    if kind != .text, let block {
      SnapshotBlockView(block: block)
    } else {
      Text(text.isEmpty ? "（空）" : text).textSelection(.enabled)
    }
  }

  private var finishControls: some View {
    let selected = article.changes.filter { $0.decision == .accept || $0.decision == .rewrite }
      .count
    let unresolved = model.unresolvedCount
    let selectedTitle = selected > 0 ? "应用 \(selected) 处改动并成稿" : "按原稿成稿"
    let bulkTitle =
      unresolved == article.changes.count ? "全部采用并成稿" : "同时采用其余 \(unresolved) 处并成稿"
    return VStack(alignment: .leading, spacing: 8) {
      if unresolved > 0 {
        Text("未选择的 \(unresolved) 条批注会保留原文。")
          .font(.caption).foregroundStyle(PaperTheme.secondaryText)
      }
      HStack(spacing: 8) {
        Button {
          model.completeReview()
        } label: {
          Text(selectedTitle).foregroundStyle(PaperTheme.paper).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        Menu {
          if unresolved > 0 {
            Button(bulkTitle) { model.completeReview(acceptRemaining: true) }
            Divider()
          }
          Button("放弃本轮批注，继续写作", action: model.cancelReview)
        } label: {
          Image(systemName: "ellipsis.circle").font(.system(size: 16))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 32)
        .help("其他成稿选项").accessibilityLabel("其他成稿选项")
      }
    }
    .padding(16)
  }
}
