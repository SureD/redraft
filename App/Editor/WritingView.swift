import AppKit
import RedraftCore
import SwiftUI
import UniformTypeIdentifiers

struct WritingView: View {
  @ObservedObject var model: WorkspaceViewModel

  var body: some View {
    ScrollViewReader { scroll in
      ScrollView {
        if let article = model.currentArticle {
          VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
              Text(
                article.updatedAt.formatted(
                  .dateTime.year().month().day().locale(Locale(identifier: "zh_CN")))
              )
              .font(.system(size: 12)).foregroundStyle(PaperTheme.secondaryText)
              TextField(
                "无标题",
                text: Binding(
                  get: { model.currentArticle?.title ?? "" },
                  set: { title in
                    model.mutateSelectedArticle { $0.title = title }
                  })
              )
              .textFieldStyle(.plain).font(.system(size: 32, weight: .semibold))
              .disabled(model.isEditorLocked)
              .accessibilityLabel("文章标题")
            }
            .padding(.bottom, 8)

            ForEach(article.blocks) { block in
              HStack(alignment: .top, spacing: 14) {
                RoundedRectangle(cornerRadius: 1)
                  .fill(
                    article.marks[block.id] == nil ? Color.clear : PaperTheme.accent.opacity(0.65)
                  )
                  .frame(width: 2)
                  .accessibilityHidden(true)
                blockView(block)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
              .padding(.leading, -16)
              .id(block.id)
              .onDrop(of: [UTType.image.identifier, UTType.fileURL.identifier], isTargeted: nil) {
                providers in
                model.receiveImageDrop(providers, after: block.id)
              }
              .contextMenu {
                Button("标记：更简洁") { model.markBlock(block.id, instruction: "更简洁") }
                Button("标记：更具体") { model.markBlock(block.id, instruction: "更具体") }
                if article.marks[block.id] != nil {
                  Button("取消标记") { model.unmarkBlock(block.id) }
                }
                Divider()
                Button("这句话的来历") {
                  model.selectBlock(block.id)
                  model.state.inspectorTab = .provenance
                  model.state.inspectorVisible = true
                }
                if article.blocks.count > 1 {
                  Button("删除内容", role: .destructive) { model.deleteBlock(block.id) }
                }
              }
            }
            Button {
              model.insertBlock(
                DocumentBlock()
              )
            } label: {
              Label("继续写作", systemImage: "plus").font(.system(size: 12))
            }
            .buttonStyle(.plain).foregroundStyle(.tertiary)
            .disabled(model.isEditorLocked)
            .padding(.top, 8)
          }
          .frame(maxWidth: 646)
          .padding(.horizontal, 44)
          .padding(.top, 42)
          .padding(.bottom, 100)
          .frame(maxWidth: .infinity)
        }
      }
      .onChange(of: model.state.selectedBlockID) { id in
        guard let id else { return }
        if let editor = NSApp.keyWindow?.firstResponder as? BlockTextView, editor.blockID == id {
          return
        }
        scroll.scrollTo(id)
      }
      .onAppear {
        if let id = model.state.selectedBlockID { scroll.scrollTo(id) }
      }
    }
    .id(model.state.selectedArticleID)
    .background(PaperTheme.paper)
    .background(WritingKeyboardNavigation(model: model).frame(width: 0, height: 0))
    .onDrop(of: [UTType.image.identifier, UTType.fileURL.identifier], isTargeted: nil) {
      providers in
      model.receiveImageDrop(providers, after: model.state.selectedBlockID)
    }
  }

  @ViewBuilder private func blockView(_ block: DocumentBlock) -> some View {
    switch block.kind {
    case .text:
      if let articleID = model.currentArticle?.id {
        TextBlockEditor(model: model, block: block, articleID: articleID)
      }
    case .image: ImageBlockEditor(model: model, block: block)
    case .table: TableBlockEditor(model: model, block: block)
    }
  }
}

private struct TextBlockEditor: View {
  @ObservedObject var model: WorkspaceViewModel
  let block: DocumentBlock
  let articleID: UUID
  @State private var height: CGFloat = 40

