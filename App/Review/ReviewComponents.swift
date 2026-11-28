import AppKit
import RedraftCore
import SwiftUI

struct ReviewEmptyState: View {
  let symbol: String
  let title: String
  let detail: String
  var actionTitle: String? = nil
  var action: (() -> Void)? = nil

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: symbol)
        .font(.system(size: 24, weight: .light))
        .foregroundStyle(PaperTheme.secondaryText)
        .accessibilityHidden(true)
      Text(title).font(.title3.weight(.medium))
      if !detail.isEmpty {
        Text(detail)
          .foregroundStyle(PaperTheme.secondaryText)
          .multilineTextAlignment(.center)
          .font(.callout)
      }
      if let actionTitle, let action {
        Button(actionTitle, action: action).padding(.top, 4)
      }
    }
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct LabeledPassage<Content: View>: View {
  let title: String
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.caption.weight(.medium)).foregroundStyle(PaperTheme.secondaryText)
        .accessibilityAddTraits(.isHeader)
      content.font(.callout).lineSpacing(4)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct SnapshotBlockView: View {
  @Environment(\.documentImageResolver) private var imageResolver
  let block: DocumentBlock

  var body: some View {
    switch block.kind {
    case .text:
      Text(AttributedString(RichTextBridge.attributedString(from: block.text)))
        .font(.system(size: 16))
        .lineSpacing(9)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    case .image:
      if let content = block.image {
        VStack(spacing: 8) {
          GeometryReader { geometry in
            DocumentImagePreview(content: content)
              .frame(width: geometry.size.width * min(1, max(0.4, content.width)))
              .clipShape(RoundedRectangle(cornerRadius: 5))
              .accessibilityLabel(content.altText.isEmpty ? "文章图片" : content.altText)
              .frame(maxWidth: .infinity)
          }
          .aspectRatio(
            DocumentImagePreview.ratio(for: content, resolver: imageResolver)
              / min(1, max(0.4, content.width)),
            contentMode: .fit)
          if !content.caption.isEmpty {
            Text(content.caption).font(.caption).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    case .table:
      if let table = block.table {
        ScrollView(.horizontal) {
          Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(Array(table.rows.enumerated()), id: \.offset) { row, cells in
              GridRow {
                ForEach(Array(cells.enumerated()), id: \.offset) { column, cell in
                  Text(cell.isEmpty ? " " : cell)
                    .font(
                      .system(size: 12, weight: row == 0 && table.hasHeader ? .medium : .regular)
                    )
                    .frame(width: column == table.columnCount - 1 ? 150 : 76, alignment: .leading)
                    .frame(minHeight: 24)
                    .padding(8)
                    .background(row == 0 && table.hasHeader ? PaperTheme.fill : Color.clear)
                    .border(PaperTheme.separator, width: 0.5)
                    .accessibilityLabel(
                      "第 \(row + 1) 行，第 \(column + 1) 列：\(cell.isEmpty ? "空白" : cell)")
                }
              }
            }
          }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("表格，\(table.rows.count) 行，\(table.columnCount) 列")
      }
    }
  }
}

struct ReviewDecisionButtons: View {
  @ObservedObject var model: WorkspaceViewModel
  let change: ReviewChange
  var body: some View {
    HStack(spacing: 4) {
      decisionButton(.accept, symbol: "checkmark", label: "采用")
      decisionButton(.keep, symbol: "arrow.uturn.backward", label: "保留原文")
      if change.kind == .text {
        decisionButton(.rewrite, symbol: "pencil", label: "重写")
          .help("自己重写这处修改")
      }
    }
  }

  private func decisionButton(_ decision: ReviewDecision, symbol: String, label: String)
    -> some View
  {
    let selected = change.decision == decision
    return Button {
      model.decide(decision, changeID: change.id)
    } label: {
      HStack(spacing: 4) {
        Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
        Text(label).font(.system(size: 12, weight: selected ? .semibold : .medium))
      }
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
      .padding(.horizontal, 4)
      .frame(maxWidth: .infinity, minHeight: 32)
      .foregroundStyle(selected ? PaperTheme.accent : PaperTheme.ink)
      .background(
        selected ? PaperTheme.selection : PaperTheme.fill, in: RoundedRectangle(cornerRadius: 8)
      )
      .overlay {
        if selected {
          RoundedRectangle(cornerRadius: 8).strokeBorder(PaperTheme.accent.opacity(0.5))
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(decision == .rewrite ? label : "\(label)这处修改")
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}
