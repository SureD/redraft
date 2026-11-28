import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { chromium } from "playwright-core";

const index = new URL("../dist/index.html", import.meta.url).href;
const a = "12008509-27a0-46bf-b4ea-650508c9dbc4";
const b = "7639f7aa-c05b-4505-ba94-47c57c0076ae";
const c = "1a994d60-7b00-4866-acd2-ee767241482f";
const asset = "redraft-image://asset/fcbcf62c-10e3-44fc-b420-1f2185b21f00";
const png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j4XoAAAAASUVORK5CYII=";
const mod = process.platform === "darwin" ? "Meta" : "Control";
const uuid = /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/;
const paragraph = (id, content = "") => ({ id, type: "paragraph", content });
let browser;

before(async () => {
  // No browser download or test server: exercise exactly the distributed file URL.
  browser = await chromium.launch(process.env.REDRAFT_CHROME
    ? { executablePath: process.env.REDRAFT_CHROME }
    : { channel: "chrome" });
});
after(async () => { await browser?.close(); });

async function pageFor(t) {
  const page = await browser.newPage();
  const errors = [], network = [], popups = [];
  page.on("pageerror", e => errors.push(e.message));
  page.on("request", req => { if (/^(https?|wss?):/.test(req.url())) network.push(req.url()); });
  page.on("popup", p => { popups.push(p.url()); return p.close(); });
  page.setDefaultTimeout(5_000);
  t.after(async () => {
    await page.close();
    assert.deepEqual({ errors, network, popups }, { errors: [], network: [], popups: [] });
  });
  await page.addInitScript(({ asset }) => {
    window.messages = []; window.uploads = [];
    window.webkit = { messageHandlers: {
      redraft: { postMessage(m) { window.messages.push(structuredClone(m)); } },
      redraftImage: { async postMessage(image) {
        window.uploads.push(image);
        if (window.delayImage) await new Promise(resolve => { window.finishUpload = resolve; });
        return asset;
      } },
    } };
  }, { asset });
  await page.goto(index);
  assert.deepEqual(await page.evaluate(() => window.messages), [{ kind: "ready" }]);
  return page;
}
function open(page, blocks, options = {}) {
  return page.evaluate(args => window.redraft.open(args), { token: "draft", editable: true, focus: true, blocks, ...options });
}
function changes(page) { return page.evaluate(() => window.messages.filter(m => m.kind === "change")); }
function markdown(page, paths) { return page.evaluate(paths => window.redraft.markdown(paths), paths); }
function paste(page, values) {
  return page.evaluate(flavors => {
    const d = new DataTransfer();
    for (const [type, value] of Object.entries(flavors)) d.setData(type, value);
    document.querySelector(".bn-editor").dispatchEvent(new ClipboardEvent("paste", { bubbles: true, cancelable: true, clipboardData: d }));
  }, values);
}
function pasteFile(page, { mime = "image/png", b64 = png, size } = {}) {
  return page.evaluate(({ mime, b64, size }) => {
    const bytes = size ? new Uint8Array(size) : Uint8Array.from(atob(b64), c => c.charCodeAt(0));
    const d = new DataTransfer(); d.items.add(new File([bytes], "春日.png", { type: mime }));
    document.querySelector(".bn-editor").dispatchEvent(new ClipboardEvent("paste", { bubbles: true, cancelable: true, clipboardData: d }));
  }, { mime, b64, size });
}
function select(page, id, from, to) {
  return page.evaluate(({ id, from, to }) => {
    const p = document.querySelector(`.bn-block[data-id="${id}"] .bn-inline-content`).firstChild;
    window.getSelection().setBaseAndExtent(p, from, p, to);
  }, { id, from, to });
}

test("hydration is silent; UTF-16 selection, review highlights and editability preserve the live editor", async t => {
  const p = await pageFor(t);
  await open(p, [paragraph(a, "甲🍃乙"), paragraph(b, "旁注")], { focus: false });
  assert.equal(await p.locator(".bn-editor").count(), 1);
  assert.equal(await p.evaluate(() => document.activeElement === document.body), true);
  await p.evaluate(() => { window.instance = document.querySelector(".bn-editor"); window.redraft.focus(); });
  await select(p, a, 1, 3);
  await p.waitForFunction(() => window.messages.some(m => m.kind === "selection" && m.location === 1 && m.length === 2));
  const after = await p.evaluate(b => {
    window.redraft.configure({ editable: true, highlight: b });
    window.redraft.configure({ editable: true, highlight: b });
    return [window.getSelection().toString(), document.activeElement === window.instance];
  }, b);
  assert.deepEqual(after, ["🍃", true]);
  assert.deepEqual(await changes(p), []);
  await p.keyboard.insertText("春");
  await p.waitForFunction(() => window.messages.some(m => m.kind === "change"));
  assert.equal((await changes(p)).at(-1).blocks[0].content[0].text, "甲春乙");
  await p.evaluate(() => window.redraft.configure({ editable: false, highlight: null }));
  assert.equal(await p.locator(".bn-editor").getAttribute("contenteditable"), "false");
  await p.locator(`.bn-block[data-id="${b}"] p`).click();
  assert.equal(await p.evaluate(() => window.messages.at(-1).id), b);
  await p.evaluate(() => { window.redraft.configure({ editable: true }); window.redraft.focus(); });
  assert.equal(await p.evaluate(() => window.instance === document.querySelector(".bn-editor")), true);
  await p.keyboard.press(`${mod}+z`);
  assert.equal((await changes(p)).at(-1).blocks[0].content[0].text, "甲🍃乙");
});

