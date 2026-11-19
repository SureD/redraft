import RedraftCore
import SwiftUI

struct ReviewView: View {
  @ObservedObject var model: WorkspaceViewModel

  var body: some View {
    Group {
      if let article = model.currentArticle, article.phase == .ready, !article.changes.isEmpty {
        review(article)
      } else {
        ReviewEmptyState(
          symbol: model.currentArticle?.phase == .running ? "sparkles" : "checkmark.circle",
          title: model.currentArticle?.phase == .running ? "改稿演示进行中" : "没有待审阅的改稿",
          detail: "回到写作，标记想调整的段落。",
          actionTitle: "回到写作",
          action: { model.setMode(.writing) }
        )
      }
    }
    .background(PaperTheme.paper)
    .background(ReviewKeyboardNavigation(model: model).frame(width: 0, height: 0))
  }

  private func review(_ article: ArticleViewState) -> some View {
    ScrollViewReader { scroll in
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          HStack {
            Text("\(article.changes.count) 处修改 · 示例审阅")
              .font(.caption)
              .foregroundStyle(.secondary)
            Spacer()
            navigationButtons(article)
            Picker("对比方式", selection: $model.state.diffLayout) {
              Text("行内").tag(DiffLayout.inline)
              Text("对照").tag(DiffLayout.sideBySide)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 128)
          }
          Text(article.title.isEmpty ? "无标题" : article.title)
            .font(.system(size: 29, weight: .semibold))
            .padding(.bottom, 10)

          ForEach(article.blocks) { block in
            let changes = article.changes.filter { $0.blockID == block.id }
            if changes.isEmpty {
              SnapshotBlockView(block: block)
                .foregroundStyle(.secondary)
                .opacity(0.65)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            } else {
              ForEach(changes) { change in
                ChangeReviewRow(
                  model: model,
                  change: change,
                  instruction: article.marks[block.id] ?? "改稿建议",
                  index: (article.changes.firstIndex(where: { $0.id == change.id }) ?? 0) + 1
                )
                .id(change.id)
              }
            }
          }

          HStack {
            let undecided = article.changes.filter { $0.decision == nil }.count
            Text(undecided == 0 ? "每一处都已取舍" : "还有 \(undecided) 处等待取舍")
              .font(.callout)
              .foregroundStyle(.secondary)
            Spacer()
            Button("完成审阅") { model.completeReview() }
              .buttonStyle(.borderedProminent)
              .disabled(undecided > 0)
          }
          .padding(.top, 12)
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 32)
        .frame(maxWidth: 780)
        .frame(maxWidth: .infinity)
      }
      .onChange(of: model.state.selectedChangeID) { id in
        if let id { scroll.scrollTo(id, anchor: .center) }
      }
      .onAppear {
        if let id = model.state.selectedChangeID { scroll.scrollTo(id, anchor: .center) }
      }
    }
  }

  private func navigationButtons(_ article: ArticleViewState) -> some View {
    let index = article.changes.firstIndex { $0.id == model.state.selectedChangeID } ?? 0
    return HStack(spacing: 3) {
      Button {
        model.selectChange(article.changes[max(0, index - 1)].id)
      } label: {
        Image(systemName: "chevron.up").frame(width: 26, height: 24)
      }
      .disabled(index == 0)
      .help("上一处修改 · K")
      .accessibilityLabel("上一处修改")
      Button {
        model.selectChange(article.changes[min(article.changes.count - 1, index + 1)].id)
      } label: {
        Image(systemName: "chevron.down").frame(width: 26, height: 24)
      }
      .disabled(index == article.changes.count - 1)
      .help("下一处修改 · J")
      .accessibilityLabel("下一处修改")
    }
    .buttonStyle(.plain)
  }
}

private struct ChangeReviewRow: View {
  @ObservedObject var model: WorkspaceViewModel
  let change: ReviewChange
  let instruction: String
  let index: Int

