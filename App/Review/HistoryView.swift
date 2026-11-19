import RedraftCore
import SwiftUI

struct HistoryView: View {
  @ObservedObject var model: WorkspaceViewModel

  var body: some View {
    VStack(spacing: 0) {
      if let article = model.currentArticle, !article.versions.isEmpty {
        comparisonBar(article)
        Divider()
        ScrollView {
          VStack(alignment: .leading, spacing: 24) {
            Text(article.title.isEmpty ? "无标题" : article.title)
              .font(.system(size: 29, weight: .semibold))
            Text("版本内容对照 · 按段落展示")
              .font(.caption)
              .foregroundStyle(.secondary)

            if let from = model.historyFrom, let to = model.historyTo {
              snapshots(from: from, to: to)
            } else {
              Text("选择两份版本，回看文字的变化。")
                .foregroundStyle(.secondary)
            }
          }
          .padding(.horizontal, 34)
          .padding(.vertical, 32)
          .frame(maxWidth: 780)
          .frame(maxWidth: .infinity, alignment: .top)
        }
      } else {
        ReviewEmptyState(
          symbol: "clock.arrow.circlepath",
          title: "还没有历史版本",
          detail: "留下一份当前稿，之后可以回来看。",
          actionTitle: "留存当前版本",
          action: { model.saveVersion() }
        )
      }
    }
    .background(PaperTheme.paper)
  }

  private func comparisonBar(_ article: ArticleViewState) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) {
        versionPickers(article)
        Spacer(minLength: 12)
        Toggle("只看改动", isOn: $model.state.onlyChanges).toggleStyle(.checkbox)
      }
      VStack(alignment: .leading, spacing: 10) {
        versionPickers(article)
        Toggle("只看改动", isOn: $model.state.onlyChanges).toggleStyle(.checkbox)
      }
    }
    .font(.callout)
    .padding(.horizontal, 24)
    .padding(.vertical, 12)
    .background(NativeMaterial(material: .headerView))
  }

  private func versionPickers(_ article: ArticleViewState) -> some View {
    HStack(spacing: 10) {
      Picker("从", selection: $model.state.historyFromID) {
        ForEach(article.versions) { version in
          Text(version.title).tag(Optional(version.id))
        }
      }
      .frame(maxWidth: 220)
      Button {
        model.swapHistoryVersions()
      } label: {
        Image(systemName: "arrow.left.arrow.right")
      }
      .buttonStyle(.plain)
      .help("交换两个版本")
      .accessibilityLabel("交换两个版本")
      Picker("到", selection: $model.state.historyToID) {
        ForEach(article.versions) { version in
          Text(version.title).tag(Optional(version.id))
        }
      }
      .frame(maxWidth: 220)
    }
  }

  private func snapshots(from: ArticleVersion, to: ArticleVersion) -> some View {
    let rows = snapshotRows(from: from, to: to)
    let changed = rows.filter { $0.before != $0.after }
    let shown = model.state.onlyChanges ? changed : rows
    return VStack(alignment: .leading, spacing: 22) {
      if from.id == to.id {
        Text("同一稿，没有差异。")
          .font(.callout).foregroundStyle(.secondary)
      } else if changed.isEmpty {
        Text("这两稿的内容相同。")
          .font(.callout).foregroundStyle(.secondary)
      }
      if model.state.onlyChanges, rows.count > changed.count {
        Button {
          model.state.onlyChanges = false
        } label: {
          Label("展开 \(rows.count - changed.count) 个未改动的段落", systemImage: "ellipsis")
            .font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
      }
      ForEach(shown) { row in
        HistoryBlockRow(row: row)
      }
    }
  }

  // This is a snapshot presentation, not the future word-level TextDiffing implementation.
  private func snapshotRows(from: ArticleVersion, to: ArticleVersion) -> [SnapshotRow] {
    var blockIDs = to.blocks.map(\.id)
    let remainingIDs = Set(blockIDs)
    // Keep new blocks in their reading position. Deleted blocks precede their next surviving neighbor.
    for (index, block) in from.blocks.enumerated() where !remainingIDs.contains(block.id) {
      let successor = from.blocks.dropFirst(index + 1).first { remainingIDs.contains($0.id) }
      let insertion = successor.flatMap { blockIDs.firstIndex(of: $0.id) } ?? blockIDs.endIndex
      blockIDs.insert(block.id, at: insertion)
    }
    return blockIDs.map { id in
      SnapshotRow(
        id: id,
        before: from.blocks.first(where: { $0.id == id }),
        after: to.blocks.first(where: { $0.id == id })
      )
    }
  }
}

private struct SnapshotRow: Identifiable {
  let id: UUID
  let before: DocumentBlock?
  let after: DocumentBlock?
}

private struct HistoryBlockRow: View {
  let row: SnapshotRow

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if row.before == row.after, let block = row.after {
        SnapshotBlockView(block: block).opacity(0.65)
      } else if let before = row.before, let after = row.after {
        if before.kind == .text, after.kind == .text {
          if before.plainText == after.plainText {
            ReviewTag(title: "格式")
            SnapshotBlockView(block: after)
          } else {
            ChangedText(text: before.plainText, inserted: false)
            ChangedText(text: after.plainText, inserted: true)
          }
        } else {
          HStack {
            ReviewTag(title: before.kind == .image ? "图片" : "表格")
            Text("内容变化").font(.caption).foregroundStyle(.secondary)
          }
          snapshot(before, inserted: false)
          snapshot(after, inserted: true)
        }
      } else if let block = row.after {
        ReviewTag(title: "新增", color: PaperTheme.insertion)
        snapshot(block, inserted: true)
      } else if let block = row.before {
        ReviewTag(title: "删去", color: PaperTheme.deletion)
        snapshot(block, inserted: false)
      }
    }
    .padding(.vertical, 8)
  }

  private func snapshot(_ block: DocumentBlock, inserted: Bool) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(inserted ? "改后" : "改前").font(.caption).foregroundStyle(.secondary)
      SnapshotBlockView(block: block)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background((inserted ? PaperTheme.insertion : PaperTheme.deletion).opacity(0.06))
  }
}
