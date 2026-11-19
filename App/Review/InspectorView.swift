import RedraftCore
import SwiftUI

struct InspectorView: View {
  @ObservedObject var model: WorkspaceViewModel

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if model.currentArticle == nil {
        ReviewEmptyState(symbol: "doc.text", title: "选择一篇文章", detail: "")
      } else {
        switch model.state.mode {
        case .writing:
          if model.state.inspectorTab == .marks {
            marksInspector
          } else {
            provenanceInspector
          }
        case .review:
          reviewInspector
        case .history:
          historyInspector
        }
      }
    }
    .background(NativeMaterial(material: .sidebar))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("检查器")
  }

  private var header: some View {
    HStack(spacing: 12) {
      if model.state.mode == .writing {
        Picker("检查器内容", selection: $model.state.inspectorTab) {
          Text("改稿").tag(InspectorTab.marks)
          Text("来历").tag(InspectorTab.provenance)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 180)
      } else {
        Text(model.state.mode == .review ? "当前修改" : "版本时间线")
          .font(.system(size: 13, weight: .semibold))
      }
      Spacer(minLength: 0)
      Button {
        model.state.inspectorVisible = false
      } label: {
        Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help("隐藏检查器")
      .accessibilityLabel("隐藏检查器")
    }
    .padding(.horizontal, 18)
    .frame(height: 49)
  }

  private var marksInspector: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          if let article = model.currentArticle {
            if article.phase == .running {
              HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在演示改稿流程").font(.callout)
              }
            } else if article.phase == .ready {
              Label("\(article.changes.count) 处建议等待审阅", systemImage: "checkmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            if article.marks.isEmpty {
              Text("没有标记的段落")
                .font(.callout).foregroundStyle(.secondary)
              Text("在正文中选中一段文字，再点工具栏的“标记”。")
                .font(.caption).foregroundStyle(.secondary).lineSpacing(5)
            } else {
              ForEach(article.blocks.filter { article.marks[$0.id] != nil }) { block in
                markRow(block, instruction: article.marks[block.id] ?? "更简洁")
              }
            }
          }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      if model.markedCount > 0 || model.currentArticle?.phase != .idle {
        Divider()
        Group {
          if model.currentArticle?.phase == .running {
            Button("取消改稿") { model.cancelReview() }
              .buttonStyle(.bordered)
          } else if model.currentArticle?.phase == .ready {
            Button("开始审阅") { model.enterReview() }
              .buttonStyle(.borderedProminent)
          } else {
            Button {
              model.beginReview()
            } label: {
              Label("改稿 \(model.markedCount)", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
          }
        }
        .frame(maxWidth: .infinity)
        .padding(18)
      }
    }
  }

  private func markRow(_ block: DocumentBlock, instruction: String) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Button {
        model.selectBlock(block.id)
      } label: {
        HStack(alignment: .top, spacing: 8) {
          RoundedRectangle(cornerRadius: 1).fill(PaperTheme.accent).frame(width: 2)
          Text(block.plainText.isEmpty ? blockName(block) : block.plainText)
            .font(.system(size: 13)).lineSpacing(5).lineLimit(3)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
      }
      .buttonStyle(.plain)
      HStack {
        Menu {
          ForEach(["更简洁", "更具体", "更顺口", "语气更自然"], id: \.self) { option in
            Button(option) { model.markBlock(block.id, instruction: option) }
          }
          Divider()
          Button("自定义要求…") {
            model.selectBlock(block.id)
            model.state.customInstruction = instruction
            model.state.sheet = .customMark
          }
        } label: {
          Text(instruction).font(.caption).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 4)
        Button {
          model.unmarkBlock(block.id)
        } label: {
          Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("取消标记")
        .accessibilityLabel("取消标记\(blockName(block))")
      }
      .disabled(model.isEditorLocked)
    }
    .padding(11)
    .background(
      model.state.selectedBlockID == block.id ? PaperTheme.fill : Color.clear,
      in: RoundedRectangle(cornerRadius: 6))
  }

  private var reviewInspector: some View {
    Group {
      if let change = model.currentChange {
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            inspectorSection("原来") { ChangedText(text: change.before, inserted: false) }
            inspectorSection("改稿建议") { ChangedText(text: change.after, inserted: true) }
            if !change.explanation.isEmpty {
              Text(change.explanation).font(.callout).foregroundStyle(.secondary).lineSpacing(6)
            }
            Divider()
            ReviewDecisionButtons(model: model, change: change, compact: true)
            if let decision = change.decision {
              Label(decision.title, systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(PaperTheme.accent)
            }
            if change.decision == .rewrite, !change.rewrittenText.isEmpty {
              inspectorSection("你的改写") {
                Text(change.rewrittenText).font(.callout).lineSpacing(7)
              }
            }
            TextField(
              "给这次取舍留一句说明",
              text: Binding(
                get: { model.currentChange?.reason ?? "" },
                set: { model.updateChangeReason($0, changeID: change.id) }
              ), axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .lineLimit(3...6)
          }
          .padding(18)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      } else {
        ReviewEmptyState(
          symbol: "text.magnifyingglass", title: "选择一处修改", detail: "点正文中的修改，查看原句和建议。")
      }
    }
  }

  private var historyInspector: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 2) {
        Text("选择版本作为对比终点")
          .font(.caption).foregroundStyle(.secondary).padding(.bottom, 20)
        if let article = model.currentArticle {
          ForEach(Array(article.versions.reversed())) { version in
            Button {
              model.state.historyToID = version.id
            } label: {
              timelineEntry(version: version, selected: model.state.historyToID == version.id)
            }
            .buttonStyle(.plain)
          }
          if article.versions.isEmpty {
            Text("还没有历史版本").font(.callout).foregroundStyle(.secondary)
          }
        }
      }
      .padding(18)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var provenanceInspector: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        if let article = model.currentArticle,
          let blockID = model.state.selectedBlockID,
          let block = article.blocks.first(where: { $0.id == blockID })
        {
          Text(block.plainText.isEmpty ? blockName(block) : block.plainText)
            .font(.callout).lineSpacing(6)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PaperTheme.fill, in: RoundedRectangle(cornerRadius: 6))
          Text("各版本中的同一段落")
            .font(.caption).foregroundStyle(.secondary)
          let versions = article.versions.filter { version in
            version.blocks.contains(where: { $0.id == blockID })
          }
          if versions.isEmpty {
            Text("这段内容还没有留存在历史版本里。")
              .font(.callout).foregroundStyle(.secondary).lineSpacing(5)
          } else {
            ForEach(versions) { version in
              VStack(alignment: .leading, spacing: 8) {
                Label(version.title, systemImage: "circle.fill")
                  .font(.caption).foregroundStyle(.secondary)
                if let original = version.blocks.first(where: { $0.id == blockID }) {
                  Text(original.plainText.isEmpty ? blockName(original) : original.plainText)
                    .font(.callout).lineSpacing(6)
                    .textSelection(.enabled)
                }
                Text(
                  version.date,
                  format: .dateTime.year().month().day().locale(Locale(identifier: "zh_CN"))
                )
                .font(.caption2).foregroundStyle(.tertiary)
              }
              .padding(.leading, 12)
              .overlay(alignment: .leading) {
                Rectangle().fill(PaperTheme.separator).frame(width: 1)
              }
            }
          }
        } else {
          Text("把光标放在一段文字上")
            .font(.callout).foregroundStyle(.secondary)
          Text("在这里回看它在各份版本中的样子。")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      .padding(18)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func timelineEntry(version: ArticleVersion, selected: Bool) -> some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(spacing: 4) {
        Circle().fill(selected ? PaperTheme.accent : Color.secondary.opacity(0.4))
          .frame(width: 7, height: 7)
        Rectangle().fill(PaperTheme.separator).frame(width: 1, height: 42)
      }
      .padding(.top, 5)
      VStack(alignment: .leading, spacing: 6) {
        Text(version.title).font(.system(size: 13, weight: selected ? .semibold : .regular))
        Text(
          version.date,
          format: .dateTime.month().day().hour().minute().locale(Locale(identifier: "zh_CN"))
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      if selected {
        Image(systemName: "checkmark").font(.caption).foregroundStyle(PaperTheme.accent)
      }
    }
    .padding(9)
    .background(selected ? PaperTheme.fill : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    .contentShape(Rectangle())
  }

  private func inspectorSection<Content: View>(
    _ title: String, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      content()
    }
  }

  private func blockName(_ block: DocumentBlock) -> String {
    switch block.kind {
    case .text: "空白段落"
    case .image: "图片"
    case .table: "表格"
    }
  }
}