  var body: some View {
    NativeRichText(
      content: {
        model.currentArticle?.blocks.first(where: { $0.id == block.id })?.text ?? block.text
      },
      onCommit: { text, expected in
        model.updateBlockText(block.id, text: text, expectedContent: expected, articleID: articleID)
      },
      measuredHeight: $height,
      blockID: block.id,
      session: model.editorSession,
      selection: model.state.selectedBlockID == block.id ? model.state.selectedRange : nil,
      editable: !model.isEditorLocked,
      onSelection: { model.updateSelection(blockID: block.id, range: $0) },
      onImageTransfer: { payload in
        guard let target = model.imageImportTarget(after: block.id) else { return }
        model.receiveImage(payload, target: target)
      },
      focusOnMount: model.state.selectedBlockID == block.id && block.text.string.utf16.count == 0
    )
    .frame(height: height)
    .overlay(alignment: .topLeading) {
      if block.text.string.utf16.count == 0 && !model.isEditorLocked {
        Text("写下第一句话…")
          .font(.system(size: 17))
          .foregroundStyle(.tertiary)
          .padding(.top, 4)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
    }
  }
}

private struct ImageBlockEditor: View {
  @ObservedObject var model: WorkspaceViewModel
  let block: DocumentBlock
  @Environment(\.documentImageResolver) private var imageResolver
  private var selected: Bool { model.state.selectedBlockID == block.id }

  var body: some View {
    if let content = block.image {
      VStack(spacing: 9) {
        GeometryReader { geometry in
          DocumentImagePreview(content: content)
            .frame(width: geometry.size.width * content.width)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
              RoundedRectangle(cornerRadius: 5).stroke(
                selected ? PaperTheme.accent : Color.clear, lineWidth: 2)
            )
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
              NSApp.keyWindow?.makeFirstResponder(nil)
              model.selectBlock(block.id)
            }
            .accessibilityAction(named: "选中图片") {
              NSApp.keyWindow?.makeFirstResponder(nil)
              model.selectBlock(block.id)
            }
        }
        .aspectRatio(
          DocumentImagePreview.ratio(for: content, resolver: imageResolver) / content.width,
          contentMode: .fit)

        if selected && !model.isEditorLocked {
          HStack(spacing: 12) {
            ForEach([0.4, 0.66, 1.0], id: \.self) { width in
              Button(width == 0.4 ? "小" : width == 0.66 ? "中" : "大") {
                model.editImage(block.id) { $0.width = width }
              }
              .foregroundStyle(
                content.width == width ? PaperTheme.accent : PaperTheme.secondaryText)
            }
            Divider().frame(height: 14)
            Button("替换") { model.chooseImage(replacing: block.id) }
            Button("替代文字") {
              model.state.imageDescription = content.altText
              model.state.sheet = .imageDescription
            }
            Button {
              model.deleteBlock(block.id)
            } label: {
              Image(systemName: "trash")
            }
            .help("删除图片")
          }
          .font(.system(size: 12)).buttonStyle(.plain)
          .padding(.horizontal, 14).padding(.vertical, 9)
          .background(.regularMaterial, in: Capsule())
        }

        TextField(
          "添加图注",
          text: Binding(
            get: { content.caption },
            set: { caption in
              model.editImage(block.id) { $0.caption = caption }
            }), axis: .vertical
        )
        .font(.system(size: 13)).multilineTextAlignment(.center)
        .foregroundStyle(PaperTheme.secondaryText).textFieldStyle(.plain)
        .disabled(model.isEditorLocked)
        .onTapGesture { model.selectBlock(block.id) }
        .accessibilityLabel("图片说明")
      }
    }
  }
}

struct TableCell: Hashable {
  var rowID: UUID
  var columnID: UUID
}

struct TableFocus {
  var cell: TableCell?
  var request = 0
  var isEditing = false

  mutating func move(to cell: TableCell) {
    self.cell = cell
    request += 1
  }
}

private struct TableBlockEditor: View {
  @ObservedObject var model: WorkspaceViewModel
  let block: DocumentBlock
  @State private var focus = TableFocus()