test("a proofreading replacement keeps marks and is isolated from typing on both sides of undo", async t => {
  const p = await pageFor(t);
  await open(p, [paragraph(a, [
    { type: "text", text: "甲🪴", styles: { italic: true } },
    { type: "text", text: "非常非常慢", styles: { bold: true } },
  ]), paragraph(b, "第二段")]);
  await p.evaluate(() => {
    window.instance = document.querySelector(".bn-editor");
    const text = window.instance.querySelector("strong").firstChild;
    window.getSelection().collapse(text, text.length);
  });
  await p.keyboard.insertText("。");
  await p.waitForFunction(() => window.messages.some(m => m.kind === "change"));
  const typed = (await changes(p)).at(-1);
  const edit = { token: "draft", version: typed.version, requestID: "proof-1", blockID: a,
    paragraph: "甲🪴非常非常慢。", original: "非常非常慢", replacement: "很慢" };
  assert.equal(await p.evaluate(edit => window.redraft.applyProofreading(edit), { ...edit, version: 0 }), false);
  assert.equal(await p.evaluate(edit => window.redraft.applyProofreading(edit), { ...edit, paragraph: "旧段落" }), false);
  assert.equal(await p.evaluate(edit => window.redraft.applyProofreading(edit), { ...edit, original: "非常" }), false);
  assert.equal(await p.evaluate(edit => window.redraft.applyProofreading(edit), { ...edit, token: "old" }), false);
  assert.deepEqual(await changes(p), [typed]);
  assert.equal(await p.evaluate(edit => window.redraft.applyProofreading(edit), edit), true);
  const applied = (await changes(p)).at(-1);
  assert.equal(applied.proofreadingID, "proof-1");
  assert.equal(applied.version, typed.version + 1);
  assert.deepEqual(applied.blocks[0].content, [
    { type: "text", text: "甲🪴", styles: { italic: true } },
    { type: "text", text: "很慢。", styles: { bold: true } },
  ]);
  assert.deepEqual(applied.blocks[1], typed.blocks[1]);
  assert.equal(await p.evaluate(() => document.activeElement === window.instance), true);
  await p.keyboard.insertText("！");
  assert.equal((await changes(p)).at(-1).proofreadingID, undefined);
  await p.keyboard.press(`${mod}+z`);
  assert.deepEqual((await changes(p)).at(-1).blocks, applied.blocks);
  await p.keyboard.press(`${mod}+z`);
  assert.deepEqual((await changes(p)).at(-1).blocks, typed.blocks);
  await p.keyboard.press(`${mod}+z`);
  assert.equal((await changes(p)).at(-1).blocks[0].content.at(-1).text, "非常非常慢");
});

test("proofreading refuses an active IME candidate and cannot cross a soft break", async t => {
  const p = await pageFor(t);
  await open(p, [paragraph(a, "非常慢")]);
  const edit = { token: "draft", version: 0, requestID: "proof-2", blockID: a,
    paragraph: "非常慢", original: "非常", replacement: "很" };
  const cdp = await p.context().newCDPSession(p);
  await cdp.send("Input.imeSetComposition", { text: "ni", selectionStart: 2, selectionEnd: 2 });
  await p.waitForFunction(() => window.messages.some(m => m.kind === "composition" && m.active));
  assert.equal(await p.evaluate(edit => window.redraft.applyProofreading(edit), edit), false);
  assert.deepEqual(await changes(p), []);
  await cdp.send("Input.insertText", { text: "你" });
  await p.waitForFunction(() => window.messages.some(m => m.kind === "composition" && !m.active));
  await open(p, [paragraph(a, "可修\n下一行")], { token: "soft-break" });
  assert.equal(await p.locator('.bn-editor br').first().count(), 1);
  const softBreak = { ...edit, token: "soft-break", paragraph: "可修\n下一行", original: "修\n下" };
  assert.equal(await p.evaluate(edit => window.redraft.applyProofreading(edit), softBreak), false);
  assert.equal(await p.evaluate(edit => window.redraft.applyProofreading(edit), { ...softBreak, original: "可修" }), true);
  const applied = (await changes(p)).at(-1);
  assert.equal(applied.blocks[0].content[0].text, "很\n下一行");
});

