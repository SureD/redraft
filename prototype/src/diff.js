/*
 * Redraft 原型 · 分层 Diff
 * 对应 design.md 中「文本对比」模块：段落按稳定 ID 对齐 → 句/词切分 → 词元序列 LCS → 语义合并。
 * 浏览器里用 Intl.Segmenter 代替 NLTokenizer，二者都能对中文分词。
 */
(function (global) {
  'use strict';

  const wordSeg = typeof Intl !== 'undefined' && Intl.Segmenter
    ? new Intl.Segmenter('zh-Hans', { granularity: 'word' })
    : null;

  function tokenize(text) {
    if (!text) return [];
    if (wordSeg) return Array.from(wordSeg.segment(text), (s) => s.segment);
    return text.match(/[A-Za-z0-9_'’]+|\s+|[\s\S]/gu) || [];
  }

  const TERMINATORS = '。！？!?…；;';
  const CLOSERS = '”’」』）)"\'';

  /** 切句，返回 [{text, start, end}]，句末标点、后引号和空白归入本句。 */
  function splitSentences(text) {
    const out = [];
    let start = 0;
    let i = 0;
    while (i < text.length) {
      const ch = text[i];
      const isLatinStop = ch === '.' && (i + 1 >= text.length || /\s/.test(text[i + 1]));
      if (TERMINATORS.includes(ch) || isLatinStop) {
        let j = i + 1;
        while (j < text.length && (TERMINATORS.includes(text[j]) || text[j] === '.')) j++;
        while (j < text.length && CLOSERS.includes(text[j])) j++;
        while (j < text.length && /\s/.test(text[j])) j++;
        out.push({ text: text.slice(start, j), start, end: j });
        start = j;
        i = j;
      } else {
        i++;
      }
    }
    if (start < text.length) out.push({ text: text.slice(start), start, end: text.length });
    return out;
  }

  /** 找出覆盖 [from, to) 的完整句子范围。 */
  function sentenceAround(text, from, to) {
    const sentences = splitSentences(text);
    if (!sentences.length) return { start: 0, end: 0, text: '' };
    let s = sentences.findIndex((x) => from < x.end || (from === x.end && x.end === text.length));
    if (s < 0) s = sentences.length - 1;
    let e = s;
    while (e < sentences.length - 1 && to > sentences[e].end) e++;
    const start = sentences[s].start;
    const end = sentences[e].end;
    return { start, end, text: text.slice(start, end) };
  }

  /** 词元级 LCS，返回 [['eq'|'del'|'ins', text]]。 */
  function diffTokens(a, b) {
    let pre = 0;
    while (pre < a.length && pre < b.length && a[pre] === b[pre]) pre++;
    let endA = a.length;
    let endB = b.length;
    while (endA > pre && endB > pre && a[endA - 1] === b[endB - 1]) { endA--; endB--; }
    const A = a.slice(pre, endA);
    const B = b.slice(pre, endB);
    const ops = [];
    const push = (type, text) => {
      if (!text) return;
      const last = ops[ops.length - 1];
      if (last && last[0] === type) last[1] += text;
      else ops.push([type, text]);
    };
    push('eq', a.slice(0, pre).join(''));
    const n = A.length;
    const m = B.length;
    if (n * m > 4_000_000) {
      push('del', A.join(''));
      push('ins', B.join(''));
    } else if (n && m) {
      const w = m + 1;
      const dp = new Uint16Array((n + 1) * w);
      for (let i = n - 1; i >= 0; i--) {
        for (let j = m - 1; j >= 0; j--) {
          dp[i * w + j] = A[i] === B[j]
            ? dp[(i + 1) * w + j + 1] + 1
            : Math.max(dp[(i + 1) * w + j], dp[i * w + j + 1]);
        }
      }
      let i = 0;
      let j = 0;
      while (i < n && j < m) {
        if (A[i] === B[j]) { push('eq', A[i]); i++; j++; }
        else if (dp[(i + 1) * w + j] >= dp[i * w + j + 1]) { push('del', A[i]); i++; }
        else { push('ins', B[j]); j++; }
      }
      while (i < n) push('del', A[i++]);
      while (j < m) push('ins', B[j++]);
    } else {
      push('del', A.join(''));
      push('ins', B.join(''));
    }
    push('eq', a.slice(endA).join(''));
    return ops;
  }

  const PUNCT = /[\p{P}]/u;

  /**
   * 把 ops 归并为段落片段：[{type:'eq', text}] 与 [{type:'chg', del, ins}]。
   * 两处修改之间只隔一两个非标点字符时并为一处，避免中文被拆得七零八落（参考 cleanupSemantic）。
   */
  function toSegments(ops) {
    let segs = [];
    for (const [type, text] of ops) {
      const last = segs[segs.length - 1];
      if (type === 'eq') segs.push({ type: 'eq', text });
      else if (last && last.type === 'chg') last[type] += text;
      else segs.push({ type: 'chg', del: type === 'del' ? text : '', ins: type === 'ins' ? text : '' });
    }
    let changed = true;
    while (changed) {
      changed = false;
      for (let k = 1; k < segs.length - 1; k++) {
        const prev = segs[k - 1];
        const cur = segs[k];
        const next = segs[k + 1];
        if (cur.type !== 'eq' || prev.type !== 'chg' || next.type !== 'chg') continue;
        const short = cur.text.trim().length <= 2 && !PUNCT.test(cur.text);
        const whitespace = cur.text.trim() === '';
        if (short || whitespace) {
          const merged = {
            type: 'chg',
            del: prev.del + cur.text + next.del,
            ins: prev.ins + cur.text + next.ins,
          };
          segs.splice(k - 1, 3, merged);
          changed = true;
          break;
        }
      }
    }
    segs = segs.filter((s) => (s.type === 'eq' ? s.text : s.del || s.ins));
    return segs;
  }

  function diffText(a, b) {
    if (a === b) return a ? [{ type: 'eq', text: a }] : [];
    return toSegments(diffTokens(tokenize(a), tokenize(b)));
  }

  function countChanges(segments) {
    let ins = 0;
    let del = 0;
    let hunks = 0;
    for (const s of segments) {
      if (s.type === 'chg') {
        hunks++;
        ins += [...s.ins.replace(/\s/g, '')].length;
        del += [...s.del.replace(/\s/g, '')].length;
      }
    }
    return { ins, del, hunks };
  }

  /** 最长递增子序列的下标集合，用于判断段落是否被移动。 */
  function lisIndexSet(arr) {
    const tails = [];
    const prevIdx = new Array(arr.length);
    const tailIdx = [];
    arr.forEach((v, i) => {
      let lo = 0;
      let hi = tails.length;
      while (lo < hi) {
        const mid = (lo + hi) >> 1;
        if (tails[mid] < v) lo = mid + 1; else hi = mid;
      }
      tails[lo] = v;
      tailIdx[lo] = i;
      prevIdx[i] = lo > 0 ? tailIdx[lo - 1] : -1;
    });
    const keep = new Set();
    let k = tailIdx[tails.length - 1];
    while (k !== undefined && k >= 0) { keep.add(k); k = prevIdx[k]; }
    return keep;
  }

  /** 文字以外的内容：图片段落换了图也算改动；表格的结构变化已经体现在它的 text 里。 */
  const blockSig = (p) => (p.kind === 'img' && p.img ? `${p.img.asset || ''}` : '');

  /**
   * 段落层对齐：段落有稳定 ID（对应 Loro Cursor 的身份），按目标稿顺序输出，
   * 被删段落插在它原来前一段之后。
   */
  function diffDocs(baseParas, targetParas) {
    const baseIndex = new Map(baseParas.map((p, i) => [p.id, i]));
    const targetIds = new Set(targetParas.map((p) => p.id));
    const common = targetParas.filter((p) => baseIndex.has(p.id));
    const keep = lisIndexSet(common.map((p) => baseIndex.get(p.id)));
    const movedIds = new Set(common.filter((_, i) => !keep.has(i)).map((p) => p.id));

    const removedAfter = new Map();
    let anchor = null;
    for (const p of baseParas) {
      if (targetIds.has(p.id)) { anchor = p.id; continue; }
      const list = removedAfter.get(anchor) || [];
      list.push(p);
      removedAfter.set(anchor, list);
    }

    const rows = [];
    const pushRemoved = (key) => {
      for (const p of removedAfter.get(key) || []) {
        rows.push({ id: p.id, status: 'removed', base: p.text, target: '', segments: [{ type: 'chg', del: p.text, ins: '' }] });
      }
    };
    pushRemoved(null);
    for (const p of targetParas) {
      if (!baseIndex.has(p.id)) {
        rows.push({ id: p.id, status: 'added', base: '', target: p.text, segments: [{ type: 'chg', del: '', ins: p.text }] });
      } else {
        const bp = baseParas[baseIndex.get(p.id)];
        const base = bp.text;
        const segments = diffText(base, p.text);
        const blockChanged = blockSig(bp) !== blockSig(p);
        rows.push({
          id: p.id,
          status: base === p.text && !blockChanged ? 'same' : 'changed',
          blockChanged,
          moved: movedIds.has(p.id),
          base,
          target: p.text,
          segments,
        });
      }
      pushRemoved(p.id);
    }
    const stats = rows.reduce((acc, r) => {
      const c = countChanges(r.segments);
      acc.ins += c.ins;
      acc.del += c.del;
      if (r.status !== 'same' || r.moved) acc.paras++;
      return acc;
    }, { ins: 0, del: 0, paras: 0 });
    return { rows, stats };
  }

  function bigrams(s) {
    const chars = [...s.replace(/\s+/g, ' ').trim().toLowerCase()];
    const out = new Map();
    for (let i = 0; i < chars.length - 1; i++) {
      const g = chars[i] + chars[i + 1];
      out.set(g, (out.get(g) || 0) + 1);
    }
    return { grams: out, size: Math.max(chars.length - 1, 0) };
  }

  /** 字符二元组 Dice 相似度，0–1。 */
  function similarity(a, b) {
    if (!a || !b) return 0;
    if (a === b) return 1;
    const A = bigrams(a);
    const B = bigrams(b);
    if (!A.size || !B.size) return a.trim() === b.trim() ? 1 : 0;
    let hit = 0;
    for (const [g, n] of A.grams) hit += Math.min(n, B.grams.get(g) || 0);
    return (2 * hit) / (A.size + B.size);
  }

  global.RedraftDiff = {
    tokenize,
    splitSentences,
    sentenceAround,
    diffText,
    diffDocs,
    countChanges,
    similarity,
  };
})(typeof window !== 'undefined' ? window : globalThis);
