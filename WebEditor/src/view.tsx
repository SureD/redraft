import { filterSuggestionItems } from "@blocknote/core";
import { zh } from "@blocknote/core/locales";
import { BlockNoteView } from "@blocknote/mantine";
import {
  DeleteLinkButton, EditLinkButton, FilePanelController, FormattingToolbar,
  FormattingToolbarController, LinkToolbar, LinkToolbarController, SuggestionMenuController,
  UploadTab, getDefaultReactSlashMenuItems, getFormattingToolbarItems, useComponentsContext,
  type FilePanelProps, type LinkToolbarProps,
} from "@blocknote/react";
import { useCallback, useRef, useState } from "react";
import type { Editor } from "./schema";
import "@blocknote/mantine/style.css";
import "./paper.css";

// Keep the stock localized upload control; the network-embed tab is intentionally absent.
function LocalImagePanel({ blockId }: FilePanelProps) {
  const components = useComponentsContext()!;
  const [loading, setLoading] = useState(false);
  const name = zh.file_panel.upload.title;
  return <components.FilePanel.Root className="bn-panel" loading={loading} openTab={name}
    defaultOpenTab={name} setOpenTab={() => {}} tabs={[{ name, tabPanel: <UploadTab blockId={blockId} setLoading={setLoading} /> }]} />;
}

function LocalToolbar() {
  return <FormattingToolbar>{getFormattingToolbarItems().filter(item => item.key !== "fileDownloadButton")}</FormattingToolbar>;
}

function EditableLink(props: LinkToolbarProps) {
  return <LinkToolbar {...props}>
    <EditLinkButton {...props} />
    <DeleteLinkButton range={props.range} setToolbarOpen={props.setToolbarOpen} />
  </LinkToolbar>;
}

export function WritingView({ editor, editable }: { editor: Editor; editable: boolean }) {
  const getItems = useCallback(async (query: string) => filterSuggestionItems(
    getDefaultReactSlashMenuItems(editor).filter(item => item.title !== zh.slash_menu.emoji.title), query,
  ), [editor]);
  // The React wrapper remounts ProseMirror when this prop changes. The bridge
  // sets editor.isEditable in place; re-render just the controls on a mode switch.
  const mountedEditable = useRef(editable);
  return <BlockNoteView editor={editor} editable={mountedEditable.current} className="redraft-paper"
    comments={false} emojiPicker={false} sideMenu={editable} tableHandles={editable}
    filePanel={false} linkToolbar={false} slashMenu={false} formattingToolbar={false}>
    {editable && <>
      <SuggestionMenuController triggerCharacter="/" getItems={getItems}
        shouldOpen={state => !state.selection.$from.parent.type.isInGroup("tableContent")} />
      <FormattingToolbarController formattingToolbar={LocalToolbar} />
      <LinkToolbarController linkToolbar={EditableLink} />
      <FilePanelController filePanel={LocalImagePanel} />
    </>}
  </BlockNoteView>;
}
