/*
 * Redraft 原型 · 图片与表格
 * 图片和表格各占一个段落位置，带稳定段落 ID，和文字段落一样参与排序、标记、版本与对比。
 *   图片：{ id, kind: 'img', text: 图注, img: { asset, w, alt, iw, ih } }
 *   表格：{ id, kind: 'table', text: 单元格文字（制表符分列、换行分行）, table: { cols, rows, head } }
 * text 始终是纯文字：图注和单元格文字因此可以走现有的逐词 Diff、溯源和字数统计；
 * 图片本身按整张处理，表格的行列以稳定 ID 对齐，结构变化单独成为一处修改。
 * 图片数据只存在本机浏览器：每张图单独存一项，文档里只记它的编号。
 */
(function (global) {
  'use strict';

  const uid = (prefix) => `${prefix}${Date.now().toString(36).slice(-3)}${Math.random().toString(36).slice(2, 6)}`;
  const isBlock = (p) => Boolean(p) && (p.kind === 'img' || p.kind === 'table');
  const WIDTHS = [
    { id: 's', label: '小' },
    { id: 'm', label: '中' },
    { id: 'l', label: '大' },
  ];
  const WIDTH_IDS = WIDTHS.map((w) => w.id);
  const MAX_ROWS = 40;
  const MAX_COLS = 8;

  const escText = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  const escAttr = (s) => escText(s).replace(/"/g, '&quot;');

  /* —— 图片数据 —— */

  const ASSET_KEY = 'redraft.asset.';
  const builtin = new Map();
  const cache = new Map();

  function registerAsset(id, url) { builtin.set(id, url); }

  function assetURL(id) {
    if (!id) return '';
    if (builtin.has(id)) return builtin.get(id);
    if (cache.has(id)) return cache.get(id);
    let v = null;
    try { v = global.localStorage && global.localStorage.getItem(ASSET_KEY + id); } catch (_) { /* 存储不可用 */ }
    if (v) cache.set(id, v);
    return v || '';
  }

  /** 存一张图，返回编号。存储空间不足时抛出 QuotaExceededError，由调用方提示。 */
  function saveAsset(url) {
    const id = uid('a');
    global.localStorage.setItem(ASSET_KEY + id, url);
    cache.set(id, url);
    return id;
  }

  function assetsIn(paras, set) {
    for (const p of paras || []) if (p && p.kind === 'img' && p.img && p.img.asset) set.add(p.img.asset);
    return set;
  }

  /** 清掉没有任何文章、版本引用的图片。只在启动时运行，此时没有撤销记录。 */
  function collectGarbage(data) {
    const ls = global.localStorage;
    if (!ls) return 0;
    const used = new Set();
    for (const a of data.articles || []) {
      assetsIn(a.paragraphs, used);
      for (const v of a.versions || []) assetsIn(v.paragraphs, used);
    }
    const stale = [];
    for (let i = 0; i < ls.length; i++) {
      const k = ls.key(i);
      if (k && k.startsWith(ASSET_KEY) && !used.has(k.slice(ASSET_KEY.length))) stale.push(k);
    }
    for (const k of stale) { try { ls.removeItem(k); } catch (_) { /* 忽略 */ } cache.delete(k.slice(ASSET_KEY.length)); }
    return stale.length;
  }

  /* —— 导入图片：只在本机读取、按需缩小，不上传 —— */

  const TYPES = new Set(['image/png', 'image/jpeg', 'image/gif', 'image/webp', 'image/avif', 'image/bmp', 'image/svg+xml']);
  const MAX_BYTES = 20 * 1024 * 1024;
  const MAX_EDGE = 1800;
  const KEEP_BYTES = 600 * 1024;

  class ImageError extends Error {}

  function readAsDataURL(file) {
    return new Promise((resolve, reject) => {
      const r = new FileReader();
      r.onload = () => resolve(r.result);
      r.onerror = () => reject(new ImageError('无法读取这张图片'));
      r.readAsDataURL(file);
    });
  }

  function decode(src) {
    return new Promise((resolve, reject) => {
      const img = new Image();
      img.onload = () => resolve(img);
      img.onerror = () => reject(new ImageError('无法读取这张图片'));
      img.src = src;
    });
  }

  /** 读出一张本地图片：返回 { url, iw, ih }，失败时抛出带简短说明的 ImageError。 */
  async function readImage(file) {
    if (!file) throw new ImageError('没有选择图片');
    if (!TYPES.has(file.type)) throw new ImageError(/^image\//.test(file.type) ? '不支持这种图片格式' : '只能插入图片文件');
    if (file.size > MAX_BYTES) throw new ImageError('图片太大，最多 20 MB');
    const src = await readAsDataURL(file);
    const img = await decode(src);
    let w = img.naturalWidth;
    let h = img.naturalHeight;
    const svg = file.type === 'image/svg+xml';
    if (!w || !h) {
      if (!svg) throw new ImageError('无法读取这张图片');
      w = 1200; h = 800;
    }
    const plain = /^image\/(png|jpeg|gif|webp)$/.test(file.type);
    if (svg || (plain && file.size <= KEEP_BYTES && Math.max(w, h) <= MAX_EDGE * 1.5)) return { url: src, iw: w, ih: h };
    const scale = Math.min(1, MAX_EDGE / Math.max(w, h));
    const cw = Math.max(1, Math.round(w * scale));
    const ch = Math.max(1, Math.round(h * scale));
    const canvas = document.createElement('canvas');
    canvas.width = cw;
    canvas.height = ch;
    const ctx = canvas.getContext('2d');
    if (!ctx) throw new ImageError('无法读取这张图片');
    ctx.drawImage(img, 0, 0, cw, ch);
    const alpha = file.type !== 'image/jpeg';
    let url = canvas.toDataURL(alpha ? 'image/webp' : 'image/jpeg', 0.86);
    if (alpha && !url.startsWith('data:image/webp')) url = canvas.toDataURL('image/png');
    return { url, iw: cw, ih: ch };
  }

  /* —— 表格 —— */

  function makeTable(rows, cols) {
    const r = Math.max(1, Math.min(MAX_ROWS, rows | 0));
    const c = Math.max(1, Math.min(MAX_COLS, cols | 0));
    const colIds = Array.from({ length: c }, () => uid('c'));
    return {
      cols: colIds,
      rows: Array.from({ length: r }, () => ({ id: uid('r'), cells: {} })),
      head: r > 1,
    };
  }

  const cellText = (t, row, colId) => {
    const r = typeof row === 'string' ? t.rows.find((x) => x.id === row) : row;
    return (r && r.cells && typeof r.cells[colId] === 'string') ? r.cells[colId] : '';
  };

  function tableText(t) {
    return t.rows.map((r) => t.cols.map((c) => cellText(t, r, c).replace(/[\t\n]+/g, ' ')).join('\t')).join('\n');
  }

  function syncText(p) {
    if (p.kind === 'table') p.text = tableText(p.table);
    return p;
  }

  function setCell(p, rowId, colId, text) {
    const r = p.table.rows.find((x) => x.id === rowId);
    if (!r) return p;
    if (text) r.cells[colId] = text;
    else delete r.cells[colId];
    return syncText(p);
  }

  function insertRow(p, at) {
    if (p.table.rows.length >= MAX_ROWS) return null;
    const row = { id: uid('r'), cells: {} };
    p.table.rows.splice(Math.max(0, Math.min(p.table.rows.length, at)), 0, row);
    syncText(p);
    return row.id;
  }

  function insertCol(p, at) {
    if (p.table.cols.length >= MAX_COLS) return null;
    const id = uid('c');
    p.table.cols.splice(Math.max(0, Math.min(p.table.cols.length, at)), 0, id);
    syncText(p);
    return id;
  }

  function removeRow(p, rowId) {
    if (p.table.rows.length <= 1) return false;
    p.table.rows = p.table.rows.filter((r) => r.id !== rowId);
    syncText(p);
    return true;
  }

  function removeCol(p, colId) {
    if (p.table.cols.length <= 1) return false;
    p.table.cols = p.table.cols.filter((c) => c !== colId);
    for (const r of p.table.rows) delete r.cells[colId];
    syncText(p);
    return true;
  }

  /* —— 复制与清理 —— */

  function cloneTable(t) {
    return {
      cols: [...t.cols],
      rows: t.rows.map((r) => ({ id: r.id, cells: Object.fromEntries(t.cols.filter((c) => typeof r.cells[c] === 'string' && r.cells[c]).map((c) => [c, r.cells[c]])) })),
      head: Boolean(t.head),
    };
  }

  function cloneBlock(p) {
    if (p.kind === 'img') {
      const i = p.img || {};
      const img = { asset: i.asset || null, w: WIDTH_IDS.includes(i.w) ? i.w : 'l', alt: String(i.alt || '') };
      if (i.iw > 0 && i.ih > 0) { img.iw = Math.round(i.iw); img.ih = Math.round(i.ih); }
      return { id: p.id, kind: 'img', text: String(p.text ?? '').replace(/\n/g, ' '), img };
    }
    const q = { id: p.id, kind: 'table', text: '', table: cloneTable(p.table) };
    return syncText(q);
  }

  const validId = (s) => typeof s === 'string' && /^[\w-]{1,40}$/.test(s);

  /** 读旧数据或外部数据：结构不完整的块返回 null，由调用方退回为文字段落。 */
  function sanitizeBlock(p) {
    if (!p || typeof p !== 'object') return null;
    if (p.kind === 'img') {
      if (!p.img || typeof p.img !== 'object') return null;
      if (p.img.asset !== null && p.img.asset !== undefined && !validId(p.img.asset)) return null;
      return cloneBlock(p);
    }
    if (p.kind === 'table') {
      const t = p.table;
      if (!t || !Array.isArray(t.cols) || !Array.isArray(t.rows) || !t.cols.length || !t.rows.length) return null;
      const cols = [...new Set(t.cols.filter(validId))].slice(0, MAX_COLS);
      const seen = new Set();
      const rows = [];
      for (const r of t.rows.slice(0, MAX_ROWS)) {
        if (!r || !validId(r.id) || seen.has(r.id)) continue;
        seen.add(r.id);
        const cells = {};
        for (const c of cols) if (r.cells && typeof r.cells[c] === 'string') cells[c] = r.cells[c];
        rows.push({ id: r.id, cells });
      }
      if (!cols.length || !rows.length) return null;
      return cloneBlock({ id: p.id, kind: 'table', table: { cols, rows, head: Boolean(t.head) } });
    }
    return null;
  }

  /** 只算排版、不算内容的部分：图片的显示宽度和替代文字、表格是否有标题行。 */
  function formatSig(p) {
    if (!isBlock(p)) return '';
    if (p.kind === 'img') return `img:${p.img.w}:${p.img.alt}`;
    return `table:${p.table.head ? 1 : 0}`;
  }

  /** 内容签名：图片本身。图注和表格文字已经在 text 里。 */
  const contentSig = (p) => (p && p.kind === 'img' ? `img:${(p.img && p.img.asset) || ''}` : '');

  /* —— 对齐两稿的行或列：按 ID 对齐，被删的排在它原来前一项之后 —— */

  function mergeOrder(baseIds, targetIds) {
    const inTarget = new Set(targetIds);
    const inBase = new Set(baseIds);
    const removedAfter = new Map();
    let anchor = null;
    for (const id of baseIds) {
      if (inTarget.has(id)) { anchor = id; continue; }
      const list = removedAfter.get(anchor) || [];
      list.push(id);
      removedAfter.set(anchor, list);
    }
    const out = [];
    const flush = (key) => { for (const id of removedAfter.get(key) || []) out.push({ id, status: 'remove' }); };
    flush(null);
    for (const id of targetIds) {
      out.push({ id, status: inBase.has(id) ? 'same' : 'add' });
      flush(id);
    }
    return out;
  }

  /* —— 导出 —— */

  function imgSrc(p) {
    return assetURL(p.img && p.img.asset);
  }

  const WIDTH_CSS = { s: '40%', m: '66%', l: '100%' };

  function exportHTML(p, opts = {}) {
    if (p.kind === 'img') {
      const src = imgSrc(p);
      const data = opts.data ? ` data-rd-block="1" data-rd-kind="img" data-rd-json="${escAttr(JSON.stringify({ img: p.img, text: p.text }))}"` : '';
      const ratio = p.img.iw && p.img.ih ? ` width="${p.img.iw}" height="${p.img.ih}"` : '';
      const img = src ? `<img src="${escAttr(src)}" alt="${escAttr(p.img.alt || p.text || '')}"${ratio} style="width:100%;height:auto">` : `<span>[图片不可用]</span>`;
      return `<figure${data} style="width:${WIDTH_CSS[p.img.w] || '100%'};max-width:100%;margin:0 auto 1em">${img}${p.text ? `<figcaption>${escText(p.text)}</figcaption>` : ''}</figure>`;
    }
    const t = p.table;
    const data = opts.data ? ` data-rd-block="1" data-rd-kind="table" data-rd-json="${escAttr(JSON.stringify({ table: t }))}"` : '';
    const cell = (tag, txt) => `<${tag}>${escText(txt).replace(/\n/g, '<br>')}</${tag}>`;
    const rows = t.rows.map((r, i) => {
      const tag = t.head && i === 0 ? 'th' : 'td';
      return `<tr>${t.cols.map((c) => cell(tag, cellText(t, r, c))).join('')}</tr>`;
    });
    const head = t.head ? `<thead>${rows[0]}</thead>` : '';
    const body = `<tbody>${(t.head ? rows.slice(1) : rows).join('')}</tbody>`;
    return `<table${data}>${head}${body}</table>`;
  }

  /** 读回本编辑器复制出的块。图片编号在本机找不到时，带上图片数据，由调用方重新存一份。 */
  function fromData(el) {
    let o = null;
    try { o = JSON.parse(el.getAttribute('data-rd-json') || 'null'); } catch (_) { return null; }
    if (!o) return null;
    const kind = el.getAttribute('data-rd-kind');
    if (kind === 'img') {
      const b = sanitizeBlock({ id: 'x', kind: 'img', text: o.text || '', img: o.img || {} });
      if (!b) return null;
      delete b.id;
      if (!assetURL(b.img.asset)) {
        const im = el.querySelector('img');
        const src = im && im.getAttribute('src');
        b.img.asset = null;
        if (src && /^data:image\//.test(src)) b.pendingSrc = src;
      }
      return b;
    }
    if (kind === 'table') {
      const b = sanitizeBlock({ id: 'x', kind: 'table', table: o.table });
      if (b) delete b.id;
      return b;
    }
    return null;
  }

  /** 新 ID 的副本，用于粘贴：表格的行列也换新 ID，避免同一篇里出现重复。 */
  function freshCopy(b) {
    const q = cloneBlock({ ...b, id: uid('p') });
    if (q.kind === 'table') {
      const map = new Map(q.table.cols.map((c) => [c, uid('c')]));
      q.table.cols = q.table.cols.map((c) => map.get(c));
      q.table.rows = q.table.rows.map((r) => ({ id: uid('r'), cells: Object.fromEntries(Object.entries(r.cells).map(([k, v]) => [map.get(k), v])) }));
      syncText(q);
    }
    return q;
  }

  const mdCell = (s) => s.replace(/\\/g, '\\\\').replace(/\|/g, '\\|').replace(/\n/g, '<br>') || ' ';

  /**
   * Markdown：图片写成 ![替代文字](图片数据)，图注另起一行斜体，显示宽度不保留；
   * 表格写成 GFM 表格，单元格里的换行写成 <br>；没有标题行时补一行空表头（GFM 要求表头）。
   */
  function toMarkdown(p) {
    if (p.kind === 'img') {
      const src = imgSrc(p);
      const alt = (p.img.alt || p.text || '图片').replace(/[[\]\\]/g, '\\$&');
      const img = src ? `![${alt}](${src})` : `*[图片不可用：${alt}]*`;
      return p.text ? `${img}\n\n*${p.text.replace(/([\\`*_~[\]<>])/g, '\\$1')}*` : img;
    }
    const t = p.table;
    const rows = t.rows.map((r) => `| ${t.cols.map((c) => mdCell(cellText(t, r, c))).join(' | ')} |`);
    const sep = `| ${t.cols.map(() => '---').join(' | ')} |`;
    if (t.head) return [rows[0], sep, ...rows.slice(1)].join('\n');
    return [`| ${t.cols.map(() => ' ').join(' | ')} |`, sep, ...rows].join('\n');
  }

  global.RedraftBlocks = {
    uid,
    isBlock,
    WIDTHS,
    MAX_ROWS,
    MAX_COLS,
    ImageError,
    registerAsset,
    assetURL,
    saveAsset,
    assetsIn,
    collectGarbage,
    readImage,
    makeTable,
    cellText,
    tableText,
    syncText,
    setCell,
    insertRow,
    insertCol,
    removeRow,
    removeCol,
    cloneBlock,
    sanitizeBlock,
    formatSig,
    contentSig,
    mergeOrder,
    exportHTML,
    fromData,
    freshCopy,
    toMarkdown,
  };
})(typeof window !== 'undefined' ? window : globalThis);