test("rich paste preserves nested formatting and links, ignores remote images and uses one undo history", async t => {
  const p = await pageFor(t);
  await open(p, [paragraph(a)]);
  await paste(p, { "text/plain": "other flavor", "text/html": '<ul><li><b>春</b><ul><li><a href="https://example.invalid/letter">嵌套链接</a></li></ul></li></ul><p>结尾</p><img src="https://example.invalid/private.png">' });
  await p.locator(".bn-editor a").waitFor();
  const [{ blocks }] = (await changes(p)).slice(-1);
  assert.equal(blocks[0].type, "bulletListItem");
  assert.equal(blocks[0].content[0].styles.bold, true);
  assert.equal(blocks[0].children[0].content[0].href, "https://example.invalid/letter");
  assert.ok(!JSON.stringify(blocks).includes("private.png"));
  await p.locator(".bn-editor a").click({ modifiers: [mod] });
  assert.equal(p.url(), index);
  await p.keyboard.press(`${mod}+z`);
  assert.ok(!(await markdown(p)).includes("嵌套链接"));
  await p.keyboard.press(`${mod}+Shift+z`);
  assert.ok((await markdown(p)).includes("嵌套链接"));
  await open(p, [paragraph(b, "新文稿")], { token: "second" });
  await p.keyboard.press(`${mod}+z`);
  assert.equal((await markdown(p)).trim(), "新文稿");
  assert.ok(!(await changes(p)).some(m => m.token === "second"));
});

test("the Chinese slash menu inserts an editable real table; image panel only offers local raster upload", async t => {
  const p = await pageFor(t);
  await open(p, [paragraph(a)]);
  assert.equal(await p.locator('.bn-editor .bn-block-content').evaluate(block =>
    getComputedStyle(block, '::after').content), '"开始写作…"');
  await p.keyboard.type("/");
  const menu = p.getByRole("listbox");
  await menu.getByText("表格", { exact: true }).click();
  const cell = p.locator(".bn-editor td").first();
  await cell.click(); await p.keyboard.insertText("表内文字");
  const blocks = (await changes(p)).at(-1).blocks;
  assert.equal(blocks[0].type, "table");
  assert.equal(blocks[0].content.rows.length, 2);
  assert.equal(blocks[0].content.rows[0].cells.length, 3);
  assert.ok(JSON.stringify(blocks[0].content.rows[0]).includes("表内文字"));
  const range = await p.evaluate(() => window.messages.filter(m => m.kind === "selection").at(-1));
  assert.ok(!("location" in range));
  await p.locator(".bn-editor td").last().click();
  await p.keyboard.insertText("末格");
  await p.keyboard.press("ArrowDown"); await p.keyboard.insertText("表格下文");
  const afterTable = (await changes(p)).at(-1).blocks;
  assert.deepEqual(afterTable.map(block => block.type), ["table", "paragraph"]);
  assert.equal(afterTable[1].content[0].text, "表格下文");
  await open(p, [paragraph(b)], { token: "image" });
  await p.keyboard.type("/");
  await menu.getByText("图片", { exact: true }).click();
  const input = p.locator("input[type=file]");
  await input.waitFor({ state: "attached" });
  assert.equal(await input.getAttribute("accept"), "image/png,image/jpeg,image/gif,image/webp");
  assert.equal(await p.locator(".bn-panel input[type=text]").count(), 0);
  await input.setInputFiles({ name: "信纸.png", mimeType: "image/png", buffer: Buffer.from(png, "base64") });
  await p.locator(`.bn-editor img[src="${asset}"]`).waitFor({ state: "attached" });
  assert.equal((await changes(p)).at(-1).blocks[0].props.url, asset);
  await p.keyboard.insertText("继续写信");
  assert.equal((await changes(p)).at(-1).blocks.at(-1).content[0].text, "继续写信");
});