  private var selected: Bool { model.state.selectedChangeID == change.id }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 8) {
        ReviewTag(title: instruction).lineLimit(1).help(instruction)
        if change.kind != .text {
          Text(kindTitle).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        if let decision = change.decision {
          Label(decision.title, systemImage: "checkmark.circle.fill")
            .font(.caption)
            .foregroundStyle(PaperTheme.accent)
        }
        Text(String(format: "%02d", index))
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.secondary)
      }

      if change.kind == .text {
        textComparison
      } else {
        blockComparison
      }

      if change.decision == .rewrite, !change.rewrittenText.isEmpty {
        VStack(alignment: .leading, spacing: 5) {
          Text("你的改写").font(.caption).foregroundStyle(.secondary)
          Text(change.rewrittenText).font(.system(size: 16)).lineSpacing(8)
        }
      }

      if selected {
        Text(change.explanation)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        ReviewDecisionButtons(model: model, change: change)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(selected ? PaperTheme.fill : Color.clear, in: RoundedRectangle(cornerRadius: 8))
    .overlay(alignment: .leading) {
      if selected {
        RoundedRectangle(cornerRadius: 2).fill(PaperTheme.accent).frame(width: 3).padding(
          .vertical, 12)
      }
    }
    .contentShape(Rectangle())
    .onTapGesture { model.selectChange(change.id) }
    .focusable(selected)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("第 \(index) 处修改，\(change.decision?.title ?? "待取舍")")
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityAction(named: "选中修改") { model.selectChange(change.id) }
    .accessibilityAction(named: "采用") { model.decide(.accept, changeID: change.id) }
    .accessibilityAction(named: "保留原文") { model.decide(.keep, changeID: change.id) }
  }

  private var kindTitle: String {
    switch change.kind {
    case .text: "文字"
    case .image: "图片替换"
    case .tableRow: "表格行"
    case .tableColumn: "表格列"
    }
  }

  @ViewBuilder private var textComparison: some View {
    if model.state.diffLayout == .sideBySide {
      ReviewComparisonLayout {
        labeledText("送审稿", text: change.before, inserted: false)
        labeledText("改稿建议", text: change.after, inserted: true)
      }
    } else {
      VStack(alignment: .leading, spacing: 7) {
        ChangedText(text: change.before, inserted: false)
        ChangedText(text: change.after, inserted: true)
      }
    }
  }

  private func labeledText(_ label: String, text: String, inserted: Bool) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(label).font(.caption).foregroundStyle(.secondary)
      ChangedText(text: text, inserted: inserted)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
  }

  private var blockComparison: some View {
    VStack(alignment: .leading, spacing: 14) {
      if change.kind == .image {
        HStack(alignment: .top, spacing: 14) {
          blockSide(change.beforeBlock, text: change.before, title: "原图", inserted: false)
          blockSide(change.afterBlock, text: change.after, title: "建议替换", inserted: true)
        }
      } else {
        blockSide(change.beforeBlock, text: change.before, title: "送审稿", inserted: false)
        blockSide(change.afterBlock, text: change.after, title: "改稿建议", inserted: true)
      }
    }
  }

  private func blockSide(_ block: DocumentBlock?, text: String, title: String, inserted: Bool)
    -> some View
  {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      if let block {
        SnapshotBlockView(block: block)
          .padding(8)
          .background((inserted ? PaperTheme.insertion : PaperTheme.deletion).opacity(0.06))
      } else {
        ChangedText(text: text, inserted: inserted)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// Use the available reading width, not a sentence's unwrapped ideal width, to choose columns.
private struct ReviewComparisonLayout: Layout {
  private let minimumWidth: CGFloat = 420
  private let spacing: CGFloat = 16

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let proposedWidth = proposal.width ?? minimumWidth
    let width = proposedWidth.isFinite ? max(0, proposedWidth) : minimumWidth
    let columns = width >= minimumWidth
    let columnWidth = columns ? max(0, (width - spacing) / 2) : width
    let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)) }
    let height =
      columns ? sizes.map(\.height).max() ?? 0 : sizes.reduce(0) { $0 + $1.height } + spacing
    return CGSize(width: width, height: height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let columns = bounds.width >= minimumWidth
    let columnWidth = columns ? max(0, (bounds.width - spacing) / 2) : bounds.width
    let childProposal = ProposedViewSize(width: columnWidth, height: nil)
    var y = bounds.minY
    for (index, subview) in subviews.enumerated() {
      let x = columns ? bounds.minX + CGFloat(index) * (columnWidth + spacing) : bounds.minX
      subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: childProposal)
      if !columns { y += subview.sizeThatFits(childProposal).height + spacing }
    }
  }
}
