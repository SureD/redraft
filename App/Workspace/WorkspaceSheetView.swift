import RedraftCore
import SwiftUI

struct WorkspaceSheetView: View {
  @ObservedObject var model: WorkspaceViewModel
  let sheet: WorkspaceSheet

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack {
        Text(title).font(.title2.weight(.semibold))
        Spacer()
        Button {
          model.dismissSheet()
        } label: {
          Image(systemName: "xmark.circle.fill").font(.title3)
        }
        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("关闭")
        .keyboardShortcut(.cancelAction)
      }
      sheetContent
    }
    .padding(28).frame(width: sheet == .shortcuts ? 500 : 440)
    .background(NativeMaterial(material: .sheet))
  }

  private var title: String {
    switch sheet {
    case .customMark: "希望怎样改写？"
    case .rewrite: "写下自己的表达"
    case .shortcuts: "快捷键"
    case .statistics: "字数统计"
    case .about: "关于 Redraft"
    case .insertTable: "插入表格"
    case .imageDescription: "图片替代文字"
    }
  }

  @ViewBuilder private var sheetContent: some View {
    switch sheet {
    case .customMark:
      Text("要求会与选中的段落一起标记。").foregroundStyle(.secondary)
      TextField("例如：保留细节，语气再自然一些", text: $model.state.customInstruction, axis: .vertical)
        .lineLimit(3...5).textFieldStyle(.roundedBorder)
      actions(
        "添加标记",
        disabled: model.state.customInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
          .isEmpty
      ) {
        model.submitCustomMark()
      }
    case .rewrite:
      if let change = model.currentChange {
        Text(change.before).foregroundStyle(.secondary).lineLimit(5)
      }
      TextEditor(text: $model.state.rewriteText).font(.body).frame(height: 130)
        .padding(8).background(PaperTheme.paper, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(PaperTheme.separator))
        .accessibilityLabel("重写内容")
      TextField("取舍说明（可选）", text: $model.state.rewriteReason).textFieldStyle(.roundedBorder)
      actions(
        "使用这段表达",
        disabled: model.state.rewriteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ) {
        model.submitRewrite()
      }
    case .insertTable:
      VStack(spacing: 5) {
        ForEach(1...8, id: \.self) { row in
          HStack(spacing: 5) {
            ForEach(1...8, id: \.self) { column in
              Button {
                model.state.tableRows = row
                model.state.tableColumns = column
              } label: {
                RoundedRectangle(cornerRadius: 3)
                  .fill(
                    row <= model.state.tableRows && column <= model.state.tableColumns
                      ? PaperTheme.accent.opacity(0.2) : PaperTheme.fill
                  )
                  .overlay(RoundedRectangle(cornerRadius: 3).stroke(PaperTheme.separator))
                  .frame(width: 28, height: 22)
              }.buttonStyle(.plain).accessibilityLabel("\(row) 行 \(column) 列")
            }
          }
        }
      }.frame(maxWidth: .infinity)
      HStack {
        Stepper("\(model.state.tableRows) 行", value: $model.state.tableRows, in: 1...8)
        Spacer(minLength: 28)
        Stepper("\(model.state.tableColumns) 列", value: $model.state.tableColumns, in: 1...8)
      }
      Text("第一行作为标题行，可在表格菜单中调整。").font(.caption).foregroundStyle(.secondary)
      actions("插入表格") {
        let rows = Array(
          repeating: Array(repeating: "", count: model.state.tableColumns),
          count: model.state.tableRows)
        model.insertBlock(
          DocumentBlock(table: TableContent(rows: rows, hasHeader: rows.count > 1)))
        model.dismissSheet()
      }
    case .imageDescription:
      Text("简短描述图片内容，方便使用屏幕阅读器的人理解。").foregroundStyle(.secondary)
      TextField("例如：阳台上并排摆着三个陶土花盆", text: $model.state.imageDescription, axis: .vertical)
        .lineLimit(3...5).textFieldStyle(.roundedBorder)
      actions("完成") {
        if var block = model.selectedBlock {
          block.image?.altText = model.state.imageDescription
          model.updateBlock(block)
        }
        model.dismissSheet()
      }
    case .statistics:
      if let article = model.currentArticle {
        Text(article.displayTitle).foregroundStyle(.secondary)
        HStack(spacing: 40) {
          metric("字符", value: article.characterCount)
          metric("段落", value: article.blocks.filter { $0.kind == .text }.count)
          metric("图片", value: article.blocks.filter { $0.kind == .image }.count)
          metric("表格", value: article.blocks.filter { $0.kind == .table }.count)
        }.padding(.vertical, 12)
        Text("字符数包括标点、图注及单元格文字。").font(.caption).foregroundStyle(.secondary)
      }
      dismissButton
    case .about:
      HStack(alignment: .top, spacing: 18) {
        Text("R").font(.system(size: 44, weight: .semibold, design: .serif))
          .frame(width: 70, height: 70).foregroundStyle(PaperTheme.paper)
          .background(Color.primary, in: RoundedRectangle(cornerRadius: 16))
        VStack(alignment: .leading, spacing: 7) {
          Text("Redraft").font(.headline)
          Text("伴随式写作编辑器").foregroundStyle(.secondary)
          Text("0.1 · 原生界面预览").font(.caption).foregroundStyle(.secondary)
        }
      }
      Divider()
      Text("批注来自本地演示。原稿、成稿和段落轨迹仅保留到退出应用。")
        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      dismissButton
    case .shortcuts:
      VStack(spacing: 12) {
        shortcut("新建文章", "⌘ N")
        shortcut("切换文章库", "⌃ ⌘ S")
        shortcut("请求或阅读批注", "⌘ ↩")
        Divider()
        shortcut("粗体 / 斜体 / 下划线", "⌘ B / I / U")
        shortcut("撤销 / 重做（正文）", "⌘ Z / ⌘ ⇧ Z")
        shortcut("显示快捷键", "⌘ /")
      }
      dismissButton
    }
  }

  private var dismissButton: some View {
    HStack {
      Spacer()
      Button("完成", action: model.dismissSheet).keyboardShortcut(.defaultAction)
    }
  }

  private func actions(_ title: String, disabled: Bool = false, action: @escaping () -> Void)
    -> some View
  {
    HStack {
      Spacer()
      Button("取消", action: model.dismissSheet).keyboardShortcut(.cancelAction)
      Button(title, action: action).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        .disabled(disabled)
    }
  }

  private func metric(_ title: String, value: Int) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(value.formatted()).font(.system(size: 26, weight: .medium, design: .rounded))
      Text(title).font(.caption).foregroundStyle(.secondary)
    }
  }

  private func shortcut(_ title: String, _ keys: String) -> some View {
    HStack {
      Text(title)
      Spacer()
      Text(keys).foregroundStyle(.secondary).font(.system(.body, design: .monospaced))
    }
  }
}
