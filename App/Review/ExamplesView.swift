import RedraftCore
import SwiftUI

struct ExamplesView: View {
  @ObservedObject var model: WorkspaceViewModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 18) {
          Text("改写范例").font(.system(size: 29, weight: .semibold))
          Picker("按取舍筛选", selection: $model.state.exampleFilter) {
            ForEach(ExampleFilter.allCases, id: \.self) { filter in
              Text(filter.title).tag(filter)
            }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .frame(maxWidth: 420)
          HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索句子或说明", text: $model.state.exampleQuery)
              .textFieldStyle(.plain)
              .accessibilityLabel("搜索改写范例")
            if !model.state.exampleQuery.isEmpty {
              Button {
                model.state.exampleQuery = ""
              } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
              }
              .buttonStyle(.plain)
              .accessibilityLabel("清除搜索")
            }
          }
          .padding(9)
          .background(PaperTheme.fill, in: RoundedRectangle(cornerRadius: 7))
          .frame(maxWidth: 340)
        }

        if model.filteredExamples.isEmpty {
          ReviewEmptyState(
            symbol: "text.quote",
            title: model.examples.isEmpty ? "还没有改写范例" : "没有符合条件的范例",
            detail: model.examples.isEmpty ? "成稿后，可以在这里回看选用的表达。" : "试试其他关键词或取舍类型。",
            actionTitle: model.examples.isEmpty ? nil : "清除筛选",
            action: {
              model.state.exampleQuery = ""
              model.state.exampleFilter = .all
            }
          )
          .frame(minHeight: 240)
        } else {
          ForEach(model.filteredExamples) { example in
            exampleCard(example)
          }
        }
      }
      .padding(.horizontal, 34)
      .padding(.vertical, 36)
      .frame(maxWidth: 820)
      .frame(maxWidth: .infinity)
    }
    .background(PaperTheme.paper)
  }

  private func exampleCard(_ example: RewriteExample) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 9) {
        ReviewTag(title: example.displayTag)
        Text(example.decision.title).font(.caption).foregroundStyle(.secondary)
        Spacer()
        Text(articleTitle(example.articleID)).font(.caption).foregroundStyle(.secondary)
          .lineLimit(1)
      }
      HStack(alignment: .top, spacing: 14) {
        Text("原来").font(.caption).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
        Text(example.before)
          .strikethrough(example.decision != .keep)
          .foregroundStyle(example.decision == .keep ? Color.primary : PaperTheme.deletion)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      if example.decision != .keep {
        HStack(alignment: .top, spacing: 14) {
          Text("现在")
            .font(.caption).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
          Text(example.after)
            .underline()
            .foregroundStyle(PaperTheme.insertion)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      if !example.reason.isEmpty {
        Text(example.reason).font(.callout).foregroundStyle(.secondary)
      }
      Button {
        model.selectExample(example.id)
      } label: {
        Label("回到文章", systemImage: "arrow.up.right")
      }
      .buttonStyle(.plain)
      .font(.callout)
      .foregroundStyle(PaperTheme.accent)
    }
    .font(.system(size: 15))
    .lineSpacing(7)
    .textSelection(.enabled)
    .padding(.vertical, 24)
    .overlay(alignment: .top) { Divider() }
  }

  private func articleTitle(_ id: UUID) -> String {
    model.articles.first(where: { $0.id == id })?.displayTitle ?? "文章"
  }
}
