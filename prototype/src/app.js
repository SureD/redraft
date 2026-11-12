/*
 * Redraft 原型 · 界面
 * 写作 → 标记 → 模拟 AI 改稿 → 对照取舍 → 定稿 → 回看历史与一句话的来历 → 积累写作范例。
 */
(function () {
  'use strict';

  const D = window.RedraftDiff;
  const AI = window.RedraftMockAI;
  const S = window.RedraftSession;
  const R = window.RedraftRich;

  const STORAGE_KEY = 'redraft.prototype.v1';
  const PALETTE_KEY = 'redraft.palette';
  const isMac = /Mac|iPhone|iPad/i.test(navigator.platform || navigator.userAgent);
  const K = isMac
    ? { mod: '⌘', shift: '⇧', alt: '⌥', enter: '↩', up: '↑', down: '↓' }
    : { mod: 'Ctrl+', shift: 'Shift+', alt: 'Alt+', enter: 'Enter', up: '↑', down: '↓' };
  const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)');
  const mqNarrow = matchMedia('(max-width: 760px)');
  const mqMid = matchMedia('(max-width: 1099px)');

  const $ = (sel, root = document) => root.querySelector(sel);
  const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const icon = (id, cls = '') => `<svg class="icon ${cls}" aria-hidden="true"><use href="#${id}"/></svg>`;
  const clip = (s, n) => { const a = [...(s || '')]; return a.length > n ? `${a.slice(0, n).join('')}…` : (s || ''); };
  const charCount = (paras) => paras.reduce((n, p) => n + [...p.text.replace(/\s/g, '')].length, 0);

  const el = {
    app: $('#app'),
    sidebar: $('#sidebar'),
    list: $('#article-list'),
    search: $('#article-search'),
    examplesNav: $('#nav-examples'),
    examplesCount: $('#examples-count'),
    toolbar: $('#toolbar'),
    formatbar: $('#formatbar'),
    content: $('#content'),
    inspector: $('#inspector'),
    scrim: $('#scrim'),
    layer: $('#layer'),
    toasts: $('#toasts'),
    announcer: $('#announcer'),
  };

  /* ───────────────────────── 数据与持久化 ───────────────────────── */

  /*
   * 第 3 版数据是纯文本段落，原样可用：逐段清理无效的排版字段后升到第 4 版，文字和历史一律保留。
   * 升级时如果文库里还没有带排版的示例文章，就补上这一篇，其余文章不动。
   * 认不出的数据不会被覆盖：先另存一份备份，再从示例数据开始。
   */
  function migrate(d) {
    if (!d || !Array.isArray(d.articles) || (d.schema !== 3 && d.schema !== 4)) return null;
    for (const a of d.articles) {
      a.paragraphs = (a.paragraphs || []).map(R.sanitize);
      if (!a.paragraphs.length) a.paragraphs = [{ id: S.uid('p'), text: '' }];
      for (const v of a.versions || []) v.paragraphs = (v.paragraphs || []).map(R.sanitize);
      a.marks = a.marks || {};
      a.versions = a.versions || [];
      a.rounds = a.rounds || [];
    }
    if (d.schema === 3 && !d.articles.some((a) => a.id === 'art-diary')) {
      const diary = window.RedraftSamples.diary();
      d.articles.unshift(diary);
      d.currentId = diary.id;
    }
    d.schema = 4;
    if (d.prefs) delete d.prefs.display;
    return d;
  }

  function load() {
    let raw = null;
    try { raw = localStorage.getItem(STORAGE_KEY); } catch (_) { /* 存储不可用 */ }
    if (raw) {
      try {
        const m = migrate(JSON.parse(raw));
        if (m) return m;
      } catch (_) { /* 解析失败时走下面的备份 */ }
      try { localStorage.setItem(`${STORAGE_KEY}.backup-${Date.now()}`, raw); } catch (_) { /* 忽略 */ }
    }
    return window.RedraftSamples.build();
  }

  let data = load();
  let saveTimer = 0;
  function save() {
    clearTimeout(saveTimer);
    saveTimer = setTimeout(() => {
      try { localStorage.setItem(STORAGE_KEY, JSON.stringify({ ...data, prefs: { diffLayout: ui.diffLayout } })); } catch (_) { /* 忽略 */ }
    }, 250);
  }

  const ui = {
    view: 'article',
    mode: 'write',
    sidebarOpen: !mqNarrow.matches,
    inspectorOpen: false,
    inspectorTab: 'marks',
    diffLayout: (data.prefs && data.prefs.diffLayout) || 'inline',
    focusKey: null,
    showBar: false,
    compare: {},
    onlyChanges: true,
    exChoice: 'all',
    exTag: '',
    exQuery: '',
    articleQuery: '',
    running: null,
    caret: null,
    sel: null,
    hoverPid: null,
    provSel: null,
  };

  const current = () => data.articles.find((a) => a.id === data.currentId) || null;
  const isLocked = (a) => Boolean(a && S.activeRound(a));
  const inspectorVisible = () => ui.inspectorOpen && ui.view === 'article' && Boolean(current());

  function touch(a) { a.updatedAt = Date.now(); save(); }

  /* ───────────────────────── 时间格式 ───────────────────────── */

  const pad = (n) => String(n).padStart(2, '0');
  function fmt(ts, opts = {}) {
    if (!ts) return '';
    const d = new Date(ts);
    const now = new Date();
    const time = `${pad(d.getHours())}:${pad(d.getMinutes())}`;
    const day = new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
    const today = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
    let date;
    if (day === today) date = '今天';
    else if (today - day === 86_400_000) date = '昨天';
    else date = `${d.getFullYear() !== now.getFullYear() ? `${d.getFullYear()}年` : ''}${d.getMonth() + 1}月${d.getDate()}日`;
    return opts.dateOnly ? date : `${date} ${time}`;
  }

  /* ───────────────────────── 撤销 ───────────────────────── */

  const stacks = new Map();
  let lastUndoKind = null;
  let lastTypingAt = 0;
  let caretBeforeInput = null;

  function stackFor(id) {
    if (!stacks.has(id)) stacks.set(id, { undo: [], redo: [] });
    return stacks.get(id);
  }

  function pushUndo(label, opts = {}) {
    const a = current();
    if (!a) return;
    const st = stackFor(a.id);
    st.undo.push({ label, article: S.clone(a), mode: ui.mode, focusKey: ui.focusKey, caret: opts.caret !== undefined ? opts.caret : getCaret() });
    if (st.undo.length > 300) st.undo.shift();
    st.redo = [];
    lastUndoKind = opts.kind || label;
    syncFormatBar();
  }

  function restoreEntry(entry) {
    const idx = data.articles.findIndex((x) => x.id === entry.article.id);
    if (idx < 0) return;
    data.articles[idx] = entry.article;
    const pending = S.activeRound(entry.article);
    ui.mode = entry.mode === 'review' && !pending ? 'write' : entry.mode;
    ui.focusKey = entry.focusKey;
    save();
    renderAll();
    if (ui.mode === 'write' && entry.caret) {
      const c = entry.caret;
      if (c.endPid && !c.collapsed && restoreSel(c)) ui.sel = c;
      else setCaret(c.pid, c.offset);
    }
  }

  /* 撤销打字和排版时不弹提示，和系统编辑器一样安静；撤销送审、定稿这类大步骤时才提示，并给出重做。 */
  const LOUD_UNDO = new Set(['送审', '生成定稿', '存为版本', '移动段落', '采用改法', '保留原句', '自己重写', '取消决定', '本段全部采用', '本段全部保留']);

  function undo() {
    const a = current();
    if (!a) return;
    if (ui.running && ui.running.articleId === a.id) { toast('AI 正在改稿'); return; }
    const st = stackFor(a.id);
    const entry = st.undo.pop();
    if (!entry) { announce('没有可以撤销的操作'); return; }
    st.redo.push({ label: entry.label, article: S.clone(a), mode: ui.mode, focusKey: ui.focusKey, caret: getCaret() });
    lastUndoKind = null;
    pending = null;
    restoreEntry(entry);
    if (LOUD_UNDO.has(entry.label)) toast(`已撤销${entry.label}`, { action: { label: '重做', run: redo } });
    else announce(`已撤销${entry.label}`);
  }

  function redo() {
    const a = current();
    if (!a) return;
    const st = stackFor(a.id);
    const entry = st.redo.pop();
    if (!entry) { announce('没有可以重做的操作'); return; }
    st.undo.push({ label: entry.label, article: S.clone(a), mode: ui.mode, focusKey: ui.focusKey, caret: getCaret() });
    lastUndoKind = null;
    pending = null;
    restoreEntry(entry);
    announce(`已重做${entry.label}`);
  }

  /* ───────────────────────── 提示、朗读、浮层 ───────────────────────── */

  function announce(msg) {
    el.announcer.textContent = '';
    setTimeout(() => { el.announcer.textContent = msg; }, 30);
  }

  let toastTimer = 0;
  function toast(msg, opts = {}) {
    clearTimeout(toastTimer);
    el.toasts.innerHTML = '';
    const t = document.createElement('div');
    t.className = `toast${opts.action ? '' : ' no-action'}`;
    t.setAttribute('role', 'status');
    t.innerHTML = `<span>${esc(msg)}</span>${opts.action ? `<button type="button" class="btn">${esc(opts.action.label)}</button>` : ''}`;
    if (opts.action) {
      t.querySelector('button').addEventListener('click', () => { dismiss(); opts.action.run(); });
    }
    el.toasts.appendChild(t);
    function dismiss() {
      t.classList.add('leaving');
      setTimeout(() => t.remove(), reduceMotion.matches ? 0 : 200);
    }
    toastTimer = setTimeout(dismiss, opts.duration || (opts.action ? 6000 : 2600));
  }

  let popover = null;
  function closePopover(restoreFocus = true) {
    if (!popover) return;
    const { node, anchor, onClose, returnSel } = popover;
    popover = null;
    node.remove();
    if (anchor) anchor.setAttribute('aria-expanded', 'false');
    document.removeEventListener('pointerdown', onOutside, true);
    if (onClose) onClose();
    if (!restoreFocus) return;
    if (returnSel && restoreSel(returnSel)) return;
    if (anchor && document.contains(anchor)) anchor.focus({ preventScroll: true });
  }
  function onOutside(e) {
    if (popover && !popover.node.contains(e.target) && !(popover.anchor && popover.anchor.contains(e.target))) closePopover(false);
  }
  function openPopover(anchor, html, opts = {}) {
    closePopover(false);
    const ed = editorEl();
    const returnSel = ed && ed.isContentEditable && document.activeElement === ed ? editSel() : null;
    if (returnSel) ui.sel = returnSel;
    const node = document.createElement('div');
    node.className = `popover ${opts.className || ''}`;
    if (opts.role) node.setAttribute('role', opts.role);
    if (opts.label) node.setAttribute('aria-label', opts.label);
    node.innerHTML = html;
    el.layer.appendChild(node);
    const rect = (opts.rect || anchor.getBoundingClientRect());
    const w = node.offsetWidth;
    const h = node.offsetHeight;
    let left = opts.alignRight ? rect.right - w : rect.left;
    left = Math.max(10, Math.min(left, window.innerWidth - w - 10));
    let top = rect.bottom + 6;
    if (top + h > window.innerHeight - 10) top = Math.max(10, rect.top - h - 6);
    node.style.left = `${left}px`;
    node.style.top = `${top}px`;
    if (anchor) anchor.setAttribute('aria-expanded', 'true');
    popover = { node, anchor, onClose: opts.onClose, returnSel };
    setTimeout(() => document.addEventListener('pointerdown', onOutside, true), 0);
    node.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); closePopover(true); return; }
      if (e.key === 'Tab' && opts.trapTab) {
        const f = $$('button, input, select, textarea', node).filter((x) => !x.disabled);
        const i = f.indexOf(document.activeElement);
        if (e.shiftKey && i <= 0) { e.preventDefault(); f[f.length - 1].focus(); }
        else if (!e.shiftKey && i === f.length - 1) { e.preventDefault(); f[0].focus(); }
        return;
      }
      const items = $$('.menu-item:not(:disabled)', node);
      if (!items.length) return;
      const i = items.indexOf(document.activeElement);
      const grid = Boolean($('.palette', node));
      if (e.key === 'ArrowDown' || (grid && e.key === 'ArrowRight')) { e.preventDefault(); items[(i + 1) % items.length].focus(); }
      if (e.key === 'ArrowUp' || (grid && e.key === 'ArrowLeft')) { e.preventDefault(); items[(i - 1 + items.length) % items.length].focus(); }
      if (e.key === 'Home') { e.preventDefault(); items[0].focus(); }
      if (e.key === 'End') { e.preventDefault(); items[items.length - 1].focus(); }
      if (e.key === 'Tab') closePopover(false);
    });
    const first = (opts.focus && $(opts.focus, node)) || $('.menu-item:not(:disabled), textarea, input, button', node);
    if (first) first.focus({ preventScroll: true });
    return node;
  }

  function openMenu(anchor, items, opts = {}) {
    const html = `<div class="menu" role="menu">${items.map((it, i) => {
      if (it === '-') return '<div class="menu-sep" role="separator"></div>';
      if (it.label && it.heading) return `<div class="menu-label">${esc(it.label)}</div>`;
      const role = it.checked !== undefined ? 'menuitemradio' : 'menuitem';
      return `<button type="button" class="menu-item ${it.danger ? 'danger' : ''}" role="${role}" data-i="${i}" ${it.checked !== undefined ? `aria-checked="${it.checked}"` : ''} ${it.disabled ? 'disabled' : ''}>
        ${it.icon ? icon(it.icon) : ''}<span class="grow ${it.cls || ''}"${it.style ? ` style="${esc(it.style)}"` : ''}>${esc(it.label)}</span>${it.kbd ? `<kbd>${esc(it.kbd)}</kbd>` : ''}</button>`;
    }).join('')}</div>`;
    const node = openPopover(anchor, html, { focus: '.menu-item[aria-checked="true"]:not(:disabled)', ...opts });
    node.addEventListener('click', (e) => {
      const b = e.target.closest('.menu-item');
      if (!b) return;
      const it = items[Number(b.dataset.i)];
      closePopover(!it.keepFocusElsewhere);
      it.run();
    });
  }

  let dialogState = null;
  function openDialog({ title, body, actions, wide, onClose, init }) {
    closeDialog(null, true);
    const prev = document.activeElement;
    const back = document.createElement('div');
    back.className = 'dialog-backdrop';
    const id = `dlg-${Date.now()}`;
    back.innerHTML = `<div class="dialog ${wide ? 'wide' : ''}" role="dialog" aria-modal="true" aria-labelledby="${id}">
      <h2 id="${id}">${esc(title)}</h2>${body}
      <div class="actions">${(actions || []).map((a, i) => `<button type="button" class="btn ${a.primary ? 'primary' : ''}" data-i="${i}">${esc(a.label)}</button>`).join('')}</div></div>`;
    el.layer.appendChild(back);
    const dlg = $('.dialog', back);
    dialogState = { back, prev, onClose, actions };
    back.addEventListener('pointerdown', (e) => { if (e.target === back) closeDialog(null); });
    dlg.addEventListener('click', (e) => {
      const b = e.target.closest('.actions .btn');
      if (b) closeDialog(actions[Number(b.dataset.i)].value);
    });
    dlg.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); closeDialog(null); }
      if (e.key === 'Enter' && e.target.tagName === 'INPUT') {
        e.preventDefault();
        const primary = actions.find((a) => a.primary);
        if (primary) closeDialog(primary.value);
      }
      if (e.key === 'Tab') {
        const f = $$('button, input, select, textarea, a[href]', dlg).filter((x) => !x.disabled);
        if (!f.length) return;
        const i = f.indexOf(document.activeElement);
        if (e.shiftKey && i <= 0) { e.preventDefault(); f[f.length - 1].focus(); }
        else if (!e.shiftKey && i === f.length - 1) { e.preventDefault(); f[0].focus(); }
      }
    });
    if (init) init(dlg);
    const focusTarget = $('input', dlg) || $('.actions .btn.primary', dlg) || $('.actions .btn', dlg);
    if (focusTarget) focusTarget.focus();
    if ($('input', dlg)) $('input', dlg).select();
    return dlg;
  }
  function closeDialog(value, silent) {
    if (!dialogState) return;
    const { back, prev, onClose } = dialogState;
    const dlg = $('.dialog', back);
    const input = $('input', dlg);
    const inputValue = input ? input.value : undefined;
    dialogState = null;
    back.remove();
    if (silent) return;
    const fromEditor = prev && prev.id === 'editor';
    if (prev && document.contains(prev) && !fromEditor) prev.focus({ preventScroll: true });
    if (onClose) onClose(value, inputValue);
    if (dialogState) return;
    const lost = !document.activeElement || document.activeElement === document.body || !document.contains(document.activeElement);
    if (fromEditor && (lost || document.activeElement === editorEl())) {
      const s = editSel();
      if (!(s && restoreSel(s)) && prev && document.contains(prev)) prev.focus({ preventScroll: true });
    }
  }

  /* ───────────────────────── 布局 ───────────────────────── */

  function applyLayout() {
    el.app.classList.toggle('no-sidebar', !ui.sidebarOpen);
    el.app.classList.toggle('no-inspector', !inspectorVisible());
    el.app.dataset.mode = ui.view === 'examples' ? 'examples' : ui.mode;
    const fb = formatBarVisible();
    el.app.classList.toggle('has-fb', fb);
    el.formatbar.hidden = !fb;
    if (fb) syncFormatBar();
    el.scrim.hidden = !(mqNarrow.matches && ui.sidebarOpen);
    el.sidebar.toggleAttribute('inert', !ui.sidebarOpen);
    el.inspector.toggleAttribute('inert', !inspectorVisible());
  }

  function renderAll() {
    renderSidebar();
    renderToolbar();
    renderContent();
    renderInspector();
    applyLayout();
  }

  /* ───────────────────────── 文章库 ───────────────────────── */

  function articleStatus(a) {
    const r = S.activeRound(a);
    if (!r) return null;
    return r.status === 'running' ? { cls: 'running', label: '改稿中' } : { cls: '', label: '待审阅' };
  }

  function renderSidebar() {
    const q = ui.articleQuery.trim().toLowerCase();
    const arts = [...data.articles]
      .sort((x, y) => y.updatedAt - x.updatedAt)
      .filter((a) => !q || `${a.title} ${a.paragraphs.map((p) => p.text).join(' ')}`.toLowerCase().includes(q));
    if (!data.articles.length) {
      el.list.innerHTML = '<li class="small muted" style="padding:6px 10px">还没有文章</li>';
    } else if (!arts.length) {
      el.list.innerHTML = `<li class="small muted" style="padding:6px 10px">没有匹配“${esc(ui.articleQuery)}”的文章</li>`;
    } else {
      el.list.innerHTML = arts.map((a) => {
        const st = articleStatus(a);
        const snippet = (a.paragraphs.find((p) => p.text.trim()) || {}).text || '还没有正文';
        const curr = ui.view === 'article' && a.id === data.currentId;
        return `<li class="row-wrap">
          <button type="button" class="article-row" data-open="${a.id}" aria-current="${curr}">
            <span class="t">${esc(a.title || '无标题')}</span>
            ${st ? `<span class="badge ${st.cls}">${st.label}</span>` : '<span></span>'}
            <span class="s"><time>${fmt(a.updatedAt, { dateOnly: true })}</time>${esc(clip(snippet, 40))}</span>
          </button>
          <button type="button" class="icon-btn sm row-more" data-row-menu="${a.id}" aria-haspopup="menu" aria-expanded="false" aria-label="${esc(a.title || '无标题')}的更多操作">${icon('i-more')}</button>
        </li>`;
      }).join('');
    }
    const recs = S.allRecords(data.articles);
    el.examplesCount.textContent = recs.length ? String(recs.length) : '';
    el.examplesNav.setAttribute('aria-current', String(ui.view === 'examples'));
  }

  function openArticle(id, opts = {}) {
    if (data.currentId !== id || ui.view !== 'article') {
      closePopover(false);
      data.currentId = id;
      ui.view = 'article';
      const a = current();
      const r = a && S.activeRound(a);
      ui.mode = opts.mode || (r && r.status === 'pending' ? 'review' : 'write');
      ui.focusKey = null;
      ui.showBar = !(ui.inspectorOpen && a);
      ui.provSel = null;
      ui.caret = null;
      save();
    }
    if (mqNarrow.matches) ui.sidebarOpen = false;
    renderAll();
    if (ui.mode === 'write' && !opts.noFocus) focusEditorEnd();
  }

  function newArticle() {
    const a = {
      id: S.uid('art'),
      title: '',
      createdAt: Date.now(),
      updatedAt: Date.now(),
      paragraphs: [{ id: S.uid('p'), text: '' }],
      marks: {},
      versions: [],
      rounds: [],
    };
    data.articles.push(a);
    data.currentId = a.id;
    ui.view = 'article';
    ui.mode = 'write';
    if (mqNarrow.matches) ui.sidebarOpen = false;
    save();
    renderAll();
    const t = $('#title-input');
    if (t) t.focus();
    announce('已新建文章');
  }

  function deleteArticle(id) {
    const idx = data.articles.findIndex((a) => a.id === id);
    if (idx < 0) return;
    if (ui.running && ui.running.articleId === id) ui.running.controller.abort();
    const [removed] = data.articles.splice(idx, 1);
    const wasCurrent = data.currentId === id;
    if (wasCurrent) {
      const next = [...data.articles].sort((x, y) => y.updatedAt - x.updatedAt)[0];
      data.currentId = next ? next.id : null;
      ui.mode = 'write';
    }
    save();
    renderAll();
    toast(`已删除“${removed.title || '无标题'}”`, {
      action: {
        label: '撤销',
        run: () => {
          data.articles.splice(Math.min(idx, data.articles.length), 0, removed);
          if (wasCurrent) data.currentId = removed.id;
          save();
          renderAll();
          announce('已恢复文章');
        },
      },
    });
  }

  el.sidebar.addEventListener('click', (e) => {
    const open = e.target.closest('[data-open]');
    if (open) { openArticle(open.dataset.open); return; }
    const more = e.target.closest('[data-row-menu]');
    if (more) {
      const id = more.dataset.rowMenu;
      openMenu(more, [
        { label: '打开', icon: 'i-doc', run: () => openArticle(id) },
        { label: '导出 Markdown', icon: 'i-export', run: () => exportMarkdown(data.articles.find((a) => a.id === id)) },
        { label: '导出 HTML', icon: 'i-export', run: () => exportHTML(data.articles.find((a) => a.id === id)) },
        '-',
        { label: '删除文章', icon: 'i-trash', danger: true, run: () => deleteArticle(id) },
      ]);
    }
  });
  $('#new-article').addEventListener('click', newArticle);
  $('#sidebar-close').addEventListener('click', () => { ui.sidebarOpen = false; applyLayout(); renderToolbar(); });
  el.scrim.addEventListener('click', () => { ui.sidebarOpen = false; applyLayout(); renderToolbar(); });
  el.examplesNav.addEventListener('click', () => {
    ui.view = 'examples';
    closePopover(false);
    if (mqNarrow.matches) ui.sidebarOpen = false;
    renderAll();
    el.content.focus({ preventScroll: true });
  });
  el.search.addEventListener('input', () => { ui.articleQuery = el.search.value; renderSidebar(); });
  el.search.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && el.search.value) { e.stopPropagation(); el.search.value = ''; ui.articleQuery = ''; renderSidebar(); }
    if (e.key === 'Enter') { const first = $('[data-open]', el.list); if (first) openArticle(first.dataset.open); }
  });
  el.list.addEventListener('keydown', (e) => {
    if (e.key !== 'ArrowDown' && e.key !== 'ArrowUp') return;
    const rows = $$('.article-row', el.list);
    const i = rows.indexOf(document.activeElement);
    if (i < 0) return;
    e.preventDefault();
    const n = rows[Math.max(0, Math.min(rows.length - 1, i + (e.key === 'ArrowDown' ? 1 : -1)))];
    n.focus();
  });

  /* ───────────────────────── 工具栏 ───────────────────────── */

  function renderToolbar() {
    const a = current();
    const sidebarBtn = `<button type="button" class="icon-btn" id="tb-sidebar" aria-label="${ui.sidebarOpen ? '隐藏' : '显示'}文章库" aria-pressed="${ui.sidebarOpen}" title="文章库">${icon('i-sidebar')}</button>`;
    const more = `<button type="button" class="icon-btn" data-act="more" aria-haspopup="menu" aria-expanded="false" aria-label="更多" title="更多">${icon('i-more')}</button>`;
    if (ui.view === 'examples' || !a) {
      el.toolbar.innerHTML = `<div class="tb-start">${sidebarBtn}<span class="tb-title">${ui.view === 'examples' ? '改写范例' : ''}</span></div><div></div><div class="tb-end">${more}</div>`;
      renderFormatBar();
      return;
    }
    const round = S.activeRound(a);
    const pending = round && round.status === 'pending';
    const running = round && round.status === 'running';
    const markCount = Object.keys(a.marks).length;
    let primary = '';
    if (running) {
      primary = `<span class="tb-run" role="status"><span class="spinner" aria-hidden="true"></span><span class="hide-narrow">改稿中</span></span><button type="button" class="icon-btn" data-act="cancel-run" aria-label="取消改稿" title="取消改稿">${icon('i-x')}</button>`;
    } else if (ui.mode === 'write' && pending) {
      primary = `<button type="button" class="btn tinted" data-act="go-review">审阅</button>`;
    } else if (ui.mode === 'write' && markCount) {
      primary = `<button type="button" class="btn tinted" data-act="submit" title="请 AI 改稿（${K.mod}${K.enter}）" aria-label="请 AI 改稿，已标记 ${markCount} 段">${icon('i-revise', 'sm')}<span class="hide-narrow">改稿</span><span class="count">${markCount}</span></button>`;
    } else if (ui.mode === 'review' && pending) {
      primary = `<button type="button" class="btn primary" data-act="finish" title="完成本轮（${K.mod}${K.enter}）">完成</button>`;
    }
    const seg = (mode, label, extra = '') => `<button type="button" data-mode="${mode}" aria-pressed="${ui.mode === mode}">${label}${extra}</button>`;
    el.toolbar.innerHTML = `
      <div class="tb-start">${sidebarBtn}</div>
      <div class="segmented" role="group" aria-label="视图">
        ${seg('write', '写作')}${seg('review', '审阅', pending ? '<span class="pip" aria-label="（待审阅）"></span>' : '')}${seg('history', '历史')}
      </div>
      <div class="tb-end">
        ${primary}
        ${more}
        <button type="button" class="icon-btn" data-act="inspector" aria-pressed="${ui.inspectorOpen}" aria-label="${ui.inspectorOpen ? '隐藏' : '显示'}检查器" title="检查器">${icon('i-inspector')}</button>
      </div>`;
    renderFormatBar();
  }

  el.toolbar.addEventListener('click', (e) => {
    const b = e.target.closest('button');
    if (!b) return;
    if (b.id === 'tb-sidebar') { ui.sidebarOpen = !ui.sidebarOpen; applyLayout(); renderToolbar(); if (ui.sidebarOpen && mqNarrow.matches) el.search.focus(); return; }
    if (b.dataset.mode) { setMode(b.dataset.mode); return; }
    const act = b.dataset.act;
    if (act === 'submit') submitRound();
    if (act === 'go-review') setMode('review');
    if (act === 'finish') finishRound();
    if (act === 'cancel-run') cancelRun();
    if (act === 'inspector') { ui.inspectorOpen = !ui.inspectorOpen; ui.showBar = !ui.inspectorOpen; renderInspector(); applyLayout(); renderToolbar(); if (ui.mode === 'review') positionHunkBar(); requestAnimationFrame(renderGutter); }
    if (act === 'more') openMoreMenu(b);
  });

  function openMoreMenu(anchor) {
    const a = ui.view === 'article' ? current() : null;
    openMenu(anchor, [
      ...(a ? [
        { label: '导出 Markdown', icon: 'i-export', run: () => exportMarkdown(a) },
        { label: '导出 HTML', icon: 'i-export', run: () => exportHTML(a) },
        { label: '字数统计', icon: 'i-doc', run: () => showWordCount(a) },
        '-',
      ] : []),
      { label: '键盘快捷键', icon: 'i-keyboard', kbd: `${K.mod}/`, run: showShortcuts },
      { label: '关于此原型', icon: 'i-info', run: showAbout },
      '-',
      { label: '配色', heading: true },
      { label: '纸面', checked: palette() === 'paper', run: () => setPalette('paper') },
      { label: '上一版', checked: palette() === 'classic', run: () => setPalette('classic') },
      '-',
      { label: '恢复示例数据', icon: 'i-reset', run: resetSamples },
    ], { alignRight: true, focus: '.menu-item:not(:disabled)' });
  }

  function palette() {
    return document.documentElement.dataset.palette === 'classic' ? 'classic' : 'paper';
  }

  function setPalette(id) {
    if (id === 'classic') document.documentElement.dataset.palette = 'classic';
    else delete document.documentElement.dataset.palette;
    try { localStorage.setItem(PALETTE_KEY, id); } catch (_) { /* 忽略 */ }
    announce(id === 'classic' ? '已切换到上一版配色' : '已切换到纸面配色');
  }

  /* ───────────────────────── 排版工具栏 ─────────────────────────
   * 写作时常驻在窗口工具栏下方。左侧是排版，作用于选区或光标处，按下时不夺走正文焦点；
   * 右侧固定放 AI 标记和“更多”。窄屏时排版部分横向滚动，右侧不动。
   */

  const AK = isMac ? 'Meta' : 'Control';
  const formatBarVisible = () => ui.view === 'article' && ui.mode === 'write' && Boolean(current());
  const FB = {
    undo: { icon: 'i-undo', label: '撤销', kbd: `${K.mod}Z`, keys: `${AK}+Z` },
    redo: { icon: 'i-redo', label: '重做', kbd: `${K.mod}${K.shift}Z`, keys: `${AK}+Shift+Z` },
    style: { label: '样式', menu: true, val: '正文', w: 'w-style' },
    font: { label: '字体', menu: true, val: '黑体', w: 'w-font' },
    sizeDown: { icon: 'i-minus', label: '减小字号', kbd: `${K.mod}${K.shift},`, keys: `${AK}+Shift+Comma` },
    size: { label: '字号', menu: true, val: '17', w: 'w-size', noChevron: true },
    sizeUp: { icon: 'i-plus', label: '增大字号', kbd: `${K.mod}${K.shift}.`, keys: `${AK}+Shift+Period` },
    b: { glyph: 'B', label: '粗体', kbd: `${K.mod}B`, keys: `${AK}+B`, toggle: true },
    i: { glyph: 'I', label: '斜体', kbd: `${K.mod}I`, keys: `${AK}+I`, toggle: true },
    u: { glyph: 'U', label: '下划线', kbd: `${K.mod}U`, keys: `${AK}+U`, toggle: true },
    s: { glyph: 'S', label: '删除线', kbd: `${K.mod}${K.shift}X`, keys: `${AK}+Shift+X`, toggle: true },
    color: { label: '文字颜色', menu: true, swatch: 'a' },
    hl: { label: '突出显示', menu: true, swatch: 'marker' },
    align: { icon: 'i-al-left', label: '对齐', menu: true },
    lh: { icon: 'i-lh', label: '行距', menu: true },
    ul: { icon: 'i-ul', label: '项目符号', kbd: `${K.mod}${K.shift}8`, keys: `${AK}+Shift+8`, toggle: true },
    ol: { icon: 'i-ol', label: '编号列表', kbd: `${K.mod}${K.shift}7`, keys: `${AK}+Shift+7`, toggle: true },
    outdent: { icon: 'i-outdent', label: '减少缩进', kbd: `${K.mod}[`, keys: `${AK}+BracketLeft` },
    indent: { icon: 'i-indent', label: '增加缩进', kbd: `${K.mod}]`, keys: `${AK}+BracketRight` },
    clear: { icon: 'i-clear', label: '清除格式', kbd: `${K.mod}\\`, keys: `${AK}+Backslash` },
    mark: { icon: 'i-revise', label: '标记给 AI 改稿', kbd: `${K.mod}${K.shift}M`, keys: `${AK}+Shift+M`, menu: true },
    more: { icon: 'i-more', label: '更多', menu: true },
  };
  let fbRove = 'undo';

  function fbButton(id) {
    const it = FB[id];
    let inner = '';
    if (it.glyph) inner = `<span class="g g-${id}" aria-hidden="true">${it.glyph}</span>`;
    else if (it.swatch === 'a') inner = `<span class="fb-sw" aria-hidden="true"><span class="g g-a">A</span><i class="fb-bar"></i></span>`;
    else if (it.swatch === 'marker') inner = `<span class="fb-sw" aria-hidden="true">${icon('i-marker')}<i class="fb-bar"></i></span>`;
    else if (it.val) inner = `<span class="fb-val">${esc(it.val)}</span>`;
    else if (it.icon) inner = icon(it.icon);
    if (it.menu && !it.noChevron && id !== 'more') inner += icon('i-chevron-down', 'xs');
    const attrs = [
      `type="button"`,
      `class="fb-btn ${it.w || ''} ${it.menu && id !== 'more' ? 'fb-menu' : ''}"`,
      `data-fb="${id}"`,
      'tabindex="-1"',
      `aria-label="${esc(it.label)}"`,
      it.keys ? `aria-keyshortcuts="${it.keys}"` : '',
      it.menu ? 'aria-haspopup="menu" aria-expanded="false"' : '',
      it.toggle ? 'aria-pressed="false"' : '',
    ].filter(Boolean).join(' ');
    return `<button ${attrs}>${inner}</button>`;
  }

  function renderFormatBar() {
    const fb = el.formatbar;
    if (!formatBarVisible()) {
      if (fb.dataset.built) { fb.innerHTML = ''; delete fb.dataset.built; }
      hideTip();
      return;
    }
    if (!fb.dataset.built) {
      const g = (label, ids) => `<div class="fb-group" role="group" aria-label="${label}">${ids.map(fbButton).join('')}</div>`;
      const sep = '<span class="fb-sep" aria-hidden="true"></span>';
      fb.innerHTML = `
        <div class="fb-scroll" id="fb-scroll">
          ${g('撤销', ['undo', 'redo'])}${sep}
          ${g('样式', ['style'])}${sep}
          ${g('字体与字号', ['font', 'sizeDown', 'size', 'sizeUp'])}${sep}
          ${g('文字样式', ['b', 'i', 'u', 's', 'color', 'hl'])}${sep}
          ${g('段落', ['align', 'lh', 'ul', 'ol', 'outdent', 'indent'])}${sep}
          ${g('清除', ['clear'])}
        </div>
        <div class="fb-end">
          <span class="fb-lock" id="fb-lock" hidden>${icon('i-lock', 'xs')}<span></span></span>
          ${fbButton('mark')}${fbButton('more')}
        </div>`;
      fb.dataset.built = '1';
      $('#fb-scroll', fb).addEventListener('scroll', () => { hideTip(); updateFbFade(); if (popover && popover.anchor && fb.contains(popover.anchor)) closePopover(false); }, { passive: true });
    }
    syncFormatBar();
    updateFbFade();
  }

  function updateFbFade() {
    const sc = $('#fb-scroll', el.formatbar);
    if (!sc) return;
    const max = sc.scrollWidth - sc.clientWidth;
    sc.classList.toggle('fade-l', sc.scrollLeft > 2);
    sc.classList.toggle('fade-r', max - sc.scrollLeft > 2);
  }

  function fbSet(id, o) {
    const b = el.formatbar.querySelector(`[data-fb="${id}"]`);
    if (!b) return;
    const dis = o.disabled ? 'true' : 'false';
    if (b.getAttribute('aria-disabled') !== dis) b.setAttribute('aria-disabled', dis);
    if (o.pressed !== undefined) {
      const v = o.pressed === 'mixed' ? 'mixed' : String(Boolean(o.pressed));
      if (b.getAttribute('aria-pressed') !== v) b.setAttribute('aria-pressed', v);
    }
    const label = o.label || FB[id].label;
    if (b.getAttribute('aria-label') !== label) b.setAttribute('aria-label', label);
    b.dataset.tip = o.tip || label;
    if (o.val !== undefined) { const v = $('.fb-val', b); if (v && v.textContent !== String(o.val)) v.textContent = o.val; }
    if (o.icon) { const u = $('use', b); if (u && u.getAttribute('href') !== `#${o.icon}`) u.setAttribute('href', `#${o.icon}`); }
    if (o.bar !== undefined) b.style.setProperty('--bar', o.bar);
  }

  const colorVar = (key, id) => (id ? `var(--${key === 'c' ? 'tc' : 'hc'}-${id})` : key === 'c' ? 'currentColor' : 'transparent');

  function fbState() {
    const a = current();
    if (!a || isLocked(a)) return null;
    const c = editSel();
    if (!c) return null;
    return { a, c, st: R.selectionState(a.paragraphs, c, pendingFor(c)) };
  }

  function syncFormatBar() {
    if (!el.formatbar.dataset.built || !formatBarVisible()) return;
    const a = current();
    const round = S.activeRound(a);
    const running = Boolean(round && round.status === 'running');
    const locked = Boolean(round);
    const stk = stackFor(a.id);
    const s = fbState();
    const st = s && s.st;
    const off = !st;
    const lastUndo = stk.undo[stk.undo.length - 1];
    const lastRedo = stk.redo[stk.redo.length - 1];
    fbSet('undo', { disabled: running || !lastUndo, label: lastUndo ? `撤销${lastUndo.label}` : '撤销' });
    fbSet('redo', { disabled: running || !lastRedo, label: lastRedo ? `重做${lastRedo.label}` : '重做' });

    const styleType = st && (st.type === 'ul' || st.type === 'ol' ? 'p' : st.type);
    fbSet('style', { disabled: off, val: !st ? '正文' : styleType === null ? '—' : R.BLOCK[styleType].label, label: st && styleType ? `样式：${R.BLOCK[styleType].label}` : '样式' });
    const font = st && st.f !== null ? R.FONTS.find((f) => f.id === st.f) : null;
    fbSet('font', { disabled: off, val: !st ? '黑体' : font ? font.label : '—', label: font ? `字体：${font.label}` : '字体' });
    const z = st ? st.z : 17;
    fbSet('size', { disabled: off, val: z === null ? '—' : z, label: z === null ? '字号' : `字号：${z}` });
    fbSet('sizeDown', { disabled: off || (z !== null && z <= R.SIZES[0]) });
    fbSet('sizeUp', { disabled: off || (z !== null && z >= R.SIZES[R.SIZES.length - 1]) });
    for (const k of ['b', 'i', 'u', 's']) fbSet(k, { disabled: off, pressed: st ? st[k] : false });
    const cl = st && st.c !== null ? R.COLORS.find((x) => x.id === st.c) : null;
    fbSet('color', { disabled: off, bar: st && st.c !== null ? colorVar('c', st.c) : 'transparent', label: cl && cl.id ? `文字颜色：${cl.label}` : '文字颜色' });
    const hl = st && st.h !== null ? R.HIGHLIGHTS.find((x) => x.id === st.h) : null;
    fbSet('hl', { disabled: off, bar: st && st.h ? colorVar('h', st.h) : 'transparent', label: hl && hl.id ? `突出显示：${hl.label}` : '突出显示' });
    const al = st && st.align ? st.align : 'left';
    fbSet('align', { disabled: off, icon: `i-al-${al}`, label: `对齐：${R.ALIGNS.find((x) => x.id === al).label}` });
    fbSet('lh', { disabled: off, label: st && st.lh ? `行距：${st.lh}` : '行距' });
    fbSet('ul', { disabled: off, pressed: Boolean(st && st.type === 'ul') });
    fbSet('ol', { disabled: off, pressed: Boolean(st && st.type === 'ol') });
    fbSet('outdent', { disabled: off || st.indentMax === 0 });
    fbSet('indent', { disabled: off || st.indentMin >= R.INDENT_MAX });
    fbSet('clear', { disabled: off });

    const pids = s ? selectedPids(a, s.c).filter((pid) => a.paragraphs.find((p) => p.id === pid).text.trim()) : [];
    const marks = pids.map((pid) => a.marks[pid]).filter(Boolean);
    const allMarked = pids.length > 0 && marks.length === pids.length;
    const labels = new Set(marks.map((m) => S.instructionLabel(m)));
    fbSet('mark', {
      disabled: locked || !pids.length,
      pressed: allMarked,
      label: allMarked ? `已标记：${labels.size === 1 ? [...labels][0] : '多种要求'}` : '标记给 AI 改稿',
    });
    el.formatbar.querySelector('[data-fb="mark"]').classList.toggle('is-on', allMarked);

    const lock = $('#fb-lock', el.formatbar);
    lock.hidden = !locked;
    if (locked) $('span', lock).textContent = running ? '改稿中' : '待审阅';

    const items = fbItems();
    const enabled = (b) => b.getAttribute('aria-disabled') !== 'true';
    const inside = el.formatbar.contains(document.activeElement);
    const pick = items.find((b) => b.dataset.fb === fbRove && (inside || enabled(b))) || items.find(enabled) || items[0];
    items.forEach((b) => { b.tabIndex = b === pick ? 0 : -1; });
  }

  let syncQueued = false;
  function queueSyncFormatBar() {
    if (syncQueued) return;
    syncQueued = true;
    requestAnimationFrame(() => { syncQueued = false; syncFormatBar(); });
  }

  const fbItems = () => $$('.fb-btn', el.formatbar).filter((b) => b.offsetParent !== null);
  function focusFb(b) {
    if (!b) return;
    fbItems().forEach((x) => { x.tabIndex = x === b ? 0 : -1; });
    fbRove = b.dataset.fb;
    b.focus({ preventScroll: true });
    b.scrollIntoView({ block: 'nearest', inline: 'nearest' });
  }
  function focusFormatBar() {
    const items = fbItems();
    focusFb(items.find((b) => b.dataset.fb === fbRove && b.getAttribute('aria-disabled') !== 'true') || items.find((b) => b.getAttribute('aria-disabled') !== 'true') || items[0]);
  }
  function returnToEditor() {
    const s = editSel();
    if (s && restoreSel(s)) return;
    const ed = editorEl();
    if (ed && ed.isContentEditable) focusEditorEnd();
    else el.content.focus({ preventScroll: true });
  }

  function runFormat(id, b) {
    const a = current();
    if (!a) return;
    switch (id) {
      case 'undo': undo(); break;
      case 'redo': redo(); break;
      case 'style': openStyleMenu(b); break;
      case 'font': openFontMenu(b); break;
      case 'size': openSizeMenu(b); break;
      case 'sizeDown': stepSize(-1); break;
      case 'sizeUp': stepSize(1); break;
      case 'b': case 'i': case 'u': case 's': toggleInline(id); break;
      case 'color': openPalette(b, 'c'); break;
      case 'hl': openPalette(b, 'h'); break;
      case 'align': openAlignMenu(b); break;
      case 'lh': openLineHeightMenu(b); break;
      case 'ul': case 'ol': toggleList(id); break;
      case 'indent': indentBlocks(1); break;
      case 'outdent': indentBlocks(-1); break;
      case 'clear': clearFormat(); break;
      case 'mark': openInstrMenu(b); break;
      case 'more': openFbMore(b); break;
      default: break;
    }
  }

  /* 按下时不夺走正文焦点，选区和光标原样保留；输入法组字时放行，让浏览器先把候选文字上屏。 */
  let fbDownFromEditor = false;
  el.formatbar.addEventListener('mousedown', (e) => {
    if (!e.target.closest('.fb-btn')) return;
    fbDownFromEditor = document.activeElement === editorEl();
    if (!composing) e.preventDefault();
  });
  el.formatbar.addEventListener('click', (e) => {
    const b = e.target.closest('.fb-btn');
    if (!b) return;
    hideTip();
    const viaKeyboard = e.detail === 0;
    const fromEditor = !viaKeyboard && fbDownFromEditor;
    fbDownFromEditor = false;
    if (b.getAttribute('aria-disabled') === 'true') {
      if (fromEditor && document.activeElement !== editorEl()) returnToEditor();
      return;
    }
    if (composing) { if (fromEditor) returnToEditor(); return; }
    fbRove = b.dataset.fb;
    if (fromEditor && document.activeElement !== editorEl()) returnToEditor();
    runFormat(b.dataset.fb, b);
    if (viaKeyboard && !popover && !dialogState) {
      const again = fbItems().find((x) => x.dataset.fb === fbRove);
      if (again && again.getAttribute('aria-disabled') !== 'true') focusFb(again);
      else focusFormatBar();
    }
  });
  el.formatbar.addEventListener('keydown', (e) => {
    const b = e.target.closest('.fb-btn');
    if (!b) return;
    const items = fbItems();
    const i = items.indexOf(b);
    if (e.key === 'ArrowRight') { e.preventDefault(); focusFb(items[(i + 1) % items.length]); }
    else if (e.key === 'ArrowLeft') { e.preventDefault(); focusFb(items[(i - 1 + items.length) % items.length]); }
    else if (e.key === 'Home') { e.preventDefault(); focusFb(items[0]); }
    else if (e.key === 'End') { e.preventDefault(); focusFb(items[items.length - 1]); }
    else if (e.key === 'ArrowDown' && b.hasAttribute('aria-haspopup')) { e.preventDefault(); b.click(); }
    else if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); hideTip(); returnToEditor(); }
  });

  /* —— 工具提示：名称和快捷键，悬停片刻或键盘聚焦时显示 —— */

  let tipEl = null;
  let tipTimer = 0;
  let tipWarmUntil = 0;
  function showTip(b) {
    clearTimeout(tipTimer);
    if (tipEl) tipEl.remove();
    if (!b.dataset.tip || !document.contains(b)) { tipEl = null; return; }
    const kbd = FB[b.dataset.fb] && FB[b.dataset.fb].kbd;
    tipEl = document.createElement('div');
    tipEl.className = 'tip';
    tipEl.setAttribute('aria-hidden', 'true');
    tipEl.dataset.for = b.dataset.fb;
    tipEl.innerHTML = `<span>${esc(b.dataset.tip)}</span>${kbd ? `<kbd>${esc(kbd)}</kbd>` : ''}`;
    el.layer.appendChild(tipEl);
    const r = b.getBoundingClientRect();
    const w = tipEl.offsetWidth;
    tipEl.style.left = `${Math.max(8, Math.min(r.left + r.width / 2 - w / 2, window.innerWidth - w - 8))}px`;
    tipEl.style.top = `${r.bottom + 6}px`;
  }
  function hideTip() {
    clearTimeout(tipTimer);
    if (tipEl) { tipEl.remove(); tipEl = null; tipWarmUntil = Date.now() + 500; }
  }
  el.formatbar.addEventListener('pointerover', (e) => {
    const b = e.target.closest('.fb-btn');
    if (!b || e.pointerType === 'touch' || popover) return;
    if (tipEl && tipEl.dataset.for === b.dataset.fb) return;
    clearTimeout(tipTimer);
    const warm = tipEl || Date.now() < tipWarmUntil;
    tipTimer = setTimeout(() => showTip(b), warm ? 0 : 600);
  });
  el.formatbar.addEventListener('pointerout', (e) => {
    const b = e.target.closest('.fb-btn');
    if (b && !b.contains(e.relatedTarget)) hideTip();
  });
  el.formatbar.addEventListener('focusin', (e) => {
    const b = e.target.closest('.fb-btn');
    if (b && b.matches(':focus-visible') && !popover) showTip(b);
  });
  el.formatbar.addEventListener('focusout', hideTip);

  /* —— 工具栏的菜单 —— */

  function openStyleMenu(b) {
    const s = fbState();
    const cur = s && s.st.type;
    const kb = (n) => `${K.mod}${K.alt}${n}`;
    openMenu(b, [
      { label: '正文', cls: 'sty sty-p', checked: cur === 'p' || cur === 'ul' || cur === 'ol', kbd: kb(0), run: () => setBlockType('p') },
      { label: '标题 1', cls: 'sty sty-h1', checked: cur === 'h1', kbd: kb(1), run: () => setBlockType('h1') },
      { label: '标题 2', cls: 'sty sty-h2', checked: cur === 'h2', kbd: kb(2), run: () => setBlockType('h2') },
      { label: '标题 3', cls: 'sty sty-h3', checked: cur === 'h3', kbd: kb(3), run: () => setBlockType('h3') },
      { label: '引用', cls: 'sty sty-quote', checked: cur === 'quote', run: () => setBlockType('quote') },
    ], { className: 'menu-pop' });
  }

  function openFontMenu(b) {
    const s = fbState();
    const cur = s ? s.st.f : '';
    openMenu(b, R.FONTS.map((f) => ({ label: f.label, style: `font-family:${f.css}`, checked: cur === f.id, run: () => formatInline({ f: f.id || null }, '字体') })));
  }

  function openSizeMenu(b) {
    const s = fbState();
    const cur = s ? s.st.z : null;
    openMenu(b, R.SIZES.map((z) => ({ label: String(z), checked: cur === z, run: () => setSize(z) })), { className: 'menu-narrow' });
  }

  function openPalette(b, key) {
    const s = fbState();
    const cur = s ? s.st[key] : null;
    const list = key === 'c' ? R.COLORS : R.HIGHLIGHTS;
    const label = key === 'c' ? '文字颜色' : '突出显示';
    const html = `<div class="palette" role="menu" aria-label="${label}">${list.map((x, i) => `<button type="button" class="menu-item swatch ${x.id ? '' : 'is-none'} k-${key}" role="menuitemradio" aria-checked="${cur === x.id}" data-i="${i}" aria-label="${esc(x.label)}" title="${esc(x.label)}" style="--sw:${colorVar(key, x.id)}"></button>`).join('')}</div>`;
    const node = openPopover(b, html, { className: 'palette-pop', focus: '.swatch[aria-checked="true"]' });
    node.addEventListener('click', (e) => {
      const sw = e.target.closest('.swatch');
      if (!sw) return;
      const id = list[Number(sw.dataset.i)].id;
      closePopover(true);
      formatInline({ [key]: id || null }, label);
    });
  }

  function openAlignMenu(b) {
    const s = fbState();
    const cur = s ? s.st.align : 'left';
    const kb = { left: 'L', center: 'E', right: 'R', justify: 'J' };
    openMenu(b, R.ALIGNS.map((x) => ({ label: x.label, icon: `i-al-${x.id}`, checked: cur === x.id, kbd: `${K.mod}${K.shift}${kb[x.id]}`, run: () => setAlign(x.id) })));
  }

  function openLineHeightMenu(b) {
    const s = fbState();
    const cur = s ? s.st.lh : null;
    openMenu(b, R.LINE_HEIGHTS.map((v) => ({ label: String(v), checked: cur === v, run: () => setLineHeight(v) })), { className: 'menu-narrow' });
  }

  function openFbMore(b) {
    const a = current();
    const c = editSel();
    const locked = isLocked(a);
    const idx = c ? a.paragraphs.findIndex((p) => p.id === c.pid) : -1;
    const span = c && selectedPids(a, c).length > 1;
    const provOn = inspectorVisible() && ui.inspectorTab === 'prov';
    openMenu(b, [
      { label: '上移段落', icon: 'i-arrow-up', kbd: `${K.alt}${K.shift}${K.up}`, disabled: locked || !c || span || idx <= 0, run: () => moveParagraph(c.pid, idx - 1, 'toolbar') },
      { label: '下移段落', icon: 'i-arrow-down', kbd: `${K.alt}${K.shift}${K.down}`, disabled: locked || !c || span || idx >= a.paragraphs.length - 1, run: () => moveParagraph(c.pid, idx + 1, 'toolbar') },
      '-',
      { label: '存为版本…', icon: 'i-bookmark', kbd: `${K.mod}S`, disabled: locked, run: saveVersion },
      { label: provOn ? '收起这句话的来历' : '这句话的来历', icon: 'i-history', run: toggleProvenance },
    ], { alignRight: true });
  }

  function openInstrMenu(b) {
    const a = current();
    const c = editSel();
    const pids = c ? selectedPids(a, c).filter((pid) => a.paragraphs.find((p) => p.id === pid).text.trim()) : [];
    if (!pids.length) return;
    const marks = pids.map((pid) => a.marks[pid]);
    const anyMarked = marks.some(Boolean);
    const first = marks[0];
    const same = marks.every((m) => m && first && m.instruction === first.instruction && (m.custom || '') === (first.custom || '')) ? first : null;
    const total = Object.keys(a.marks).length;
    const items = [
      { label: pids.length > 1 ? `修改要求 · ${pids.length} 段` : '修改要求', heading: true },
      ...AI.INSTRUCTIONS.map((it) => ({ label: it.label, checked: Boolean(same && !same.custom && same.instruction === it.id), run: () => applyMarks(pids, it.id) })),
      { label: same && same.custom ? `自定义：${clip(same.custom, 10)}` : '自定义…', checked: Boolean(same && same.custom), run: () => customInstruction(pids) },
    ];
    const selMarked = marks.filter(Boolean).length;
    if (anyMarked || total > selMarked) items.push('-');
    if (anyMarked) items.push({ label: '取消标记', icon: 'i-x', run: () => applyMarks(pids, null) });
    if (total > selMarked) items.push({ label: `取消全部标记（${total}）`, run: clearAllMarks });
    openMenu(b, items, { alignRight: true });
  }

  function toggleProvenance() {
    if (inspectorVisible() && ui.inspectorTab === 'prov') {
      ui.inspectorTab = 'marks';
      if (mqMid.matches) ui.inspectorOpen = false;
      clearHighlight('prov');
      renderInspector();
      applyLayout();
      renderToolbar();
      return;
    }
    openProvenance();
  }

  el.content.addEventListener('focusin', (e) => {
    if (e.target.id === 'title-input') { ui.sel = null; paintGhost(); syncFormatBar(); }
  });

  function setMode(mode) {
    const a = current();
    if (!a) return;
    closePopover(false);
    ui.mode = mode;
    ui.showBar = !inspectorVisible();
    if (mode !== 'write') clearHighlight('prov');
    renderAll();
    if (mode === 'review') focusHunk(ui.focusKey, { scroll: true });
    if (mode === 'write') {
      const ed = $('#editor');
      if (ed && ed.isContentEditable) focusEditorEnd();
    }
  }

  /* ───────────────────────── 内容区 ───────────────────────── */

  function renderContent() {
    const a = current();
    const keepScroll = el.content.scrollTop;
    el.content.onscroll = null;
    if (ui.view === 'examples') renderExamples();
    else if (!a) renderNoArticle();
    else if (ui.mode === 'review') renderReview(a);
    else if (ui.mode === 'history') renderHistory(a);
    else renderWrite(a);
    const markScrolled = () => {
      const s = el.content.scrollTop > 4;
      el.toolbar.classList.toggle('scrolled', s);
      el.formatbar.classList.toggle('scrolled', s);
    };
    el.content.onscroll = () => { markScrolled(); hideTip(); };
    if (renderContent.sameView === `${ui.view}:${data.currentId}:${ui.mode}`) el.content.scrollTop = keepScroll;
    else el.content.scrollTop = 0;
    renderContent.sameView = `${ui.view}:${data.currentId}:${ui.mode}`;
    markScrolled();
  }

  function renderNoArticle() {
    el.content.innerHTML = `<div class="empty full">
      <div class="glyph">${icon('i-doc')}</div>
      <h3>还没有文章</h3>
      <button type="button" class="btn primary" id="empty-new" style="margin-top:6px">${icon('i-compose', 'sm')}新建文章</button>
    </div>`;
    $('#empty-new').addEventListener('click', newArticle);
  }

  /* ───────────────────────── 写作 ───────────────────────── */

  function renderWrite(a) {
    const round = S.activeRound(a);
    el.content.innerHTML = `
      <div class="page">
        <div class="meta-line" id="meta-line"></div>
        <textarea class="title-input" id="title-input" rows="1" placeholder="标题" aria-label="标题" ${round ? 'readonly' : ''}>${esc(a.title)}</textarea>
        <div class="editor-wrap" id="editor-wrap">
          <div class="editor" id="editor" contenteditable="${round ? 'false' : 'true'}" role="textbox" aria-multiline="true" aria-label="正文" spellcheck="true" ${round ? 'aria-readonly="true"' : ''}></div>
          <div class="gutter" id="gutter"></div>
        </div>
      </div>`;
    autosizeTitle();
    renderEditorParas();
    renderMeta();
    edResize.disconnect();
    edResize.observe($('#editor'));
  }

  function renderMeta() {
    const a = current();
    const m = $('#meta-line');
    if (!a || !m) return;
    const r = S.activeRound(a);
    const state = r ? `<span class="locked">${icon('i-lock', 'xs')}${r.status === 'running' ? '改稿中' : '待审阅'}</span>` : '';
    const html = `<time>${fmt(a.updatedAt)}</time>${state}`;
    if (m.innerHTML !== html) m.innerHTML = html;
  }

  function autosizeTitle() {
    const t = $('#title-input');
    if (!t) return;
    t.style.height = 'auto';
    t.style.height = `${t.scrollHeight}px`;
  }

  const editorEl = () => $('#editor');

  function paraOpen(p, nums) {
    const n = nums.get(p.id);
    return `<p data-pid="${p.id}" class="${R.blockClass(p)}"${n ? ` data-num="${n}"` : ''}>`;
  }

  function renderEditorParas() {
    const a = current();
    const ed = editorEl();
    if (!a || !ed) return;
    const nums = R.numbering(a.paragraphs);
    ed.innerHTML = a.paragraphs.map((p) => `${paraOpen(p, nums)}${R.inlineHTML(p.text, p.runs) || '<br>'}</p>`).join('');
    updateDecor();
    if (document.activeElement !== ed) paintGhost();
  }

  function updateDecor() {
    const a = current();
    const ed = editorEl();
    if (!a || !ed) return;
    const only = a.paragraphs.length === 1;
    const run = ui.running && ui.running.articleId === a.id ? ui.running : null;
    $$('p', ed).forEach((p) => {
      const pid = p.dataset.pid;
      const empty = !p.textContent;
      p.classList.toggle('is-marked', Boolean(a.marks[pid]));
      p.classList.toggle('is-empty', empty);
      p.classList.toggle('is-revising', Boolean(run && run.current === pid));
      if (empty && only && p.classList.contains('t-p')) p.dataset.placeholder = '开始写作';
      else delete p.dataset.placeholder;
    });
    renderGutter();
  }

  function renderGutter() {
    const a = current();
    const ed = editorEl();
    const g = $('#gutter');
    if (!a || !ed || !g) return;
    const locked = isLocked(a);
    const run = ui.running && ui.running.articleId === a.id ? ui.running : null;
    const html = [];
    $$('p', ed).forEach((p) => {
      const pid = p.dataset.pid;
      const mark = a.marks[pid];
      if (!locked) {
        const show = ui.hoverPid === pid;
        const lineTop = p.offsetTop + Math.max(0, (parseFloat(getComputedStyle(p).lineHeight) || 30) / 2 - 13);
        html.push(`<div class="g-item ${show ? 'show' : ''}" data-pid="${pid}" style="top:${lineTop}px"><button type="button" class="g-btn g-handle" data-drag="${pid}" tabindex="-1" aria-hidden="true" title="拖动以移动段落">${icon('i-grip', 'sm')}</button></div>`);
      }
      if (mark) {
        const st = run ? run.status[pid] : '';
        const tip = `${S.instructionLabel(mark)}${st === 'run' ? ' · 改稿中' : st === 'done' ? ' · 已改完' : ''}`;
        html.push(`<button type="button" class="g-bar ${st ? `is-${st}` : ''}" data-chip="${pid}" tabindex="-1" aria-hidden="true" title="${esc(tip)}" style="top:${p.offsetTop}px;height:${p.offsetHeight}px" ${locked ? 'disabled' : ''}></button>`);
      }
    });
    g.innerHTML = html.join('');
  }

  function refreshGutterVisibility() {
    $$('.g-item').forEach((it) => it.classList.toggle('show', ui.hoverPid === it.dataset.pid));
  }

  const edResize = new ResizeObserver(() => renderGutter());

  /* —— 光标与选区（偏移量与 JS 字符串一致，按 UTF-16 计数）—— */

  function paraOf(node) {
    const e = node && (node.nodeType === 1 ? node : node.parentElement);
    const p = e && e.closest('p[data-pid]');
    return p && p.parentElement && p.parentElement.id === 'editor' ? p : null;
  }
  function offsetIn(p, node, off) {
    const r = document.createRange();
    r.selectNodeContents(p);
    try { r.setEnd(node, off); } catch (_) { return 0; }
    return r.toString().length;
  }
  function getCaret() {
    const ed = editorEl();
    const sel = window.getSelection();
    if (!ed || !sel || !sel.rangeCount) return null;
    const r = sel.getRangeAt(0);
    if (!ed.contains(r.startContainer)) return null;
    let sp = paraOf(r.startContainer);
    let ep = paraOf(r.endContainer);
    if (!sp) sp = ed.querySelector('p');
    if (!ep) ep = sp;
    if (!sp) return null;
    return {
      pid: sp.dataset.pid,
      offset: paraOf(r.startContainer) ? offsetIn(sp, r.startContainer, r.startOffset) : 0,
      endPid: ep.dataset.pid,
      endOffset: paraOf(r.endContainer) ? offsetIn(ep, r.endContainer, r.endOffset) : 0,
      collapsed: r.collapsed,
    };
  }
  function rangeIn(p, start, end) {
    const range = document.createRange();
    const walker = document.createTreeWalker(p, NodeFilter.SHOW_TEXT);
    let pos = 0;
    let node;
    let last = null;
    let startSet = false;
    while ((node = walker.nextNode())) {
      const len = node.data.length;
      if (!startSet && start <= pos + len) { range.setStart(node, start - pos); startSet = true; }
      if (startSet && end <= pos + len) { range.setEnd(node, end - pos); return range; }
      pos += len;
      last = node;
    }
    if (!last) { range.setStart(p, 0); range.setEnd(p, 0); return range; }
    if (!startSet) range.setStart(last, last.data.length);
    range.setEnd(last, last.data.length);
    return range;
  }
  function setCaret(pid, offset, endOffset) {
    const ed = editorEl();
    const p = ed && ed.querySelector(`p[data-pid="${CSS.escape(pid)}"]`);
    if (!p) return;
    if (ed.isContentEditable) ed.focus({ preventScroll: true });
    const sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(rangeIn(p, offset, endOffset !== undefined ? endOffset : offset));
    scrollRangeIntoView(sel.getRangeAt(0), p);
    ui.caret = { pid, offset };
    refreshGutterVisibility();
  }
  function scrollRangeIntoView(range, fallback) {
    let rect = range.getBoundingClientRect();
    if (!rect || (!rect.height && fallback)) rect = fallback.getBoundingClientRect();
    const box = el.content.getBoundingClientRect();
    const topLimit = box.top + el.toolbar.offsetHeight + (formatBarVisible() ? el.formatbar.offsetHeight : 0) + 12;
    const bottomLimit = box.bottom - 48;
    if (rect.bottom > bottomLimit) el.content.scrollTop += rect.bottom - bottomLimit + 24;
    else if (rect.top < topLimit) el.content.scrollTop -= topLimit - rect.top + 24;
  }
  /* 最近一次在正文里的选区。焦点移到工具栏、弹层或对话框后，操作仍作用于它，结束后再放回原处。 */
  function editSel() {
    const a = current();
    const act = document.activeElement;
    if (act && (act.tagName === 'INPUT' || act.tagName === 'TEXTAREA') && act.closest('#content')) return null;
    const live = getCaret();
    if (live) return live;
    const s = ui.sel;
    if (!a || !s) return null;
    const has = (pid) => a.paragraphs.some((p) => p.id === pid);
    if (!has(s.pid)) return null;
    return has(s.endPid) ? s : { ...s, endPid: s.pid, endOffset: s.offset, collapsed: true };
  }
  function restoreSel(c) {
    const ed = editorEl();
    if (!ed || !ed.isContentEditable || !c) return false;
    const sp = ed.querySelector(`p[data-pid="${CSS.escape(c.pid)}"]`);
    if (!sp) return false;
    const ep = ed.querySelector(`p[data-pid="${CSS.escape(c.endPid || c.pid)}"]`) || sp;
    const a = current();
    const clamp = (pid, n) => { const p = a.paragraphs.find((x) => x.id === pid); return Math.min(n || 0, p ? p.text.length : 0); };
    const start = rangeIn(sp, clamp(c.pid, c.offset), clamp(c.pid, c.offset));
    const end = rangeIn(ep, clamp(ep.dataset.pid, c.endOffset), clamp(ep.dataset.pid, c.endOffset));
    const range = document.createRange();
    range.setStart(start.startContainer, start.startOffset);
    range.setEnd(end.startContainer, end.startOffset);
    ed.focus({ preventScroll: true });
    const sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(range);
    return true;
  }
  function selectedPids(a, c) {
    if (!a || !c) return [];
    const i1 = a.paragraphs.findIndex((p) => p.id === c.pid);
    let i2 = a.paragraphs.findIndex((p) => p.id === (c.endPid || c.pid));
    if (i1 < 0) return [];
    if (i2 < i1) i2 = i1;
    let ids = a.paragraphs.slice(i1, i2 + 1);
    if (ids.length > 1 && !c.collapsed && c.endOffset === 0) ids = ids.slice(0, -1);
    return ids.map((p) => p.id);
  }

  function focusEditorEnd() {
    const a = current();
    const ed = editorEl();
    if (!a || !ed || !ed.isContentEditable) return;
    const last = a.paragraphs[a.paragraphs.length - 1];
    if (!last) return;
    const prevScroll = el.content.scrollTop;
    setCaret(last.id, last.text.length);
    el.content.scrollTop = prevScroll;
  }

  /* —— DOM → 段落模型同步（输入法组字期间不同步，确认上屏后再同步）——
   * 每段都读回文字和本编辑器自己的字符样式；读回的结果若与规范 HTML 不同（浏览器自行插入了样式或结构），就按模型重绘。
   */

  let composing = false;
  let pending = null;
  let pendingBeforeInput = null;

  /** 光标处待用的字符样式：在光标处点了粗体等按钮、但还没输入文字时保存在这里。 */
  function pendingFor(c) {
    return c && c.collapsed && pending && pending.pid === c.pid && pending.offset === c.offset ? pending.patch : null;
  }

  function desiredAttrs(op, off, extra) {
    const want = { ...R.attrsAt(op, off) };
    if (extra) for (const k of Object.keys(extra)) { if (extra[k]) want[k] = extra[k]; else delete want[k]; }
    const change = {};
    for (const k of R.INLINE) change[k] = want[k] || null;
    return change;
  }

  const AUTO_BLOCK = /^(?:([-*•])|(1[.)])|(#{1,3})) /;

  function syncFromDOM() {
    const a = current();
    const ed = editorEl();
    if (!a || !ed || composing) return;
    const sel = window.getSelection();
    let caretIdx = -1;
    let caretOff = 0;
    const caret = getCaret();
    const prevById = new Map(a.paragraphs.map((p) => [p.id, p]));
    const out = [];
    const seen = new Set();
    let structural = false;
    for (const node of Array.from(ed.childNodes)) {
      if (node.nodeType === 3) {
        const t = node.data.replace(/\u200b/g, '');
        if (!t) continue;
        structural = true;
        if (out.length) R.append(out[out.length - 1], t);
        else out.push({ id: S.uid('p'), text: t });
        continue;
      }
      if (node.nodeType !== 1) continue;
      if (node.tagName !== 'P') structural = true;
      const srcId = node.dataset && node.dataset.pid;
      let id = srcId;
      if (!id || seen.has(id)) { id = S.uid('p'); structural = true; }
      seen.add(id);
      if (sel && sel.rangeCount && node.contains(sel.getRangeAt(0).startContainer)) {
        caretIdx = out.length;
        caretOff = offsetIn(node, sel.getRangeAt(0).startContainer, sel.getRangeAt(0).startOffset);
      }
      const { text, runs } = R.parseInline(node);
      const prev = prevById.get(srcId);
      const para = { id, text, ...(prev ? R.blockOf(prev) : {}) };
      R.setRuns(para, runs);
      if (node.tagName === 'P' && node.innerHTML !== (R.inlineHTML(para.text, para.runs) || '<br>')) structural = true;
      out.push(para);
    }
    if (!out.length) { out.push({ id: (a.paragraphs[0] && a.paragraphs[0].id) || S.uid('p'), text: '', ...(a.paragraphs[0] ? R.blockOf(a.paragraphs[0]) : {}) }); structural = true; caretIdx = 0; }

    const before = caretBeforeInput;
    if (before && before.collapsed && caretIdx >= 0) {
      const np = out[caretIdx];
      const op = prevById.get(np.id);
      const d = op ? np.text.length - op.text.length : 0;
      const off = before.offset;
      if (op && np.id === before.pid && d > 0 && np.text.slice(0, off) === op.text.slice(0, off) && np.text.slice(off + d) === op.text.slice(off)) {
        const was = JSON.stringify(np.runs || null);
        R.patch(np, off, off + d, desiredAttrs(op, off, pendingBeforeInput));
        if (JSON.stringify(np.runs || null) !== was) structural = true;
      }
    }

    const sig = (p) => `${p.id}\u0001${p.text}\u0001${JSON.stringify(p.runs || null)}`;
    const changed = out.length !== a.paragraphs.length || out.some((p, i) => sig(p) !== sig(a.paragraphs[i]));
    if (changed) {
      const now = Date.now();
      if (lastUndoKind !== 'typing' || now - lastTypingAt > 1500) pushUndo('输入', { kind: 'typing', caret: caretBeforeInput || caret });
      lastTypingAt = now;
      a.paragraphs = out;
      pending = null;
      for (const pid of Object.keys(a.marks)) if (!out.some((p) => p.id === pid)) delete a.marks[pid];

      const np = caretIdx >= 0 ? out[caretIdx] : null;
      const m = np && before && before.collapsed && before.pid === np.id && R.typeOf(np) === 'p' ? AUTO_BLOCK.exec(np.text) : null;
      if (m && caretOff === m[0].length && before.offset === m[0].length - 1) {
        const type = m[1] ? 'ul' : m[2] ? 'ol' : ['h1', 'h2', 'h3'][m[3].length - 1];
        pushUndo(type === 'ul' ? '项目符号' : type === 'ol' ? '编号列表' : '段落样式', { caret: { pid: np.id, offset: caretOff, endPid: np.id, endOffset: caretOff, collapsed: true } });
        lastUndoKind = null;
        R.remove(np, 0, m[0].length);
        R.setBlock(np, { type });
        caretOff = 0;
        structural = true;
      }
      touch(a);
    }
    if (structural) {
      renderEditorParas();
      const target = out[Math.max(0, caretIdx)] || out[0];
      setCaret(target.id, caretIdx >= 0 ? Math.min(caretOff, target.text.length) : 0);
    } else if (changed) {
      updateDecor();
    }
    if (changed) afterTextChange();
  }

  let afterTimer = 0;
  function afterTextChange() {
    renderMeta();
    queueSyncFormatBar();
    clearTimeout(afterTimer);
    afterTimer = setTimeout(() => {
      renderSidebar();
      renderToolbar();
      if (inspectorVisible()) renderInspector();
    }, 160);
  }

  function rerender(caretPid, offset) {
    touch(current());
    renderEditorParas();
    setCaret(caretPid, offset);
    afterTextChange();
  }

  function deleteSelectionModel(c) {
    const a = current();
    const i1 = a.paragraphs.findIndex((p) => p.id === c.pid);
    const i2 = a.paragraphs.findIndex((p) => p.id === c.endPid);
    if (i1 < 0 || i2 < 0) return c;
    const first = a.paragraphs[i1];
    if (i1 === i2) {
      R.remove(first, c.offset, c.endOffset);
    } else {
      const last = a.paragraphs[i2];
      R.cut(first, c.offset);
      const tail = R.cut(last, c.endOffset);
      R.append(first, tail.text, tail.runs);
      const removed = a.paragraphs.splice(i1 + 1, i2 - i1);
      for (const p of removed) delete a.marks[p.id];
    }
    return { pid: c.pid, offset: c.offset, endPid: c.pid, endOffset: c.offset, collapsed: true };
  }

  const LIST_LIKE = new Set(['ul', 'ol', 'quote']);

  function splitAtCaret() {
    const a = current();
    let c = getCaret();
    if (!a || !c) return;
    const pend = pendingFor(c);
    const idx0 = a.paragraphs.findIndex((p) => p.id === c.pid);
    const p0 = a.paragraphs[idx0];
    if (c.collapsed && !p0.text && LIST_LIKE.has(R.typeOf(p0))) {
      pushUndo('段落样式', { caret: c });
      R.setBlock(p0, { type: 'p', indent: 0 });
      rerender(p0.id, 0);
      return;
    }
    pushUndo('分段', { caret: c });
    if (!c.collapsed) c = deleteSelectionModel(c);
    const idx = a.paragraphs.findIndex((p) => p.id === c.pid);
    const p = a.paragraphs[idx];
    const block = R.blockOf(p);
    const after = { ...block };
    if (/^h[1-3]$/.test(R.typeOf(p))) delete after.type;
    let caretPid;
    pending = null;
    if (c.offset === 0 && p.text.length > 0) {
      a.paragraphs.splice(idx, 0, { id: S.uid('p'), text: '', ...block });
      caretPid = p.id;
      if (pend) pending = { pid: p.id, offset: 0, patch: pend };
    } else {
      const right = R.cut(p, c.offset);
      const np = { id: S.uid('p'), text: right.text, ...(right.text ? block : after) };
      R.setRuns(np, right.runs);
      a.paragraphs.splice(idx + 1, 0, np);
      caretPid = np.id;
      if (!right.text) {
        const patch = desiredAttrs(p, c.offset, pend);
        if (Object.values(patch).some(Boolean)) pending = { pid: np.id, offset: 0, patch };
      }
    }
    rerender(caretPid, 0);
  }

  /** 段首退格：先去掉列表或引用，再减少缩进，最后与上一段合并。 */
  function backspaceAtStart(c) {
    const a = current();
    const idx = a.paragraphs.findIndex((p) => p.id === c.pid);
    const p = a.paragraphs[idx];
    const b = R.blockOf(p);
    if (LIST_LIKE.has(R.typeOf(p))) {
      pushUndo('段落样式', { caret: c });
      R.setBlock(p, { type: 'p' });
      rerender(p.id, 0);
      return;
    }
    if (b.indent) {
      pushUndo('缩进', { caret: c });
      R.setBlock(p, { indent: b.indent - 1 });
      rerender(p.id, 0);
      return;
    }
    if (idx <= 0) return;
    const prev = a.paragraphs[idx - 1];
    pushUndo('合并段落', { caret: c });
    if (!prev.text) {
      a.paragraphs.splice(idx - 1, 1);
      delete a.marks[prev.id];
      rerender(p.id, 0);
      return;
    }
    const off = prev.text.length;
    R.append(prev, p.text, R.runsOf(p));
    a.paragraphs.splice(idx, 1);
    delete a.marks[p.id];
    rerender(prev.id, off);
  }

  function deleteAtEnd(c) {
    const a = current();
    const idx = a.paragraphs.findIndex((p) => p.id === c.pid);
    const p = a.paragraphs[idx];
    const next = a.paragraphs[idx + 1];
    if (!next) return;
    pushUndo('合并段落', { caret: c });
    if (!p.text) {
      a.paragraphs.splice(idx, 1);
      delete a.marks[p.id];
      rerender(next.id, 0);
      return;
    }
    const off = p.text.length;
    R.append(p, next.text, R.runsOf(next));
    a.paragraphs.splice(idx + 1, 1);
    delete a.marks[next.id];
    rerender(p.id, off);
  }

  /** 选区内容，按段落切开，带段落样式和字符样式。 */
  function selectionBlocks(a, c) {
    const i1 = a.paragraphs.findIndex((p) => p.id === c.pid);
    const i2 = a.paragraphs.findIndex((p) => p.id === c.endPid);
    const out = [];
    if (i1 < 0 || i2 < 0) return out;
    for (let i = i1; i <= i2; i++) {
      const p = a.paragraphs[i];
      const s = i === i1 ? c.offset : 0;
      const e = i === i2 ? c.endOffset : p.text.length;
      if (i === i2 && i > i1 && e === 0) break;
      out.push({ text: p.text.slice(s, e), runs: R.slice(R.runsOf(p), s, e), ...R.blockOf(p) });
    }
    return out;
  }

  /** 插入一组段落。plain 为真时文字沿用光标处的样式；否则保留来源的字符样式，多段时也保留段落样式。 */
  function insertBlocks(blocks, plain, label = '粘贴') {
    const a = current();
    let c = getCaret() || editSel();
    if (!a || !c || !blocks.length || isLocked(a)) return;
    pushUndo(label, { caret: c });
    const pend = pendingFor(c);
    if (!c.collapsed) c = deleteSelectionModel(c);
    const idx = a.paragraphs.findIndex((p) => p.id === c.pid);
    const p = a.paragraphs[idx];
    const off = c.offset;
    const here = desiredAttrs(p, off, pend);
    const base = Object.fromEntries(Object.entries(here).filter(([, v]) => v));
    const runsFor = (b) => (plain || !b.runs || !b.runs.length ? [{ n: b.text.length, ...base }] : b.runs);
    pending = null;
    if (blocks.length === 1) {
      R.insert(p, off, blocks[0].text, runsFor(blocks[0]));
      lastUndoKind = 'paste';
      rerender(p.id, off + blocks[0].text.length);
      return;
    }
    const wasEmpty = !p.text;
    const right = R.cut(p, off);
    const first = blocks[0];
    R.append(p, first.text, runsFor(first));
    if (wasEmpty && !plain) R.setBlock(p, R.blockOf(first));
    const inherit = LIST_LIKE.has(R.typeOf(p)) ? R.blockOf(p) : {};
    const added = blocks.slice(1).map((b) => {
      const np = { id: S.uid('p'), text: b.text, ...(plain ? inherit : R.blockOf(b)) };
      return R.setRuns(np, runsFor(b));
    });
    const last = added[added.length - 1];
    const caretOff = last.text.length;
    R.append(last, right.text, right.runs);
    a.paragraphs.splice(idx + 1, 0, ...added);
    lastUndoKind = 'paste';
    rerender(last.id, caretOff);
  }

  /* —— 排版命令：字符样式作用于选区，光标处则记为待用样式；段落样式作用于选区涉及的所有段落 —— */

  function editTarget() {
    const a = current();
    if (!a || isLocked(a) || ui.view !== 'article' || ui.mode !== 'write') return null;
    const c = editSel();
    return c ? { a, c } : null;
  }

  function inlineRanges(a, c) {
    const i1 = a.paragraphs.findIndex((p) => p.id === c.pid);
    const i2 = a.paragraphs.findIndex((p) => p.id === (c.endPid || c.pid));
    const out = [];
    if (i1 < 0 || i2 < i1) return out;
    for (let i = i1; i <= i2; i++) {
      const p = a.paragraphs[i];
      const s = i === i1 ? c.offset : 0;
      const e = i === i2 ? c.endOffset : p.text.length;
      if (e > s) out.push({ p, s, e });
    }
    return out;
  }

  function commitFormat(a, c) {
    touch(a);
    const focused = document.activeElement === editorEl();
    renderEditorParas();
    if (focused) restoreSel(c);
    else {
      const s = window.getSelection();
      if (s) s.removeAllRanges();
      ui.sel = c;
      paintGhost();
    }
    syncFormatBar();
    afterTextChange();
  }

  const INLINE_LABEL = { b: '粗体', i: '斜体', u: '下划线', s: '删除线' };

  function formatInline(change, label) {
    const t = editTarget();
    if (!t) return;
    const { a, c } = t;
    const ranges = c.collapsed ? [] : inlineRanges(a, c);
    if (!ranges.length) {
      pending = { pid: c.pid, offset: c.offset, patch: { ...(pendingFor(c) || {}), ...change } };
      syncFormatBar();
      return;
    }
    const before = JSON.stringify(ranges.map((r) => r.p.runs || null));
    const trial = ranges.map((r) => R.patch(R.clonePara(r.p), r.s, r.e, change).runs || null);
    if (JSON.stringify(trial) === before) return;
    pushUndo(label, { caret: c });
    for (const r of ranges) R.patch(r.p, r.s, r.e, change);
    commitFormat(a, c);
  }

  function toggleInline(k) {
    const s = fbState();
    if (!s) return;
    formatInline({ [k]: s.st[k] === true ? null : true }, INLINE_LABEL[k]);
    announce(`${INLINE_LABEL[k]}${s.st[k] === true ? '已关闭' : '已打开'}`);
  }

  function setSize(z) {
    const t = editTarget();
    if (!t) return;
    const { a, c } = t;
    const ranges = c.collapsed ? [] : inlineRanges(a, c);
    if (!ranges.length) {
      const p = a.paragraphs.find((x) => x.id === c.pid);
      formatInline({ z: z === R.defaultSize(p) ? null : z }, '字号');
      return;
    }
    pushUndo('字号', { caret: c });
    for (const r of ranges) R.patch(r.p, r.s, r.e, { z: z === R.defaultSize(r.p) ? null : z });
    commitFormat(a, c);
  }

  function stepSize(d) {
    const s = fbState();
    if (!s) return;
    let z = s.st.z;
    if (z === null) {
      const p = s.a.paragraphs.find((x) => x.id === s.c.pid);
      z = R.charAttrs(R.runsOf(p), s.c.offset).z || R.defaultSize(p);
    }
    const next = d > 0 ? R.SIZES.find((v) => v > z) : [...R.SIZES].reverse().find((v) => v < z);
    if (next) setSize(next);
  }

  function clearFormat() {
    formatInline(Object.fromEntries(R.INLINE.map((k) => [k, null])), '清除格式');
  }

  function formatBlocks(label, changeFor) {
    const t = editTarget();
    if (!t) return;
    const { a, c } = t;
    const paras = selectedPids(a, c).map((id) => a.paragraphs.find((p) => p.id === id));
    const differs = paras.some((p) => JSON.stringify(R.blockOf(R.setBlock(R.clonePara(p), changeFor(p)))) !== JSON.stringify(R.blockOf(p)));
    if (!differs) return;
    pushUndo(label, { caret: c });
    for (const p of paras) R.setBlock(p, changeFor(p));
    commitFormat(a, c);
  }

  function setBlockType(type) {
    formatBlocks('段落样式', () => ({ type }));
    announce(`样式：${R.BLOCK[type].label}`);
  }

  function toggleList(type) {
    const s = fbState();
    if (!s) return;
    const all = s.st.type === type;
    formatBlocks(R.BLOCK[type].label, () => ({ type: all ? 'p' : type }));
    announce(all ? `已取消${R.BLOCK[type].label}` : R.BLOCK[type].label);
  }

  function indentBlocks(d) {
    formatBlocks(d > 0 ? '增加缩进' : '减少缩进', (p) => ({ indent: Math.max(0, Math.min(R.INDENT_MAX, (R.blockOf(p).indent || 0) + d)) }));
  }

  function setAlign(align) {
    formatBlocks('对齐', () => ({ align }));
    announce(R.ALIGNS.find((x) => x.id === align).label);
  }

  function setLineHeight(lh) {
    formatBlocks('行距', () => ({ lh }));
  }

  /** 焦点离开正文（进入工具栏、菜单或对话框）时，用淡色把刚才的选区标出来。 */
  function paintGhost() {
    const ed = editorEl();
    const a = current();
    if (!ed || !a || ui.mode !== 'write' || document.activeElement === ed || !ui.sel || ui.sel.collapsed) { clearHighlight('ghost'); return; }
    const ranges = inlineRanges(a, ui.sel).map((r) => {
      const node = ed.querySelector(`p[data-pid="${CSS.escape(r.p.id)}"]`);
      return node ? rangeIn(node, r.s, r.e) : null;
    }).filter(Boolean);
    if (ranges.length) setHighlight('ghost', ranges);
    else clearHighlight('ghost');
  }

  function moveParagraph(pid, toIndex, via) {
    const a = current();
    if (!a || isLocked(a)) return;
    const from = a.paragraphs.findIndex((p) => p.id === pid);
    if (from < 0) return;
    const target = Math.max(0, Math.min(a.paragraphs.length - 1, toIndex));
    if (target === from) return;
    const editorFocused = document.activeElement === editorEl();
    const c = editSel();
    pushUndo('移动段落', { caret: c });
    const [p] = a.paragraphs.splice(from, 1);
    a.paragraphs.splice(target, 0, p);
    touch(a);
    renderEditorParas();
    if (c && c.pid === pid && (editorFocused || via !== 'toolbar')) {
      if (c.endPid === pid) setCaret(pid, c.offset, c.endOffset);
      else setCaret(pid, c.offset);
    } else if (via === 'drag') setCaret(pid, 0);
    if (c && c.pid === pid) {
      ui.sel = c.endPid === pid ? { ...c } : { ...c, endPid: pid, endOffset: c.offset, collapsed: true };
      ui.caret = { pid, offset: c.offset };
      const node = editorEl().querySelector(`p[data-pid="${CSS.escape(pid)}"]`);
      if (node && !editorFocused) scrollRangeIntoView(rangeIn(node, c.offset, c.offset), node);
    }
    flashParagraph(pid);
    announce(`已移到第 ${target + 1} 段`);
    afterTextChange();
  }

  function flashParagraph(pid) {
    const p = editorEl() && editorEl().querySelector(`p[data-pid="${CSS.escape(pid)}"]`);
    if (!p || !window.CSS || !CSS.highlights) return;
    const r = document.createRange();
    r.selectNodeContents(p);
    setHighlight('flash', [r]);
    setTimeout(() => clearHighlight('flash'), 900);
  }

  function setHighlight(name, ranges) {
    if (!window.CSS || !CSS.highlights || typeof Highlight === 'undefined') return;
    CSS.highlights.set(name, new Highlight(...ranges));
  }
  function clearHighlight(name) {
    if (window.CSS && CSS.highlights) CSS.highlights.delete(name);
  }

  /* —— 标记 —— */

  function toggleMark(pid, force) {
    const a = current();
    if (!a || isLocked(a)) return;
    const p = a.paragraphs.find((x) => x.id === pid);
    if (!p) return;
    const marked = Boolean(a.marks[pid]);
    const want = force !== undefined ? force : !marked;
    if (want === marked) return;
    if (want && !p.text.trim()) { toast('空段落不需要改稿'); return; }
    const c = editSel();
    pushUndo(want ? '标记段落' : '取消标记', { caret: c });
    if (want) a.marks[pid] = { instruction: 'concise' };
    else delete a.marks[pid];
    touch(a);
    updateDecor();
    renderToolbar();
    renderInspector();
    renderSidebar();
    const n = a.paragraphs.findIndex((x) => x.id === pid) + 1;
    announce(want ? `已标记第 ${n} 段，要求：更简洁` : `已取消标记第 ${n} 段`);
  }

  function setInstruction(pid, instruction, custom) {
    const a = current();
    if (!a || !a.marks[pid]) return;
    pushUndo('修改要求', { caret: editSel() });
    a.marks[pid] = { instruction, custom: custom || '' };
    touch(a);
    updateDecor();
    renderInspector();
    syncFormatBar();
  }

  /* 一次设置多段的标记和要求，作为一步撤销。instruction 为 null 时取消标记。 */
  function applyMarks(pids, instruction, custom = '') {
    const a = current();
    if (!a || isLocked(a)) return;
    const targets = pids.filter((pid) => {
      const p = a.paragraphs.find((x) => x.id === pid);
      return p && (instruction ? p.text.trim() : a.marks[pid]);
    });
    if (!targets.length) { if (instruction) toast('空段落不需要改稿'); return; }
    const relabel = instruction && targets.every((pid) => a.marks[pid]);
    pushUndo(!instruction ? '取消标记' : relabel ? '修改要求' : '标记段落', { caret: editSel() });
    for (const pid of targets) {
      if (instruction) a.marks[pid] = { instruction, custom: instruction === 'custom' ? custom : '' };
      else delete a.marks[pid];
    }
    touch(a);
    updateDecor();
    renderToolbar();
    renderInspector();
    renderSidebar();
    const label = instruction ? S.instructionLabel(a.marks[targets[0]]) : '';
    const where = targets.length > 1 ? `${targets.length} 段` : `第 ${a.paragraphs.findIndex((x) => x.id === targets[0]) + 1} 段`;
    announce(!instruction ? `已取消标记${where}` : relabel ? `${where}的要求改为：${label}` : `已标记${where}，要求：${label}`);
  }

  function markSelection() {
    const a = current();
    const c = editSel();
    if (!a || !c || isLocked(a)) return;
    const pids = selectedPids(a, c).filter((pid) => a.paragraphs.find((p) => p.id === pid).text.trim());
    if (!pids.length) { toast('空段落不需要改稿'); return; }
    if (pids.every((pid) => a.marks[pid])) applyMarks(pids, null);
    else applyMarks(pids.filter((pid) => !a.marks[pid]), 'concise');
  }

  function clearAllMarks() {
    const a = current();
    if (!a) return;
    applyMarks(Object.keys(a.marks), null);
  }

  function openChipMenu(chip, pid) {
    const a = current();
    const mark = a.marks[pid];
    const items = [
      { label: '修改要求', heading: true },
      ...AI.INSTRUCTIONS.map((it) => ({ label: it.label, checked: !mark.custom && mark.instruction === it.id, run: () => setInstruction(pid, it.id) })),
      { label: mark.custom ? `自定义：${clip(mark.custom, 10)}` : '自定义…', checked: Boolean(mark.custom), run: () => customInstruction(pid) },
      '-',
      { label: '取消标记', icon: 'i-x', run: () => toggleMark(pid, false) },
    ];
    openMenu(chip, items);
  }

  function customInstruction(pidOrPids) {
    const a = current();
    const pids = [].concat(pidOrPids);
    const mark = a.marks[pids[0]] || {};
    openDialog({
      title: '修改要求',
      body: `<div class="field"><input type="text" value="${esc(mark.custom || '')}" placeholder="例如：保留口语感，只删重复的词" aria-label="修改要求"></div>`,
      actions: [{ label: '取消', value: null }, { label: '确定', value: 'ok', primary: true }],
      onClose: (v, text) => {
        if (v === 'ok' && text && text.trim()) applyMarks(pids, 'custom', text.trim());
      },
    });
  }

  /* —— 编辑器事件 —— */

  const FORMAT_INPUT = { formatBold: 'b', formatItalic: 'i', formatUnderline: 'u', formatStrikeThrough: 's' };

  el.content.addEventListener('beforeinput', (e) => {
    const ed = editorEl();
    if (!ed || !ed.contains(e.target)) return;
    if (!ed.isContentEditable) { e.preventDefault(); return; }
    const c = getCaret();
    caretBeforeInput = c;
    pendingBeforeInput = pendingFor(c);
    const t = e.inputType;
    if (t === 'historyUndo') { e.preventDefault(); undo(); return; }
    if (t === 'historyRedo') { e.preventDefault(); redo(); return; }
    if (FORMAT_INPUT[t]) { e.preventDefault(); toggleInline(FORMAT_INPUT[t]); return; }
    if (t && t.startsWith('format')) { e.preventDefault(); return; }
    if (composing || e.isComposing || !c) return;
    if (t === 'insertParagraph' || t === 'insertLineBreak') { e.preventDefault(); splitAtCaret(); return; }
    if (t === 'insertFromDrop') {
      e.preventDefault();
      const dt = e.dataTransfer;
      const html = dt && dt.getData('text/html');
      const blocks = (html && R.fromHTML(html)) || [];
      insertBlocks(blocks.length ? blocks : R.fromPlain(dt && dt.getData('text/plain')), !blocks.length, '拖入文字');
      return;
    }
    const multi = !c.collapsed && c.pid !== c.endPid;
    if (t.startsWith('delete')) {
      if (multi) {
        e.preventDefault();
        pushUndo('删除', { caret: c });
        const n = deleteSelectionModel(c);
        rerender(n.pid, n.offset);
        return;
      }
      if (c.collapsed && /Backward$/.test(t) && c.offset === 0) { e.preventDefault(); backspaceAtStart(c); return; }
      if (c.collapsed && /Forward$/.test(t)) {
        const p = current().paragraphs.find((x) => x.id === c.pid);
        if (p && c.offset >= p.text.length) { e.preventDefault(); deleteAtEnd(c); }
      }
      return;
    }
    if (multi && (t === 'insertText' || t === 'insertReplacementText') && e.data) {
      e.preventDefault();
      const a = current();
      pushUndo('输入', { caret: c, kind: 'typing' });
      lastTypingAt = Date.now();
      const n = deleteSelectionModel(c);
      const p = a.paragraphs.find((x) => x.id === n.pid);
      R.insert(p, n.offset, e.data, R.attrsAt(p, n.offset));
      rerender(p.id, n.offset + e.data.length);
    }
  });
  el.content.addEventListener('input', (e) => {
    if (e.target.id === 'title-input') {
      const a = current();
      a.title = e.target.value.replace(/\n/g, ' ');
      touch(a);
      autosizeTitle();
      clearTimeout(afterTimer);
      afterTimer = setTimeout(() => { renderSidebar(); renderToolbar(); }, 120);
      return;
    }
    const ed = editorEl();
    if (!ed || !ed.contains(e.target)) return;
    if (e.isComposing || composing) return;
    syncFromDOM();
  });
  el.content.addEventListener('compositionstart', (e) => {
    if (editorEl() && editorEl().contains(e.target)) {
      composing = true;
      caretBeforeInput = getCaret();
      pendingBeforeInput = pendingFor(caretBeforeInput);
    }
  });
  el.content.addEventListener('compositionend', (e) => {
    if (editorEl() && editorEl().contains(e.target)) { composing = false; syncFromDOM(); }
  });

  /* —— 剪贴板：复制时同时写入纯文本和带排版的 HTML；粘贴时优先读排版，⇧ 粘贴只取文字 —— */

  let plainPasteNext = false;
  function editorSelection() {
    const c = getCaret();
    return c && !c.collapsed ? c : null;
  }
  function writeClipboard(e, c) {
    const blocks = selectionBlocks(current(), c);
    e.clipboardData.setData('text/plain', blocks.map((b) => b.text).join('\n'));
    e.clipboardData.setData('text/html', R.clipboardHTML(blocks));
  }
  el.content.addEventListener('copy', (e) => {
    const ed = editorEl();
    if (!ed || !ed.contains(e.target)) return;
    const c = editorSelection();
    if (!c) return;
    e.preventDefault();
    writeClipboard(e, c);
  });
  el.content.addEventListener('cut', (e) => {
    const ed = editorEl();
    if (!ed || !ed.contains(e.target)) return;
    const c = editorSelection();
    if (!c) return;
    e.preventDefault();
    writeClipboard(e, c);
    if (!ed.isContentEditable) return;
    pushUndo('剪切', { caret: c });
    const n = deleteSelectionModel(c);
    rerender(n.pid, n.offset);
  });
  el.content.addEventListener('paste', (e) => {
    const ed = editorEl();
    if (!ed || !ed.contains(e.target)) return;
    e.preventDefault();
    const plain = plainPasteNext;
    plainPasteNext = false;
    if (!ed.isContentEditable) return;
    const cd = e.clipboardData;
    const html = !plain && cd && cd.getData('text/html');
    const rich = html ? R.fromHTML(html) : [];
    const blocks = rich.length ? rich : R.fromPlain(cd && cd.getData('text/plain'));
    if (blocks.length) insertBlocks(blocks, !rich.length);
  });

  /* —— 编辑器里的键盘：段落移动、列表缩进、排版快捷键 —— */

  function formatShortcut(e) {
    const mod = isMac ? e.metaKey : e.ctrlKey;
    if (!mod) return false;
    const k = e.key.length === 1 ? e.key.toLowerCase() : e.key;
    const code = e.code;
    const run = (fn) => { e.preventDefault(); fn(); return true; };
    if (e.altKey && !e.shiftKey && /^Digit[0-3]$/.test(code)) return run(() => setBlockType(['p', 'h1', 'h2', 'h3'][Number(code.slice(5))]));
    if (e.altKey) return false;
    if (!e.shiftKey) {
      if (k === 'b') return run(() => toggleInline('b'));
      if (k === 'i') return run(() => toggleInline('i'));
      if (k === 'u') return run(() => toggleInline('u'));
      if (code === 'BracketRight') return run(() => indentBlocks(1));
      if (code === 'BracketLeft') return run(() => indentBlocks(-1));
      if (code === 'Backslash') return run(clearFormat);
      return false;
    }
    if (k === 'x') return run(() => toggleInline('s'));
    if (code === 'Digit7') return run(() => toggleList('ol'));
    if (code === 'Digit8') return run(() => toggleList('ul'));
    if (code === 'Period') return run(() => stepSize(1));
    if (code === 'Comma') return run(() => stepSize(-1));
    if (k === 'l') return run(() => setAlign('left'));
    if (k === 'e') return run(() => setAlign('center'));
    if (k === 'r') return run(() => setAlign('right'));
    if (k === 'j') return run(() => setAlign('justify'));
    if (k === 'v') { plainPasteNext = true; setTimeout(() => { plainPasteNext = false; }, 400); return false; }
    return false;
  }

  el.content.addEventListener('keydown', (e) => {
    if (e.target.id === 'title-input') {
      if (e.key === 'Enter' || (e.key === 'ArrowDown' && e.target.selectionStart === e.target.value.length)) {
        e.preventDefault();
        const a = current();
        if (a && a.paragraphs[0]) setCaret(a.paragraphs[0].id, 0);
      }
      return;
    }
    const ed = editorEl();
    if (!ed || !ed.contains(e.target)) return;
    if (e.isComposing || composing) return;
    if (ed.isContentEditable && formatShortcut(e)) return;
    if (e.altKey && e.shiftKey && (e.key === 'ArrowUp' || e.key === 'ArrowDown')) {
      e.preventDefault();
      const c = getCaret();
      const a = current();
      if (!c || !a) return;
      const i = a.paragraphs.findIndex((p) => p.id === c.pid);
      moveParagraph(c.pid, i + (e.key === 'ArrowUp' ? -1 : 1));
      return;
    }
    if (e.key === 'Tab' && !e.altKey && !e.ctrlKey && !e.metaKey && ed.isContentEditable) {
      const a = current();
      const c = getCaret();
      const pids = c ? selectedPids(a, c) : [];
      if (pids.length && pids.every((pid) => ['ul', 'ol'].includes(R.typeOf(a.paragraphs.find((p) => p.id === pid))))) {
        e.preventDefault();
        indentBlocks(e.shiftKey ? -1 : 1);
      }
      return;
    }
    if (e.key === 'ArrowUp' && !e.shiftKey && !e.altKey) {
      const c = getCaret();
      const a = current();
      if (c && c.collapsed && a.paragraphs[0] && c.pid === a.paragraphs[0].id && c.offset === 0) {
        e.preventDefault();
        const t = $('#title-input');
        t.focus();
        t.setSelectionRange(t.value.length, t.value.length);
      }
    }
  });
  el.content.addEventListener('focusin', (e) => { if (e.target === editorEl()) clearHighlight('ghost'); });
  el.content.addEventListener('focusout', (e) => {
    if (e.target !== editorEl()) return;
    const c = getCaret();
    if (c) ui.sel = c;
    setTimeout(paintGhost, 0);
  });
  el.content.addEventListener('mousemove', (e) => {
    const wrap = $('#editor-wrap');
    if (!wrap || dragState) return;
    let pid = null;
    const p = e.target.closest && e.target.closest('#editor > p');
    if (p) pid = p.dataset.pid;
    else {
      const it = e.target.closest && e.target.closest('.g-item, .g-bar');
      if (it) pid = it.dataset.pid || it.dataset.chip;
    }
    if (pid !== ui.hoverPid) { ui.hoverPid = pid; refreshGutterVisibility(); }
  });
  el.content.addEventListener('mouseleave', () => { if (ui.hoverPid) { ui.hoverPid = null; refreshGutterVisibility(); } });

  el.content.addEventListener('click', (e) => {
    const b = e.target.closest('button, [data-key]');
    if (!b) return;
    if (b.dataset.chip) { openChipMenu(b, b.dataset.chip); return; }
    const act = b.dataset.act;
    if (act === 'cancel-run') cancelRun();
    if (act === 'go-review') setMode('review');
    if (act === 'go-write') setMode('write');
    if (act === 'snapshot') saveVersion();
  });

  /* —— 拖动段落 —— */

  let dragState = null;
  el.content.addEventListener('pointerdown', (e) => {
    const h = e.target.closest('[data-drag]');
    if (!h || e.button !== 0) return;
    e.preventDefault();
    const pid = h.dataset.drag;
    const ed = editorEl();
    const p = ed.querySelector(`p[data-pid="${CSS.escape(pid)}"]`);
    const ghost = document.createElement('div');
    ghost.className = 'drag-ghost';
    ghost.textContent = p.textContent || '（空段落）';
    const line = document.createElement('div');
    line.className = 'drop-line';
    line.hidden = true;
    $('#editor-wrap').appendChild(line);
    document.body.appendChild(ghost);
    p.classList.add('is-drag-source');
    dragState = { pid, ghost, line, target: null, startY: e.clientY, moved: false, p };
    h.setPointerCapture(e.pointerId);
    const move = (ev) => {
      if (!dragState) return;
      if (Math.abs(ev.clientY - dragState.startY) > 3) dragState.moved = true;
      ghost.style.left = `${ev.clientX + 14}px`;
      ghost.style.top = `${ev.clientY - 10}px`;
      const paras = $$('p', ed);
      let idx = paras.length;
      for (let i = 0; i < paras.length; i++) {
        const r = paras[i].getBoundingClientRect();
        if (ev.clientY < r.top + r.height / 2) { idx = i; break; }
      }
      dragState.target = idx;
      const wrapRect = $('#editor-wrap').getBoundingClientRect();
      let y;
      if (idx < paras.length) y = paras[idx].getBoundingClientRect().top - wrapRect.top - 6;
      else y = paras[paras.length - 1].getBoundingClientRect().bottom - wrapRect.top + 4;
      line.hidden = false;
      line.style.top = `${y}px`;
      const box = el.content.getBoundingClientRect();
      if (ev.clientY < box.top + 80) el.content.scrollTop -= 12;
      if (ev.clientY > box.bottom - 50) el.content.scrollTop += 12;
    };
    const up = () => {
      h.removeEventListener('pointermove', move);
      h.removeEventListener('pointerup', up);
      h.removeEventListener('pointercancel', up);
      const st = dragState;
      dragState = null;
      ghost.remove();
      line.remove();
      st.p.classList.remove('is-drag-source');
      if (!st.moved || st.target === null) return;
      const a = current();
      const from = a.paragraphs.findIndex((x) => x.id === st.pid);
      let to = st.target;
      if (to > from) to -= 1;
      moveParagraph(st.pid, to, 'drag');
    };
    h.addEventListener('pointermove', move);
    h.addEventListener('pointerup', up);
    h.addEventListener('pointercancel', up);
  });

  /* —— 光标所在段落与句子 —— */

  let selTimer = 0;
  document.addEventListener('selectionchange', () => {
    if (ui.view !== 'article' || ui.mode !== 'write') return;
    const c = getCaret();
    if (!c) return;
    const changedPid = !ui.caret || ui.caret.pid !== c.pid;
    ui.caret = { pid: c.pid, offset: c.offset };
    ui.sel = c;
    if (pending && !pendingFor(c)) pending = null;
    queueSyncFormatBar();
    clearTimeout(selTimer);
    selTimer = setTimeout(() => {
      const prev = ui.provSel;
      computeProvSel();
      const provChanged = ui.inspectorTab === 'prov' && (!prev || !ui.provSel || prev.pid !== ui.provSel.pid || prev.start !== ui.provSel.start || prev.text !== ui.provSel.text);
      if (inspectorVisible() && (changedPid || provChanged)) renderInspector();
    }, 120);
  });

  function computeProvSel() {
    const a = current();
    if (!a || !ui.caret) { ui.provSel = null; return; }
    const p = a.paragraphs.find((x) => x.id === ui.caret.pid);
    if (!p || !p.text.trim()) { ui.provSel = null; clearHighlight('prov'); return; }
    const sentences = D.splitSentences(p.text);
    let s = sentences.find((x) => ui.caret.offset >= x.start && ui.caret.offset < x.end) || sentences[sentences.length - 1];
    if (!s) { ui.provSel = null; return; }
    ui.provSel = { pid: p.id, start: s.start, end: s.end, text: s.text.trim() };
    if (ui.inspectorTab === 'prov' && inspectorVisible()) {
      const node = editorEl() && editorEl().querySelector(`p[data-pid="${CSS.escape(p.id)}"]`);
      if (node) setHighlight('prov', [rangeIn(node, s.start, s.start + s.text.trimEnd().length)]);
    } else clearHighlight('prov');
  }

  function openProvenance() {
    const a = current();
    if (!a) return;
    if (ui.mode !== 'write') setMode('write');
    ui.inspectorOpen = true;
    ui.inspectorTab = 'prov';
    if (!ui.caret && a.paragraphs[0]) ui.caret = { pid: a.paragraphs[0].id, offset: 0 };
    computeProvSel();
    renderInspector();
    applyLayout();
    renderToolbar();
  }

  /* ───────────────────────── 送审与模拟改稿 ───────────────────────── */

  async function submitRound() {
    const a = current();
    if (!a || ui.mode !== 'write') return;
    if (S.activeRound(a)) { setMode('review'); return; }
    const order = a.paragraphs.filter((p) => a.marks[p.id] && p.text.trim()).map((p) => p.id);
    if (!order.length) { toast('先标记段落'); return; }
    pushUndo('送审', { caret: getCaret() });
    const round = S.beginRound(a, Date.now());
    const controller = new AbortController();
    ui.running = { articleId: a.id, roundN: round.n, controller, status: Object.fromEntries(order.map((id) => [id, 'wait'])), current: null, counts: {} };
    touch(a);
    renderAll();
    announce(`已送审 ${order.length} 段，AI 正在改稿`);
    const results = {};
    try {
      for (const pid of order) {
        ui.running.current = pid;
        ui.running.status[pid] = 'run';
        refreshRunUI(a.id);
        const text = a.paragraphs.find((p) => p.id === pid).text;
        const r = await AI.revise(text, a.marks[pid].instruction, { signal: controller.signal });
        results[pid] = r;
        ui.running.status[pid] = 'done';
        ui.running.counts[pid] = D.countChanges(D.diffText(text, r.text)).hunks;
      }
      S.completeRound(a, round, results, Date.now());
      ui.running = null;
      touch(a);
      const total = S.reviewModel(a, round).total;
      if (data.currentId === a.id && ui.view === 'article') {
        ui.mode = 'review';
        ui.focusKey = null;
        ui.showBar = !inspectorVisible();
        renderAll();
        focusHunk(ui.focusKey, { scroll: true });
        announce(`改稿完成，共 ${total} 处修改`);
      } else {
        renderSidebar();
        toast(`“${a.title || '无标题'}”改稿完成`, { action: { label: '审阅', run: () => openArticle(a.id, { mode: 'review' }) } });
      }
    } catch (err) {
      if (err && err.name === 'AbortError') {
        S.cancelRound(a, round);
        stackFor(a.id).undo.pop();
        ui.running = null;
        touch(a);
        if (data.currentId === a.id) renderAll();
        else renderSidebar();
        toast('已取消改稿');
      } else {
        throw err;
      }
    }
  }

  function cancelRun() {
    if (ui.running) ui.running.controller.abort();
  }

  function refreshRunUI(articleId) {
    if (data.currentId !== articleId || ui.view !== 'article') { renderSidebar(); return; }
    if (ui.mode === 'write') updateDecor();
    renderInspector();
  }

  /* ───────────────────────── 审阅 ───────────────────────── */

  let reviewModelCache = null;

  function hunkLabel(h, n) {
    let desc;
    if (h.del && h.ins) desc = `把“${clip(h.del, 30)}”改为“${clip(h.ins, 30)}”`;
    else if (h.del) desc = `删去“${clip(h.del, 30)}”`;
    else desc = `补上“${clip(h.ins, 30)}”`;
    const d = h.decision;
    const st = !d ? '未决定' : d.choice === 'adopt' ? '已采用改法' : d.choice === 'keep' ? '已保留原句' : `已重写为“${clip(d.text, 20)}”`;
    return `修改 ${n}：${desc}。${st}`;
  }

  /* 审阅时文字差异和排版分开：差异按逐词对比标出，片段内部仍按各稿自己的字符样式显示（差异色优先于文字颜色）。 */
  const NO_COLOR = { noColor: true };

  function hunkHTML(h, variant, n, para) {
    const d = h.decision;
    const cls = `hunk ${d ? `is-${d.choice}` : 'is-pending'} ${ui.focusKey === h.key ? 'is-focused' : ''}`;
    const attrs = `class="${cls}" data-key="${h.key}" role="button" tabindex="${ui.focusKey === h.key && variant !== 'base' && variant !== 'result' ? 0 : -1}" aria-label="${esc(hunkLabel(h, n))}"`;
    const delHTML = R.sliceHTML(para.src, h.bStart, h.bEnd, NO_COLOR);
    const insHTML = R.sliceHTML(para.aiSrc, h.aStart, h.aEnd, NO_COLOR);
    const delS = h.del ? `<span class="seg-del">${delHTML}</span>` : '';
    const insS = h.ins ? `<span class="seg-ins">${insHTML}</span>` : '';
    if (variant === 'base') {
      return `<span ${attrs}>${h.del ? delS : '<span class="ins-point" aria-hidden="true"></span>'}</span>`;
    }
    if (variant === 'ai') {
      return `<span ${attrs}>${h.ins ? insS : '<span class="del-point" aria-hidden="true"></span>'}</span>`;
    }
    if (!d) {
      if (variant === 'result') return `<span ${attrs}><span class="pending-ghost">${delHTML || '<span class="ins-point" aria-hidden="true"></span>'}</span></span>`;
      return `<span ${attrs}>${delS}${insS}</span>`;
    }
    let chosen;
    if (d.choice === 'adopt') chosen = R.sliceHTML(para.aiSrc, h.aStart, h.aEnd);
    else if (d.choice === 'keep') chosen = delHTML;
    else chosen = R.inlineHTML(d.text, [{ n: d.text.length, ...R.charAttrs(R.runsOf(para.src), h.bStart) }], NO_COLOR);
    const empty = d.choice === 'adopt' ? !h.ins : d.choice === 'keep' ? !h.del : !d.text;
    return `<span ${attrs}><span class="chosen ${empty ? 'void' : ''}">${chosen}</span></span>`;
  }

  function paraHTML(para, variant, counter) {
    let out = '';
    let hi = 0;
    let bPos = 0;
    for (const s of para.segments) {
      if (s.type === 'eq') { out += R.sliceHTML(para.src, bPos, bPos + s.text.length); bPos += s.text.length; }
      else { const h = para.hunks[hi++]; out += hunkHTML(h, variant, counter.get(h.key), para); bPos += s.del.length; }
    }
    return out;
  }

  const blockOpen = (p, nums, cls = '') => `<p class="${R.blockClass(p)} ${cls}"${nums.get(p.id) ? ` data-num="${nums.get(p.id)}"` : ''}>`;

  function renderReview(a) {
    const round = S.activeRound(a);
    if (!round || round.status !== 'pending') {
      reviewModelCache = null;
      const running = round && round.status === 'running';
      el.content.innerHTML = `<div class="empty full">
        <div class="glyph">${running ? '<span class="spinner" style="width:24px;height:24px"></span>' : icon('i-revise')}</div>
        <h3>${running ? 'AI 正在改稿' : '没有待审阅的改稿'}</h3>
        <div style="display:flex;gap:8px;margin-top:6px"><button type="button" class="btn" data-act="go-write">回到写作</button></div></div>`;
      return;
    }
    const model = S.reviewModel(a, round);
    reviewModelCache = model;
    const all = model.paras.flatMap((p) => (p.marked ? p.hunks : []));
    const counter = new Map(all.map((h, i) => [h.key, i + 1]));
    if (!ui.focusKey || !counter.has(ui.focusKey)) {
      const firstOpen = all.find((h) => !h.decision) || all[0];
      ui.focusKey = firstOpen ? firstOpen.key : null;
    }
    const focusPid = ui.focusKey ? ui.focusKey.split(':')[0] : null;
    const nums = R.numbering(model.submitted.paragraphs);
    const body = model.paras.map((para) => {
      const open = (cls) => blockOpen(para.src, nums, `r-para ${cls || ''}`);
      if (!para.marked) return `${open('context')}${R.inlineHTML(para.src.text, para.src.runs)}</p>`;
      const head = `<div class="r-head">
          <span class="tag">${esc(S.instructionLabel(para.meta))}</span>
          <span class="grow"></span>
          ${para.hunks.length > 1 ? `<span class="r-bulk"><button type="button" class="link" data-bulk="keep" data-pid="${para.id}">全部保留</button><button type="button" class="link" data-bulk="adopt" data-pid="${para.id}">全部采用</button></span>` : ''}
        </div>`;
      let inner;
      if (!para.hunks.length) {
        inner = `${open()}${R.inlineHTML(para.src.text, para.src.runs)}</p><p class="r-note">没有修改</p>`;
      } else if (ui.diffLayout === 'stacked') {
        inner = `<div class="stack-label">送审稿</div>${open()}${paraHTML(para, 'base', counter)}</p>
          <div class="stack-label">AI 改稿</div>${open()}${paraHTML(para, 'ai', counter)}</p>
          <div class="stack-label">定稿</div>${open()}${paraHTML(para, 'result', counter)}</p>`;
      } else {
        inner = `${open()}${paraHTML(para, 'inline', counter)}</p>`;
      }
      return `<section class="r-block ${para.id === focusPid ? 'is-current' : ''}" data-pid="${para.id}" aria-label="第 ${para.index + 1} 段，${para.hunks.length} 处修改">${head}${inner}</section>`;
    }).join('');
    el.content.innerHTML = `
      <div class="page" id="review-page">
        <div class="meta-line"><span>第 ${round.n} 轮 · ${model.total} 处修改</span><span class="grow"></span>
          <div class="segmented small" role="group" aria-label="对比方式">
            <button type="button" data-layout="inline" aria-pressed="${ui.diffLayout === 'inline'}">行内</button>
            <button type="button" data-layout="stacked" aria-pressed="${ui.diffLayout === 'stacked'}">对照</button>
          </div></div>
        <h1 class="r-title">${esc(a.title || '无标题')}</h1>
        <div class="read" id="review-doc" role="region" aria-label="改稿对照，按 J、K 在修改之间移动">${body}</div>
      </div>`;
    positionHunkBar();
  }

  function positionHunkBar() {
    const page = $('#review-page');
    const old = $('#hunk-bar');
    if (old) old.remove();
    if (!page || !reviewModelCache || !ui.focusKey || !ui.showBar) return;
    const h = findHunk(ui.focusKey);
    if (!h) return;
    const nodes = $$(`[data-key="${CSS.escape(ui.focusKey)}"]`, page);
    const anchor = ui.diffLayout === 'stacked' ? (nodes[1] || nodes[0]) : nodes[0];
    if (!anchor) return;
    const d = h.decision;
    const bar = document.createElement('div');
    bar.className = 'hunk-bar';
    bar.id = 'hunk-bar';
    bar.setAttribute('role', 'toolbar');
    bar.setAttribute('aria-label', '处理这处修改');
    bar.innerHTML = `<div class="row">
        <button type="button" class="choice" data-choice="keep" aria-pressed="${Boolean(d && d.choice === 'keep')}" aria-keyshortcuts="O" title="保留原句（O）">${icon('i-keep', 'sm')}保留</button>
        <button type="button" class="choice" data-choice="adopt" aria-pressed="${Boolean(d && d.choice === 'adopt')}" aria-keyshortcuts="A" title="采用改法（A）">${icon('i-check', 'sm')}采用</button>
        <button type="button" class="choice" data-choice="rewrite" aria-pressed="${Boolean(d && d.choice === 'rewrite')}" aria-keyshortcuts="E" title="自己重写（E）">${icon('i-pen', 'sm')}重写</button>
      </div>${inspectorVisible() ? '' : `<div class="why">${esc(h.reason)}</div>`}`;
    page.appendChild(bar);
    const rects = anchor.getClientRects();
    const last = rects[rects.length - 1] || anchor.getBoundingClientRect();
    const pr = page.getBoundingClientRect();
    const top = last.bottom - pr.top + 8;
    const left = Math.max(12, Math.min(last.left - pr.left - 10, pr.width - bar.offsetWidth - 12));
    bar.style.top = `${top}px`;
    bar.style.left = `${left}px`;
  }

  function findHunk(key) {
    if (!reviewModelCache) return null;
    for (const p of reviewModelCache.paras) if (p.marked) for (const h of p.hunks) if (h.key === key) return h;
    return null;
  }
  function allHunks() {
    return reviewModelCache ? reviewModelCache.paras.flatMap((p) => (p.marked ? p.hunks : [])) : [];
  }

  function focusHunk(key, opts = {}) {
    if (ui.mode !== 'review' || !reviewModelCache) return;
    if (key) ui.focusKey = key;
    $$('.hunk.is-focused', el.content).forEach((n) => n.classList.remove('is-focused'));
    $$('[data-key]', el.content).forEach((n) => n.setAttribute('tabindex', '-1'));
    const nodes = $$(`[data-key="${CSS.escape(ui.focusKey || '')}"]`, el.content);
    nodes.forEach((n) => n.classList.add('is-focused'));
    const pid = (ui.focusKey || '').split(':')[0];
    $$('.r-block', el.content).forEach((b) => b.classList.toggle('is-current', b.dataset.pid === pid));
    const target = ui.diffLayout === 'stacked' ? (nodes[1] || nodes[0]) : nodes[0];
    if (target) {
      target.setAttribute('tabindex', '0');
      if (opts.focus !== false) target.focus({ preventScroll: true });
      if (opts.scroll) {
        const r = target.getBoundingClientRect();
        const box = el.content.getBoundingClientRect();
        if (r.top < box.top + 90 || r.bottom > box.bottom - 120) {
          el.content.scrollTo({ top: el.content.scrollTop + r.top - box.top - box.height * 0.35, behavior: reduceMotion.matches ? 'auto' : 'smooth' });
        }
      }
    }
    positionHunkBar();
    renderInspector();
  }

  function stepHunk(delta) {
    const list = allHunks();
    if (!list.length) return;
    const i = list.findIndex((h) => h.key === ui.focusKey);
    const n = list[Math.max(0, Math.min(list.length - 1, (i < 0 ? 0 : i) + delta))];
    focusHunk(n.key, { scroll: true });
    announce(hunkLabel(n, list.indexOf(n) + 1));
  }

  const CHOICE_LABEL = { adopt: '采用改法', keep: '保留原句', rewrite: '自己重写' };

  function decide(key, choice, text) {
    const a = current();
    const round = a && S.activeRound(a);
    if (!round || round.status !== 'pending') return;
    const existing = round.decisions[key];
    pushUndo(existing && existing.choice === choice && choice !== 'rewrite' ? '取消决定' : CHOICE_LABEL[choice], { caret: null });
    if (existing && existing.choice === choice && choice !== 'rewrite') delete round.decisions[key];
    else round.decisions[key] = choice === 'rewrite' ? { choice, text } : { choice };
    touch(a);
    const list = allHunks();
    const idx = list.findIndex((h) => h.key === key);
    renderReview(a);
    const fresh = allHunks();
    const after = fresh.slice(idx + 1).find((h) => !h.decision) || fresh.find((h) => !h.decision);
    const removed = !round.decisions[key];
    if (!removed && after) ui.focusKey = after.key;
    renderReview(a);
    focusHunk(ui.focusKey, { scroll: true });
    renderToolbar();
    const left = fresh.filter((h) => !h.decision).length;
    announce(removed ? '已取消这处的决定' : `已${CHOICE_LABEL[choice]}。${left ? `还有 ${left} 处未决定` : '所有修改都已决定，可以完成本轮'}`);
  }

  function bulkDecide(pid, choice) {
    const a = current();
    const round = a && S.activeRound(a);
    if (!round) return;
    const para = reviewModelCache.paras.find((p) => p.id === pid);
    if (!para) return;
    pushUndo(`本段${choice === 'adopt' ? '全部采用' : '全部保留'}`, { caret: null });
    for (const h of para.hunks) round.decisions[h.key] = { choice };
    touch(a);
    renderReview(a);
    const next = allHunks().find((h) => !h.decision);
    if (next) ui.focusKey = next.key;
    renderReview(a);
    focusHunk(ui.focusKey, { scroll: true });
    announce(`第 ${para.index + 1} 段已${choice === 'adopt' ? '全部采用改法' : '全部保留原句'}`);
  }

  function sentenceHTML(text, start, end, cls) {
    const s = D.sentenceAround(text, start, end);
    const a = start - s.start;
    const b = end - s.start;
    const mid = s.text.slice(a, b);
    return `${esc(s.text.slice(0, a))}<mark class="${cls} ${mid ? '' : 'void'}">${esc(mid)}</mark>${esc(s.text.slice(b))}`;
  }

  function openRewrite(key) {
    const h = findHunk(key);
    if (!h) return;
    const para = reviewModelCache.paras.find((p) => p.id === h.pid);
    const anchorNodes = $$(`[data-key="${CSS.escape(key)}"]`, el.content);
    const anchor = (ui.diffLayout === 'stacked' ? anchorNodes[1] : anchorNodes[0]) || anchorNodes[0];
    const initial = h.decision && h.decision.choice === 'rewrite' ? h.decision.text : (h.ins || h.del);
    const bar = $('#hunk-bar');
    if (bar) bar.remove();
    const node = openPopover(anchor, `<form class="pop-form" aria-label="自己重写这处">
        <div class="small muted">原句</div><p class="sent" style="font-size:13px">${sentenceHTML(para.base, h.bStart, h.bEnd, 'del')}</p>
        <div class="small muted">AI 改句</div><p class="sent" style="font-size:13px">${sentenceHTML(para.after, h.aStart, h.aEnd, 'ins')}</p>
        <label class="small muted" for="rw-text">你的写法</label>
        <textarea id="rw-text" rows="2">${esc(initial)}</textarea>
        <div class="small muted">替换后</div><p class="sent" id="rw-preview" style="font-size:13px" aria-live="polite"></p>
        <div class="actions"><button type="button" class="btn" data-rw="cancel">取消</button><button type="submit" class="btn primary">使用</button></div>
      </form>`, { role: 'dialog', label: '自己重写这处', focus: 'textarea', onClose: () => focusHunk(key, { scroll: false }) });
    node.style.width = 'min(400px, calc(100vw - 24px))';
    const ta = $('textarea', node);
    const around = D.sentenceAround(para.base, h.bStart, h.bEnd);
    const preview = () => {
      const v = ta.value.replace(/\n/g, '');
      $('#rw-preview', node).innerHTML = `${esc(para.base.slice(around.start, h.bStart))}<mark class="mine ${v ? '' : 'void'}">${esc(v)}</mark>${esc(para.base.slice(h.bEnd, around.end))}`;
    };
    preview();
    ta.addEventListener('input', preview);
    ta.select();
    const submit = (e) => {
      if (e) e.preventDefault();
      const v = ta.value.replace(/\n/g, '');
      closePopover(false);
      decide(key, 'rewrite', v);
    };
    $('form', node).addEventListener('submit', submit);
    ta.addEventListener('keydown', (e) => { if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) submit(e); });
    $('[data-rw="cancel"]', node).addEventListener('click', () => closePopover(true));
  }

  function finishRound() {
    const a = current();
    const round = a && S.activeRound(a);
    if (!round || round.status !== 'pending') return;
    const model = S.reviewModel(a, round);
    const left = model.total - model.decided;
    if (left > 0) {
      openDialog({
        title: `还有 ${left} 处未决定`,
        body: '',
        actions: [
          { label: '返回', value: null },
          { label: '都保留原句', value: 'keep' },
          { label: '都采用', value: 'adopt', primary: true },
        ],
        onClose: (v) => { if (v) doFinish(v); },
      });
    } else {
      doFinish(null);
    }
  }

  function doFinish(fallback) {
    const a = current();
    const round = S.activeRound(a);
    pushUndo('生成定稿', { caret: null });
    const submitted = S.getVersion(a, round.submittedId);
    S.finalizeRound(a, round, fallback, Date.now());
    const c = { adopt: 0, keep: 0, rewrite: 0 };
    for (const r of round.records) c[r.choice]++;
    ui.mode = 'write';
    ui.focusKey = null;
    save();
    renderAll();
    flashChanges(submitted.paragraphs, a.paragraphs);
    toast(`已生成定稿 · 第 ${round.n} 轮`, { action: { label: '撤销', run: undo } });
    announce(`已生成定稿：采用 ${c.adopt}，保留 ${c.keep}，重写 ${c.rewrite}`);
  }

  function flashChanges(beforeParas, afterParas) {
    const ed = editorEl();
    if (!ed) return;
    const before = new Map(beforeParas.map((p) => [p.id, p.text]));
    const ranges = [];
    for (const p of afterParas) {
      const old = before.get(p.id);
      if (old === undefined || old === p.text) continue;
      const node = ed.querySelector(`p[data-pid="${CSS.escape(p.id)}"]`);
      if (!node) continue;
      let pos = 0;
      for (const s of D.diffText(old, p.text)) {
        if (s.type === 'eq') { pos += s.text.length; continue; }
        if (s.ins) ranges.push(rangeIn(node, pos, pos + s.ins.length));
        pos += s.ins.length;
      }
    }
    if (ranges.length) {
      setHighlight('flash', ranges);
      setTimeout(() => clearHighlight('flash'), 2600);
    }
  }

  el.content.addEventListener('click', (e) => {
    if (ui.mode !== 'review' || ui.view !== 'article') return;
    const layout = e.target.closest('[data-layout]');
    if (layout) {
      ui.diffLayout = layout.dataset.layout;
      save();
      renderReview(current());
      focusHunk(ui.focusKey, { scroll: true });
      return;
    }
    const bulk = e.target.closest('[data-bulk]');
    if (bulk) { bulkDecide(bulk.dataset.pid, bulk.dataset.bulk); return; }
    const choice = e.target.closest('#hunk-bar [data-choice]');
    if (choice) {
      const c = choice.dataset.choice;
      if (c === 'rewrite') openRewrite(ui.focusKey);
      else decide(ui.focusKey, c);
      return;
    }
    const h = e.target.closest('[data-key]');
    if (h) {
      const same = ui.focusKey === h.dataset.key;
      ui.showBar = same ? !ui.showBar || !$('#hunk-bar') : true;
      focusHunk(h.dataset.key);
    }
  });

  /* ───────────────────────── 历史 ───────────────────────── */

  function versionOptions(a, selected) {
    const opts = [...a.versions].map((v) => ({ id: v.id, label: `${S.versionLabel(v)} · ${fmt(v.at, { dateOnly: true })}` }));
    opts.push({ id: 'live', label: '当前稿' });
    return opts.map((o) => `<option value="${o.id}" ${o.id === selected ? 'selected' : ''}>${esc(o.label)}</option>`).join('');
  }

  function compareFor(a) {
    let c = ui.compare[a.id];
    const ids = new Set([...a.versions.map((v) => v.id), 'live']);
    if (!c || !ids.has(c.from) || !ids.has(c.to)) {
      c = { from: a.versions.length ? a.versions[0].id : 'live', to: 'live' };
      if (a.versions.length > 1 && !D.diffDocs(a.versions[0].paragraphs, a.paragraphs).stats.paras) {
        c.to = a.versions[a.versions.length - 1].id;
      }
      ui.compare[a.id] = c;
    }
    return c;
  }

  function renderHistory(a) {
    if (!a.versions.length) {
      el.content.innerHTML = `<div class="empty full">
        <div class="glyph">${icon('i-history')}</div>
        <h3>还没有历史版本</h3>
        <button type="button" class="btn" data-act="snapshot" style="margin-top:6px">${icon('i-bookmark', 'sm')}存为版本</button>
      </div>`;
      return;
    }
    const c = compareFor(a);
    const from = S.getVersion(a, c.from);
    const to = S.getVersion(a, c.to);
    const { rows, stats } = D.diffDocs(from.paragraphs, to.paragraphs);
    const fromById = new Map(from.paragraphs.map((p) => [p.id, p]));
    const toById = new Map(to.paragraphs.map((p) => [p.id, p]));
    const nums = R.numbering(to.paragraphs);
    const fromNums = R.numbering(from.paragraphs);
    const parts = [];
    let sameRun = [];
    let fmtOnly = 0;
    const flush = () => {
      if (!sameRun.length) return;
      if (ui.onlyChanges) parts.push(`<div class="h-collapsed"><button type="button" data-expand>${sameRun.length} 段未改动</button></div>`);
      else parts.push(...sameRun.map((r) => `${blockOpen(toById.get(r.id), nums, 'h-row same')}${R.inlineHTML(r.target, toById.get(r.id).runs)}</p>`));
      sameRun = [];
    };
    for (const r of rows) {
      const bp = fromById.get(r.id);
      const tp = toById.get(r.id);
      const fmtChanged = r.status === 'same' && !R.sameFormat(bp, tp);
      if (r.status === 'same' && !r.moved && !fmtChanged) { sameRun.push(r); continue; }
      flush();
      if (r.status === 'added') parts.push(`${blockOpen(tp, nums, 'h-row added')}<span class="h-badge">新增</span><span class="seg-ins">${R.inlineHTML(tp.text, tp.runs, NO_COLOR)}</span></p>`);
      else if (r.status === 'removed') parts.push(`${blockOpen(bp, fromNums, 'h-row removed')}<span class="h-badge">删去</span><span class="seg-del">${R.inlineHTML(bp.text, bp.runs, NO_COLOR)}</span></p>`);
      else {
        let bPos = 0;
        let tPos = 0;
        const html = r.segments.map((sg) => {
          if (sg.type === 'eq') { const h = R.sliceHTML(tp, tPos, tPos + sg.text.length); bPos += sg.text.length; tPos += sg.text.length; return h; }
          const h = `${sg.del ? `<span class="seg-del">${R.sliceHTML(bp, bPos, bPos + sg.del.length, NO_COLOR)}</span>` : ''}${sg.ins ? `<span class="seg-ins">${R.sliceHTML(tp, tPos, tPos + sg.ins.length, NO_COLOR)}</span>` : ''}`;
          bPos += sg.del.length;
          tPos += sg.ins.length;
          return h;
        }).join('');
        if (fmtChanged) fmtOnly++;
        const badges = `${r.moved ? '<span class="h-badge">已移动</span>' : ''}${fmtChanged ? '<span class="h-badge fmt" title="只改了排版，文字没有变化">格式</span>' : ''}`;
        parts.push(`${blockOpen(tp, nums, `h-row ${r.status}${fmtChanged ? ' fmt' : ''}`)}${badges}${html}</p>`);
      }
    }
    flush();
    const titleDiff = from.title !== to.title
      ? D.diffText(from.title || '', to.title || '').map((s) => (s.type === 'eq' ? esc(s.text) : `${s.del ? `<span class="seg-del">${esc(s.del)}</span>` : ''}${s.ins ? `<span class="seg-ins">${esc(s.ins)}</span>` : ''}`)).join('')
      : esc(to.title || '无标题');
    const same = c.from === c.to || (!stats.paras && !fmtOnly && from.title === to.title);
    el.content.innerHTML = `
      <div class="subbar">
        <span class="cmp-pair">
          <label class="pill-select">从 <select class="select" data-cmp="from" aria-label="对比起点">${versionOptions(a, c.from)}</select></label>
          <button type="button" class="icon-btn sm" data-swap aria-label="交换起点和终点" title="交换">${icon('i-swap', 'sm')}</button>
          <label class="pill-select">到 <select class="select" data-cmp="to" aria-label="对比终点">${versionOptions(a, c.to)}</select></label>
        </span>
        <span class="grow"></span>
        <label class="pill-select"><input type="checkbox" data-only ${ui.onlyChanges ? 'checked' : ''}> 只看改动</label>
      </div>
      <div class="page">
        <h1 class="r-title">${titleDiff}</h1>
        <div class="meta-line"><span class="stat">${same ? (c.from === c.to ? '同一稿' : '两稿相同') : `<span class="plus">+${stats.ins}</span> <span class="minus">−${stats.del}</span> 字${stats.paras ? ` · ${stats.paras} 段改动` : ''}${fmtOnly ? ` · ${fmtOnly} 段仅格式` : ''}`}</span></div>
        <div class="read">${parts.join('') || '<p class="muted">两稿相同。</p>'}</div>
      </div>`;
  }

  el.content.addEventListener('change', (e) => {
    const a = current();
    if (!a) return;
    const sel = e.target.closest('[data-cmp]');
    if (sel) {
      const c = compareFor(a);
      c[sel.dataset.cmp] = sel.value;
      renderHistory(a);
      renderInspector();
      const again = $(`[data-cmp="${sel.dataset.cmp}"]`, el.content);
      if (again) again.focus();
      return;
    }
    if (e.target.matches('[data-only]')) { ui.onlyChanges = e.target.checked; renderHistory(a); $('[data-only]', el.content).focus(); }
  });
  el.content.addEventListener('click', (e) => {
    if (ui.mode !== 'history' || ui.view !== 'article') return;
    const a = current();
    if (e.target.closest('[data-swap]')) {
      const c = compareFor(a);
      [c.from, c.to] = [c.to, c.from];
      renderHistory(a);
      renderInspector();
      $('[data-swap]', el.content).focus();
    }
    if (e.target.closest('[data-expand]')) { ui.onlyChanges = false; renderHistory(a); }
  });

  /* ───────────────────────── 改写范例 ───────────────────────── */

  function renderExamples() {
    const recs = S.allRecords(data.articles);
    const tags = [...new Set(recs.map((r) => r.tag))];
    const q = ui.exQuery.trim().toLowerCase();
    const list = recs.filter((r) => (ui.exChoice === 'all' || r.choice === ui.exChoice)
      && (!ui.exTag || r.tag === ui.exTag)
      && (!q || `${r.before.text}${r.after.text}${r.ai.text}${r.reason}${r.articleTitle}`.toLowerCase().includes(q)));
    const count = (c) => recs.filter((r) => c === 'all' || r.choice === c).length;
    const chip = (attr, val, label, on) => `<button type="button" class="chip" ${attr}="${val}" aria-pressed="${on}">${esc(label)}</button>`;
    const cards = list.map((r) => {
      const before = `${esc(r.before.text.slice(0, r.before.hl[0]))}<mark class="${r.choice === 'keep' ? '' : 'del'} ${r.del ? '' : 'void'}">${esc(r.before.text.slice(r.before.hl[0], r.before.hl[1]))}</mark>${esc(r.before.text.slice(r.before.hl[1]))}`;
      const aiS = `${esc(r.ai.text.slice(0, r.ai.hl[0]))}<mark class="ins ${r.ins ? '' : 'void'}">${esc(r.ai.text.slice(r.ai.hl[0], r.ai.hl[1]))}</mark>${esc(r.ai.text.slice(r.ai.hl[1]))}`;
      const after = `${esc(r.after.text.slice(0, r.after.hl[0]))}<mark class="${r.choice === 'rewrite' ? 'mine' : 'ins'} ${r.final ? '' : 'void'}">${esc(r.after.text.slice(r.after.hl[0], r.after.hl[1]))}</mark>${esc(r.after.text.slice(r.after.hl[1]))}`;
      let rowsHTML;
      if (r.choice === 'adopt') rowsHTML = `<dt>原来</dt><dd><p class="sent">${before}</p></dd><dt>现在</dt><dd><p class="sent">${after}</p></dd>`;
      else if (r.choice === 'rewrite') rowsHTML = `<dt>原来</dt><dd><p class="sent">${before}</p></dd><dt>AI</dt><dd><p class="sent">${aiS}</p></dd><dt>你写成</dt><dd><p class="sent">${after}</p></dd>`;
      else rowsHTML = `<dt>保留</dt><dd><p class="sent">${before}</p></dd><dt>AI</dt><dd><p class="sent">${aiS}</p></dd>`;
      const choiceText = r.choice === 'adopt' ? '采用了 AI 改法' : r.choice === 'rewrite' ? '自己重写' : `保留了原句${r.auto ? '（完成时自动）' : ''}`;
      return `<li class="ex-card">
        <div class="top"><span class="tagchip">${esc(r.tag)}</span><span>${choiceText}</span><span class="grow"></span><span>${esc(r.articleTitle || '无标题')} · 第 ${r.round} 轮 · ${fmt(r.at, { dateOnly: true })}</span></div>
        <dl class="pair">${rowsHTML}</dl>
        <p class="why">${esc(r.reason)}</p>
        <div class="foot"><button type="button" class="btn ghost" data-goto-record="${r.id}">查看来历 ${icon('i-chevron-right', 'sm')}</button></div>
      </li>`;
    }).join('');
    el.content.innerHTML = `<div class="page">
      <div class="ex-head">
        <h1>改写范例</h1>
        <div class="chips" role="group" aria-label="按取舍筛选">
          ${chip('data-ex-choice', 'all', `全部 ${count('all')}`, ui.exChoice === 'all')}
          ${chip('data-ex-choice', 'adopt', `采用改法 ${count('adopt')}`, ui.exChoice === 'adopt')}
          ${chip('data-ex-choice', 'rewrite', `自己重写 ${count('rewrite')}`, ui.exChoice === 'rewrite')}
          ${chip('data-ex-choice', 'keep', `保留原句 ${count('keep')}`, ui.exChoice === 'keep')}
        </div>
        ${tags.length ? `<div class="chips" role="group" aria-label="按问题类型筛选">${chip('data-ex-tag', '', '所有类型', !ui.exTag)}${tags.map((t) => chip('data-ex-tag', t, t, ui.exTag === t)).join('')}</div>` : ''}
        <label class="search-field" style="margin:0;max-width:340px">${icon('i-search')}<input type="search" id="ex-search" placeholder="搜索句子或说明" value="${esc(ui.exQuery)}" aria-label="搜索改写范例"></label>
      </div>
      ${!recs.length ? `<div class="empty"><div class="glyph">${icon('i-quote')}</div><h3>还没有改写范例</h3></div>`
        : list.length ? `<ul class="ex-list">${cards}</ul>`
          : '<div class="empty"><h3>没有符合条件的范例</h3></div>'}
    </div>`;
  }

  el.content.addEventListener('click', (e) => {
    if (ui.view !== 'examples') return;
    const c = e.target.closest('[data-ex-choice]');
    if (c) { ui.exChoice = c.dataset.exChoice; renderExamples(); $(`[data-ex-choice="${ui.exChoice}"]`, el.content).focus(); return; }
    const t = e.target.closest('[data-ex-tag]');
    if (t) { ui.exTag = t.dataset.exTag; renderExamples(); $(`[data-ex-tag="${CSS.escape(ui.exTag)}"]`, el.content).focus(); return; }
    const g = e.target.closest('[data-goto-record]');
    if (g) gotoRecord(g.dataset.gotoRecord);
  });
  el.content.addEventListener('input', (e) => {
    if (e.target.id !== 'ex-search') return;
    ui.exQuery = e.target.value;
    const pos = e.target.selectionStart;
    renderExamples();
    const s = $('#ex-search');
    s.focus();
    s.setSelectionRange(pos, pos);
  });

  function gotoRecord(id) {
    const rec = S.allRecords(data.articles).find((r) => r.id === id);
    if (!rec) return;
    const a = data.articles.find((x) => x.id === rec.articleId);
    if (!a) return;
    data.currentId = a.id;
    ui.view = 'article';
    ui.mode = 'write';
    ui.inspectorOpen = true;
    ui.inspectorTab = 'prov';
    renderAll();
    const p = a.paragraphs.find((x) => x.id === rec.pid);
    if (!p) { toast('这一段已经不在当前稿里了'); return; }
    let best = { start: 0, score: -1 };
    for (const s of D.splitSentences(p.text)) {
      const sc = D.similarity(s.text, rec.after.text);
      if (sc > best.score) best = { start: s.start, score: sc };
    }
    setCaret(p.id, best.start);
    ui.caret = { pid: p.id, offset: best.start };
    computeProvSel();
    renderInspector();
    applyLayout();
  }

  /* ───────────────────────── 检查器 ───────────────────────── */

  function renderInspector() {
    const a = current();
    if (ui.view !== 'article' || !a) { el.inspector.innerHTML = ''; return; }
    const close = `<button type="button" class="icon-btn sm" data-insp="close" aria-label="隐藏检查器">${icon('i-x', 'sm')}</button>`;
    let html = '';
    if (ui.mode === 'review') html = inspectorReview(a, close);
    else if (ui.mode === 'history') html = inspectorHistory(a, close);
    else html = inspectorWrite(a, close);
    const scroll = $('.insp-body', el.inspector);
    const st = scroll ? scroll.scrollTop : 0;
    const focusedSel = document.activeElement && el.inspector.contains(document.activeElement) ? document.activeElement.dataset : null;
    el.inspector.innerHTML = html;
    const nb = $('.insp-body', el.inspector);
    if (nb) nb.scrollTop = st;
    if (focusedSel) {
      const key = Object.keys(focusedSel)[0];
      if (key) {
        const attr = key.replace(/[A-Z]/g, (m) => `-${m.toLowerCase()}`);
        const again = $(`[data-${attr}="${CSS.escape(focusedSel[key])}"]`, el.inspector);
        if (again) again.focus({ preventScroll: true });
      }
    }
    if (ui.mode === 'write' && ui.inspectorTab === 'prov') computeProvSelHighlightOnly();
    else clearHighlight('prov');
    syncFormatBar();
  }

  function computeProvSelHighlightOnly() {
    if (!ui.provSel || !inspectorVisible()) { clearHighlight('prov'); return; }
    const node = editorEl() && editorEl().querySelector(`p[data-pid="${CSS.escape(ui.provSel.pid)}"]`);
    if (node) setHighlight('prov', [rangeIn(node, ui.provSel.start, ui.provSel.start + ui.provSel.text.length)]);
  }

  function inspectorWrite(a, close) {
    const round = S.activeRound(a);
    const head = `<div class="insp-head"><div class="segmented" role="tablist" aria-label="检查器内容">
        <button type="button" role="tab" data-tab="marks" aria-selected="${ui.inspectorTab === 'marks'}">改稿</button>
        <button type="button" role="tab" data-tab="prov" aria-selected="${ui.inspectorTab === 'prov'}">来历</button>
      </div><span class="grow"></span>${close}</div>`;
    if (ui.inspectorTab === 'prov') return head + inspectorProvenance(a);
    if (round && round.status === 'running') {
      const run = ui.running && ui.running.articleId === a.id ? ui.running : null;
      const items = Object.keys(round.paras).map((pid) => {
        const p = a.paragraphs.find((x) => x.id === pid);
        const st = run ? run.status[pid] : 'wait';
        const label = st === 'run' ? '改稿中' : st === 'done' ? `${run.counts[pid] || 0} 处` : '';
        return `<li><span class="spinner ${st === 'run' ? '' : st === 'done' ? 'done' : 'idle'}" aria-hidden="true"></span><span class="ex">${esc(clip(p ? p.text : '', 22))}</span><span class="st">${label}</span></li>`;
      }).join('');
      return `${head}<div class="insp-body"><ul class="run-list" aria-live="polite">${items}</ul></div>
        <div class="insp-foot"><button type="button" class="btn block" data-act="cancel-run">取消改稿</button></div>`;
    }
    if (round && round.status === 'pending') {
      const m = S.reviewModel(a, round);
      return `${head}<div class="insp-body"><p class="insp-note">第 ${round.n} 轮 · ${m.total} 处修改</p></div>
        <div class="insp-foot"><button type="button" class="btn primary block" data-act="go-review">审阅</button></div>`;
    }
    const caretPid = ui.caret && a.paragraphs.some((p) => p.id === ui.caret.pid) ? ui.caret.pid : null;
    const marked = a.paragraphs.filter((p) => a.marks[p.id]);
    const list = marked.length ? `<ul class="mark-list">${marked.map((p) => {
      const idx = a.paragraphs.indexOf(p) + 1;
      const m = a.marks[p.id];
      const isCustom = Boolean(m.custom) || m.instruction === 'custom';
      return `<li class="mark-item ${p.id === caretPid ? 'is-current' : ''}">
        <button type="button" class="excerpt" data-goto="${p.id}">${esc(p.text)}</button>
        <div class="ctrl">
          <select class="select" data-instr="${p.id}" aria-label="第 ${idx} 段的修改要求">
            ${AI.INSTRUCTIONS.map((it) => `<option value="${it.id}" ${!isCustom && m.instruction === it.id ? 'selected' : ''}>${it.label}</option>`).join('')}
            <option value="custom" ${isCustom ? 'selected' : ''}>${isCustom && m.custom ? `自定义：${esc(clip(m.custom, 8))}` : '自定义…'}</option>
          </select>
          <button type="button" class="icon-btn sm" data-unmark="${p.id}" aria-label="取消标记第 ${idx} 段" title="取消标记">${icon('i-x', 'sm')}</button>
        </div></li>`;
    }).join('')}</ul>`
      : '<p class="insp-note">没有标记的段落</p>';
    return `${head}<div class="insp-body">${list}</div>
      ${marked.length ? `<div class="insp-foot"><button type="button" class="btn primary block" data-act="submit">${icon('i-revise', 'sm')}请 AI 改稿 · ${marked.length} 段</button></div>` : ''}`;
  }

  function diffSentHTML(prev, cur) {
    if (prev === null || prev === undefined) return esc(cur);
    return D.diffText(prev, cur).map((s) => (s.type === 'eq' ? esc(s.text) : `${s.del ? `<mark class="del">${esc(s.del)}</mark>` : ''}${s.ins ? `<mark class="ins">${esc(s.ins)}</mark>` : ''}`)).join('');
  }

  function inspectorProvenance(a) {
    const sel = ui.provSel;
    if (!sel) {
      return `<div class="insp-body"><p class="insp-note">把光标放在一句话上</p></div>`;
    }
    const { steps, records } = S.provenance(a, sel.pid, sel.text);
    const real = steps.filter((s) => s.text);
    const head = `<div class="insp-body"><div class="quote-current">${esc(sel.text)}</div>`;
    if (real.length <= 1) {
      return `${head}<p class="insp-note">这句话还没有经过改稿</p></div>`;
    }
    let prevAuthor = null;
    const entries = steps.map((s) => {
      const k = s.version.kind;
      const label = S.versionLabel(s.version);
      if (s.missing) return { same: false, html: `<div class="prov-step"><div class="h">${esc(label)}</div><div class="same">这句话写于这一稿之后。</div></div>` };
      let body;
      let unchanged;
      if (k === 'ai') {
        unchanged = s.text === prevAuthor;
        body = unchanged ? '<div class="same">AI 没有改这句。</div>' : `<p class="sent">${diffSentHTML(prevAuthor, s.text)}</p>`;
      } else {
        unchanged = prevAuthor !== null && s.text === prevAuthor;
        body = unchanged ? '<div class="same">与上一稿相同。</div>' : `<p class="sent">${diffSentHTML(prevAuthor, s.text)}</p>`;
        prevAuthor = s.text;
      }
      let dec = '';
      if (k === 'final') {
        const rs = records.filter((r) => r.round === s.version.round);
        if (rs.length) {
          dec = `<ul class="decisions">${rs.map((r) => {
            const ic = r.choice === 'adopt' ? 'i-check' : r.choice === 'keep' ? 'i-keep' : 'i-pen';
            let t;
            if (r.choice === 'adopt') t = r.del && r.ins ? `采用：“${clip(r.del, 12)}”→“${clip(r.ins, 12)}”` : r.del ? `采用：删去“${clip(r.del, 14)}”` : `采用：补上“${clip(r.ins, 14)}”`;
            else if (r.choice === 'keep') t = `保留“${clip(r.del, 12) || '原样'}”${r.ins ? `，没有用“${clip(r.ins, 12)}”` : ''}`;
            else t = `自己重写为“${clip(r.final, 12)}”${r.ins ? `（AI 建议“${clip(r.ins, 10)}”）` : ''}`;
            return `<li class="${r.choice}"><span class="ic">${icon(ic)}</span><span>${esc(t)}</span></li>`;
          }).join('')}</ul>`;
        }
      }
      const role = k === 'ai' ? '模拟 AI' : k === 'final' ? '你的取舍' : k === 'submitted' ? '送审' : k === 'live' ? '' : '存档';
      return {
        same: unchanged && !dec,
        label,
        html: `<div class="prov-step k-${k}"><div class="h">${esc(label)}${role ? `<span class="tl-role">${role}</span>` : ''}<time>${fmt(s.version.at)}</time></div>${body}${dec}</div>`,
      };
    });
    const out = [];
    let run = [];
    const flush = () => {
      if (run.length === 1) out.push(run[0].html);
      else if (run.length > 1) out.push(`<div class="prov-step k-same"><div class="same">${run.map((r) => esc(r.label)).join('、')}：都与上一稿相同。</div></div>`);
      run = [];
    };
    for (const en of entries) {
      if (en.same) { run.push(en); continue; }
      flush();
      out.push(en.html);
    }
    flush();
    return `${head}<div class="prov-line">${out.join('')}</div>
      <button type="button" class="btn ghost" data-prov-history="${sel.pid}" style="margin-top:4px">在历史中对比整篇 ${icon('i-chevron-right', 'sm')}</button></div>`;
  }

  function inspectorReview(a, close) {
    const round = S.activeRound(a);
    const head = `<div class="insp-head"><span class="t">审阅${round ? ` · 第 ${round.n} 轮` : ''}</span>${close}</div>`;
    if (!round || round.status !== 'pending' || !reviewModelCache) {
      return `${head}<div class="insp-body"><p class="insp-note">没有待审阅的改稿</p></div>`;
    }
    const m = reviewModelCache;
    const list = allHunks();
    const h = findHunk(ui.focusKey);
    const n = h ? list.indexOf(h) + 1 : 0;
    const pct = m.total ? (m.decided / m.total) * 100 : 0;
    let card = '';
    if (h) {
      const para = m.paras.find((p) => p.id === h.pid);
      const d = h.decision;
      const mine = d && d.choice === 'rewrite'
        ? `<dt>你的</dt><dd><p class="sent">${esc(para.base.slice(D.sentenceAround(para.base, h.bStart, h.bEnd).start, h.bStart))}<mark class="mine ${d.text ? '' : 'void'}">${esc(d.text)}</mark>${esc(para.base.slice(h.bEnd, D.sentenceAround(para.base, h.bStart, h.bEnd).end))}</p></dd>` : '';
      const btn = (c, ic, label, key) => `<button type="button" class="choice" data-insp-choice="${c}" aria-pressed="${Boolean(d && d.choice === c)}" aria-keyshortcuts="${key}" title="${label}（${key}）">${icon(ic, 'sm')}<span>${label}</span></button>`;
      card = `<div class="card">
        <h4>修改 ${n} / ${list.length} · 第 ${para.index + 1} 段<span style="flex:1"></span>
          <span class="nav-pair"><button type="button" class="icon-btn sm" data-step="-1" aria-label="上一处修改（K）" ${n <= 1 ? 'disabled' : ''}>${icon('i-chevron-left', 'sm')}</button><button type="button" class="icon-btn sm" data-step="1" aria-label="下一处修改（J）" ${n >= list.length ? 'disabled' : ''}>${icon('i-chevron-right', 'sm')}</button></span></h4>
        <dl class="kv">
          <dt>原句</dt><dd><p class="sent">${sentenceHTML(para.base, h.bStart, h.bEnd, 'del')}</p></dd>
          <dt>改句</dt><dd><p class="sent">${sentenceHTML(para.after, h.aStart, h.aEnd, 'ins')}</p></dd>
          ${mine}
        </dl>
        <p class="small" style="margin-top:10px;color:var(--text-2)"><span class="tagchip">${esc(h.tag)}</span>${esc(h.reason)}</p>
        <div class="choice-grid" role="group" aria-label="处理这处修改">
          ${btn('keep', 'i-keep', '保留原句', 'O')}${btn('adopt', 'i-check', '采用改法', 'A')}${btn('rewrite', 'i-pen', '自己重写', 'E')}
        </div>
      </div>`;
    }
    return `${head}<div class="insp-body">
        <div class="card">
          <div class="progress-row"><span class="big">${m.decided} / ${m.total}</span><span class="small muted">处已决定</span></div>
          <div class="progress" role="progressbar" aria-valuemin="0" aria-valuemax="${m.total}" aria-valuenow="${m.decided}" aria-label="审阅进度"><span style="width:${pct}%"></span></div>
          <div class="legend"><span><i style="background:var(--ins)"></i>采用 ${m.counts.adopt}</span><span><i style="background:var(--text-3)"></i>保留 ${m.counts.keep}</span><span><i style="background:var(--accent)"></i>重写 ${m.counts.rewrite}</span></div>
        </div>
        ${card}
      </div>
      <div class="insp-foot">
        <button type="button" class="btn primary block" data-act="finish">完成本轮</button>
      </div>`;
  }

  function inspectorHistory(a, close) {
    const head = `<div class="insp-head"><span class="t">版本</span>${close}</div>`;
    if (!a.versions.length) return `${head}<div class="insp-body"><p class="insp-note">还没有版本</p></div>`;
    const c = compareFor(a);
    const chain = [...a.versions, { id: 'live', kind: 'live', at: a.updatedAt, paragraphs: a.paragraphs }];
    const items = chain.map((v, i) => {
      const prev = i > 0 ? chain[i - 1] : null;
      let role = '';
      if (v.kind === 'submitted') role = '你送审的稿';
      if (v.kind === 'ai') role = '模拟 AI 生成';
      if (v.kind === 'final') {
        const r = a.rounds.find((x) => x.n === v.round);
        const cnt = { adopt: 0, keep: 0, rewrite: 0 };
        (r && r.records || []).forEach((x) => cnt[x.choice]++);
        role = `按你的取舍合成 · 采用 ${cnt.adopt} · 保留 ${cnt.keep} · 重写 ${cnt.rewrite}`;
      }
      if (v.kind === 'snapshot') role = '手动存档';
      if (v.kind === 'live') role = '正在编辑';
      let stat = '';
      if (prev) {
        const base = prev.kind === 'ai' ? chain[i - 2] : prev;
        const st = D.diffDocs(base.paragraphs, v.paragraphs).stats;
        stat = st.ins || st.del ? ` · <span class="plus">+${st.ins}</span> <span class="minus">−${st.del}</span>` : ' · 无改动';
      }
      const pressed = c.to === v.id;
      return `<li class="tl-item k-${v.kind}"><button type="button" class="tl-btn" data-tl="${v.id}" data-tl-prev="${prev ? (prev.kind === 'ai' && v.kind === 'final' ? chain[i - 2].id : prev.id) : v.id}" aria-pressed="${pressed}">
        <span class="t">${esc(S.versionLabel(v))}</span>
        <span class="s stat">${fmt(v.at)}${stat}</span>
        <span class="s">${esc(role)}</span></button></li>`;
    }).reverse().join('');
    return `${head}<div class="insp-body">
        <ul class="timeline">${items}</ul>
      </div>`;
  }

  el.inspector.addEventListener('click', (e) => {
    const b = e.target.closest('button');
    if (!b) return;
    const a = current();
    if (b.dataset.insp === 'close') { ui.inspectorOpen = false; ui.showBar = true; applyLayout(); renderToolbar(); clearHighlight('prov'); if (ui.mode === 'review') positionHunkBar(); requestAnimationFrame(renderGutter); return; }
    if (b.dataset.tab) {
      ui.inspectorTab = b.dataset.tab;
      if (ui.inspectorTab === 'prov') computeProvSel();
      renderInspector();
      const t = $(`[data-tab="${ui.inspectorTab}"]`, el.inspector);
      if (t) t.focus();
      return;
    }
    if (b.dataset.unmark) { toggleMark(b.dataset.unmark, false); return; }
    if (b.dataset.goto) {
      const p = a.paragraphs.find((x) => x.id === b.dataset.goto);
      if (p) { setCaret(p.id, p.text.length); flashParagraph(p.id); }
      return;
    }
    if (b.dataset.act === 'submit') { submitRound(); return; }
    if (b.dataset.act === 'cancel-run') { cancelRun(); return; }
    if (b.dataset.act === 'go-review') { setMode('review'); return; }
    if (b.dataset.act === 'finish') { finishRound(); return; }
    if (b.dataset.step) { stepHunk(Number(b.dataset.step)); return; }
    if (b.dataset.inspChoice) {
      const c = b.dataset.inspChoice;
      if (c === 'rewrite') openRewrite(ui.focusKey);
      else decide(ui.focusKey, c);
      return;
    }
    if (b.dataset.tl) {
      ui.compare[a.id] = { from: b.dataset.tlPrev, to: b.dataset.tl };
      renderHistory(a);
      renderInspector();
      const again = $(`[data-tl="${b.dataset.tl}"]`, el.inspector);
      if (again) again.focus();
      return;
    }
    if (b.dataset.provHistory) {
      const first = a.versions.find((v) => v.paragraphs.some((p) => p.id === b.dataset.provHistory));
      ui.compare[a.id] = { from: first ? first.id : 'live', to: 'live' };
      setMode('history');
    }
  });
  el.inspector.addEventListener('change', (e) => {
    const s = e.target.closest('[data-instr]');
    if (!s) return;
    if (s.value === 'custom') customInstruction(s.dataset.instr);
    else setInstruction(s.dataset.instr, s.value);
  });

  /* ───────────────────────── 版本、导出、说明 ───────────────────────── */

  function saveVersion() {
    const a = current();
    if (!a) return;
    if (isLocked(a)) { toast('完成本轮后会自动保存定稿'); return; }
    const t = new Date();
    const def = a.versions.length ? `存档 ${t.getMonth() + 1}月${t.getDate()}日 ${pad(t.getHours())}:${pad(t.getMinutes())}` : '初稿';
    openDialog({
      title: '存为版本',
      body: `<div class="field"><input type="text" value="${esc(def)}" aria-label="版本名称" maxlength="40"></div>`,
      actions: [{ label: '取消', value: null }, { label: '保存', value: 'ok', primary: true }],
      onClose: (v, name) => {
        if (v !== 'ok') return;
        pushUndo('存为版本', { caret: null });
        a.versions.push({ id: S.uid('v'), kind: 'snapshot', name: (name || def).trim() || def, at: Date.now(), title: a.title, paragraphs: S.snapshot(a.paragraphs) });
        touch(a);
        renderAll();
        toast(`已存为“${(name || def).trim() || def}”`, { action: { label: '查看', run: () => setMode('history') } });
      },
    });
  }

  function download(a, content, type, ext) {
    const blob = new Blob([content], { type });
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.download = `${(a.title || '无标题').replace(/[\\/:*?"<>|]/g, '_')}.${ext}`;
    document.body.appendChild(link);
    link.click();
    link.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }
  function exportMarkdown(a) {
    if (!a) return;
    download(a, S.toMarkdown(a), 'text/markdown;charset=utf-8', 'md');
    toast('已导出 Markdown');
  }
  function exportHTML(a) {
    if (!a) return;
    download(a, S.toHTML(a), 'text/html;charset=utf-8', 'html');
    toast('已导出 HTML');
  }

  function showWordCount(a) {
    const chars = charCount(a.paragraphs);
    const paras = a.paragraphs.filter((p) => p.text.trim()).length;
    openDialog({
      title: '字数统计',
      body: `<table class="count-table"><tr><td>字数</td><td>${chars}</td></tr><tr><td>段落</td><td>${paras}</td></tr><tr><td>版本</td><td>${a.versions.length}</td></tr></table>`,
      actions: [{ label: '好', value: null, primary: true }],
    });
  }

  function resetSamples() {
    openDialog({
      title: '恢复示例数据？',
      body: '<p>你在原型里写的内容会被清除。</p>',
      actions: [{ label: '取消', value: null }, { label: '恢复示例', value: 'ok', primary: true }],
      onClose: (v) => {
        if (v !== 'ok') return;
        if (ui.running) ui.running.controller.abort();
        data = window.RedraftSamples.build();
        stacks.clear();
        ui.view = 'article';
        ui.mode = 'write';
        ui.focusKey = null;
        ui.compare = {};
        save();
        renderAll();
        toast('已恢复示例数据');
      },
    });
  }

  function showShortcuts() {
    const row = (label, keys) => `<tr><td>${label}</td><td>${keys.map((k) => `<kbd>${k}</kbd>`).join('')}</td></tr>`;
    const M = K.mod;
    const SH = K.shift;
    openDialog({
      title: '键盘快捷键',
      wide: true,
      body: `<table class="shortcut-table">
        <tr><th colspan="2">排版</th></tr>
        ${row('粗体、斜体、下划线', [`${M}B`, `${M}I`, `${M}U`])}
        ${row('删除线', [`${M}${SH}X`])}
        ${row('正文、标题 1–3', [`${M}${K.alt}0`, `${M}${K.alt}1–3`])}
        ${row('编号列表、项目符号', [`${M}${SH}7`, `${M}${SH}8`])}
        ${row('增加、减少缩进', [`${M}]`, `${M}[`])}
        ${row('左对齐、居中、右对齐、两端对齐', [`${M}${SH}L`, `${M}${SH}E`, `${M}${SH}R`, `${M}${SH}J`])}
        ${row('增大、减小字号', [`${M}${SH}.`, `${M}${SH},`])}
        ${row('清除格式', [`${M}\\`])}
        ${row('粘贴为纯文本', [`${M}${SH}V`])}
        <tr><th colspan="2">写作</th></tr>
        ${row('标记给 AI 改稿', [`${M}${SH}M`])}
        ${row('请 AI 改稿', [`${M}${K.enter}`])}
        ${row('上移、下移段落', [`${K.alt}${SH}${K.up}`, `${K.alt}${SH}${K.down}`])}
        ${row('存为版本', [`${M}S`])}
        ${row('撤销、重做', [`${M}Z`, `${M}${SH}Z`])}
        ${row('移到排版工具栏', [`${K.alt}F10`])}
        <tr><th colspan="2">审阅</th></tr>
        ${row('下一处、上一处', ['J', 'K'])}
        ${row('采用、保留、重写', ['A', 'O', 'E'])}
        ${row('完成本轮', [`${M}${K.enter}`])}
      </table>`,
      actions: [{ label: '好', value: null, primary: true }],
    });
  }

  function showAbout() {
    openDialog({
      title: '关于这个原型',
      wide: true,
      body: `<p>Redraft 是以 Diff 为核心的写作编辑器。这个网页原型用来体验它的交互；正式产品计划为原生 macOS 应用。</p>
        <ul class="about-list">
          <li><b>真实运行：</b>排版（样式、字体、字号、粗斜体、颜色、对齐、列表、缩进、行距）、撤销重做、标记、版本、任意两稿对比、逐句溯源、改写范例、Markdown 与 HTML 导出。</li>
          <li><b>模拟：</b>AI 改稿。示例段落使用预置改法；其他段落只做删赘词等本地规则精简。没有网络请求。</li>
          <li><b>保存：</b>内容只保存在这个浏览器里。</li>
        </ul>`,
      actions: [{ label: '好', value: null, primary: true }],
    });
  }

  /* ───────────────────────── 全局快捷键 ───────────────────────── */

  document.addEventListener('keydown', (e) => {
    if (dialogState) return;
    const mod = isMac ? e.metaKey : e.ctrlKey;
    const tgt = e.target;
    const inField = tgt && (tgt.tagName === 'INPUT' || tgt.tagName === 'TEXTAREA' || tgt.tagName === 'SELECT');
    const inEditor = editorEl() && editorEl().contains(tgt);
    const key = e.key.length === 1 ? e.key.toLowerCase() : e.key;

    if (e.key === 'Escape') {
      if (popover) { closePopover(true); e.preventDefault(); return; }
      if (mqNarrow.matches && ui.sidebarOpen) { ui.sidebarOpen = false; applyLayout(); renderToolbar(); return; }
      if (ui.mode === 'review' && $('#hunk-bar')) { ui.showBar = false; positionHunkBar(); return; }
      if (mqMid.matches && ui.inspectorOpen && inspectorVisible()) { ui.inspectorOpen = false; applyLayout(); renderToolbar(); return; }
    }

    if (e.altKey && e.key === 'F10' && formatBarVisible()) { e.preventDefault(); focusFormatBar(); return; }
    if (el.formatbar.contains(tgt) && formatShortcut(e)) return;

    if (mod && !e.altKey) {
      if (key === 'z' && !inField) { e.preventDefault(); if (e.shiftKey) redo(); else undo(); return; }
      if (key === 'y' && !isMac && !inField) { e.preventDefault(); redo(); return; }
      if (key === 's') { e.preventDefault(); saveVersion(); return; }
      if (key === '/') { e.preventDefault(); showShortcuts(); return; }
      if (key === 'm' && e.shiftKey && ui.view === 'article' && ui.mode === 'write') {
        e.preventDefault();
        markSelection();
        return;
      }
      if (e.key === 'Enter' && ui.view === 'article') {
        e.preventDefault();
        if (ui.mode === 'write') submitRound();
        else if (ui.mode === 'review') finishRound();
        return;
      }
    }

    if (ui.view === 'article' && ui.mode === 'review' && !inField && !inEditor && !mod && !e.altKey && !popover) {
      const inBar = tgt && tgt.closest && (tgt.closest('#hunk-bar') || tgt.closest('.choice-grid'));
      if (key === 'j' || (key === 'ArrowDown' && !inBar)) { e.preventDefault(); stepHunk(1); return; }
      if (key === 'k' || (key === 'ArrowUp' && !inBar)) { e.preventDefault(); stepHunk(-1); return; }
      if (key === 'a' && ui.focusKey) { e.preventDefault(); decide(ui.focusKey, 'adopt'); return; }
      if ((key === 'o' || key === 'r') && ui.focusKey) { e.preventDefault(); decide(ui.focusKey, 'keep'); return; }
      if (key === 'e' && ui.focusKey) { e.preventDefault(); openRewrite(ui.focusKey); return; }
      if ((key === ' ' || key === 'Enter') && tgt && tgt.dataset && tgt.dataset.key) {
        e.preventDefault();
        ui.showBar = !ui.showBar;
        positionHunkBar();
      }
    }
  });

  /* ───────────────────────── 视口变化 ───────────────────────── */

  mqNarrow.addEventListener('change', () => { ui.sidebarOpen = !mqNarrow.matches; applyLayout(); renderToolbar(); });
  mqMid.addEventListener('change', () => { if (mqMid.matches) ui.inspectorOpen = false; applyLayout(); renderToolbar(); renderInspector(); });
  let resizeTimer = 0;
  window.addEventListener('resize', () => {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => {
      closePopover(false);
      hideTip();
      syncFormatBar();
      updateFbFade();
      renderGutter();
      if (ui.mode === 'review') positionHunkBar();
    }, 80);
  });
  el.app.addEventListener('transitionend', (e) => {
    if (e.target === el.app) { renderGutter(); if (ui.mode === 'review') positionHunkBar(); }
  });
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(() => renderGutter());

  /* ───────────────────────── 启动 ───────────────────────── */

  window.__redraft = { get data() { return data; }, ui, R };
  renderAll();
})();
