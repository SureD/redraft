/*
 * Redraft 原型 · 富文本模型
 * 段落的 text 始终是纯文本，对比、改稿、溯源和改写范例都只看它。排版是叠在上面的两层：
 *   段落级  type（p / h1 / h2 / h3 / quote / ul / ol）、align、indent、lh
 *   字符级  runs = [{ n, b, i, u, s, f, z, c, h }]，n 之和等于 text.length；全是默认样式时省略
 * 文字变化时（AI 改稿、作者取舍）用同一套逐词对比把字符样式搬到新文字上，
 * 所以排版改动不会被算成文字修改，文字修改也不会丢掉排版。
 * 图片和表格段落（kind）没有段落样式和字符样式，它们的复制、清理、导出交给 RedraftBlocks。
 */
(function (global) {
  'use strict';

  const D = global.RedraftDiff;
  const B = global.RedraftBlocks;
  const isBlock = B.isBlock;

  const BLOCKS = [
    { id: 'p', label: '正文', size: 17, lh: 1.9 },
    { id: 'h1', label: '标题 1', size: 28, lh: 1.35 },
    { id: 'h2', label: '标题 2', size: 22, lh: 1.45 },
    { id: 'h3', label: '标题 3', size: 19, lh: 1.6 },
    { id: 'quote', label: '引用', size: 17, lh: 1.9 },
    { id: 'ul', label: '项目符号', size: 17, lh: 1.9 },
    { id: 'ol', label: '编号列表', size: 17, lh: 1.9 },
  ];
  const BLOCK = Object.fromEntries(BLOCKS.map((b) => [b.id, b]));
  const FONTS = [
    { id: '', label: '黑体', css: 'var(--font)', hex: '-apple-system, "PingFang SC", "Noto Sans CJK SC", "Microsoft YaHei", sans-serif' },
    { id: 'serif', label: '宋体', css: 'var(--font-serif)', hex: '"Songti SC", "STSong", "Noto Serif CJK SC", "Source Han Serif SC", Georgia, serif' },
    { id: 'kai', label: '楷体', css: 'var(--font-kai)', hex: '"Kaiti SC", "STKaiti", "KaiTi", "AR PL UKai CN", serif' },
    { id: 'mono', label: '等宽', css: 'var(--font-mono)', hex: 'ui-monospace, "SF Mono", Menlo, Consolas, monospace' },
  ];
  const SIZES = [12, 13, 14, 15, 16, 17, 18, 19, 20, 22, 24, 28, 32, 40];
  const COLORS = [
    { id: '', label: '默认', hex: 'inherit' },
    { id: 'gray', label: '灰色', hex: '#7a7a80' },
    { id: 'red', label: '红色', hex: '#c4314b' },
    { id: 'orange', label: '橙色', hex: '#b85a00' },
    { id: 'green', label: '绿色', hex: '#1f7a4a' },
    { id: 'blue', label: '蓝色', hex: '#2459d0' },
    { id: 'purple', label: '紫色', hex: '#7a3fc2' },
  ];
  const HIGHLIGHTS = [
    { id: '', label: '无', hex: 'transparent' },
    { id: 'yellow', label: '黄色', hex: 'rgba(255, 212, 0, 0.38)' },
    { id: 'green', label: '绿色', hex: 'rgba(52, 199, 89, 0.24)' },
    { id: 'blue', label: '蓝色', hex: 'rgba(10, 132, 255, 0.2)' },
    { id: 'pink', label: '粉色', hex: 'rgba(255, 55, 120, 0.18)' },
    { id: 'purple', label: '紫色', hex: 'rgba(175, 82, 222, 0.2)' },
  ];
  const ALIGNS = [
    { id: 'left', label: '左对齐' },
    { id: 'center', label: '居中' },
    { id: 'right', label: '右对齐' },
    { id: 'justify', label: '两端对齐' },
  ];
  const LINE_HEIGHTS = [1.35, 1.6, 1.9, 2.3];
  const INDENT_MAX = 6;

  const INLINE = ['b', 'i', 'u', 's', 'f', 'z', 'c', 'h'];
  const BOOL = ['b', 'i', 'u', 's'];
  const VALID = {
    f: new Set(FONTS.map((x) => x.id).filter(Boolean)),
    c: new Set(COLORS.map((x) => x.id).filter(Boolean)),
    h: new Set(HIGHLIGHTS.map((x) => x.id).filter(Boolean)),
  };

  const escText = (s) => String(s).replace(/[&<>\u00a0]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '\u00a0': '&nbsp;' }[c]));
  const escAttr = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

  /* —— 字符样式 —— */

  function attrsOf(r) {
    const o = {};
    for (const k of INLINE) if (r && r[k]) o[k] = r[k];
    return o;
  }
  const isPlain = (r) => INLINE.every((k) => !r[k]);
  const sameAttrs = (a, b) => INLINE.every((k) => (a[k] || null) === (b[k] || null));
  const total = (runs) => runs.reduce((n, r) => n + r.n, 0);

  function validAttrs(r) {
    const o = {};
    for (const k of BOOL) if (r[k]) o[k] = true;
    for (const k of ['f', 'c', 'h']) if (r[k] && VALID[k].has(r[k])) o[k] = r[k];
    const z = Number(r.z);
    if (z >= 8 && z <= 96) o.z = Math.round(z);
    return o;
  }

  /** 段落的完整 runs（覆盖全文）；runs 缺失或与文字长度对不上时按无样式处理。 */
  function runsOf(p) {
    const n = p.text.length;
    if (Array.isArray(p.runs) && p.runs.length && total(p.runs) === n) return p.runs.map((r) => ({ ...r }));
    return n ? [{ n }] : [];
  }

  function normalize(runs) {
    const out = [];
    for (const r of runs) {
      if (!r || !(r.n > 0)) continue;
      const a = { n: r.n, ...attrsOf(r) };
      const last = out[out.length - 1];
      if (last && sameAttrs(last, a)) last.n += a.n;
      else out.push(a);
    }
    return out;
  }

  function setRuns(p, runs) {
    const r = normalize(runs);
    if (r.length && total(r) === p.text.length && !r.every(isPlain)) p.runs = r;
    else delete p.runs;
    return p;
  }

  function slice(runs, s, e) {
    const out = [];
    let pos = 0;
    for (const r of runs) {
      const a = Math.max(s, pos);
      const b = Math.min(e, pos + r.n);
      if (b > a) out.push({ ...r, n: b - a });
      pos += r.n;
      if (pos >= e) break;
    }
    return out;
  }

  function charAttrs(runs, idx) {
    if (!runs.length) return {};
    let pos = 0;
    for (const r of runs) {
      if (idx < pos + r.n) return attrsOf(r);
      pos += r.n;
    }
    return attrsOf(runs[runs.length - 1]);
  }

  /** 在 off 处新输入的文字会带上的样式：跟随前一个字，段首则跟随第一个字。 */
  function attrsAt(p, off) {
    return charAttrs(runsOf(p), off > 0 ? off - 1 : 0);
  }

  function cutAt(runs, off) {
    let pos = 0;
    for (let i = 0; i < runs.length; i++) {
      const r = runs[i];
      if (off > pos && off < pos + r.n) {
        runs.splice(i, 1, { ...r, n: off - pos }, { ...r, n: pos + r.n - off });
        return;
      }
      pos += r.n;
    }
  }

  /** 对 [s, e) 应用样式变化；值为空表示恢复默认。 */
  function patch(p, s, e, change) {
    if (e <= s) return p;
    const runs = runsOf(p);
    cutAt(runs, s);
    cutAt(runs, e);
    let pos = 0;
    for (const r of runs) {
      if (pos >= s && pos + r.n <= e) {
        for (const k of Object.keys(change)) {
          if (change[k]) r[k] = change[k];
          else delete r[k];
        }
      }
      pos += r.n;
    }
    return setRuns(p, runs);
  }

  /** 在 off 处插入文字。style 可以是一组 runs，也可以是一组样式；省略时跟随 off 处的样式。 */
  function insert(p, off, text, style) {
    if (!text) return p;
    const add = Array.isArray(style) && total(style) === text.length ? style.map((r) => ({ ...r })) : [{ n: text.length, ...(style && !Array.isArray(style) ? attrsOf(style) : attrsAt(p, off)) }];
    const runs = runsOf(p);
    cutAt(runs, off);
    let pos = 0;
    let i = 0;
    while (i < runs.length && pos < off) { pos += runs[i].n; i++; }
    runs.splice(i, 0, ...add);
    p.text = p.text.slice(0, off) + text + p.text.slice(off);
    return setRuns(p, runs);
  }

  function remove(p, s, e) {
    if (e <= s) return p;
    const runs = runsOf(p);
    p.text = p.text.slice(0, s) + p.text.slice(e);
    return setRuns(p, [...slice(runs, 0, s), ...slice(runs, e, total(runs))]);
  }

  /** 在 off 处截断段落，返回被切下的后半部分 { text, runs }。 */
  function cut(p, off) {
    const runs = runsOf(p);
    const right = { text: p.text.slice(off), runs: normalize(slice(runs, off, total(runs))) };
    p.text = p.text.slice(0, off);
    setRuns(p, slice(runs, 0, off));
    return right;
  }

  function append(p, text, runs) {
    if (!text) return p;
    const add = runs && total(runs) === text.length ? runs : [{ n: text.length }];
    const base = runsOf(p);
    p.text += text;
    return setRuns(p, [...base, ...add]);
  }

  /** 文字从 from.text 改成 text 时搬运字符样式：相同的部分原样保留，替换的部分沿用被替换文字的样式。 */
  function carry(from, text) {
    const runs = runsOf(from);
    if (!runs.length || runs.every(isPlain) || !text) return [];
    if (from.text === text) return normalize(runs);
    const out = [];
    let o = 0;
    for (const s of D.diffText(from.text, text)) {
      if (s.type === 'eq') {
        out.push(...slice(runs, o, o + s.text.length));
        o += s.text.length;
        continue;
      }
      const a = charAttrs(runs, s.del ? o : Math.max(0, o - 1));
      if (s.ins) out.push({ n: s.ins.length, ...a });
      o += s.del.length;
    }
    const res = normalize(out);
    return total(res) === text.length ? res : [{ n: text.length, ...charAttrs(runs, 0) }];
  }

  /* —— 段落样式 —— */

  function blockOf(p) {
    const o = {};
    if (p.type && p.type !== 'p' && BLOCK[p.type]) o.type = p.type;
    if (p.align && p.align !== 'left' && ALIGNS.some((a) => a.id === p.align)) o.align = p.align;
    const ind = Math.round(Number(p.indent) || 0);
    if (ind > 0) o.indent = Math.min(INDENT_MAX, ind);
    if (p.lh && LINE_HEIGHTS.includes(Number(p.lh))) o.lh = Number(p.lh);
    return o;
  }

  function setBlock(p, change) {
    const next = { ...blockOf(p), ...change };
    for (const k of ['type', 'align', 'indent', 'lh']) delete p[k];
    Object.assign(p, blockOf(next));
    if (p.lh && p.lh === BLOCK[p.type || 'p'].lh) delete p.lh;
    return p;
  }

  const typeOf = (p) => (p.type && BLOCK[p.type] ? p.type : 'p');
  const defaultSize = (p) => BLOCK[typeOf(p)].size;
  const lineHeight = (p) => p.lh || BLOCK[typeOf(p)].lh;

  function clonePara(p) {
    if (isBlock(p)) return B.cloneBlock(p);
    const q = { id: p.id, text: String(p.text ?? ''), ...blockOf(p) };
    return setRuns(q, runsOf({ text: q.text, runs: p.runs }));
  }

  /** 读取旧数据或外部数据时使用：丢掉无效的样式，文字原样保留。结构不完整的图片或表格退回为文字段落。 */
  function sanitize(p) {
    if (p && p.kind) {
      const b = B.sanitizeBlock(p);
      if (b) return b;
    }
    const text = typeof p.text === 'string' ? p.text : String(p.text ?? '');
    const q = { id: p.id, text, ...blockOf(p) };
    if (Array.isArray(p.runs)) {
      const runs = p.runs.map((r) => ({ n: Math.max(0, Math.floor(Number(r && r.n) || 0)), ...validAttrs(r || {}) }));
      setRuns(q, runs);
    }
    return q;
  }

  /** 文字换成 text，段落样式不变，字符样式按逐词对比搬运。 */
  function retext(p, text) {
    const q = clonePara(p);
    if (isBlock(p)) {
      if (p.kind === 'img') q.text = text.replace(/\n/g, ' ');
      return q;
    }
    q.text = text;
    delete q.runs;
    return setRuns(q, carry(p, text));
  }

  function sameFormat(a, b) {
    if (!a || !b) return true;
    if (isBlock(a) || isBlock(b)) return B.formatSig(a) === B.formatSig(b);
    return JSON.stringify(blockOf(a)) === JSON.stringify(blockOf(b))
      && JSON.stringify(normalize(runsOf(a))) === JSON.stringify(normalize(runsOf(b)));
  }

  /* —— 编号 —— */

  function roman(n) {
    const map = [[10, 'x'], [9, 'ix'], [5, 'v'], [4, 'iv'], [1, 'i']];
    let out = '';
    for (const [v, s] of map) while (n >= v) { out += s; n -= v; }
    return out;
  }
  function numLabel(n, level) {
    const k = level % 3;
    if (k === 1) return `${String.fromCharCode(97 + ((n - 1) % 26))}.`;
    if (k === 2) return `${roman(n)}.`;
    return `${n}.`;
  }
  /** 编号列表的序号：连续的编号段落按缩进层级计数，被其他段落打断后重新开始。 */
  function numbering(paras) {
    const map = new Map();
    let counters = [];
    for (const p of paras) {
      const t = typeOf(p);
      const lv = blockOf(p).indent || 0;
      if (t === 'ol') {
        counters = counters.slice(0, lv + 1);
        counters[lv] = (counters[lv] || 0) + 1;
        map.set(p.id, numLabel(counters[lv], lv));
      } else if (t === 'ul') {
        counters = counters.slice(0, lv);
      } else {
        counters = [];
      }
    }
    return map;
  }

  /* —— 渲染 —— */

  function blockClass(p) {
    const b = blockOf(p);
    const cls = ['blk', `t-${b.type || 'p'}`];
    if (b.align) cls.push(`al-${b.align}`);
    if (b.indent) cls.push(`in-${b.indent}`);
    if (b.lh) cls.push(`lh-${String(b.lh).replace('.', '')}`);
    return cls.join(' ');
  }

  function wrap(r, html, opts) {
    let h = html;
    if (r.s) h = `<s>${h}</s>`;
    if (r.u) h = `<u>${h}</u>`;
    if (r.i) h = `<i>${h}</i>`;
    if (r.b) h = `<b>${h}</b>`;
    const cls = [];
    if (r.f) cls.push(`f-${r.f}`);
    if (r.c && !opts.noColor) cls.push(`c-${r.c}`);
    if (r.h && !opts.noColor) cls.push(`h-${r.h}`);
    if (cls.length || r.z) h = `<span${cls.length ? ` class="${cls.join(' ')}"` : ''}${r.z ? ` data-z="${r.z}" style="font-size:${r.z}px"` : ''}>${h}</span>`;
    return h;
  }

  /** 正文的规范 HTML。编辑器每次同步后都会与它比较，不一致就重绘，浏览器自行插入的样式因此不会留下。 */
  function inlineHTML(text, runs, opts = {}) {
    if (!text) return '';
    const rs = runs && total(runs) === text.length ? runs : [{ n: text.length }];
    let pos = 0;
    let out = '';
    for (const r of rs) {
      out += wrap(r, escText(text.slice(pos, pos + r.n)), opts);
      pos += r.n;
    }
    return out;
  }

  function sliceHTML(p, s, e, opts) {
    return inlineHTML(p.text.slice(s, e), slice(runsOf(p), s, e), opts);
  }

  /* —— 从 DOM 读回 —— */

  function ownAttrs(el, a) {
    const o = { ...a };
    const t = el.tagName;
    if (t === 'B' || t === 'STRONG') o.b = true;
    if (t === 'I' || t === 'EM') o.i = true;
    if (t === 'U') o.u = true;
    if (t === 'S' || t === 'STRIKE' || t === 'DEL') o.s = true;
    if (el.classList) {
      for (const c of el.classList) {
        const m = /^([fch])-([a-z]+)$/.exec(c);
        if (m && VALID[m[1]].has(m[2])) o[m[1]] = m[2];
      }
    }
    const z = el.getAttribute && Number(el.getAttribute('data-z'));
    if (z >= 8 && z <= 96) o.z = Math.round(z);
    return o;
  }

  /** 读出一个段落元素的文字和字符样式。只认本编辑器自己的标签和类名，忽略浏览器插入的行内样式。 */
  function parseInline(root, attrsFn = ownAttrs) {
    let text = '';
    const runs = [];
    const walk = (node, a) => {
      for (const ch of node.childNodes) {
        if (ch.nodeType === 3) {
          const t = ch.data.replace(/\u200b/g, '');
          if (t) { text += t; runs.push({ n: t.length, ...a }); }
        } else if (ch.nodeType === 1 && ch.tagName !== 'BR') {
          walk(ch, attrsFn(ch, a));
        }
      }
    };
    walk(root, {});
    return { text, runs: normalize(runs) };
  }

  /* —— 剪贴板 —— */

  function foreignAttrs(el, a) {
    const o = { ...a };
    const t = el.tagName;
    const st = el.style || {};
    if (t === 'B' || t === 'STRONG') o.b = true;
    if (t === 'I' || t === 'EM' || t === 'CITE') o.i = true;
    if (t === 'U' || t === 'INS') o.u = true;
    if (t === 'S' || t === 'STRIKE' || t === 'DEL') o.s = true;
    const w = st.fontWeight;
    if (w) {
      if (w === 'bold' || w === 'bolder' || Number(w) >= 600) o.b = true;
      else if (w === 'normal' || Number(w) <= 500) delete o.b;
    }
    if (st.fontStyle === 'italic') o.i = true;
    else if (st.fontStyle === 'normal') delete o.i;
    const deco = `${st.textDecoration || ''} ${st.textDecorationLine || ''}`;
    if (/underline/.test(deco)) o.u = true;
    if (/line-through/.test(deco)) o.s = true;
    return o;
  }

  function trimBlock(b) {
    const lead = b.text.length - b.text.replace(/^\s+/, '').length;
    const tail = b.text.length - b.text.replace(/\s+$/, '').length;
    if (!lead && !tail) return b;
    const end = b.text.length - tail;
    return { ...b, text: b.text.slice(lead, Math.max(lead, end)), runs: normalize(slice(b.runs, lead, Math.max(lead, end))) };
  }

  const BLOCK_TAGS = /^(P|DIV|H[1-6]|LI|BLOCKQUOTE|PRE|TR|SECTION|ARTICLE|HEADER|FOOTER|UL|OL|TABLE|TBODY|THEAD|DL|DT|DD|FIGURE|FIGCAPTION|ADDRESS|ASIDE|MAIN|NAV|HR)$/;
  const SKIP_TAGS = /^(STYLE|SCRIPT|META|TITLE|HEAD|NOSCRIPT|TEMPLATE|LINK|IMG|SVG|VIDEO|AUDIO|IFRAME|OBJECT|CANVAS|BUTTON|INPUT|SELECT|TEXTAREA)$/;

  function blockInfo(el, parent) {
    const t = el.tagName;
    const info = { type: parent.type === 'quote' ? 'quote' : 'p', indent: parent.indent || 0 };
    if (t === 'H1') info.type = 'h1';
    else if (t === 'H2') info.type = 'h2';
    else if (/^H[3-6]$/.test(t)) info.type = 'h3';
    else if (t === 'BLOCKQUOTE') info.type = 'quote';
    else if (t === 'LI') {
      const list = el.parentElement && el.parentElement.closest('ol, ul');
      info.type = list && list.tagName === 'OL' ? 'ol' : 'ul';
      let depth = 0;
      for (let n = el.parentElement; n; n = n.parentElement) if (n.tagName === 'OL' || n.tagName === 'UL') depth++;
      info.indent = Math.min(INDENT_MAX, Math.max(0, depth - 1));
    }
    const al = (el.style && el.style.textAlign) || el.getAttribute('align');
    if (al && ['center', 'right', 'justify'].includes(al)) info.align = al;
    else if (parent.align) info.align = parent.align;
    return info;
  }

  /**
   * 把剪贴板 HTML 读成段落。本编辑器复制出的内容带 data-rd-block，段落和字符样式完整还原；
   * 其他来源只保留粗体、斜体、下划线、删除线、标题、列表和引用，不带入外部的字体、颜色和字号。
   */
  function fromHTML(html) {
    if (!html || typeof DOMParser === 'undefined') return [];
    const doc = new DOMParser().parseFromString(html, 'text/html');
    const own = doc.querySelectorAll('[data-rd-block]');
    if (own.length) {
      return Array.from(own).map((el) => {
        if (el.hasAttribute('data-rd-kind')) return B.fromData(el);
        const { text, runs } = parseInline(el);
        const b = blockOf({ type: el.dataset.type, align: el.dataset.align, indent: el.dataset.indent, lh: el.dataset.lh });
        return { text, runs, ...b };
      }).filter(Boolean);
    }
    const blocks = [];
    let cur = null;
    const walk = (node, a, info) => {
      for (const ch of node.childNodes) {
        if (ch.nodeType === 3) {
          const t = ch.data.replace(/[\s\u00a0]+/g, ' ');
          if (!t || (t === ' ' && (!cur || !cur.text))) continue;
          if (!cur) { cur = { text: '', runs: [], ...info }; blocks.push(cur); }
          cur.text += t;
          cur.runs.push({ n: t.length, ...a });
          continue;
        }
        if (ch.nodeType !== 1 || SKIP_TAGS.test(ch.tagName)) continue;
        if (ch.tagName === 'BR') { cur = null; continue; }
        if (BLOCK_TAGS.test(ch.tagName)) {
          cur = null;
          walk(ch, foreignAttrs(ch, a), blockInfo(ch, info));
          cur = null;
        } else {
          walk(ch, foreignAttrs(ch, a), info);
        }
      }
    };
    walk(doc.body, {}, { type: 'p', indent: 0 });
    return blocks
      .map((b) => trimBlock({ ...b, runs: normalize(b.runs) }))
      .filter((b) => b.text)
      .map((b) => ({ text: b.text, runs: b.runs.map(validAttrs).map((x, i) => ({ n: b.runs[i].n, ...x })), ...blockOf(b) }));
  }

  function fromPlain(text) {
    return String(text || '').replace(/\r\n?/g, '\n').split('\n')
      .map((l) => l.replace(/\t/g, ' '))
      .filter((l) => l.trim())
      .map((l) => ({ text: l, runs: [] }));
  }

  /* —— 导出 —— */

  function styleAttr(parts) {
    const s = parts.filter(Boolean).join(';');
    return s ? ` style="${escAttr(s)}"` : '';
  }

  function exportInline(text, runs, opts) {
    if (!text) return '';
    const rs = runs && total(runs) === text.length ? runs : [{ n: text.length }];
    let pos = 0;
    let out = '';
    for (const r of rs) {
      let h = escText(text.slice(pos, pos + r.n));
      pos += r.n;
      if (r.s) h = `<s>${h}</s>`;
      if (r.u) h = `<u>${h}</u>`;
      if (r.i) h = `<em>${h}</em>`;
      if (r.b) h = `<strong>${h}</strong>`;
      if (r.f || r.c || r.h || r.z) {
        const cls = [r.f && `f-${r.f}`, r.c && `c-${r.c}`, r.h && `h-${r.h}`].filter(Boolean).join(' ');
        const css = [
          r.f && `font-family:${FONTS.find((x) => x.id === r.f).hex}`,
          r.c && `color:${COLORS.find((x) => x.id === r.c).hex}`,
          r.h && `background-color:${HIGHLIGHTS.find((x) => x.id === r.h).hex}`,
          r.z && `font-size:${r.z}px`,
        ];
        h = `<span${opts.data && cls ? ` class="${cls}"` : ''}${opts.data && r.z ? ` data-z="${r.z}"` : ''}${styleAttr(css)}>${h}</span>`;
      }
      out += h;
    }
    return out;
  }

  /** 语义化的 HTML 正文：列表合并成 ul / ol，对齐、缩进、行距写成行内样式，其他软件也能读懂。 */
  function bodyHTML(paras, opts = {}) {
    const out = [];
    let list = null;
    const close = () => { if (list) { out.push(`</${list}>`); list = null; } };
    for (const p of paras) {
      if (isBlock(p)) { close(); out.push(B.exportHTML(p, opts)); continue; }
      const b = blockOf(p);
      const type = b.type || 'p';
      const isList = type === 'ul' || type === 'ol';
      if (!isList || list !== type) close();
      if (!opts.data && !isList && !p.text.trim()) continue;
      if (isList && !list) { out.push(`<${type}>`); list = type; }
      const tag = { p: 'p', h1: 'h1', h2: 'h2', h3: 'h3', quote: 'blockquote', ul: 'li', ol: 'li' }[type];
      const css = [
        b.align && `text-align:${b.align}`,
        b.indent && `margin-left:${b.indent * 2}em`,
        b.lh && `line-height:${b.lh}`,
      ];
      const data = opts.data
        ? ` data-rd-block="1"${b.type ? ` data-type="${b.type}"` : ''}${b.align ? ` data-align="${b.align}"` : ''}${b.indent ? ` data-indent="${b.indent}"` : ''}${b.lh ? ` data-lh="${b.lh}"` : ''}`
        : '';
      out.push(`<${tag}${data}${styleAttr(css)}>${exportInline(p.text, p.runs, opts) || (opts.data ? '<br>' : '')}</${tag}>`);
    }
    close();
    return out.join('\n');
  }

  function clipboardHTML(blocks) {
    return `<div data-redraft="1">${bodyHTML(blocks.map((b, i) => ({ id: `c${i}`, ...b })), { data: true })}</div>`;
  }

  function htmlDocument(title, paras) {
    const t = escText(title || '无标题');
    return `<!doctype html>
<html lang="zh-Hans">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${t}</title>
<style>
  body { margin: 0; background: #fdfdfc; color: #1d1d1f; font: 17px/1.9 ${FONTS[0].hex}; }
  main { max-width: 38em; margin: 0 auto; padding: 56px 24px 96px; }
  .doc-title { font-size: 30px; line-height: 1.3; margin: 0 0 28px; }
  p, li { margin: 0 0 0.85em; }
  h1 { font-size: 28px; line-height: 1.35; margin: 1.2em 0 0.45em; }
  h2 { font-size: 22px; line-height: 1.45; margin: 1.15em 0 0.4em; }
  h3 { font-size: 19px; line-height: 1.6; margin: 1em 0 0.35em; }
  blockquote { margin: 0 0 0.85em; padding-left: 1em; border-left: 3px solid #d5d5da; color: #5f5f66; }
  ul, ol { margin: 0 0 0.85em; padding-left: 1.6em; }
  li { margin-bottom: 0.3em; }
  figure img { display: block; border-radius: 6px; }
  figcaption { margin-top: 6px; font-size: 14px; line-height: 1.6; color: #6e6e73; text-align: center; }
  table { width: 100%; border-collapse: collapse; margin: 0 0 1em; font-size: 15px; line-height: 1.6; }
  th, td { border: 1px solid #dcdcde; padding: 6px 10px; text-align: left; vertical-align: top; }
  th { background: #f3f3f2; font-weight: 600; }
  @media (prefers-color-scheme: dark) { body { background: #1e1e20; color: #ececef; } blockquote { border-color: #44444a; color: #a7a7ae; } th, td { border-color: #3a3a3e; } th { background: #29292c; } figcaption { color: #a7a7ae; } }
</style>
</head>
<body>
<main>
<h1 class="doc-title">${t}</h1>
${bodyHTML(paras)}
</main>
</body>
</html>
`;
  }

  function mdEsc(s) {
    return s.replace(/([\\`*_~[\]<>])/g, '\\$1');
  }
  function mdInline(text, runs) {
    const rs = normalize(runsOf({ text, runs }).map((r) => ({ n: r.n, b: r.b, i: r.i, s: r.s })));
    let pos = 0;
    let out = '';
    for (const r of rs) {
      const t = mdEsc(text.slice(pos, pos + r.n));
      pos += r.n;
      const m = /^(\s*)([\s\S]*?)(\s*)$/.exec(t);
      let core = m[2];
      if (!core || (!r.b && !r.i && !r.s)) { out += t; continue; }
      if (r.s) core = `~~${core}~~`;
      if (r.i) core = `*${core}*`;
      if (r.b) core = `**${core}**`;
      out += m[1] + core + m[3];
    }
    return out;
  }

  /** Markdown 只保留它能表达的：标题、引用、列表、粗体、斜体、删除线、图片和简单表格。 */
  function toMarkdown(title, paras) {
    const nums = numbering(paras);
    const lines = [`# ${title || '无标题'}`];
    let prevList = false;
    for (const p of paras) {
      if (isBlock(p)) { lines.push(`\n\n${B.toMarkdown(p)}`); prevList = false; continue; }
      if (!p.text.trim()) { prevList = false; continue; }
      const b = blockOf(p);
      const type = b.type || 'p';
      let body = mdInline(p.text, p.runs);
      const isList = type === 'ul' || type === 'ol';
      if (type === 'p' && /^(#{1,6}\s|>|[-+*]\s|\d+[.)]\s)/.test(body)) body = `\\${body}`;
      let line;
      if (type === 'h1') line = `## ${body}`;
      else if (type === 'h2') line = `### ${body}`;
      else if (type === 'h3') line = `#### ${body}`;
      else if (type === 'quote') line = `> ${body}`;
      else if (type === 'ul') line = `${'  '.repeat(b.indent || 0)}- ${body}`;
      else if (type === 'ol') line = `${'   '.repeat(b.indent || 0)}${/^\d/.test(nums.get(p.id)) ? nums.get(p.id) : '1.'} ${body}`;
      else line = body;
      lines.push(isList && prevList ? `\n${line}` : `\n\n${line}`);
      prevList = isList;
    }
    return `${lines.join('').replace(/^\n+/, '')}\n`;
  }

  /* —— 选区的排版状态 —— */

  const MIXED = null;

  function uniform(values) {
    const set = new Set(values);
    return set.size === 1 ? values[0] : MIXED;
  }

  /**
   * 选区（或光标处）的排版状态。布尔样式返回 true / false / 'mixed'；
   * 其余返回统一的值，不统一时返回 null。光标处有待用样式（pending）时以它为准。
   */
  function selectionState(paras, c, pending) {
    const i1 = paras.findIndex((p) => p.id === c.pid);
    let i2 = paras.findIndex((p) => p.id === (c.endPid || c.pid));
    if (i1 < 0) return null;
    if (i2 < i1) i2 = i1;
    let blocks = paras.slice(i1, i2 + 1);
    if (blocks.length > 1 && !c.collapsed && c.endOffset === 0) blocks = blocks.slice(0, -1);
    blocks = blocks.filter((p) => !isBlock(p));
    if (!blocks.length) return null;
    const chars = [];
    if (!c.collapsed) {
      blocks.forEach((p) => {
        const s = p.id === c.pid ? c.offset : 0;
        const e = paras.indexOf(p) === i2 ? c.endOffset : p.text.length;
        for (const r of slice(runsOf(p), s, e)) chars.push({ r, p });
      });
    }
    if (!chars.length) {
      const p = blocks[0];
      const a = { ...attrsAt(p, c.offset) };
      if (pending) for (const k of Object.keys(pending)) { if (pending[k]) a[k] = pending[k]; else delete a[k]; }
      chars.push({ r: { n: 1, ...a }, p });
    }
    const st = {};
    for (const k of BOOL) {
      const on = chars.filter((x) => x.r[k]).length;
      st[k] = on === chars.length ? true : on === 0 ? false : 'mixed';
    }
    st.f = uniform(chars.map((x) => x.r.f || ''));
    st.c = uniform(chars.map((x) => x.r.c || ''));
    st.h = uniform(chars.map((x) => x.r.h || ''));
    st.z = uniform(chars.map((x) => x.r.z || defaultSize(x.p)));
    st.type = uniform(blocks.map(typeOf));
    st.align = uniform(blocks.map((p) => p.align || 'left'));
    st.lh = uniform(blocks.map(lineHeight));
    st.indentMin = Math.min(...blocks.map((p) => blockOf(p).indent || 0));
    st.indentMax = Math.max(...blocks.map((p) => blockOf(p).indent || 0));
    st.blocks = blocks.map((p) => p.id);
    return st;
  }

  global.RedraftRich = {
    BLOCKS,
    BLOCK,
    FONTS,
    SIZES,
    COLORS,
    HIGHLIGHTS,
    ALIGNS,
    LINE_HEIGHTS,
    INDENT_MAX,
    INLINE,
    attrsOf,
    runsOf,
    normalize,
    setRuns,
    slice,
    charAttrs,
    attrsAt,
    patch,
    insert,
    remove,
    cut,
    append,
    carry,
    blockOf,
    setBlock,
    typeOf,
    defaultSize,
    lineHeight,
    isBlock,
    clonePara,
    sanitize,
    retext,
    sameFormat,
    numbering,
    blockClass,
    inlineHTML,
    sliceHTML,
    parseInline,
    fromHTML,
    fromPlain,
    clipboardHTML,
    bodyHTML,
    htmlDocument,
    toMarkdown,
    selectionState,
  };
})(typeof window !== 'undefined' ? window : globalThis);