  var body: some View {
    if let table = block.table {
      VStack(alignment: .trailing, spacing: 6) {
        Menu {
          Button("上方插入行") { model.insertTableRow(block.id, at: selectedRow(in: table) ?? 0) }
            .disabled(
              table.rows.count >= 40)
          Button("下方插入行") {
            model.insertTableRow(block.id, at: (selectedRow(in: table) ?? table.rows.count - 1) + 1)
          }.disabled(table.rows.count >= 40)
          Button("左侧插入列") { model.insertTableColumn(block.id, at: selectedColumn(in: table) ?? 0) }
            .disabled(table.columnCount >= 8)
          Button("右侧插入列") {
            model.insertTableColumn(
              block.id, at: (selectedColumn(in: table) ?? table.columnCount - 1) + 1)
          }.disabled(table.columnCount >= 8)
          Divider()
          Button("删除当前行") {
            model.deleteTableRow(block.id, at: selectedRow(in: table) ?? table.rows.count - 1)
            focus.cell = nil
          }
          .disabled(table.rows.count <= 1)
          Button("删除当前列") {
            model.deleteTableColumn(
              block.id, at: selectedColumn(in: table) ?? table.columnCount - 1)
            focus.cell = nil
          }
          .disabled(table.columnCount <= 1)
          Toggle(
            "标题行",
            isOn: Binding(
              get: { table.hasHeader },
              set: { value in model.editTable(block.id) { $0.hasHeader = value } }))
          Divider()
          Button("删除表格", role: .destructive) { model.deleteBlock(block.id) }
        } label: {
          Image(systemName: "ellipsis").frame(width: 24, height: 18)
        }
        .menuStyle(.borderlessButton).fixedSize().help("表格操作")
        .disabled(model.isEditorLocked)

        ScrollView(.horizontal) {
          Grid(horizontalSpacing: 1, verticalSpacing: 1) {
            ForEach(table.rowIDs, id: \.self) { rowID in
              if let row = table.rowIDs.firstIndex(of: rowID), table.rows.indices.contains(row) {
                GridRow {
                  ForEach(table.columnIDs, id: \.self) { columnID in
                    if let column = table.columnIDs.firstIndex(of: columnID),
                      table.rows[row].indices.contains(column)
                    {
                      TableCellField(
                        text: Binding(
                          get: { table.rows[row][column] },
                          set: { value in
                            model.updateTableCell(
                              block.id, cell: TableCell(rowID: rowID, columnID: columnID),
                              text: value)
                          }),
                        cell: TableCell(rowID: rowID, columnID: columnID),
                        focus: $focus,
                        isHeader: row == 0 && table.hasHeader,
                        editable: !model.isEditorLocked,
                        columnCount: table.columnCount,
                        onNavigate: { direction, appendRow in
                          navigate(
                            from: TableCell(rowID: rowID, columnID: columnID), direction: direction,
                            appendRow: appendRow, table: table)
                        }
                      )
                      .padding(.horizontal, 12).padding(.vertical, 11)
                      .frame(
                        minWidth: column == table.columnCount - 1 ? 170 : 95, maxWidth: .infinity,
                        minHeight: 44, alignment: .leading
                      )
                      .background(
                        row == 0 && table.hasHeader ? PaperTheme.secondaryPaper : PaperTheme.paper
                      )
                      .disabled(model.isEditorLocked)
                      .accessibilityLabel("第 \(row + 1) 行，第 \(column + 1) 列")
                    }
                  }
                }
              }
            }
          }
          .padding(1).background(PaperTheme.separator)
          .clipShape(RoundedRectangle(cornerRadius: 4))
          .overlay(
            RoundedRectangle(cornerRadius: 4).stroke(
              model.state.selectedBlockID == block.id && !focus.isEditing
                ? PaperTheme.accent : .clear, lineWidth: 2))
        }
      }
      .onChange(of: focus.cell) { cell in
        if cell != nil { model.selectBlock(block.id) }
      }
      .accessibilityAction(named: "选中整张表格") {
        NSApp.keyWindow?.makeFirstResponder(nil)
        focus.isEditing = false
        model.selectBlock(block.id)
      }
    }
  }

  private func selectedRow(in table: TableContent) -> Int? {
    focus.cell.flatMap { table.rowIDs.firstIndex(of: $0.rowID) }
  }

  private func selectedColumn(in table: TableContent) -> Int? {
    focus.cell.flatMap { table.columnIDs.firstIndex(of: $0.columnID) }
  }

  private func navigate(from cell: TableCell, direction: Int, appendRow: Bool, table: TableContent)
    -> Bool
  {
    guard let row = table.rowIDs.firstIndex(of: cell.rowID),
      let column = table.columnIDs.firstIndex(of: cell.columnID)
    else { return false }
    let count = max(1, table.columnCount)
    let index = row * count + column + direction
    if index < 0 { return false }
    if index >= table.rows.count * count {
      guard appendRow, table.rows.count < 40 else { return false }
      model.insertTableRow(block.id, at: table.rows.count)
    }
    guard let current = model.currentArticle?.blocks.first(where: { $0.id == block.id })?.table,
      current.rowIDs.indices.contains(index / count),
      current.columnIDs.indices.contains(index % count)
    else { return false }
    focus.move(
      to: TableCell(
        rowID: current.rowIDs[index / count], columnID: current.columnIDs[index % count]))
    return true
  }

}

