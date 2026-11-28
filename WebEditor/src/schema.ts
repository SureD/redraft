import {
  BlockNoteEditor, BlockNoteSchema, createExtension, createHeadingBlockSpec,
  createImageBlockSpec, defaultBlockSpecs, markdownToHTML,
} from "@blocknote/core";
import { zh } from "@blocknote/core/locales";
import { VALID_LINK_PROTOCOLS } from "@blocknote/core/extensions";
import { Plugin } from "prosemirror-state";
import { isAssetURL, rasterTypes } from "./media";
import { localHTML } from "./clipboard";

const image = createImageBlockSpec();
const schema = BlockNoteSchema.create({ blockSpecs: {
  paragraph: defaultBlockSpecs.paragraph,
  heading: createHeadingBlockSpec({ levels: [1, 2, 3, 4, 5, 6] }),
  bulletListItem: defaultBlockSpecs.bulletListItem,
  numberedListItem: defaultBlockSpecs.numberedListItem,
  checkListItem: defaultBlockSpecs.checkListItem,
  quote: defaultBlockSpecs.quote,
  image: { ...image, implementation: { ...image.implementation,
    meta: { ...image.implementation.meta, fileBlockAccept: rasterTypes },
  } },
  table: defaultBlockSpecs.table,
} });

// All paste/drop paths (including internal BlockNote HTML and Markdown) arrive here
// before ProseMirror updates its view. Keep surrounding text, never persist a remote
// image, and replace the collaboration plugin's special empty-document sentinel.
const documentPolicy = createExtension({ key: "redraft-document", prosemirrorPlugins: [new Plugin({
  appendTransaction(transactions, previous, state) {
    if (!transactions.some(tr => tr.docChanged)) return;
    const from = previous.doc.content.findDiffStart(state.doc.content);
    if (from === null) return;
    const end = previous.doc.content.findDiffEnd(state.doc.content)?.b ?? from;
    const tr = state.tr;
    state.doc.nodesBetween(from, Math.max(from, end), (node, pos) => {
      if (node.type.name === "image" && node.attrs.url && !isAssetURL(node.attrs.url)) {
        tr.setNodeAttribute(pos, "url", "");
      }
      if (node.type.name === "blockContainer" && node.attrs.id === "initialBlockId") {
        tr.setNodeAttribute(pos, "id", crypto.randomUUID());
      }
    });
    return tr.docChanged ? tr : null;
  },
})] });

export type Blocks = typeof schema.PartialBlock[];
export type Editor = ReturnType<typeof createEditor>;

export function createEditor(blocks: Blocks, uploadFile: (file: File) => Promise<string>, report: (cause: unknown) => void) {
  function validateImages(items: Blocks) {
    for (const item of items) {
      if (item.type === "image" && item.props?.url && !isAssetURL(item.props.url)) {
        throw new Error("文稿含有非本地图片地址。");
      }
      if (item.children) validateImages(item.children);
    }
  }
  validateImages(blocks);
  return BlockNoteEditor.create({
    schema, initialContent: blocks, uploadFile,
    dictionary: { ...zh, placeholders: { ...zh.placeholders, default: "开始写作…" } },
    extensions: [documentPolicy], animations: false, selectAllBehavior: "document",
    domAttributes: { editor: { "aria-label": "正文", "aria-multiline": "true", role: "textbox", lang: "zh-CN" } },
    links: {
      onClick: event => { event.preventDefault(); },
      isValidLink(href) {
        if (isAssetURL(href)) return true; // A link mentioning an asset is not an image to rewrite on export.
        try { return VALID_LINK_PROTOCOLS.includes(new URL(href, "https://redraft.invalid/").protocol.slice(0, -1)); }
        catch { return false; }
      },
    },
    pasteHandler: ({ event, editor, defaultPasteHandler }) => {
      const data = event.clipboardData;
      try {
        for (const type of ["blocknote/html", "text/html", "text/markdown"]) {
          const value = data?.getData(type);
          if (!value) continue;
          const html = localHTML(type === "text/markdown" ? markdownToHTML(value) : value);
          if (html) editor.pasteHTML(html, type === "blocknote/html");
          return true;
        }
        return defaultPasteHandler({ prioritizeMarkdownOverHTML: false, plainTextAsMarkdown: false });
      } catch (cause) { report(cause); return true; }
    },
    // Native HTML drag/drop goes directly through ProseMirror, not pasteHandler.
    _tiptapOptions: { editorProps: { transformPastedHTML(html) {
      try { return localHTML(html); } catch (cause) { report(cause); return ""; }
    } } },
    tables: { splitCells: false, headers: true },
  });
}
