/*
 * Redraft 原型 · 文章会话
 * 对应 design.md 中「文章会话」与「文档与版本」：协调一篇文章的编辑、送审、改稿、取舍与版本历史。
 * 段落带稳定 ID（代替 Loro Cursor），每一稿保存为完整快照，以便任意两稿对比和逐句溯源。
 */
(function (global) {
  'use strict';

  const D = global.RedraftDiff;
  const AI = global.RedraftMockAI;

  const uid = (prefix) => `${prefix}${Date.now().toString(36).slice(-4)}${Math.random().toString(36).slice(2, 7)}`;
  const clone = (x) => JSON.parse(JSON.stringify(x));
  const snapshot = (paras) => paras.map((p) => ({ id: p.id, text: p.text }));

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

  /** AI 改完所有标记段落后，生成一份新版本。 */
  function completeRound(article, round, results, now) {
    const submitted = getVersion(article, round.submittedId);
    const aiParas = submitted.paragraphs.map((p) => {
      const r = results[p.id];
      if (!r) return { id: p.id, text: p.text };
      round.paras[p.id].source = r.source;
      round.paras[p.id].notes = r.notes;
      return { id: p.id, text: r.text };
    });
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

  /** 审阅视图数据：按阅读顺序列出每段，标记段落带逐处修改。 */
  function reviewModel(article, round) {
    const submitted = getVersion(article, round.submittedId);
    const ai = getVersion(article, round.aiId);
    const aiText = new Map(ai.paragraphs.map((p) => [p.id, p.text]));
    let total = 0;
    let decided = 0;
    const counts = { adopt: 0, keep: 0, rewrite: 0 };
    const paras = submitted.paragraphs.map((p, index) => {
      const meta = round.paras[p.id];
      if (!meta) return { id: p.id, index, marked: false, base: p.text };
      const after = aiText.get(p.id) ?? p.text;
      const segments = D.diffText(p.text, after);
      const hunks = [];
      let bPos = 0;
      let aPos = 0;
      segments.forEach((s) => {
        if (s.type === 'eq') { bPos += s.text.length; aPos += s.text.length; return; }
        const key = `${p.id}:${hunks.length}`;
        const why = AI.explain(s, meta.notes);
        const decision = round.decisions[key] || null;
        hunks.push({ key, pid: p.id, idx: hunks.length, del: s.del, ins: s.ins, reason: why.reason, tag: why.tag, decision, bStart: bPos, bEnd: bPos + s.del.length, aStart: aPos, aEnd: aPos + s.ins.length });
        s.key = key;
        bPos += s.del.length;
        aPos += s.ins.length;
        total++;
        if (decision) { decided++; counts[decision.choice]++; }
      });
      return { id: p.id, index, marked: true, base: p.text, after, segments, hunks, meta };
    });
    return { paras, total, decided, counts, submitted, ai };
  }

  /** 按取舍合成一段；spans 记录每处修改在结果中的位置，供溯源和范例使用。 */
  function composeParagraph(para, decisions, fallback) {
    let text = '';
    const spans = {};
    for (const s of para.segments) {
      if (s.type === 'eq') { text += s.text; continue; }
      const d = decisions[s.key] || (fallback ? { choice: fallback } : { choice: 'keep' });
      const piece = d.choice === 'adopt' ? s.ins : d.choice === 'rewrite' ? d.text : s.del;
      spans[s.key] = { start: text.length, end: text.length + piece.length, text: piece };
      text += piece;
    }
    return { text, spans };
  }

  /** 完成本轮：未决定的修改按 fallback 处理，生成定稿版本并沉淀为写作范例。 */
  function finalizeRound(article, round, fallback, now) {
    const model = reviewModel(article, round);
    const finalParas = [];
    const records = [];
    for (const para of model.paras) {
      if (!para.marked) { finalParas.push({ id: para.id, text: para.base }); continue; }
      for (const h of para.hunks) {
        if (!round.decisions[h.key]) round.decisions[h.key] = { choice: fallback || 'keep', auto: true };
      }
      const { text, spans } = composeParagraph(para, round.decisions, null);
      finalParas.push({ id: para.id, text });
      for (const h of para.hunks) {
        const d = round.decisions[h.key];
        const span = spans[h.key];
        const before = D.sentenceAround(para.base, h.bStart, h.bEnd);
        const aiS = D.sentenceAround(para.after, h.aStart, h.aEnd);
        const after = D.sentenceAround(text, span.start, span.end);
        records.push({
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
        });
      }
    }
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
  function provenance(article, pid, sentence) {
    const chain = [{ id: 'live', kind: 'live', at: article.updatedAt }, ...[...article.versions].reverse()];
    const steps = [];
    let probe = sentence;
    for (const v of chain) {
      const para = (v.id === 'live' ? article.paragraphs : v.paragraphs).find((p) => p.id === pid);
      if (!para) { steps.push({ version: v, text: null, missing: true }); break; }
      let best = null;
      let score = 0;
      for (const s of D.splitSentences(para.text)) {
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
        if (rec.pid !== pid) continue;
        const match = steps.some((s) => s.text && s.version.kind === 'final' && s.version.round === r.n && D.similarity(s.text, rec.after.text) > 0.6);
        if (match) records.push(rec);
      }
    }
    return { steps, records };
  }

  function allRecords(articles) {
    const out = [];
    for (const a of articles) for (const r of a.rounds) for (const rec of r.records || []) out.push({ ...rec, articleTitle: a.title });
    return out.sort((x, y) => y.at - x.at);
  }

  function toMarkdown(article) {
    const body = article.paragraphs.map((p) => p.text).filter((t) => t.trim()).join('\n\n');
    return `# ${article.title || '无标题'}\n\n${body}\n`;
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
  };
})(typeof window !== 'undefined' ? window : globalThis);