struct TableCellField: NSViewRepresentable {
  @Binding var text: String
  let cell: TableCell
  @Binding var focus: TableFocus
  let isHeader: Bool
  let editable: Bool
  let columnCount: Int
  var onNavigate: (Int, Bool) -> Bool

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: text)
    field.isEditable = editable
    field.isSelectable = true
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.maximumNumberOfLines = 0
    field.delegate = context.coordinator
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return field
  }

  func updateNSView(_ field: NSTextField, context: Context) {
    context.coordinator.parent = self
    field.isEditable = editable
    field.font = .systemFont(ofSize: 14, weight: isHeader ? .medium : .regular)
    field.textColor = PaperTheme.textColor
    if field.stringValue != text, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true {
      field.stringValue = text
    }
    if focus.cell == cell, context.coordinator.handledRequest != focus.request, editable {
      context.coordinator.handledRequest = focus.request
      let request = focus.request
      DispatchQueue.main.async { [weak field, weak coordinator = context.coordinator] in
        guard let field, let coordinator,
          coordinator.parent.focus.cell == coordinator.parent.cell,
          coordinator.parent.focus.request == request,
          coordinator.parent.editable,
          field.currentEditor() == nil
        else { return }
        field.window?.makeFirstResponder(field)
      }
    }
  }

  @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: TableCellField
    var handledRequest = 0
    init(_ parent: TableCellField) { self.parent = parent }

    func controlTextDidBeginEditing(_ notification: Notification) {
      parent.focus.cell = parent.cell
      parent.focus.isEditing = true
    }

    func controlTextDidChange(_ notification: Notification) {
      if let field = notification.object as? NSTextField { parent.text = field.stringValue }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
      if parent.focus.cell == parent.cell { parent.focus.isEditing = false }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector)
      -> Bool
    {
      guard !textView.hasMarkedText() else { return false }
      switch commandSelector {
      case #selector(NSResponder.insertTab(_:)):
        return parent.onNavigate(1, true)
      case #selector(NSResponder.insertBacktab(_:)):
        return parent.onNavigate(-1, false)
      case #selector(NSResponder.moveLeft(_:))
      where textView.selectedRange() == NSRange(location: 0, length: 0):
        return parent.onNavigate(-1, false)
      case #selector(NSResponder.moveRight(_:))
      where textView.selectedRange().length == 0
        && NSMaxRange(textView.selectedRange()) == (textView.string as NSString).length:
        return parent.onNavigate(1, false)
      case #selector(NSResponder.moveUp(_:))
      where textView.selectedRange() == NSRange(location: 0, length: 0):
        return parent.onNavigate(-parent.columnCount, false)
      case #selector(NSResponder.moveDown(_:))
      where textView.selectedRange().length == 0
        && NSMaxRange(textView.selectedRange()) == (textView.string as NSString).length:
        return parent.onNavigate(parent.columnCount, false)
      case #selector(NSResponder.cancelOperation(_:)):
        control.window?.makeFirstResponder(nil)
        return true
      default: return false
      }
    }
  }
}

extension WorkspaceViewModel {
  func updateTableCell(_ id: UUID, cell: TableCell, text: String) {
    editTable(id) { table in
      guard let row = table.rowIDs.firstIndex(of: cell.rowID),
        let column = table.columnIDs.firstIndex(of: cell.columnID),
        table.rows.indices.contains(row), table.rows[row].indices.contains(column)
      else { return }
      table.rows[row][column] = text
    }
  }

  func editImage(_ id: UUID, change: (inout ImageContent) -> Void) {
    guard !isEditorLocked, var block = currentArticle?.blocks.first(where: { $0.id == id }),
      var image = block.image
    else { return }
    change(&image)
    block.image = image
    updateBlock(block)
  }

  func editTable(_ id: UUID, change: (inout TableContent) -> Void) {
    guard !isEditorLocked, var block = currentArticle?.blocks.first(where: { $0.id == id }),
      var table = block.table
    else { return }
    change(&table)
    block.table = table
    updateBlock(block)
  }

  func insertTableRow(_ id: UUID, at index: Int) {
    editTable(id) { table in
      guard table.rows.count < 40 else { return }
      let position = min(max(0, index), table.rows.count)
      table.rows.insert(
        Array(repeating: "", count: max(1, table.columnCount)),
        at: position)
      table.rowIDs.insert(UUID(), at: position)
    }
  }

  func insertTableColumn(_ id: UUID, at index: Int) {
    editTable(id) { table in
      guard table.columnCount < 8 else { return }
      let position = min(max(0, index), table.columnCount)
      for row in table.rows.indices {
        table.rows[row].insert("", at: min(position, table.rows[row].count))
      }
      table.columnIDs.insert(UUID(), at: position)
    }
  }

  func deleteTableRow(_ id: UUID, at index: Int) {
    editTable(id) {
      if $0.rows.count > 1, $0.rows.indices.contains(index) {
        $0.rows.remove(at: index)
        $0.rowIDs.remove(at: index)
      }
    }
  }

  func deleteTableColumn(_ id: UUID, at index: Int) {
    editTable(id) { table in
      guard table.columnCount > 1, table.columnIDs.indices.contains(index) else { return }
      for row in table.rows.indices where table.rows[row].indices.contains(index) {
        table.rows[row].remove(at: index)
      }
      table.columnIDs.remove(at: index)
    }
  }
}