test("stock formatting toolbar works across a selection; a multiblock deletion undoes as one edit", async t => {
  const p = await pageFor(t);
  await open(p, [paragraph(a, "春天的信"), paragraph(b, "地址")]);
  await select(p, a, 0, 2);
  const button = p.locator('.bn-formatting-toolbar [data-test="bold"]');
  await button.click();
  const formatted = (await changes(p)).at(-1).blocks;
  assert.deepEqual(formatted[0].content[0], { type: "text", text: "春天", styles: { bold: true } });
  await p.evaluate(() => {
    const [a, b] = document.querySelectorAll(".bn-editor p");
    const first = document.createTreeWalker(a, NodeFilter.SHOW_TEXT).nextNode();
    window.getSelection().setBaseAndExtent(first, 1, b.firstChild, 1);
  });
  await p.waitForFunction(() => { const s = window.messages.filter(m => m.kind === "selection").at(-1); return s && !("location" in s); });
  await p.keyboard.press("Backspace");
  assert.equal((await changes(p)).at(-1).blocks.length, 1);
  await p.keyboard.press(`${mod}+z`);
  assert.deepEqual((await changes(p)).at(-1).blocks, formatted);
});

test("native image replies are token-bound, raster size/type checked, Markdown relocates only the cloned image", async t => {
  const p = await pageFor(t);
  await open(p, [paragraph(a)]);
  await pasteFile(p, { mime: "image/svg+xml", b64: "PHN2Zy8+" });
  await pasteFile(p, { size: 12 * 1024 * 1024 + 1 });
  await pasteFile(p, { mime: "image/png", b64: "PHN2Zy8+" });
  await p.waitForFunction(() => window.messages.filter(m => m.kind === "error").length === 3);
  assert.equal(await p.evaluate(() => window.uploads.length), 0);
  await p.evaluate(() => { window.delayImage = true; });
  await pasteFile(p);
  await p.waitForFunction(() => window.uploads.length === 1);
  await open(p, [{ ...paragraph(b, [{ type: "text", text: `正文 ${asset}`, styles: {} },
    { type: "link", href: asset, content: [{ type: "text", text: "本文链接", styles: {} }] }]), children: [
    { id: c, type: "image", props: { url: asset, name: "春日" } },
  ] }], { token: "replacement" });
  await p.evaluate(() => window.finishUpload());
  const path = `assets/${c}.png`;
  const exported = await markdown(p, { [c]: path });
  assert.ok(exported.includes(path));
  assert.ok(exported.includes(`正文 ${asset}`));
  assert.ok(exported.includes(`[本文链接](${asset})`));
  assert.ok(!(await markdown(p)).includes(path));
  assert.equal(await p.locator(".bn-editor img").getAttribute("src"), asset);
  await assert.rejects(markdown(p, {}), /导出路径/);
  assert.deepEqual(await changes(p), []);
});

test("a pasted raster leaves a fresh typing line and image insertion undoes in one step", async t => {
  const p = await pageFor(t);
  await open(p, [paragraph(a, "前文")]);
  await pasteFile(p);
  await p.waitForFunction(() => document.querySelector('.bn-editor img[src^="redraft-image:"]'));
  const withImage = (await changes(p)).at(-1).blocks;
  assert.deepEqual(withImage.map(b => b.type), ["paragraph", "image", "paragraph"]);
  await p.keyboard.press(`${mod}+z`);
  assert.deepEqual((await changes(p)).at(-1).blocks.map(b => b.type), ["paragraph"]);
  await p.keyboard.press(`${mod}+Shift+z`);
  await p.keyboard.insertText("后记");
  assert.equal((await changes(p)).at(-1).blocks.at(-1).content[0].text, "后记");
});

test("real IME preedit never escapes; the committed change precedes composition false", async t => {
  const p = await pageFor(t);
  await open(p, [paragraph(a)]);
  const cdp = await p.context().newCDPSession(p);
  await cdp.send("Input.imeSetComposition", { text: "ni", selectionStart: 2, selectionEnd: 2 });
  await p.waitForFunction(() => window.messages.some(m => m.kind === "composition" && m.active));
  await cdp.send("Input.imeSetComposition", { text: "ni hao", selectionStart: 6, selectionEnd: 6 });
  assert.deepEqual(await changes(p), []);
  await cdp.send("Input.insertText", { text: "你好" });
  await p.waitForFunction(() => window.messages.some(m => m.kind === "composition" && !m.active));
  const updates = await p.evaluate(() => window.messages.filter(m => m.kind === "composition" || m.kind === "change"));
  assert.deepEqual(updates.map(m => [m.kind, m.active]), [["composition", true], ["change", undefined], ["composition", false]]);
  assert.equal(updates[1].blocks[0].content[0].text, "你好");
  await p.keyboard.press("Enter");
  assert.match((await changes(p)).at(-1).blocks.at(-1).id, uuid);
  await p.keyboard.press(`${mod}+a`); await p.keyboard.press("Backspace");
  assert.match((await changes(p)).at(-1).blocks[0].id, uuid);
});
