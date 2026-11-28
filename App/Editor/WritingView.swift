import RedraftCore
import SwiftUI

struct WritingView: View {
  @ObservedObject var model: WorkspaceViewModel
  @State private var focusRequest = 0

  var body: some View {
    if let article = model.currentArticle {
      VStack(spacing: 0) {
        TextField(
          "标题（可稍后填写）",
          text: Binding(
            get: { model.currentArticle?.title ?? "" },
            set: { if model.currentArticle?.id == article.id { model.renameArticle($0) } })
        )
        .textFieldStyle(.plain).font(.title.weight(.semibold))
        .accessibilityLabel("文章标题").disabled(model.isEditorLocked)
        .onSubmit { focusRequest += 1 }
        .frame(maxWidth: 692, alignment: .leading)
        .padding(.horizontal, 52).padding(.top, 28).padding(.bottom, 8)

        BlockNoteEditor(model: model, focusRequest: focusRequest)
      }
      .background(PaperTheme.paper)
    }
  }
}
