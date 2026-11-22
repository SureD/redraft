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
        HStack(spacing: 6) {
          Text("第 \(index + 1) 条，共 \(article.changes.count) 条")
            .font(.callout).foregroundStyle(.secondary)
          Spacer()
          navigationButton(from: index, offset: -1)
          navigationButton(from: index, offset: 1)
        }
        .padding(.horizontal, 18).padding(.top, 16)
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            if let instruction = article.marks[change.blockID] {
              Label(instruction, systemImage: "bookmark")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityLabel("你的要求，\(instruction)")
            }
            if !change.explanation.isEmpty {
              Text(change.explanation)
                .font(.system(size: 15, weight: .medium)).lineSpacing(5)
                .textSelection(.enabled)
            }
            LabeledPassage(title: change.kind == .text ? "建议写法" : "建议") {
              passage(text: change.after, block: change.afterBlock, kind: change.kind)
            }
            DisclosureGroup("对照原稿") {
              passage(text: change.before, block: change.beforeBlock, kind: change.kind)
                .font(.callout).padding(.top, 5).frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption).foregroundStyle(.secondary)
            if change.decision == .rewrite {
              LabeledPassage(title: "你的改写") {
                Text(change.rewrittenText).textSelection(.enabled)
              }
            }
            Divider()
            ReviewDecisionButtons(model: model, change: change)
            if let decision = change.decision {
              Text("已选「\(decision.title)」，成稿时生效。")
                .font(.caption).foregroundStyle(.secondary)
              DisclosureGroup("取舍说明") {
                TextField(
                  "给自己留一句话",
                  text: Binding(
                    get: { model.currentChange?.reason ?? "" },
                    set: { model.updateChangeReason($0, changeID: change.id) }
                  ), axis: .vertical
                )
                .textFieldStyle(.roundedBorder).lineLimit(1...4).padding(.top, 5)
              }
              .font(.caption)
            }
          }
          .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(change.id)
        Divider()
        finishControls
      }
    } else if article.phase == .ready {
      Button("阅读本轮批注", action: model.enterReview)
        .padding(18)
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
        .frame(width: 24, height: 22)
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
    let allUndecided = unresolved == article.changes.count
    let selectedTitle = selected > 0 ? "采用所选 \(selected) 处并成稿" : "按原稿成稿"
    let bulkTitle = allUndecided ? "全部采用并成稿" : "同时采用其余 \(unresolved) 处并成稿"
    return HStack(spacing: 8) {
      Button {
        model.completeReview(acceptRemaining: allUndecided)
      } label: {
        Text(allUndecided ? bulkTitle : selectedTitle).frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      Menu {
        if allUndecided {
          Button(selectedTitle) { model.completeReview() }
        } else if unresolved > 0 {
          Button(bulkTitle) { model.completeReview(acceptRemaining: true) }
        }
        Button("放弃本轮批注，继续写作", action: model.cancelReview)
      } label: {
        Image(systemName: "ellipsis.circle").font(.system(size: 16))
      }
      .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 30)
      .help("其他成稿选项").accessibilityLabel("其他成稿选项")
    }
    .padding(16)
  }
}
