/*
 * Redraft 原型 · 文章会话
 * 对应 design.md 中「文章会话」与「文档与版本」：协调一篇文章的编辑、送审、改稿、取舍与版本历史。
 * 段落带稳定 ID（代替 Loro Cursor），每一稿保存为完整快照，以便任意两稿对比和逐句溯源。
 */
(function (global) {
  'use strict';

  const D = global.RedraftDiff;
  const AI = global.RedraftMockAI;
  const R = global.RedraftRich;
  const B = global.RedraftBlocks;

  const uid = (prefix) => `${prefix}${Date.now().toString(36).slice(-4)}${Math.random().toString(36).slice(2, 7)}`;
  const clone = (x) => JSON.parse(JSON.stringify(x));
  const snapshot = (paras) => paras.map(R.clonePara);

  function instructionLabel(mark) {
    if (!mark) return '';
    if (mark.custom) return mark.custom;
    const hit = AI.INSTRUCTIONS.find((i) => i.id === mark.instruction);
    return hit ? hit.label : '修改';
  }

  function versionLabel(v) {
    if (!v) return '';
    if (v.id === 'live') return '当前稿';
    switch (v.kind) {
      case 'submitted': return `送审稿 · 第 ${v.round} 轮`;
      case 'ai': return `AI 改稿 · 第 ${v.round} 轮`;
      case 'final': return `定稿 · 第 ${v.round} 轮`;
      default: return v.name || '手动保存';
    }
  }

  function getVersion(article, id) {
    if (id === 'live') return { id: 'live', kind: 'live', at: article.updatedAt, title: article.title, paragraphs: article.paragraphs };
    return article.versions.find((v) => v.id === id) || null;
  }

  function activeRound(article) {
    return article.rounds.find((r) => r.status === 'running' || r.status === 'pending') || null;
  }

  /** 送审：保存送审稿快照，开启新一轮。 */
  function beginRound(article, now) {
    const n = article.rounds.length + 1;
    const submitted = { id: uid('v'), kind: 'submitted', round: n, at: now, title: article.title, paragraphs: snapshot(article.paragraphs) };
    article.versions.push(submitted);
    const paras = {};
    for (const p of article.paragraphs) {
      const mark = article.marks[p.id];
      if (mark) paras[p.id] = { instruction: mark.instruction, custom: mark.custom || '', source: null, notes: [] };
    }
    const round = { n, status: 'running', submittedId: submitted.id, aiId: null, finalId: null, submittedAt: now, paras, decisions: {}, records: [] };
    article.rounds.push(round);
    return round;
  }

  /**
   * AI 改完所有标记段落后，生成一份新版本。文字段落只改文字，段落样式不变，字符样式随文字搬运；
   * 图片和表格段落由结果直接给出改后的整段（r.para），或整段删去（r.remove）。
   */
  function completeRound(article, round, results, now) {
    const submitted = getVersion(article, round.submittedId);
    const aiParas = [];
    for (const p of submitted.paragraphs) {
      const r = results[p.id];
      if (!r) { aiParas.push(R.clonePara(p)); continue; }
      round.paras[p.id].source = r.source;
      round.paras[p.id].notes = r.notes;
      if (r.remove && R.isBlock(p)) continue;
      if (r.para && R.isBlock(p) && r.para.kind === p.kind) aiParas.push(R.clonePara({ ...r.para, id: p.id }));
      else aiParas.push(R.retext(p, typeof r.text === 'string' ? r.text : p.text));
    }
    const ai = { id: uid('v'), kind: 'ai', round: round.n, at: now, title: article.title, paragraphs: aiParas };
    article.versions.push(ai);
    round.aiId = ai.id;
    round.status = 'pending';
    return ai;
  }

  function cancelRound(article, round) {
    article.versions = article.versions.filter((v) => v.id !== round.submittedId && v.id !== round.aiId);
    article.rounds = article.rounds.filter((r) => r !== round);
  }

  /**
   * 一组文字的逐处修改：普通段落、图注、表格的每个单元格各是一组。
   * prefix 决定修改的键：普通段落和图注沿用 `${pid}:${n}`，单元格是 `${pid}:${行}.${列}:${n}`。
   */
  function textGroup(pid, prefix, base, after, meta, decisions, src, aiSrc) {
    const segments = D.diffText(base, after);
    const hunks = [];
    let bPos = 0;
    let aPos = 0;
    segments.forEach((s) => {
      if (s.type === 'eq') { bPos += s.text.length; aPos += s.text.length; return; }
      const key = `${prefix}:${hunks.length}`;
      const why = AI.explain(s, meta.notes);
      hunks.push({ key, pid, kind: 'text', idx: hunks.length, del: s.del, ins: s.ins, reason: why.reason, tag: why.tag, decision: decisions[key] || null, bStart: bPos, bEnd: bPos + s.del.length, aStart: aPos, aEnd: aPos + s.ins.length, base, after });
      s.key = key;
      bPos += s.del.length;
      aPos += s.ins.length;
    });
    return { segments, hunks, base, after, src: src || { text: base }, aiSrc: aiSrc || { text: after } };
  }

  const noteFor = (meta, on, fallback) => {
    const n = (meta.notes || []).find((x) => x.on === on);
    return n ? { reason: n.reason, tag: n.tag || fallback.tag } : fallback;
  };

  function rowLabel(t, rowId) {
    const words = t.cols.map((c) => B.cellText(t, rowId, c).trim()).filter(Boolean).slice(0, 2);
    return words.length ? `“${words.join(' · ')}”` : '空行';
  }
  function colLabel(t, colId) {
    const head = B.cellText(t, t.rows[0] && t.rows[0].id, colId).trim();
    return head ? `“${head}”列` : `第 ${t.cols.indexOf(colId) + 1} 列`;
  }

  /** 表格：行列按 ID 对齐，增删的行列各是一处结构修改；两稿都有的单元格逐格做文字对比。 */
  function tableReview(p, aiSrc, meta, decisions) {
    const st = p.table;
    const at = aiSrc.table;
    const cols = B.mergeOrder(st.cols, at.cols);
    const rows = B.mergeOrder(st.rows.map((r) => r.id), at.rows.map((r) => r.id));
    const hunks = [];
    const groups = [];
    const cells = {};
    for (const c of cols) {
      if (c.status === 'same') continue;
      const key = `${p.id}:col:${c.id}`;
      const label = c.status === 'add' ? `新增${colLabel(at, c.id)}` : `删去${colLabel(st, c.id)}`;
      const why = noteFor(meta, `col:${c.id}`, { reason: c.status === 'add' ? '新增了一列。' : '删去了这一列。', tag: '结构' });
      hunks.push({ key, pid: p.id, kind: 'col', op: c.status, id: c.id, label, reason: why.reason, tag: why.tag, decision: decisions[key] || null });
    }
    for (const r of rows) {
      if (r.status !== 'same') {
        const key = `${p.id}:row:${r.id}`;
        const label = r.status === 'add' ? `新增一行 ${rowLabel(at, r.id)}` : `删去一行 ${rowLabel(st, r.id)}`;
        const why = noteFor(meta, `row:${r.id}`, { reason: r.status === 'add' ? '新增了一行。' : '删去了这一行。', tag: '结构' });
        hunks.push({ key, pid: p.id, kind: 'row', op: r.status, id: r.id, label, reason: why.reason, tag: why.tag, decision: decisions[key] || null });
        continue;
      }
      for (const c of cols) {
        if (c.status !== 'same') continue;
        const k = `${r.id}.${c.id}`;
        const g = textGroup(p.id, `${p.id}:${k}`, B.cellText(st, r.id, c.id), B.cellText(at, r.id, c.id), meta, decisions);
        g.cell = k;
        for (const h of g.hunks) h.cell = k;
        cells[k] = g;
        groups.push(g);
        hunks.push(...g.hunks);
      }
    }
    return { rows, cols, cells, groups, hunks };
  }

  /** 审阅视图数据：按阅读顺序列出每段，标记段落带逐处修改。图片按整张替换或删去，表格的结构修改单独成项。 */
  function reviewModel(article, round) {
    const submitted = getVersion(article, round.submittedId);
    const ai = getVersion(article, round.aiId);
    const aiParas = new Map(ai.paragraphs.map((p) => [p.id, p]));
    let total = 0;
    let decided = 0;
    const counts = { adopt: 0, keep: 0, rewrite: 0 };
    const decisions = round.decisions;
    const paras = submitted.paragraphs.map((p, index) => {
      const meta = round.paras[p.id];
      if (!meta) return { id: p.id, index, marked: false, base: p.text, src: p };
      const found = aiParas.get(p.id);
      const aiSrc = found || p;
      const out = { id: p.id, index, marked: true, kind: p.kind || 'text', base: p.text, after: aiSrc.text, meta, src: p, aiSrc };
      if (p.kind === 'table' && found) {
        Object.assign(out, tableReview(p, found, meta, decisions));
        out.segments = [];
      } else {
        const g = textGroup(p.id, p.id, p.text, found ? aiSrc.text : (R.isBlock(p) ? p.text : ''), meta, decisions, p, aiSrc);
        out.segments = g.segments;
        out.groups = [g];
        out.hunks = [...g.hunks];
        if (R.isBlock(p)) {
          let op = null;
          if (!found) op = 'remove';
          else if (p.kind === 'img' && (found.img.asset || '') !== (p.img.asset || '')) op = 'replace';
          if (op) {
            const key = `${p.id}:${p.kind === 'img' ? 'img' : 'block'}`;
            const what = p.kind === 'img' ? '图片' : '表格';
            const why = noteFor(meta, p.kind === 'img' ? 'img' : 'block', { reason: op === 'replace' ? '换了一张图。' : `删去了这个${what}。`, tag: what });
            out.hunks.unshift({ key, pid: p.id, kind: p.kind === 'img' ? 'img' : 'block', op, label: op === 'replace' ? '换一张图' : `删去这个${what}`, reason: why.reason, tag: why.tag, decision: decisions[key] || null });
          }
        }
      }
      for (const h of out.hunks) {
        total++;
        if (h.decision) { decided++; counts[h.decision.choice]++; }
      }
      return out;
    });
    return { paras, total, decided, counts, submitted, ai };
  }

  const choose = (decisions, key, fallback) => decisions[key] || { choice: fallback || 'keep' };

  /** 按取舍合成一组文字；spans 记录每处修改在结果中的位置，供溯源和范例使用。 */
  function composeParagraph(group, decisions, fallback) {
    let text = '';
    const spans = {};
    for (const s of group.segments) {
      if (s.type === 'eq') { text += s.text; continue; }
      const d = choose(decisions, s.key, fallback);
      const piece = d.choice === 'adopt' ? s.ins : d.choice === 'rewrite' ? d.text : s.del;
      spans[s.key] = { start: text.length, end: text.length + piece.length, text: piece };
      text += piece;
    }
    return { text, spans };
  }

  function composeTable(para, decisions, fallback, texts) {
    const st = para.src.table;
    const at = para.aiSrc.table;
    const adopted = (kind, id) => choose(decisions, `${para.id}:${kind}:${id}`, fallback).choice === 'adopt';
    const keepItem = (kind, it) => (it.status === 'same' ? true : it.status === 'add' ? adopted(kind, it.id) : !adopted(kind, it.id));
    const cols = para.cols.filter((c) => keepItem('col', c));
    const rows = para.rows.filter((r) => keepItem('row', r));
    const table = { cols: cols.map((c) => c.id), rows: [], head: st.head };
    for (const r of rows) {
      const cells = {};
      for (const c of cols) {
        const k = `${r.id}.${c.id}`;
        let v;
        if (texts[k] !== undefined) v = texts[k];
        else if (r.status === 'add' || (c.status === 'add' && r.status === 'same')) v = B.cellText(at, r.id, c.id);
        else v = B.cellText(st, r.id, c.id);
        if (v) cells[c.id] = v;
      }
      table.rows.push({ id: r.id, cells });
    }
    if (!table.cols.length || !table.rows.length) return null;
    return B.syncText({ id: para.id, kind: 'table', text: '', table });
  }

  /** 一段的定稿：返回 null 表示这一段（图片或表格）按取舍删去。 */
  function composeFinal(para, decisions, fallback) {
    const texts = {};
    const results = (para.groups || []).map((g) => {
      const r = composeParagraph(g, decisions, fallback);
      if (g.cell) texts[g.cell] = r.text;
      return { group: g, ...r };
    });
    let final;
    if (para.kind === 'table' && para.cols) {
      final = composeTable(para, decisions, fallback, texts);
    } else {
      final = R.retext(para.src, results[0] ? results[0].text : para.src.text);
      const bh = para.hunks.find((h) => h.kind === 'img' || h.kind === 'block');
      if (bh && choose(decisions, bh.key, fallback).choice === 'adopt') {
        if (bh.op === 'remove') final = null;
        else if (bh.op === 'replace') {
          const ai = para.aiSrc.img;
          final.img = { ...final.img, asset: ai.asset, alt: ai.alt };
          if (ai.iw && ai.ih) { final.img.iw = ai.iw; final.img.ih = ai.ih; } else { delete final.img.iw; delete final.img.ih; }
        }
      }
    }
    return { para: final, results };
  }

  /** 完成本轮：未决定的修改按 fallback 处理，生成定稿版本并沉淀为写作范例。 */
  function finalizeRound(article, round, fallback, now) {
    const model = reviewModel(article, round);
    const finalParas = [];
    const records = [];
    for (const para of model.paras) {
      if (!para.marked) { finalParas.push(R.clonePara(para.src)); continue; }
      for (const h of para.hunks) {
        if (!round.decisions[h.key]) round.decisions[h.key] = { choice: fallback || 'keep', auto: true };
      }
      const { para: final, results } = composeFinal(para, round.decisions, null);
      if (final) finalParas.push(final);
      for (const h of para.hunks) {
        if (h.kind === 'text') continue;
        const d = round.decisions[h.key];
        records.push({ id: uid('r'), articleId: article.id, round: round.n, pid: para.id, key: h.key, block: h.kind, op: h.op, choice: d.choice, auto: Boolean(d.auto), label: h.label, reason: h.reason, tag: h.tag, at: now });
      }
      for (const { group, text, spans } of results) {
        for (const h of group.hunks) {
          const d = round.decisions[h.key];
          const span = spans[h.key];
          const before = D.sentenceAround(group.base, h.bStart, h.bEnd);
          const aiS = D.sentenceAround(group.after, h.aStart, h.aEnd);
          const after = D.sentenceAround(text, span.start, span.end);
          const rec = {
            id: uid('r'),
            articleId: article.id,
            round: round.n,
            pid: para.id,
            key: h.key,
            choice: d.choice,
            auto: Boolean(d.auto),
            del: h.del,
            ins: h.ins,
            final: span.text,
            reason: h.reason,
            tag: h.tag,
            before: { text: before.text, hl: [h.bStart - before.start, h.bEnd - before.start] },
            ai: { text: aiS.text, hl: [h.aStart - aiS.start, h.aEnd - aiS.start] },
            after: { text: after.text, hl: [span.start - after.start, span.end - after.start] },
            at: now,
          };
          if (group.cell) rec.cell = group.cell;
          records.push(rec);
        }
      }
    }
    if (!finalParas.length || R.isBlock(finalParas[finalParas.length - 1])) finalParas.push({ id: uid('p'), text: '' });
    const final = { id: uid('v'), kind: 'final', round: round.n, at: now, title: article.title, paragraphs: finalParas };
    article.versions.push(final);
    round.finalId = final.id;
    round.status = 'done';
    round.finishedAt = now;
    round.records = records;
    article.paragraphs = snapshot(finalParas);
    article.marks = {};
    article.updatedAt = now;
    return final;
  }

  /**
   * 一句话的来历：从当前稿出发，沿各稿逐级向前找最相似的句子，
   * 段落 ID 保证只在同一段落的各稿之间查找。
   */
  function provenance(article, pid, sentence, cell) {
    const chain = [{ id: 'live', kind: 'live', at: article.updatedAt }, ...[...article.versions].reverse()];
    const steps = [];
    let probe = sentence;
    const textOf = (para) => {
      if (!cell) return para.text;
      if (para.kind !== 'table') return null;
      const [row, col] = cell.split('.');
      return para.table.cols.includes(col) && para.table.rows.some((r) => r.id === row) ? B.cellText(para.table, row, col) : null;
    };
    for (const v of chain) {
      const para = (v.id === 'live' ? article.paragraphs : v.paragraphs).find((p) => p.id === pid);
      const text = para ? textOf(para) : null;
      if (text === null) { steps.push({ version: v, text: null, missing: true }); break; }
      let best = null;
      let score = 0;
      for (const s of D.splitSentences(text)) {
        const sc = D.similarity(probe, s.text);
        if (sc > score) { score = sc; best = s.text; }
      }
      if (!best || score < 0.18) { steps.push({ version: v, text: null, missing: true }); break; }
      steps.push({ version: v, text: best });
      probe = best;
    }
    steps.reverse();
    const records = [];
    for (const r of article.rounds) {
      for (const rec of r.records || []) {
        if (rec.pid !== pid || rec.block || (rec.cell || null) !== (cell || null)) continue;
        const match = steps.some((s) => s.text && s.version.kind === 'final' && s.version.round === r.n && D.similarity(s.text, rec.after.text) > 0.6);
        if (match) records.push(rec);
      }
    }
    return { steps, records };
  }

  function allRecords(articles) {
    const out = [];
    for (const a of articles) for (const r of a.rounds) for (const rec of r.records || []) if (!rec.block) out.push({ ...rec, articleTitle: a.title });
    return out.sort((x, y) => y.at - x.at);
  }

  function toMarkdown(article) {
    return R.toMarkdown(article.title, article.paragraphs);
  }

  function toHTML(article) {
    return R.htmlDocument(article.title, article.paragraphs);
  }

  global.RedraftSession = {
    uid,
    clone,
    snapshot,
    instructionLabel,
    versionLabel,
    getVersion,
    activeRound,
    beginRound,
    completeRound,
    cancelRound,
    reviewModel,
    composeParagraph,
    finalizeRound,
    provenance,
    allRecords,
    toMarkdown,
    toHTML,
  };
})(typeof window !== 'undefined' ? window : globalThis);
