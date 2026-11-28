import RedraftCore
import SwiftUI

struct BlockTrailPanel: View {
  let article: ArticleViewState
  let block: DocumentBlock?
  let selectBlock: (UUID?) -> Void
  @State private var selectedRoundID: UUID?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        if let roundIndex = article.rounds.firstIndex(where: { $0.id == selectedRoundID }) {
          roundOverview(article.rounds[roundIndex], ordinal: roundIndex + 1)
        } else if let block {
          blockTrail(block)
        } else {
          Text("在正文中选一段，回看它的改写轨迹。")
            .font(.callout).foregroundStyle(.secondary)
          ForEach(Array(article.rounds.enumerated().reversed()), id: \.element.id) { index, round in
            Button("第 \(index + 1) 轮批注 · \(round.changes.count) 条") { selectedRoundID = round.id }
              .buttonStyle(.link)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading).padding(18)
    }
    .id(selectedRoundID ?? block?.id)
    .onChange(of: block?.id) { selectedRoundID = nil }
  }

  @ViewBuilder private func blockTrail(_ block: DocumentBlock) -> some View {
    let rounds = article.rounds.enumerated().filter { item in
      item.element.changes.contains { $0.blockID == block.id }
    }
    let snapshots = earlierSnapshots(for: block)
    let lastDraft =
      rounds.last?.element.result.blocks.first { $0.id == block.id }
      ?? snapshots.last?.blocks.first { $0.id == block.id }
    if let lastDraft, lastDraft != block {
      LabeledPassage(title: "当前稿") { SnapshotBlockView(block: block) }
      Divider()
    }
    ForEach(rounds.reversed(), id: \.element.id) { index, round in
      TrailEntry(
        title: "第 \(index + 1) 轮批注",
        detail: round.date.formatted(.dateTime.month().day().locale(Locale(identifier: "zh_CN"))),
        expanded: round.id == rounds.last?.element.id
      ) {
        if let original = round.source.blocks.first(where: { $0.id == block.id }) {
          RoundPassages(round: round, original: original)
        }
        Button("查看本轮全部 \(round.changes.count) 条批注") { selectedRoundID = round.id }
          .buttonStyle(.link).font(.callout)
      }
      Divider()
    }
    ForEach(snapshots.reversed()) { version in
      if let entry = version.blocks.first(where: { $0.id == block.id }) {
        LabeledPassage(title: version.title) { SnapshotBlockView(block: entry) }
      }
    }
    if rounds.isEmpty && snapshots.isEmpty {
      Text("这段还没有改稿记录。").font(.callout).foregroundStyle(.secondary)
    }
  }

  @ViewBuilder private func roundOverview(_ round: AnnotationRound, ordinal: Int) -> some View {
    Button {
      selectedRoundID = nil
    } label: {
      Label("返回段落轨迹", systemImage: "chevron.left")
    }
    .buttonStyle(.link).font(.callout)
    Text("第 \(ordinal) 轮 · \(round.changes.count) 条批注").font(.headline)
    let blocks = round.source.blocks.filter { source in
      round.changes.contains { $0.blockID == source.id }
    }
    ForEach(Array(blocks.enumerated()), id: \.element.id) { index, source in
      let label =
        source.plainText.isEmpty ? (source.kind == .image ? "图片" : "表格") : source.plainText
      TrailEntry(
        title: label, detail: "", expanded: source.id == (block?.id ?? blocks.first?.id)
      ) {
        RoundPassages(round: round, original: source)
        if article.blocks.contains(where: { $0.id == source.id }) {
          Button("定位到正文") {
            selectBlock(source.id)
            selectedRoundID = nil
          }
          .buttonStyle(.link)
        }
      }
      if index < blocks.count - 1 { Divider() }
    }
  }

  /// Older manuscripts may include snapshots from before annotation rounds were recorded.
  private func earlierSnapshots(for block: DocumentBlock) -> [ArticleVersion] {
    let revisions = Set(article.rounds.flatMap { [$0.source.revisionID, $0.result.revisionID] })
    var previous: DocumentBlock?
    return article.versions.filter { version in
      guard !revisions.contains(version.revisionID),
        let entry = version.blocks.first(where: { $0.id == block.id }), entry != previous
      else { return false }
      previous = entry
      return true
    }
  }
}

private struct TrailEntry<Content: View>: View {
  let title: String
  let detail: String
  @State private var expanded: Bool
  private let content: Content

  init(title: String, detail: String, expanded: Bool, @ViewBuilder content: () -> Content) {
    self.title = title
    self.detail = detail
    _expanded = State(initialValue: expanded)
    self.content = content()
  }

  var body: some View {
    DisclosureGroup(isExpanded: $expanded) {
      VStack(alignment: .leading, spacing: 14) { content }
        .padding(.top, 12).frame(maxWidth: .infinity, alignment: .leading)
    } label: {
      HStack {
        Text(title).font(.subheadline.weight(.semibold)).lineLimit(2)
        Spacer(minLength: 4)
        if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
      }
    }
  }
}

private struct RoundPassages: View {
  let round: AnnotationRound
  let original: DocumentBlock

  var body: some View {
    LabeledPassage(title: "原稿") { SnapshotBlockView(block: original) }
    ForEach(round.changes.filter { $0.blockID == original.id }) { change in
      LabeledPassage(title: "AI 建议 · \(change.decision?.title ?? "未选择")") {
        if change.kind != .text, let suggestion = change.afterBlock {
          SnapshotBlockView(block: suggestion)
        } else {
          Text(change.after.isEmpty ? "（空）" : change.after).textSelection(.enabled)
        }
      }
      if !change.reason.isEmpty {
        LabeledPassage(title: "取舍说明") { Text(change.reason).textSelection(.enabled) }
      }
      if change.decision == .rewrite, !change.rewrittenText.isEmpty {
        LabeledPassage(title: "你的改写") {
          Text(change.rewrittenText).textSelection(.enabled)
        }
      }
    }
    if let result = round.result.blocks.first(where: { $0.id == original.id }) {
      LabeledPassage(title: "本轮成稿") { SnapshotBlockView(block: result) }
    }
  }
}
