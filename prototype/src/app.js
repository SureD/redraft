/*
 * Redraft 原型 · 界面
 * 写作 → 标记 → 模拟 AI 改稿 → 对照取舍 → 定稿 → 回看历史与一句话的来历 → 积累写作范例。
 */
(function () {
  'use strict';

  const D = window.RedraftDiff;
  const AI = window.RedraftMockAI;
  const S = window.RedraftSession;

  const STORAGE_KEY = 'redraft.prototype.v1';
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
    content: $('#content'),
    inspector: $('#inspector'),
    scrim: $('#scrim'),
    layer: $('#layer'),
    toasts: $('#toasts'),
    announcer: $('#announcer'),
  };

  /* ───────────────────────── 数据与持久化 ───────────────────────── */

  function load() {
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      if (raw) {
        const parsed = JSON.parse(raw);
        if (parsed && parsed.schema === 3 && Array.isArray(parsed.articles)) return parsed;
      }
    } catch (_) { /* 存储不可用时退回示例数据 */ }
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
    inspectorOpen: !mqMid.matches,
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
    if (ui.mode === 'write' && entry.caret) setCaret(entry.caret.pid, entry.caret.offset);
  }

  function undo() {
    const a = current();
    if (!a) return;
    if (ui.running && ui.running.articleId === a.id) { toast('AI 正在改稿，可以先取消改稿。'); return; }
    const st = stackFor(a.id);
    const entry = st.undo.pop();
    if (!entry) { announce('没有可以撤销的操作'); toast('没有可以撤销的操作'); return; }
    st.redo.push({ label: entry.label, article: S.clone(a), mode: ui.mode, focusKey: ui.focusKey, caret: getCaret() });
    lastUndoKind = null;
    restoreEntry(entry);
    if (entry.label === '输入') announce('已撤销输入');
    else toast(`已撤销：${entry.label}`, { action: { label: '重做', run: redo } });
  }

  function redo() {
    const a = current();
    if (!a) return;
    const st = stackFor(a.id);
    const entry = st.redo.pop();
    if (!entry) { announce('没有可以重做的操作'); return; }
    st.undo.push({ label: entry.label, article: S.clone(a), mode: ui.mode, focusKey: ui.focusKey, caret: getCaret() });
    lastUndoKind = null;
    restoreEntry(entry);
    if (entry.label === '输入') announce('已重做输入');
    else toast(`已重做：${entry.label}`);
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
    const { node, anchor, onClose } = popover;
    popover = null;
    node.remove();
    if (anchor) anchor.setAttribute('aria-expanded', 'false');
    document.removeEventListener('pointerdown', onOutside, true);
    if (onClose) onClose();
    if (restoreFocus && anchor && document.contains(anchor)) anchor.focus({ preventScroll: true });
  }
  function onOutside(e) {
    if (popover && !popover.node.contains(e.target) && !(popover.anchor && popover.anchor.contains(e.target))) closePopover(false);
  }
  function openPopover(anchor, html, opts = {}) {
    closePopover(false);
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
    popover = { node, anchor, onClose: opts.onClose };
    setTimeout(() => document.addEventListener('pointerdown', onOutside, true), 0);
    node.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); closePopover(true); return; }
      const items = $$('.menu-item', node);
      if (!items.length) return;
      const i = items.indexOf(document.activeElement);
      if (e.key === 'ArrowDown') { e.preventDefault(); items[(i + 1) % items.length].focus(); }
      if (e.key === 'ArrowUp') { e.preventDefault(); items[(i - 1 + items.length) % items.length].focus(); }
      if (e.key === 'Home') { e.preventDefault(); items[0].focus(); }
      if (e.key === 'End') { e.preventDefault(); items[items.length - 1].focus(); }
      if (e.key === 'Tab') closePopover(false);
    });
    const first = opts.focus ? $(opts.focus, node) : $('.menu-item, textarea, input, button', node);
    if (first) first.focus({ preventScroll: true });
    return node;
  }

  function openMenu(anchor, items, opts = {}) {
    const html = `<div class="menu" role="menu">${items.map((it, i) => {
      if (it === '-') return '<div class="menu-sep" role="separator"></div>';
      if (it.label && it.heading) return `<div class="menu-label">${esc(it.label)}</div>`;
      const role = it.checked !== undefined ? 'menuitemradio' : 'menuitem';
      return `<button type="button" class="menu-item ${it.danger ? 'danger' : ''}" role="${role}" data-i="${i}" ${it.checked !== undefined ? `aria-checked="${it.checked}"` : ''}>
        ${it.icon ? icon(it.icon) : ''}<span class="grow">${esc(it.label)}</span>${it.kbd ? `<kbd>${esc(it.kbd)}</kbd>` : ''}</button>`;
    }).join('')}</div>`;
    const node = openPopover(anchor, html, { ...opts });
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
    if (!silent && prev && document.contains(prev)) prev.focus({ preventScroll: true });
    if (!silent && onClose) onClose(value, inputValue);
  }

  /* ───────────────────────── 布局 ───────────────────────── */

  function applyLayout() {
    el.app.classList.toggle('no-sidebar', !ui.sidebarOpen);
    el.app.classList.toggle('no-inspector', !inspectorVisible());
    el.app.dataset.mode = ui.view === 'examples' ? 'examples' : ui.mode;
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
        '-',
        { label: '删除文章', icon: 'i-trash', danger: true, run: () => deleteArticle(id) },
      ]);
    }
  });
  $('#new-article').addEventListener('click', newArticle);
  $('#about-btn').addEventListener('click', showAbout);
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

  function statusLine(a) {
    if (ui.running && ui.running.articleId === a.id) return `AI 正在改稿 · 第 ${ui.running.roundN} 轮（本地模拟）`;
    const r = S.activeRound(a);
    if (r && r.status === 'pending') return `第 ${r.n} 轮改稿已返回 · 待审阅`;
    if (ui.mode === 'history') return `${a.versions.length} 个版本 · ${a.rounds.filter((x) => x.status === 'done').length} 轮改稿`;
    return `已保存在本机 · ${fmt(a.updatedAt)}`;
  }

  function renderToolbar() {
    const a = current();
    const sidebarBtn = `<button type="button" class="icon-btn" id="tb-sidebar" aria-label="${ui.sidebarOpen ? '隐藏' : '显示'}文章库" aria-pressed="${ui.sidebarOpen}" title="文章库">${icon('i-sidebar')}</button>`;
    if (ui.view === 'examples') {
      const recs = S.allRecords(data.articles);
      const n = new Set(recs.map((r) => r.articleId)).size;
      el.toolbar.innerHTML = `${sidebarBtn}<div class="tb-title"><span class="t">改写范例</span><span class="s">${recs.length} 处取舍 · 来自 ${n} 篇文章</span></div>`;
      return;
    }
    if (!a) {
      el.toolbar.innerHTML = `${sidebarBtn}<div class="tb-title"><span class="t">Redraft</span></div>`;
      return;
    }
    const round = S.activeRound(a);
    const pending = round && round.status === 'pending';
    const running = round && round.status === 'running';
    const markCount = Object.keys(a.marks).length;
    let primary = '';
    if (ui.mode === 'write') {
      if (running) primary = '<button type="button" class="btn" disabled><span class="spinner" aria-hidden="true"></span>改稿中…</button>';
      else if (pending) primary = `<button type="button" class="btn primary" data-act="go-review">${icon('i-revise', 'sm')}<span><span class="hide-narrow">继续</span>审阅</span></button>`;
      else primary = `<button type="button" class="btn primary" data-act="submit" ${markCount ? '' : 'disabled'} title="请 AI 改稿（${K.mod}${K.enter}）">${icon('i-revise', 'sm')}<span><span class="hide-narrow">请 AI </span>改稿${markCount ? `<span class="count"> · ${markCount}</span>` : ''}</span></button>`;
    } else if (ui.mode === 'review' && pending) {
      primary = `<button type="button" class="btn primary" data-act="finish" title="完成本轮（${K.mod}${K.enter}）">${icon('i-check', 'sm')}<span>完成<span class="hide-narrow">本轮</span></span></button>`;
    }
    const seg = (mode, label, extra = '') => `<button type="button" data-mode="${mode}" aria-pressed="${ui.mode === mode}">${label}${extra}</button>`;
    el.toolbar.innerHTML = `
      ${sidebarBtn}
      <div class="tb-title"><span class="t">${esc(a.title || '无标题')}</span><span class="s">${esc(statusLine(a))}</span></div>
      <div class="segmented" role="group" aria-label="视图">
        ${seg('write', '写作')}${seg('review', '审阅', pending ? '<span class="pip" aria-label="（待审阅）"></span>' : '')}${seg('history', '历史')}
      </div>
      <div class="tb-group" style="flex:1 1 0;justify-content:flex-end">
        ${ui.mode === 'write' ? `<button type="button" class="icon-btn hide-narrow" data-act="snapshot" aria-label="存为版本" title="存为版本（${K.mod}S）">${icon('i-bookmark')}</button>` : ''}
        ${primary}
        <button type="button" class="icon-btn" data-act="more" aria-haspopup="menu" aria-expanded="false" aria-label="更多">${icon('i-more')}</button>
        <button type="button" class="icon-btn" data-act="inspector" aria-pressed="${ui.inspectorOpen}" aria-label="${ui.inspectorOpen ? '隐藏' : '显示'}检查器" title="检查器">${icon('i-inspector')}</button>
      </div>`;
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
    if (act === 'snapshot') saveVersion();
    if (act === 'inspector') { ui.inspectorOpen = !ui.inspectorOpen; ui.showBar = !ui.inspectorOpen; renderInspector(); applyLayout(); renderToolbar(); if (ui.mode === 'review') positionHunkBar(); requestAnimationFrame(renderGutter); }
    if (act === 'more') openMoreMenu(b);
  });

  function openMoreMenu(anchor) {
    const a = current();
    openMenu(anchor, [
      ...(a ? [
        { label: '存为版本', icon: 'i-bookmark', kbd: `${K.mod}S`, run: saveVersion },
        { label: '导出 Markdown', icon: 'i-export', run: () => exportMarkdown(a) },
        { label: '查看这句话的来历', icon: 'i-history', kbd: `${K.mod}I`, run: openProvenance },
        '-',
      ] : []),
      { label: '键盘快捷键', icon: 'i-keyboard', kbd: `${K.mod}/`, run: showShortcuts },
      { label: '关于此原型', icon: 'i-info', run: showAbout },
      '-',
      { label: '恢复示例数据', icon: 'i-reset', run: resetSamples },
    ], { alignRight: true });
  }

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
    el.content.onscroll = () => el.toolbar.classList.toggle('scrolled', el.content.scrollTop > 4);
    if (renderContent.sameView === `${ui.view}:${data.currentId}:${ui.mode}`) el.content.scrollTop = keepScroll;
    else el.content.scrollTop = 0;
    renderContent.sameView = `${ui.view}:${data.currentId}:${ui.mode}`;
    el.toolbar.classList.toggle('scrolled', el.content.scrollTop > 4);
  }

  function renderNoArticle() {
    el.content.innerHTML = `<div class="empty full">
      <div class="glyph">${icon('i-doc')}</div>
      <h3>还没有文章</h3>
      <p>新建一篇，先专心把话写下来。写完一轮后，再标记想请 AI 修改的段落。</p>
      <button type="button" class="btn primary" id="empty-new" style="margin-top:6px">${icon('i-compose', 'sm')}新建文章</button>
    </div>`;
    $('#empty-new').addEventListener('click', newArticle);
  }

  /* ───────────────────────── 写作 ───────────────────────── */

  function renderWrite(a) {
    const round = S.activeRound(a);
    let banner = '';
    if (round && round.status === 'running') {
      banner = `<div class="banner"><div class="banner-inner" role="status"><span class="spinner" aria-hidden="true"></span><span class="grow">AI 正在按标记改稿（本地模拟），改完前正文暂不能编辑。</span><button type="button" class="btn" data-act="cancel-run">取消改稿</button></div></div>`;
    } else if (round && round.status === 'pending') {
      banner = `<div class="banner"><div class="banner-inner">${icon('i-revise')}<span class="grow">第 ${round.n} 轮改稿已返回。审阅完成前，正文保持送审时的样子。</span><button type="button" class="btn primary" data-act="go-review">开始审阅</button></div></div>`;
    }
    el.content.innerHTML = `${banner}
      <div class="page">
        <textarea class="title-input" id="title-input" rows="1" placeholder="无标题" aria-label="标题" ${round ? 'readonly' : ''}>${esc(a.title)}</textarea>
        <div class="meta-line" id="meta-line"></div>
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
    const n = a.paragraphs.filter((p) => p.text.trim()).length;
    m.innerHTML = `<span>${fmt(a.updatedAt)}</span><span>${n} 段</span><span>${charCount(a.paragraphs)} 字</span>${a.versions.length ? `<span>${a.versions.length} 个版本</span>` : ''}`;
  }

  function autosizeTitle() {
    const t = $('#title-input');
    if (!t) return;
    t.style.height = 'auto';
    t.style.height = `${t.scrollHeight}px`;
  }

  const editorEl = () => $('#editor');

  function renderEditorParas() {
    const a = current();
    const ed = editorEl();
    if (!a || !ed) return;
    ed.innerHTML = a.paragraphs.map((p) => `<p data-pid="${p.id}">${p.text ? esc(p.text) : '<br>'}</p>`).join('');
    updateDecor();
  }

  function updateDecor() {
    const a = current();
    const ed = editorEl();
    if (!a || !ed) return;
    const only = a.paragraphs.length === 1;
    const run = ui.running && ui.running.articleId === a.id ? ui.running : null;
    $$('p', ed).forEach((p) => {
      const pid = p.dataset.pid;
      const text = p.textContent;
      p.classList.toggle('is-marked', Boolean(a.marks[pid]));
      p.classList.toggle('is-empty', !text);
      p.classList.toggle('is-revising', Boolean(run && run.current === pid));
      if (!text && only) p.dataset.placeholder = '从第一句话开始写。写完一轮后，标记想请 AI 修改的段落。';
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
      const top = p.offsetTop + (mark ? 8 : 0) + 3;
      const show = !locked && (ui.hoverPid === pid || (ui.caret && ui.caret.pid === pid));
      html.push(`<div class="g-item ${mark ? 'marked' : ''} ${show ? 'show' : ''}" data-pid="${pid}" style="top:${top}px">
        ${locked ? '' : `<button type="button" class="g-btn g-handle" data-drag="${pid}" tabindex="-1" aria-hidden="true" title="拖动以移动段落（${K.alt}${K.shift}${K.up}/${K.down}）">${icon('i-grip', 'sm')}</button>`}
        <button type="button" class="g-btn g-mark" data-mark="${pid}" tabindex="-1" aria-hidden="true" ${locked ? 'disabled' : ''} title="${mark ? '取消标记' : '标记给 AI 修改'}（${K.mod}${K.shift}M）">${icon(mark ? 'i-mark-on' : 'i-mark', 'sm')}</button>
      </div>`);
      if (mark) {
        let state = '';
        if (run) {
          const st = run.status[pid];
          state = st === 'run' ? '正在改稿…' : st === 'done' ? '已改完' : '等待中';
        }
        const chipTop = p.offsetTop + p.offsetHeight - 30;
        html.push(`<button type="button" class="g-chip" data-chip="${pid}" tabindex="-1" aria-hidden="true" style="top:${chipTop}px;left:0" ${locked ? 'disabled' : ''}>
          ${icon('i-revise')}${esc(S.instructionLabel(mark))}${state ? `<span class="state">· ${state}</span>` : icon('i-chevron-down')}</button>`);
      }
    });
    g.innerHTML = html.join('');
  }

  function refreshGutterVisibility() {
    const a = current();
    const locked = isLocked(a);
    $$('.g-item').forEach((it) => {
      const pid = it.dataset.pid;
      it.classList.toggle('show', !locked && (ui.hoverPid === pid || (ui.caret && ui.caret.pid === pid)));
    });
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
    const topLimit = box.top + 64;
    const bottomLimit = box.bottom - 48;
    if (rect.bottom > bottomLimit) el.content.scrollTop += rect.bottom - bottomLimit + 24;
    else if (rect.top < topLimit) el.content.scrollTop -= topLimit - rect.top + 24;
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

  /* —— DOM → 段落模型同步（输入法组字期间不同步，确认上屏后再同步）—— */

  let composing = false;

  function syncFromDOM() {
    const a = current();
    const ed = editorEl();
    if (!a || !ed || composing) return;
    const sel = window.getSelection();
    let caretIdx = -1;
    let caretOff = 0;
    const caret = getCaret();
    const out = [];
    const seen = new Set();
    let structural = false;
    for (const node of Array.from(ed.childNodes)) {
      if (node.nodeType === 3) {
        if (!node.data) continue;
        structural = true;
        if (out.length) out[out.length - 1].text += node.data;
        else out.push({ id: S.uid('p'), text: node.data });
        continue;
      }
      if (node.nodeType !== 1) continue;
      if (node.tagName !== 'P') structural = true;
      let id = node.dataset && node.dataset.pid;
      if (!id || seen.has(id)) { id = S.uid('p'); structural = true; }
      seen.add(id);
      if (node.querySelector('*:not(br)')) structural = true;
      if (sel && sel.rangeCount && node.contains(sel.getRangeAt(0).startContainer)) {
        caretIdx = out.length;
        caretOff = offsetIn(node, sel.getRangeAt(0).startContainer, sel.getRangeAt(0).startOffset);
      }
      out.push({ id, text: node.textContent.replace(/\u200b/g, '') });
    }
    if (!out.length) { out.push({ id: (a.paragraphs[0] && a.paragraphs[0].id) || S.uid('p'), text: '' }); structural = true; caretIdx = 0; }
    const changed = out.length !== a.paragraphs.length || out.some((p, i) => p.id !== a.paragraphs[i].id || p.text !== a.paragraphs[i].text);
    if (changed) {
      const now = Date.now();
      if (lastUndoKind !== 'typing' || now - lastTypingAt > 1500) pushUndo('输入', { kind: 'typing', caret: caretBeforeInput || caret });
      lastTypingAt = now;
      a.paragraphs = out;
      for (const pid of Object.keys(a.marks)) if (!out.some((p) => p.id === pid)) delete a.marks[pid];
      touch(a);
    }
    if (structural) {
      renderEditorParas();
      const target = out[Math.max(0, caretIdx)] || out[0];
      setCaret(target.id, caretIdx >= 0 ? caretOff : 0);
    } else if (changed) {
      updateDecor();
    }
    if (changed) afterTextChange();
  }

  let afterTimer = 0;
  function afterTextChange() {
    renderMeta();
    clearTimeout(afterTimer);
    afterTimer = setTimeout(() => {
      renderSidebar();
      renderToolbar();
      if (inspectorVisible()) renderInspector();
    }, 160);
  }

  function deleteSelectionModel(c) {
    const a = current();
    const i1 = a.paragraphs.findIndex((p) => p.id === c.pid);
    const i2 = a.paragraphs.findIndex((p) => p.id === c.endPid);
    if (i1 < 0 || i2 < 0) return c;
    const first = a.paragraphs[i1];
    if (i1 === i2) {
      first.text = first.text.slice(0, c.offset) + first.text.slice(c.endOffset);
    } else {
      const last = a.paragraphs[i2];
      first.text = first.text.slice(0, c.offset) + last.text.slice(c.endOffset);
      const removed = a.paragraphs.splice(i1 + 1, i2 - i1);
      for (const p of removed) delete a.marks[p.id];
    }
    return { pid: c.pid, offset: c.offset, endPid: c.pid, endOffset: c.offset, collapsed: true };
  }

  function splitAtCaret() {
    const a = current();
    let c = getCaret();
    if (!a || !c) return;
    pushUndo('分段', { caret: c });
    if (!c.collapsed) c = deleteSelectionModel(c);
    const idx = a.paragraphs.findIndex((p) => p.id === c.pid);
    const p = a.paragraphs[idx];
    let caretPid;
    if (c.offset === 0 && p.text.length > 0) {
      a.paragraphs.splice(idx, 0, { id: S.uid('p'), text: '' });
      caretPid = p.id;
    } else {
      const np = { id: S.uid('p'), text: p.text.slice(c.offset) };
      p.text = p.text.slice(0, c.offset);
      a.paragraphs.splice(idx + 1, 0, np);
      caretPid = np.id;
    }
    touch(a);
    renderEditorParas();
    setCaret(caretPid, 0);
    afterTextChange();
  }

  function pasteText(text) {
    const a = current();
    let c = getCaret();
    if (!a || !c) return;
    const lines = text.replace(/\r\n?/g, '\n').split('\n').map((l) => l.replace(/\t/g, ' ')).filter((l) => l.trim());
    if (!lines.length) return;
    pushUndo('粘贴', { caret: c });
    if (!c.collapsed) c = deleteSelectionModel(c);
    const idx = a.paragraphs.findIndex((p) => p.id === c.pid);
    const p = a.paragraphs[idx];
    const left = p.text.slice(0, c.offset);
    const right = p.text.slice(c.offset);
    if (lines.length === 1) {
      p.text = left + lines[0] + right;
      touch(a);
      renderEditorParas();
      setCaret(p.id, left.length + lines[0].length);
    } else {
      p.text = left + lines[0];
      const added = lines.slice(1).map((l) => ({ id: S.uid('p'), text: l }));
      const last = added[added.length - 1];
      const caretOff = last.text.length;
      last.text += right;
      a.paragraphs.splice(idx + 1, 0, ...added);
      touch(a);
      renderEditorParas();
      setCaret(last.id, caretOff);
    }
    lastUndoKind = 'paste';
    afterTextChange();
  }

  function moveParagraph(pid, toIndex, via) {
    const a = current();
    if (!a || isLocked(a)) return;
    const from = a.paragraphs.findIndex((p) => p.id === pid);
    if (from < 0) return;
    const target = Math.max(0, Math.min(a.paragraphs.length - 1, toIndex));
    if (target === from) return;
    const c = getCaret();
    pushUndo('移动段落', { caret: c });
    const [p] = a.paragraphs.splice(from, 1);
    a.paragraphs.splice(target, 0, p);
    touch(a);
    renderEditorParas();
    if (c && c.pid === pid) setCaret(pid, c.offset);
    else if (via === 'drag') setCaret(pid, 0);
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
    const c = getCaret();
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
    pushUndo('修改要求', { caret: getCaret() });
    a.marks[pid] = { instruction, custom: custom || '' };
    touch(a);
    updateDecor();
    renderInspector();
  }

  function openChipMenu(chip, pid) {
    const a = current();
    const mark = a.marks[pid];
    const items = [
      { label: '想怎样修改这一段', heading: true },
      ...AI.INSTRUCTIONS.map((it) => ({ label: it.label, checked: !mark.custom && mark.instruction === it.id, run: () => setInstruction(pid, it.id) })),
      { label: mark.custom ? `自定义：${clip(mark.custom, 10)}` : '自定义要求…', checked: Boolean(mark.custom), run: () => customInstruction(pid) },
      '-',
      { label: '取消标记', icon: 'i-x', run: () => toggleMark(pid, false) },
    ];
    openMenu(chip, items);
  }

  function customInstruction(pid) {
    const a = current();
    const mark = a.marks[pid];
    openDialog({
      title: '自定义修改要求',
      body: `<p>用一句话告诉 AI 你希望这一段怎样改。原型里的模拟服务不会理解这句话：示例段落仍使用预置改法，其他段落只做简单规则精简。</p>
        <div class="field"><input type="text" value="${esc(mark.custom || '')}" placeholder="例如：保留口语感，只删重复的词" aria-label="修改要求"></div>`,
      actions: [{ label: '取消', value: null }, { label: '确定', value: 'ok', primary: true }],
      onClose: (v, text) => {
        if (v === 'ok' && text && text.trim()) setInstruction(pid, 'custom', text.trim());
      },
    });
  }

  /* —— 编辑器事件 —— */

  el.content.addEventListener('beforeinput', (e) => {
    const ed = editorEl();
    if (!ed || !ed.contains(e.target)) return;
    if (!ed.isContentEditable) { e.preventDefault(); return; }
    caretBeforeInput = getCaret();
    const t = e.inputType;
    if (t === 'historyUndo') { e.preventDefault(); undo(); return; }
    if (t === 'historyRedo') { e.preventDefault(); redo(); return; }
    if (t === 'insertParagraph' || t === 'insertLineBreak') {
      if (composing || e.isComposing) return;
      e.preventDefault();
      splitAtCaret();
      return;
    }
    if (t && t.startsWith('format')) e.preventDefault();
    if (t === 'insertFromDrop') {
      e.preventDefault();
      const text = e.dataTransfer && e.dataTransfer.getData('text/plain');
      if (text) pasteText(text);
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
    if (editorEl() && editorEl().contains(e.target)) { composing = true; caretBeforeInput = getCaret(); }
  });
  el.content.addEventListener('compositionend', (e) => {
    if (editorEl() && editorEl().contains(e.target)) { composing = false; syncFromDOM(); }
  });
  el.content.addEventListener('paste', (e) => {
    const ed = editorEl();
    if (!ed || !ed.contains(e.target)) return;
    e.preventDefault();
    if (!ed.isContentEditable) return;
    const text = e.clipboardData && e.clipboardData.getData('text/plain');
    if (text) pasteText(text);
  });
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
    if (e.altKey && e.shiftKey && (e.key === 'ArrowUp' || e.key === 'ArrowDown')) {
      e.preventDefault();
      const c = getCaret();
      const a = current();
      if (!c || !a) return;
      const i = a.paragraphs.findIndex((p) => p.id === c.pid);
      moveParagraph(c.pid, i + (e.key === 'ArrowUp' ? -1 : 1));
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
  el.content.addEventListener('mousemove', (e) => {
    const wrap = $('#editor-wrap');
    if (!wrap || dragState) return;
    let pid = null;
    const p = e.target.closest && e.target.closest('#editor > p');
    if (p) pid = p.dataset.pid;
    else {
      const it = e.target.closest && e.target.closest('.g-item, .g-chip');
      if (it) pid = it.dataset.pid || it.dataset.chip;
    }
    if (pid !== ui.hoverPid) { ui.hoverPid = pid; refreshGutterVisibility(); }
  });
  el.content.addEventListener('transitionend', (e) => {
    if (e.target.matches && e.target.matches('#editor > p')) renderGutter();
  });
  el.content.addEventListener('mouseleave', () => { if (ui.hoverPid) { ui.hoverPid = null; refreshGutterVisibility(); } });

  el.content.addEventListener('click', (e) => {
    const b = e.target.closest('button, [data-key]');
    if (!b) return;
    if (b.dataset.mark) { toggleMark(b.dataset.mark); return; }
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
    if (changedPid) refreshGutterVisibility();
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
    if (!order.length) { toast('先标记想请 AI 修改的段落'); return; }
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
        announce(`改稿完成，共 ${total} 处修改。按 A 采用，O 保留原句，E 自己重写。`);
      } else {
        renderSidebar();
        toast(`“${a.title || '无标题'}”改稿完成，共 ${total} 处修改`, { action: { label: '去审阅', run: () => openArticle(a.id, { mode: 'review' }) } });
      }
    } catch (err) {
      if (err && err.name === 'AbortError') {
        S.cancelRound(a, round);
        stackFor(a.id).undo.pop();
        ui.running = null;
        touch(a);
        if (data.currentId === a.id) renderAll();
        else renderSidebar();
        toast('已取消改稿，标记保留不变');
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

  function hunkHTML(h, variant, n) {
    const d = h.decision;
    const cls = `hunk ${d ? `is-${d.choice}` : 'is-pending'} ${ui.focusKey === h.key ? 'is-focused' : ''}`;
    const attrs = `class="${cls}" data-key="${h.key}" role="button" tabindex="${ui.focusKey === h.key && variant !== 'base' && variant !== 'result' ? 0 : -1}" aria-label="${esc(hunkLabel(h, n))}"`;
    const delS = h.del ? `<span class="seg-del">${esc(h.del)}</span>` : '';
    const insS = h.ins ? `<span class="seg-ins">${esc(h.ins)}</span>` : '';
    if (variant === 'base') {
      return `<span ${attrs}>${h.del ? delS : '<span class="ins-point" aria-hidden="true"></span>'}</span>`;
    }
    if (variant === 'ai') {
      return `<span ${attrs}>${h.ins ? insS : '<span class="del-point" aria-hidden="true"></span>'}</span>`;
    }
    if (!d) {
      if (variant === 'result') return `<span ${attrs}><span class="pending-ghost">${esc(h.del) || '<span class="ins-point" aria-hidden="true"></span>'}</span></span>`;
      return `<span ${attrs}>${delS}${insS}</span>`;
    }
    const chosen = d.choice === 'adopt' ? h.ins : d.choice === 'keep' ? h.del : d.text;
    return `<span ${attrs}><span class="chosen ${chosen ? '' : 'void'}">${esc(chosen)}</span></span>`;
  }

  function paraHTML(para, variant, counter) {
    let out = '';
    let hi = 0;
    for (const s of para.segments) {
      if (s.type === 'eq') out += esc(s.text);
      else { const h = para.hunks[hi++]; out += hunkHTML(h, variant, counter.get(h.key)); }
    }
    return out;
  }

  function renderReview(a) {
    const round = S.activeRound(a);
    if (!round || round.status !== 'pending') {
      reviewModelCache = null;
      const last = [...a.rounds].reverse().find((r) => r.status === 'done');
      const running = round && round.status === 'running';
      el.content.innerHTML = `<div class="empty full">
        <div class="glyph">${running ? '<span class="spinner" style="width:24px;height:24px"></span>' : icon('i-revise')}</div>
        <h3>${running ? 'AI 正在改稿' : '没有待审阅的改稿'}</h3>
        <p>${running ? '改完后，这里会按文章顺序列出每一处修改，供你对照送审稿逐处取舍。' : `在写作视图里标记段落并请 AI 改稿，改稿返回后会出现在这里。${last ? `最近一轮（第 ${last.n} 轮）的取舍可以在“历史”里回看。` : ''}`}</p>
        <div style="display:flex;gap:8px;margin-top:6px">
          <button type="button" class="btn ${running ? '' : 'primary'}" data-act="go-write">回到写作</button>
          ${last ? '<button type="button" class="btn" data-act="go-history">查看历史</button>' : ''}
        </div></div>`;
      const gh = $('[data-act="go-history"]', el.content);
      if (gh) gh.addEventListener('click', () => setMode('history'));
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
    const markedCount = model.paras.filter((p) => p.marked).length;
    const body = model.paras.map((para) => {
      if (!para.marked) return `<p class="r-para context">${esc(para.base)}</p>`;
      const decided = para.hunks.filter((h) => h.decision).length;
      const head = `<div class="r-head">
          <span>第 ${para.index + 1} 段</span><span class="tag">${esc(S.instructionLabel(para.meta))}</span>
          <span>${para.hunks.length ? `${para.hunks.length} 处修改${decided ? ` · 已决定 ${decided}` : ''}` : '没有修改'}</span>
          <span class="grow"></span>
          ${para.hunks.length ? `<button type="button" class="link" data-bulk="keep" data-pid="${para.id}">全部保留</button><button type="button" class="link" data-bulk="adopt" data-pid="${para.id}">全部采用</button>` : ''}
        </div>`;
      let inner;
      if (!para.hunks.length) {
        inner = `<p class="r-para">${esc(para.base)}</p><p class="r-note">${para.meta.source === 'none' ? '模拟改稿没有找到要改的地方。原型里，示例段落之外的文字只做删赘词等简单规则精简。' : 'AI 没有修改这一段。'}</p>`;
      } else if (ui.diffLayout === 'stacked') {
        inner = `<div class="stack-label">送审稿</div><p class="r-para">${paraHTML(para, 'base', counter)}</p>
          <div class="stack-label">AI 改稿</div><p class="r-para">${paraHTML(para, 'ai', counter)}</p>
          <div class="stack-label">你的定稿</div><p class="r-para">${paraHTML(para, 'result', counter)}</p>`;
      } else {
        inner = `<p class="r-para">${paraHTML(para, 'inline', counter)}</p>`;
      }
      return `<section class="r-block ${para.id === focusPid ? 'is-current' : ''}" data-pid="${para.id}" aria-label="第 ${para.index + 1} 段，${para.hunks.length} 处修改">${head}${inner}</section>`;
    }).join('');
    el.content.innerHTML = `
      <div class="subbar">
        <span class="label">第 ${round.n} 轮 · 对照送审稿阅读 AI 改稿</span>
        <span class="grow"></span>
        <div class="segmented small" role="group" aria-label="对比方式">
          <button type="button" data-layout="inline" aria-pressed="${ui.diffLayout === 'inline'}">行内</button>
          <button type="button" data-layout="stacked" aria-pressed="${ui.diffLayout === 'stacked'}">上下对照</button>
        </div>
      </div>
      <div class="page" id="review-page">
        <h1 class="r-title">${esc(a.title || '无标题')}</h1>
        <div class="meta-line"><span>送审于 ${fmt(round.submittedAt)}</span><span>标记 ${markedCount} 段</span><span>${model.total} 处修改</span><span>改稿由本地模拟</span></div>
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
        <button type="button" class="choice" data-choice="keep" aria-pressed="${Boolean(d && d.choice === 'keep')}">${icon('i-keep', 'sm')}保留原句<kbd>O</kbd></button>
        <button type="button" class="choice" data-choice="adopt" aria-pressed="${Boolean(d && d.choice === 'adopt')}">${icon('i-check', 'sm')}采用改法<kbd>A</kbd></button>
        <button type="button" class="choice" data-choice="rewrite" aria-pressed="${Boolean(d && d.choice === 'rewrite')}">${icon('i-pen', 'sm')}自己重写<kbd>E</kbd></button>
      </div>${inspectorVisible() ? '' : `<div class="why"><span class="tagchip">${esc(h.tag)}</span>${esc(h.reason)}</div>`}`;
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
        <label class="small muted" for="rw-text">用你自己的写法替换标出的部分</label>
        <textarea id="rw-text" rows="2">${esc(initial)}</textarea>
        <div class="small muted">替换后</div><p class="sent" id="rw-preview" style="font-size:13px" aria-live="polite"></p>
        <div class="actions"><span class="hint">${K.enter} 使用 · Esc 取消</span><button type="button" class="btn" data-rw="cancel">取消</button><button type="submit" class="btn primary">使用这段</button></div>
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
        title: `还有 ${left} 处没有决定`,
        body: '<p>完成本轮时，这些修改要怎样处理？生成定稿后仍可撤销。</p>',
        actions: [
          { label: '返回审阅', value: null },
          { label: '保留原句', value: 'keep' },
          { label: '采用改法', value: 'adopt', primary: true },
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
    toast(`已生成“定稿 · 第 ${round.n} 轮”：采用 ${c.adopt} · 保留 ${c.keep} · 重写 ${c.rewrite}`, { action: { label: '撤销', run: undo } });
    announce(`已生成定稿。${round.records.length} 处取舍已加入改写范例。`);
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
        <p>送审一轮改稿，或按 ${K.mod}S 存为版本后，各稿会按时间出现在这里，可以任意两稿对照着读。</p>
        <button type="button" class="btn primary" data-act="snapshot" style="margin-top:6px">${icon('i-bookmark', 'sm')}存为版本</button>
      </div>`;
      return;
    }
    const c = compareFor(a);
    const from = S.getVersion(a, c.from);
    const to = S.getVersion(a, c.to);
    const { rows, stats } = D.diffDocs(from.paragraphs, to.paragraphs);
    const parts = [];
    let sameRun = [];
    const flush = () => {
      if (!sameRun.length) return;
      if (ui.onlyChanges) parts.push(`<div class="h-collapsed"><button type="button" data-expand>${sameRun.length} 段未改动</button></div>`);
      else parts.push(...sameRun.map((r) => `<p class="h-row same">${esc(r.target)}</p>`));
      sameRun = [];
    };
    for (const r of rows) {
      if (r.status === 'same' && !r.moved) { sameRun.push(r); continue; }
      flush();
      if (r.status === 'added') parts.push(`<p class="h-row added"><span class="h-badge">新增段落</span><span class="seg-ins">${esc(r.target)}</span></p>`);
      else if (r.status === 'removed') parts.push(`<p class="h-row removed"><span class="h-badge">删去段落</span><span class="seg-del">${esc(r.base)}</span></p>`);
      else {
        const html = r.segments.map((s) => (s.type === 'eq' ? esc(s.text) : `${s.del ? `<span class="seg-del">${esc(s.del)}</span>` : ''}${s.ins ? `<span class="seg-ins">${esc(s.ins)}</span>` : ''}`)).join('');
        parts.push(`<p class="h-row ${r.status}">${r.moved ? '<span class="h-badge">已移动</span>' : ''}${html}</p>`);
      }
    }
    flush();
    const titleDiff = from.title !== to.title
      ? D.diffText(from.title || '', to.title || '').map((s) => (s.type === 'eq' ? esc(s.text) : `${s.del ? `<span class="seg-del">${esc(s.del)}</span>` : ''}${s.ins ? `<span class="seg-ins">${esc(s.ins)}</span>` : ''}`)).join('')
      : esc(to.title || '无标题');
    const same = c.from === c.to || (!stats.paras && from.title === to.title);
    el.content.innerHTML = `
      <div class="subbar">
        <span class="cmp-pair">
          <label class="pill-select">从 <select class="select" data-cmp="from" aria-label="对比起点">${versionOptions(a, c.from)}</select></label>
          <button type="button" class="icon-btn sm" data-swap aria-label="交换起点和终点" title="交换">${icon('i-swap', 'sm')}</button>
          <label class="pill-select">到 <select class="select" data-cmp="to" aria-label="对比终点">${versionOptions(a, c.to)}</select></label>
        </span>
        <span class="grow"></span>
        <label class="pill-select"><input type="checkbox" data-only ${ui.onlyChanges ? 'checked' : ''}> 折叠未改动段落</label>
      </div>
      <div class="page">
        <h1 class="r-title">${titleDiff}</h1>
        <div class="meta-line"><span class="stat">${same ? (c.from === c.to ? '同一稿' : '两稿相同') : `<span class="plus">+${stats.ins}</span> 字 · <span class="minus">−${stats.del}</span> 字 · ${stats.paras} 段有改动`}</span><span>${esc(S.versionLabel(from))} → ${esc(S.versionLabel(to))}</span></div>
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
        <div class="foot"><button type="button" class="btn ghost" data-goto-record="${r.id}">在文章中查看来历 ${icon('i-chevron-right', 'sm')}</button></div>
      </li>`;
    }).join('');
    el.content.innerHTML = `<div class="page">
      <div class="ex-head">
        <h1>改写范例</h1>
        <p>每一轮取舍都会留在这里：哪些改法你采用了，哪些原句你坚持保留，哪些地方你自己重写。下次遇到类似的表达问题，可以回来看看当时怎样改。</p>
        <div class="chips" role="group" aria-label="按取舍筛选">
          ${chip('data-ex-choice', 'all', `全部 ${count('all')}`, ui.exChoice === 'all')}
          ${chip('data-ex-choice', 'adopt', `采用改法 ${count('adopt')}`, ui.exChoice === 'adopt')}
          ${chip('data-ex-choice', 'rewrite', `自己重写 ${count('rewrite')}`, ui.exChoice === 'rewrite')}
          ${chip('data-ex-choice', 'keep', `保留原句 ${count('keep')}`, ui.exChoice === 'keep')}
        </div>
        ${tags.length ? `<div class="chips" role="group" aria-label="按问题类型筛选">${chip('data-ex-tag', '', '所有类型', !ui.exTag)}${tags.map((t) => chip('data-ex-tag', t, t, ui.exTag === t)).join('')}</div>` : ''}
        <label class="search-field" style="margin:0;max-width:340px">${icon('i-search')}<input type="search" id="ex-search" placeholder="搜索句子或说明" value="${esc(ui.exQuery)}" aria-label="搜索改写范例"></label>
      </div>
      ${!recs.length ? `<div class="empty"><div class="glyph">${icon('i-quote')}</div><h3>还没有改写范例</h3><p>完成一轮审阅后，你对每一处修改的取舍都会出现在这里。</p></div>`
        : list.length ? `<ul class="ex-list">${cards}</ul>`
          : '<div class="empty"><h3>没有符合条件的范例</h3><p>换一个筛选条件，或清空搜索。</p></div>'}
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
  }

  function computeProvSelHighlightOnly() {
    if (!ui.provSel || !inspectorVisible()) { clearHighlight('prov'); return; }
    const node = editorEl() && editorEl().querySelector(`p[data-pid="${CSS.escape(ui.provSel.pid)}"]`);
    if (node) setHighlight('prov', [rangeIn(node, ui.provSel.start, ui.provSel.start + ui.provSel.text.length)]);
  }

  function inspectorWrite(a, close) {
    const round = S.activeRound(a);
    const tabs = `<div class="insp-tabs"><div class="segmented" role="tablist" aria-label="检查器内容">
        <button type="button" role="tab" data-tab="marks" aria-selected="${ui.inspectorTab === 'marks'}">改稿标记</button>
        <button type="button" role="tab" data-tab="prov" aria-selected="${ui.inspectorTab === 'prov'}">这句话的来历</button>
      </div></div>`;
    const head = `<div class="insp-head"><span class="t">${ui.inspectorTab === 'prov' ? '来历' : '改稿'}</span>${close}</div>${tabs}`;
    if (ui.inspectorTab === 'prov') return head + inspectorProvenance(a);
    if (round && round.status === 'running') {
      const run = ui.running && ui.running.articleId === a.id ? ui.running : null;
      const items = Object.keys(round.paras).map((pid) => {
        const p = a.paragraphs.find((x) => x.id === pid);
        const idx = a.paragraphs.indexOf(p) + 1;
        const st = run ? run.status[pid] : 'wait';
        const label = st === 'run' ? '改稿中…' : st === 'done' ? `${run.counts[pid] || 0} 处修改` : '等待中';
        return `<li><span class="spinner ${st === 'run' ? '' : st === 'done' ? 'done' : 'idle'}" aria-hidden="true"></span><span class="ex">第 ${idx} 段 · ${esc(clip(p ? p.text : '', 18))}</span><span class="st">${label}</span></li>`;
      }).join('');
      const done = run ? Object.values(run.status).filter((s) => s === 'done').length : 0;
      const total = Object.keys(round.paras).length;
      return `${head}<div class="insp-body">
          <p class="lede">AI 正在按你的标记逐段改稿。每段改完，都会和送审稿逐词对照，供你取舍。</p>
          <div class="card"><div class="progress-row"><span class="big">${done} / ${total}</span><span class="small muted">段已改完</span></div>
          <div class="progress" role="progressbar" aria-valuemin="0" aria-valuemax="${total}" aria-valuenow="${done}" aria-label="改稿进度"><span style="width:${(done / total) * 100}%"></span></div></div>
          <ul class="run-list" aria-live="polite">${items}</ul>
        </div>
        <div class="insp-foot"><button type="button" class="btn block" data-act="cancel-run">取消改稿</button>
        <div class="hint">本地模拟，不联网。取消后标记保留，可以修改后重新送审。</div></div>`;
    }
    if (round && round.status === 'pending') {
      const m = S.reviewModel(a, round);
      return `${head}<div class="insp-body">
        <div class="card"><h4>${icon('i-revise', 'sm')}第 ${round.n} 轮改稿已返回</h4>
        <p class="small">${Object.keys(round.paras).length} 段，共 ${m.total} 处修改，已决定 ${m.decided} 处。逐处选择保留原句、采用改法，或自己重写。</p></div>
        </div><div class="insp-foot"><button type="button" class="btn primary block" data-act="go-review">开始审阅</button></div>`;
    }
    const caretPid = ui.caret && a.paragraphs.some((p) => p.id === ui.caret.pid) ? ui.caret.pid : null;
    const cp = caretPid && a.paragraphs.find((p) => p.id === caretPid);
    const marked = a.paragraphs.filter((p) => a.marks[p.id]);
    const cur = cp ? `<div class="card cur-card">
        <div class="grow"><div class="small muted">光标所在 · 第 ${a.paragraphs.indexOf(cp) + 1} 段</div><div class="ex">${esc(clip(cp.text, 40) || '（空段落）')}</div></div>
        <button type="button" class="btn" data-mark-current="${cp.id}" ${cp.text.trim() ? '' : 'disabled'}>${a.marks[cp.id] ? '取消标记' : '标记'}</button>
      </div>` : '';
    const list = marked.length ? `<ul class="mark-list">${marked.map((p) => {
      const idx = a.paragraphs.indexOf(p) + 1;
      const m = a.marks[p.id];
      const isCustom = Boolean(m.custom) || m.instruction === 'custom';
      return `<li class="mark-item ${p.id === caretPid ? 'is-current' : ''}">
        <button type="button" class="excerpt" data-goto="${p.id}" title="跳到这一段">${esc(p.text)}</button>
        <div class="ctrl"><span class="num">第 ${idx} 段</span>
          <select class="select" data-instr="${p.id}" aria-label="第 ${idx} 段的修改要求">
            ${AI.INSTRUCTIONS.map((it) => `<option value="${it.id}" ${!isCustom && m.instruction === it.id ? 'selected' : ''}>${it.label}</option>`).join('')}
            <option value="custom" ${isCustom ? 'selected' : ''}>${isCustom && m.custom ? `自定义：${esc(clip(m.custom, 8))}` : '自定义…'}</option>
          </select>
          <button type="button" class="icon-btn sm" data-unmark="${p.id}" aria-label="取消标记第 ${idx} 段" title="取消标记">${icon('i-x', 'sm')}</button>
        </div></li>`;
    }).join('')}</ul>`
      : `<div class="card flat"><p class="small muted">还没有标记段落。把光标放在一段里按 ${K.mod}${K.shift}M，或点击段落左侧的圆点。</p></div>`;
    const presetHint = marked.some((p) => !AI.presetFor(p.text))
      ? '有段落不是原样的示例文字，模拟服务对它们只做删赘词等简单规则精简。'
      : '标记的段落都有预置改法，可以看到完整的改稿效果。';
    return `${head}<div class="insp-body">
        <p class="lede">先专心写完一轮，再标记想请 AI 修改的段落，并说明想要怎样改。每改完一轮就生成一个新版本，你逐处决定采用哪种写法。</p>
        ${cur}
        <div class="card flat" style="padding-bottom:0"><h4>已标记 ${marked.length} 段</h4></div>
        ${list}
      </div>
      <div class="insp-foot">
        <button type="button" class="btn primary block" data-act="submit" ${marked.length ? '' : 'disabled'}>${icon('i-revise', 'sm')}请 AI 改稿${marked.length ? ` · ${marked.length} 段` : ''}<kbd>${K.mod}${K.enter}</kbd></button>
        <div class="hint">原型中的 AI 由本地模拟，不联网。${marked.length ? presetHint : ''}</div>
      </div>`;
  }

  function diffSentHTML(prev, cur) {
    if (prev === null || prev === undefined) return esc(cur);
    return D.diffText(prev, cur).map((s) => (s.type === 'eq' ? esc(s.text) : `${s.del ? `<mark class="del">${esc(s.del)}</mark>` : ''}${s.ins ? `<mark class="ins">${esc(s.ins)}</mark>` : ''}`)).join('');
  }

  function inspectorProvenance(a) {
    const sel = ui.provSel;
    if (!sel) {
      return `<div class="insp-body"><div class="empty"><div class="glyph">${icon('i-history')}</div><h3>选一句话</h3><p>把光标放在正文的任意一句话上，这里会显示它从初稿到现在的每一稿，以及你每一轮的取舍。</p></div></div>`;
    }
    const { steps, records } = S.provenance(a, sel.pid, sel.text);
    const real = steps.filter((s) => s.text);
    const head = `<div class="insp-body"><div class="quote-current">${esc(sel.text)}</div>`;
    if (real.length <= 1) {
      return `${head}<div class="empty" style="padding-top:12px"><h3>这句话还没有经过改稿</h3><p>${a.versions.length ? '它是在最近一次存档之后写下的。' : ''}送审之后，这里会记录它的每一稿和你的取舍。</p></div></div>`;
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
      return `${head}<div class="insp-body"><p class="lede">没有待审阅的改稿。</p></div>`;
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
      const btn = (c, ic, label, key) => `<button type="button" class="choice" data-insp-choice="${c}" aria-pressed="${Boolean(d && d.choice === c)}">${icon(ic, 'sm')}<span>${label}</span><kbd>${key}</kbd></button>`;
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
      </div>
      <p class="small muted" style="margin:0 2px">${para.meta.source === 'preset' ? '这段使用原型的预置改法（模拟 AI）。' : para.meta.source === 'rules' ? '这段由本地规则精简（模拟 AI）。' : ''}</p>`;
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
        <button type="button" class="btn primary block" data-act="finish">${icon('i-check', 'sm')}完成本轮，生成定稿<kbd>${K.mod}${K.enter}</kbd></button>
        <div class="hint">J / K 在修改之间移动。每一步都可以撤销（${K.mod}Z）。</div>
      </div>`;
  }

  function inspectorHistory(a, close) {
    const head = `<div class="insp-head"><span class="t">版本</span>${close}</div>`;
    if (!a.versions.length) return `${head}<div class="insp-body"><p class="lede">还没有版本。送审或存为版本后，各稿会出现在这里。</p></div>`;
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
        <p class="lede">每一轮都留在文章历史里。点一稿，与它的上一稿对照；也可以在上方任选两稿。</p>
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
    if (b.dataset.markCurrent) { toggleMark(b.dataset.markCurrent); return; }
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
    if (isLocked(a)) { toast('改稿进行中，完成本轮后会自动保存定稿'); return; }
    const t = new Date();
    const def = a.versions.length ? `存档 ${t.getMonth() + 1}月${t.getDate()}日 ${pad(t.getHours())}:${pad(t.getMinutes())}` : '初稿';
    openDialog({
      title: '存为版本',
      body: `<p>给这一稿起个名字。版本会保存完整正文，之后可以和任意一稿对照。</p><div class="field"><input type="text" value="${esc(def)}" aria-label="版本名称" maxlength="40"></div>`,
      actions: [{ label: '取消', value: null }, { label: '保存', value: 'ok', primary: true }],
      onClose: (v, name) => {
        if (v !== 'ok') return;
        pushUndo('存为版本', { caret: null });
        a.versions.push({ id: S.uid('v'), kind: 'snapshot', name: (name || def).trim() || def, at: Date.now(), title: a.title, paragraphs: S.snapshot(a.paragraphs) });
        touch(a);
        renderAll();
        toast(`已存为版本“${(name || def).trim() || def}”`, { action: { label: '查看历史', run: () => setMode('history') } });
      },
    });
  }

  function exportMarkdown(a) {
    if (!a) return;
    const blob = new Blob([S.toMarkdown(a)], { type: 'text/markdown;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.download = `${(a.title || '无标题').replace(/[\\/:*?"<>|]/g, '_')}.md`;
    document.body.appendChild(link);
    link.click();
    link.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
    toast('已导出 Markdown');
  }

  function resetSamples() {
    openDialog({
      title: '恢复示例数据？',
      body: '<p>这会清除你在原型里新建和修改的全部内容，回到三篇示例文章。</p>',
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
    openDialog({
      title: '键盘快捷键',
      wide: true,
      body: `<table class="shortcut-table">
        <tr><th colspan="2">写作</th></tr>
        ${row('标记或取消标记当前段落', [`${K.mod}${K.shift}M`])}
        ${row('上移、下移当前段落', [`${K.alt}${K.shift}${K.up}`, `${K.alt}${K.shift}${K.down}`])}
        ${row('请 AI 改稿', [`${K.mod}${K.enter}`])}
        ${row('查看光标所在句子的来历', [`${K.mod}I`])}
        ${row('存为版本', [`${K.mod}S`])}
        ${row('撤销、重做', [`${K.mod}Z`, `${K.mod}${K.shift}Z`])}
        <tr><th colspan="2">审阅</th></tr>
        ${row('下一处、上一处修改', ['J', 'K'])}
        ${row('采用改法', ['A'])}
        ${row('保留原句', ['O'])}
        ${row('自己重写', ['E'])}
        ${row('显示或隐藏操作条', ['Space'])}
        ${row('完成本轮，生成定稿', [`${K.mod}${K.enter}`])}
        <tr><th colspan="2">通用</th></tr>
        ${row('显示本表', [`${K.mod}/`])}
      </table>`,
      actions: [{ label: '好', value: null, primary: true }],
    });
  }

  function showAbout() {
    openDialog({
      title: '关于这个原型',
      wide: true,
      body: `<p>Redraft 是以 Diff 为核心的写作编辑器。这个网页原型用来体验它的交互：写作、标记、改稿、对照取舍、回看历史。正式产品计划为原生 macOS 应用。</p>
        <ul class="about-list">
          <li><b>真实运行：</b>编辑、分段、拖动段落、撤销重做、标记、版本快照、任意两稿对比、逐句溯源、改写范例、Markdown 导出。文本对比在浏览器里实时计算：段落按稳定 ID 对齐，再用系统分词（Intl.Segmenter）逐词比较。</li>
          <li><b>模拟：</b>AI 改稿。示例段落使用预置改法和说明；其他段落只做删赘词等本地规则精简，并如实标注。没有任何网络请求，也不需要账号或密钥。</li>
          <li><b>保存：</b>内容只保存在这个浏览器的本地存储中。可以在“更多”菜单里恢复示例数据。</li>
        </ul>`,
      actions: [{ label: '知道了', value: null, primary: true }],
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

    if (mod && !e.altKey) {
      if (key === 'z' && !inField) { e.preventDefault(); if (e.shiftKey) redo(); else undo(); return; }
      if (key === 'y' && !isMac && !inField) { e.preventDefault(); redo(); return; }
      if (key === 's') { e.preventDefault(); saveVersion(); return; }
      if (key === '/') { e.preventDefault(); showShortcuts(); return; }
      if (key === 'i' && ui.view === 'article') { e.preventDefault(); openProvenance(); return; }
      if (key === 'm' && e.shiftKey && ui.view === 'article' && ui.mode === 'write') {
        e.preventDefault();
        const c = getCaret() || ui.caret;
        if (c) toggleMark(c.pid);
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
  mqMid.addEventListener('change', () => { ui.inspectorOpen = !mqMid.matches; applyLayout(); renderToolbar(); renderInspector(); });
  let resizeTimer = 0;
  window.addEventListener('resize', () => {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => {
      closePopover(false);
      renderGutter();
      if (ui.mode === 'review') positionHunkBar();
    }, 80);
  });
  el.app.addEventListener('transitionend', (e) => {
    if (e.target === el.app) { renderGutter(); if (ui.mode === 'review') positionHunkBar(); }
  });
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(() => renderGutter());

  /* ───────────────────────── 启动 ───────────────────────── */

  window.__redraft = { get data() { return data; }, ui };
  renderAll();
})();
