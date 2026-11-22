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
    VStack(spacing: 14) {
      Image(systemName: symbol)
        .font(.system(size: 30, weight: .light))
        .foregroundStyle(.secondary)
      Text(title).font(.title3.weight(.medium))
      if !detail.isEmpty {
        Text(detail)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .font(.callout)
      }
      if let actionTitle, let action {
        Button(actionTitle, action: action).padding(.top, 6)
      }
    }
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct ReviewTag: View {
  let title: String
  var color: Color = .secondary

  var body: some View {
    Text(title)
      .font(.caption)
      .foregroundStyle(color)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
  }
}

struct LabeledPassage<Content: View>: View {
  let title: String
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      content.font(.callout).lineSpacing(5)
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
    HStack(spacing: 7) {
      decisionButton(.accept, symbol: "checkmark", label: "采用")
      decisionButton(.keep, symbol: "arrow.uturn.backward", label: "保留原文")
      if change.kind == .text {
        Button {
          model.decide(.rewrite, changeID: change.id)
        } label: {
          Label("重写", systemImage: "pencil")
        }
        .tint(change.decision == .rewrite ? PaperTheme.accent : .secondary)
        .help("自己重写这处修改")
      }
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
  }

  private func decisionButton(_ decision: ReviewDecision, symbol: String, label: String)
    -> some View
  {
    Button {
      model.decide(decision, changeID: change.id)
    } label: {
      Label(label, systemImage: symbol)
    }
    .tint(change.decision == decision ? PaperTheme.accent : .secondary)
    .accessibilityLabel("\(label)这处修改\(change.decision == decision ? "，已选" : "")")
  }
}
