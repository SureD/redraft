import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { Selection as PMSelection } from "prosemirror-state";
import { checkRaster, uploadRaster } from "./media";
import { createEditor, type Blocks, type Editor } from "./schema";
import { WritingView } from "./view";

type Open = { token: string; blocks: Blocks; editable: boolean; focus: boolean };
type Configuration = { editable?: boolean; highlight?: string | null };
type Selection = { id: string; location?: number; length?: number };
type Message = { kind: "ready" } | { kind: "change"; token: string; blocks: Blocks }
  | ({ kind: "selection"; token: string } & Selection)
  | { kind: "composition"; token: string; active: boolean } | { kind: "error"; token: string; message: string };

declare global {
  interface Window {
    webkit: { messageHandlers: {
      redraft: { postMessage(message: Message): void };
      redraftImage: { postMessage(image: { token: string; dataURL: string }): Promise<string> };
    } };
    redraft: { open(data: Open): void; configure(data: Configuration): void; focus(): void; markdown(paths?: Record<string, string>): string };
  }
}
const host = document.getElementById("writing")!;
const highlightStyle = document.createElement("style");
document.head.append(highlightStyle);
let current: WritingSession | undefined;
function post(message: Message) { window.webkit.messageHandlers.redraft.postMessage(message); }
function error(token: string, cause: unknown) {
  post({ kind: "error", token, message: cause instanceof Error ? cause.message : String(cause) });
}
const root = createRoot(host, { onUncaughtError: cause => error(current?.token ?? "", cause) });

// One ProseMirror history per authoritative token, not one history per block/render.
class WritingSession {
  readonly editor: Editor;
  readonly token: string;
  editable: boolean;
  private published: Editor["prosemirrorState"]["doc"];
  private readonly events = new AbortController();
  private composing = false;
  private finishTimer?: number;
  private nextEditable?: boolean;
  private highlight: string | null = null;
  private selectionQueued = false;
  private lastSelection?: string;

  constructor(data: Open) {
    this.token = data.token;
    this.editable = data.editable;
    const report = (cause: unknown) => { if (current === this) error(this.token, cause); };
    this.editor = createEditor(data.blocks, async file => {
      try { return await this.upload(file); }
      catch (cause) { report(cause); throw cause; }
    }, report);
    this.published = this.editor.prosemirrorState.doc;
  }

  private upload(file: File) {
    return uploadRaster(file, this.token, () => current === this && this.editable);
  }

  render() {
    flushSync(() => root.render(<WritingView key={this.token} editor={this.editor} editable={this.editable} />));
  }

  listen() {
    const { signal } = this.events;
    const opts = { capture: true, signal };
    const body = this.editor.domElement!;
    const off = [
      this.editor.onChange(() => { if (!this.composing) this.publish(); }),
      this.editor.onSelectionChange(() => this.queueSelection()),
      this.editor.onFocusChange((_, { focused }) => { if (focused) this.queueSelection(); }),
    ];
    signal.addEventListener("abort", () => off.forEach(fn => fn()), { once: true });
    body.addEventListener("compositionstart", () => this.beginComposition(), opts);
    body.addEventListener("compositionupdate", () => this.beginComposition(), opts);
    body.addEventListener("compositionend", () => {
      // On WebKit the DOM observer can still have the commit queued *after*
      // compositionend. Let the input and ProseMirror's end-composition pass finish.
      clearTimeout(this.finishTimer);
      this.finishTimer = window.setTimeout(() => this.endComposition(), 30);
    }, opts);
    body.addEventListener("keydown", event => {
      if (event.key !== "ArrowDown" || event.altKey || event.ctrlKey || event.metaKey || event.shiftKey ||
        event.isComposing || this.composing || !this.editable) return;
      const { doc, selection } = this.editor.prosemirrorState;
      if (!selection.eq(PMSelection.atEnd(doc))) return;
      const block = this.editor.getTextCursorPosition().block;
      if (block.type !== "table" && block.type !== "image") return;
      // The stock trailing widget is mouse-only at the end of a table.
      // Only intercept the document boundary, not navigation between cells or lines.
      event.preventDefault(); event.stopImmediatePropagation();
      this.editor.transact(tr => { this.continueAfter(block.id); tr.scrollIntoView(); });
    }, opts);
    body.addEventListener("paste", event => this.receiveFiles(event, event.clipboardData), opts);
    body.addEventListener("drop", event => this.receiveFiles(event, event.dataTransfer), opts);
    body.addEventListener("auxclick", event => {
      if (event.target instanceof Element && event.target.closest("a[href]")) event.preventDefault();
    }, opts);
    body.addEventListener("click", event => {
      const el = event.target instanceof Element ? event.target : null;
      if (el?.closest("a[href]")) event.preventDefault();
      const id = el?.closest<HTMLElement>(".bn-block[data-id]")?.dataset.id;
      if (this.editable) this.queueSelection();
      else if (id) this.sendSelection({ id });
    }, opts);
    this.published = this.editor.prosemirrorState.doc;
  }

  stop() {
    this.events.abort();
    clearTimeout(this.finishTimer);
    highlightStyle.textContent = "";
  }

  private publish(force = false) {
    if (current !== this || !this.editable) return;
    const doc = this.editor.prosemirrorState.doc;
    if (!force && this.published.eq(doc)) return;
    // WK's structured message body does not accept undefined (e.g. an unset
    // image width); absent properties are omitted and missing array cells become null.
    const blocks: Blocks = JSON.parse(JSON.stringify(this.editor.document));
    post({ kind: "change", token: this.token, blocks });
    this.published = doc;
  }

  private beginComposition() {
    if (!this.editable) return;
    clearTimeout(this.finishTimer);
    if (this.composing) return;
    this.composing = true;
    post({ kind: "composition", token: this.token, active: true });
  }

