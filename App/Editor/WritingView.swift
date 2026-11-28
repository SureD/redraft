import RedraftCore
import SwiftUI

struct WritingView: View {
  @ObservedObject var model: WorkspaceViewModel
  @State private var focusRequest = 0

  var body: some View {
    if let article = model.currentArticle {
      VStack(spacing: 0) {
        Group {
          if model.isEditorLocked {
            Text(article.title.isEmpty ? "未命名文章" : article.title)
              .lineLimit(1)
              .textSelection(.enabled)
              .accessibilityAddTraits(.isHeader)
          } else {
            TextField(
              "标题",
              text: Binding(
                get: { model.currentArticle?.title ?? "" },
                set: { if model.currentArticle?.id == article.id { model.renameArticle($0) } }),
              prompt: Text("标题").foregroundStyle(PaperTheme.secondaryText)
            )
            .textFieldStyle(.plain)
            .accessibilityLabel("文章标题")
            .onSubmit { focusRequest += 1 }
          }
        }
        .font(.system(size: 30, weight: .semibold))
        .foregroundStyle(Color(nsColor: PaperTheme.textColor))
        // Match the content width and minimum margin of the bundled editor page.
        .frame(maxWidth: 640, alignment: .leading)
        .padding(.horizontal, 48)
        .frame(maxWidth: .infinity)
        .padding(.top, 40).padding(.bottom, 16)

        BlockNoteEditor(model: model, focusRequest: focusRequest)
      }
      .background(PaperTheme.paper)
    }
  }
}
