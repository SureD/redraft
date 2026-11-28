import RedraftCore
import SwiftUI

struct ExamplesView: View {
  @ObservedObject var model: WorkspaceViewModel

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 16) {
          Text("改写范例").font(.system(size: 32, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
          HStack(spacing: 8) {
            HStack(spacing: 8) {
              Image(systemName: "magnifyingglass").foregroundStyle(PaperTheme.secondaryText)
                .accessibilityHidden(true)
              TextField("搜索句子或说明", text: $model.state.exampleQuery)
                .textFieldStyle(.plain)
                .accessibilityLabel("搜索改写范例")
              if !model.state.exampleQuery.isEmpty {
                Button {
                  model.state.exampleQuery = ""
                } label: {
                  Image(systemName: "xmark.circle.fill").foregroundStyle(PaperTheme.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
              }
            }
            .padding(.horizontal, 12).frame(height: 32)
            .background(PaperTheme.fill, in: RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: 320)
            Picker("按取舍筛选", selection: $model.state.exampleFilter) {
              ForEach(ExampleFilter.allCases, id: \.self) { filter in
                Text(filter.title).tag(filter)
              }
            }
            .labelsHidden().fixedSize()
          }
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
            exampleRow(example)
          }
        }
      }
      .frame(maxWidth: 640)
      .padding(.horizontal, 32)
      .padding(.vertical, 32)
      .frame(maxWidth: .infinity)
    }
    .foregroundStyle(PaperTheme.ink)
    .background(PaperTheme.paper)
  }

  private func exampleRow(_ example: RewriteExample) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 8) {
        Text(example.displayTag).font(.subheadline.weight(.semibold))
        Text(example.decision.title).font(.caption).foregroundStyle(PaperTheme.secondaryText)
        Spacer(minLength: 8)
        Button {
          model.selectExample(example.id)
        } label: {
          Label(articleTitle(example.articleID), systemImage: "arrow.up.right")
            .lineLimit(1)
        }
        .buttonStyle(.plain).font(.callout)
        .foregroundStyle(PaperTheme.accent)
        .help("回到文章").accessibilityLabel("回到文章，\(articleTitle(example.articleID))")
      }
      examplePassage("原文", text: example.before)
      if example.decision != .keep {
        examplePassage("成稿", text: example.after)
      }
      if !example.reason.isEmpty {
        examplePassage("取舍", text: example.reason)
      }
    }
    .padding(.top, 24)
    .overlay(alignment: .top) { Rectangle().fill(PaperTheme.separator).frame(height: 1) }
  }

  private func examplePassage(_ title: String, text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(title).font(.caption.weight(.medium)).foregroundStyle(PaperTheme.secondaryText)
        .frame(width: 32, alignment: .leading)
      Text(text).font(.system(size: 15)).lineSpacing(6).textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func articleTitle(_ id: UUID) -> String {
    model.articles.first(where: { $0.id == id })?.displayTitle ?? "文章"
  }
}