  private endComposition() {
    if (!this.composing || current !== this) return;
    this.publish(true);
    this.composing = false;
    post({ kind: "composition", token: this.token, active: false });
    this.queueSelection();
    if (this.nextEditable !== undefined) this.configure({ editable: this.nextEditable });
    this.nextEditable = undefined;
  }

  private sendSelection(selection: Selection) {
    const key = JSON.stringify(selection);
    if (key === this.lastSelection) return;
    this.lastSelection = key;
    post({ kind: "selection", token: this.token, ...selection });
  }

  private queueSelection() {
    if (this.selectionQueued || this.composing) return;
    this.selectionQueued = true;
    // Tiptap reports selectionUpdate before update; publish newly inserted IDs
    // to native in their document before referring to them as the selection.
    queueMicrotask(() => {
      this.selectionQueued = false;
      if (current !== this || this.composing || !this.editable) return;
      const block = this.editor.getTextCursorPosition().block;
      const { $from, $to } = this.editor.prosemirrorState.selection;
      const selection: Selection = { id: block.id };
      if ($from.sameParent($to) && $from.parent.isTextblock && $from.parent.type.name === block.type) {
        selection.location = $from.parentOffset;
        selection.length = $to.parentOffset - $from.parentOffset;
      }
      this.sendSelection(selection);
    });
  }

  configure({ editable, highlight }: Configuration) {
    if (editable !== undefined) {
      if (this.composing) this.nextEditable = editable;
      else if (editable !== this.editable) {
        this.editable = this.editor.isEditable = editable;
        this.render();
      }
    }
    if (highlight === undefined || highlight === this.highlight) return;
    this.highlight = highlight;
    this.lastSelection = undefined; // A click can reselect a block after native highlighted another one.
    const selector = highlight ? `.bn-block[data-id="${CSS.escape(highlight)}"]` : null;
    // Do not touch DOM managed by ProseMirror or dispatch a cursor transaction.
    highlightStyle.textContent = selector ? `.redraft-paper ${selector} > .bn-block-content { background: var(--review-fill); box-shadow: -3px 0 var(--mark); border-radius: 2px; }` : "";
    if (selector) host.querySelector(selector)?.scrollIntoView({ block: "nearest", inline: "nearest" });
  }

  private continueAfter(id: string) {
    const next = this.editor.getNextBlock(id);
    const typing = next?.type === "paragraph" && !next.content.length ? next
      : this.editor.insertBlocks([{ type: "paragraph" }], id, "after")[0];
    this.editor.setTextCursorPosition(typing);
  }

  private receiveFiles(event: ClipboardEvent | DragEvent, data: DataTransfer | null) {
    const files = Array.from(data?.files ?? []);
    if (!files.length) return; // Ordinary content uses BlockNote's rich paste and drag handlers.
    event.preventDefault();
    event.stopImmediatePropagation();
    if (!this.editable) return;
    try { files.forEach(checkRaster); }
    catch (cause) { error(this.token, cause); return; }
    const target = event.type === "drop" && event.target instanceof Element
      ? event.target.closest<HTMLElement>(".bn-block[data-id]") : null;
    const id = target?.dataset.id || this.editor.getTextCursorPosition().block.id;
    const atPaste = this.editor.prosemirrorState;
    const before = target && event instanceof DragEvent && event.clientY < target.getBoundingClientRect().top + target.offsetHeight / 2;
    void (async () => {
      const images: { type: "image"; props: { url: string; name: string } }[] = [];
      for (const file of files) images.push({ type: "image" as const, props: { url: await this.upload(file), name: file.name } });
      const anchor = this.editor.getBlock(id);
      if (current !== this || !this.editable || !anchor) return;
      const state = this.editor.prosemirrorState;
      const continueWriting = event.type === "paste" && this.editor.isFocused() &&
        state.doc === atPaste.doc && state.selection.eq(atPaste.selection);
      this.editor.transact(() => {
        let last: string;
        if (anchor.type === "paragraph" && !anchor.content.length && !anchor.children.length) {
          const first = this.editor.updateBlock(id, images[0]);
          last = images.length === 1 ? first.id : this.editor.insertBlocks(images.slice(1), id, "after").at(-1)!.id;
        } else last = this.editor.insertBlocks(images, id, before ? "before" : "after").at(-1)!.id;
        // Match the slash menu's writing flow, but don't move a caret that the
        // author has already moved while native was storing the file.
        if (continueWriting) this.continueAfter(last);
      });
    })().catch(cause => { if (current === this) error(this.token, cause); });
  }
}

window.redraft = {
  open(data) {
    try {
      if (data.token === current?.token) return;
      const next = new WritingSession(data);
      const old = current;
      old?.stop();
      current = next;
      next.render();
      old?.editor._tiptapEditor.destroy(); // React has now unmounted its old view.
      next.listen();
      if (data.focus && next.editable) next.editor.focus();
    } catch (cause) { error(data.token, cause); }
  },
  configure(data) { current?.configure(data); },
  focus() { if (current?.editable) current.editor.focus(); },
  markdown(paths) {
    if (!current) return "";
    const { editor } = current;
    if (!paths) return editor.blocksToMarkdownLossy();
    const blocks = structuredClone(editor.document);
    function rewriteImages(items: typeof blocks) {
      for (const block of items) {
        if (block.type === "image" && block.props.url) {
          const path = paths![block.id.toLowerCase()];
          if (!path) throw new Error(`缺少图片 ${block.id} 的导出路径。`);
          block.props = { ...block.props, url: path };
        }
        rewriteImages(block.children);
      }
    }
    rewriteImages(blocks);
    return editor.blocksToMarkdownLossy(blocks);
  },
};
post({ kind: "ready" });
