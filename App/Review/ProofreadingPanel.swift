import SwiftUI

struct ProofreadingPanel: View {
  @ObservedObject var model: WorkspaceViewModel
  let article: ArticleViewState

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Text("Redraft 助手")
          .font(.system(size: 15, weight: .semibold))
          .accessibilityAddTraits(.isHeader)
        Spacer(minLength: 4)
        if let sourceName, article.phase == .idle {
          Text(sourceName).font(.caption).foregroundStyle(PaperTheme.secondaryText)
        }
        Button {
          model.state.proofreadingVisible = false
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(PaperTheme.secondaryText)
        .help("收起 Redraft 助手")
        .accessibilityLabel("收起 Redraft 助手")
      }
      .padding(.horizontal, 16)
      .frame(height: 52)
      Rectangle().fill(PaperTheme.separator).frame(height: 1)

      ScrollView {
        LazyVStack(alignment: .leading, spacing: 16) {
          if article.phase == .ready {
            Text("有一轮待处理的批注").font(.callout.weight(.medium))
            HStack(spacing: 8) {
              Button("查看本轮批注", action: model.enterReview).buttonStyle(.bordered)
              Button("放弃并继续写作", action: model.cancelReview).buttonStyle(.borderless)
            }
          } else if article.phase == .running {
            HStack(spacing: 8) {
              ProgressView().controlSize(.small).accessibilityHidden(true)
              Text("正在生成本轮批注")
              Spacer()
              Button("取消", action: model.cancelReview)
            }
            .font(.callout)
          } else {
            status
            ForEach(model.proofreadingSuggestions) { suggestion in
              suggestionRow(suggestion)
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
      }
    }
    .frame(maxHeight: .infinity, alignment: .top)
    .foregroundStyle(PaperTheme.ink)
    .background(PaperTheme.reviewSurface)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Redraft 助手")
  }

  private var sourceName: String? {
    switch model.proofreadingSource {
    case .appleIntelligence: "Apple Intelligence · 本机"
    case .localRules: "本机基础检查"
    case nil: nil
    }
  }

  @ViewBuilder private var status: some View {
    switch model.proofreadingStatus {
    case .waitingForText:
      Text("写下正文后，建议会出现在这里。")
        .font(.callout).foregroundStyle(PaperTheme.secondaryText)
    case .waiting:
      Text("停笔后检查行文…")
        .font(.callout).foregroundStyle(PaperTheme.secondaryText)
    case .checking:
      HStack(spacing: 8) {
        ProgressView().controlSize(.small).accessibilityHidden(true)
        Text("正在检查行文…")
      }
      .font(.callout).foregroundStyle(PaperTheme.secondaryText)
    case .upToDate:
      if model.proofreadingSuggestions.isEmpty {
        Text("当前没有修改建议。")
          .font(.callout).foregroundStyle(PaperTheme.secondaryText)
      }
    case .failed:
      VStack(alignment: .leading, spacing: 8) {
        Text("暂时无法检查行文。").font(.callout)
        Button("重试", action: model.retryProofreading).buttonStyle(.bordered)
      }
    }
  }

  private func suggestionRow(_ suggestion: ProofreadingSuggestion) -> some View {
    let applying = model.proofreadingApplyingID == suggestion.id
    return VStack(alignment: .leading, spacing: 12) {
      LabeledPassage(title: "原文") {
        Text(suggestion.original)
          .foregroundStyle(PaperTheme.secondaryText)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
      LabeledPassage(title: "建议写法") {
        Text(suggestion.replacement.isEmpty ? "删除这段文字" : suggestion.replacement)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(12)
      .background(PaperTheme.selection, in: RoundedRectangle(cornerRadius: 8))
      if !suggestion.reason.isEmpty {
        Text(suggestion.reason)
          .font(.callout)
          .foregroundStyle(PaperTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack(spacing: 8) {
        Button {
          model.applyProofreadingSuggestion(suggestion)
        } label: {
          Label(applying ? "正在应用…" : "应用到正文", systemImage: "arrow.left")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(PaperTheme.paper)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background(PaperTheme.accent, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .opacity(model.proofreadingApplyingID == nil ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(suggestion.original))
        Button("忽略") { model.dismissProofreadingSuggestion(suggestion) }
          .buttonStyle(.borderless)
          .accessibilityHint(Text(suggestion.original))
      }
      .disabled(model.proofreadingApplyingID != nil)
      Divider().padding(.top, 4)
    }
    .accessibilityElement(children: .contain)
  }
}
