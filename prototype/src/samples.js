/*
 * Redraft 原型 · 示例文章
 * 历史版本不是手写的结果：第 1 轮通过与界面相同的会话流程生成（送审 → 预置改稿 → 按脚本取舍 → 定稿），
 * 因此示例里的差异、取舍记录和写作范例与真实操作产生的数据结构一致。
 */
(function (global) {
  'use strict';

  const S = global.RedraftSession;
  const AI = global.RedraftMockAI;
  const t = (iso) => new Date(iso).getTime();

  function article(id, title, createdAt, paragraphs) {
    return {
      id,
      title,
      createdAt,
      updatedAt: createdAt,
      paragraphs: paragraphs.map(([pid, text]) => ({ id: pid, text })),
      marks: {},
      versions: [],
      rounds: [],
    };
  }

  function runRound(a, marks, at, decide) {
    a.marks = marks;
    const round = S.beginRound(a, at);
    const results = {};
    for (const pid of Object.keys(marks)) {
      const p = a.paragraphs.find((x) => x.id === pid);
      const preset = AI.presetFor(p.text);
      results[pid] = preset ? { text: preset.text, notes: preset.notes, source: 'preset' } : { text: p.text, notes: [], source: 'none' };
    }
    S.completeRound(a, round, results, at + 52_000);
    if (decide) {
      const model = S.reviewModel(a, round);
      for (const para of model.paras) {
        if (!para.marked) continue;
        for (const h of para.hunks) {
          const rule = decide.find((d) => d.pid === para.id && h.del.trim() === d.del);
          round.decisions[h.key] = rule ? { choice: rule.choice, text: rule.text } : { choice: 'adopt' };
        }
      }
      S.finalizeRound(a, round, 'keep', at + 17 * 60_000);
    }
    return round;
  }

  function build() {
    // —— 雨季的旧书店：初稿 → 第 1 轮已完成 → 作者续写了三段，两段已标记，等待第 2 轮 ——
    const shop = article('art-shop', '雨季的旧书店', t('2026-11-03T21:40:00+08:00'), [
      ['a1', '我家楼下有一家旧书店，开了很多年了，我其实一直都没有进去过。'],
      ['a2', '那天下了很大的雨，我没有带伞，然后就躲进了书店里面。店里面的灯光是那种很暗的黄色，空气里有一股纸张受潮之后的味道。'],
      ['a3', '老板是一个看起来大概六十多岁的老人，他坐在柜台后面看书，看到我进来也没有抬头。'],
      ['a4', '我在书架之间走来走去，随便翻了几本书。'],
      ['a5', '雨停了以后我买了一本旧诗集，花了十二块钱。'],
    ]);
    shop.versions.push({ id: 'v-shop-1', kind: 'snapshot', name: '初稿', at: shop.createdAt, title: shop.title, paragraphs: S.snapshot(shop.paragraphs) });
    const selfEdit = {
      a1: '我家楼下有一家旧书店，开了很多年，我一直没有进去过。',
      a2: '那天雨下得很大，我没带伞，就躲进了书店。店里的灯光是那种很暗的黄色，空气里有一股纸张受潮之后的味道。',
      a4: '我在书架之间走来走去，随便翻了几本书。有一本书里夹着一张电影票，日期是一九九八年。',
    };
    shop.paragraphs.forEach((p) => { if (selfEdit[p.id]) p.text = selfEdit[p.id]; });
    runRound(shop, {
      a2: { instruction: 'concise' },
      a3: { instruction: 'concise' },
      a4: { instruction: 'flow' },
    }, t('2026-11-04T09:15:00+08:00'), [
      { pid: 'a2', del: '有一股', choice: 'rewrite', text: '有' },
      { pid: 'a2', del: '之后的味道', choice: 'rewrite', text: '后的味道' },
      { pid: 'a3', del: '看到我进来也没有', choice: 'keep' },
      { pid: 'a4', del: '之间走来走去', choice: 'keep' },
    ]);
    shop.paragraphs.push(
      { id: 'a6', text: '回家以后我把那张电影票夹回了诗集里面，我觉得它应该是属于那本书的。' },
      { id: 'a7', text: '后来我又去过几次那家书店，老板还是不太说话，但是有一次他非常主动地给我推荐了一本书，我觉得这件事情让我非常开心。' },
    );
    shop.marks = { a6: { instruction: 'concise' }, a7: { instruction: 'concrete' } };
    shop.updatedAt = t('2026-11-09T22:18:00+08:00');

    // —— 给新同事的一封信：第 1 轮 AI 改稿已返回，等待作者审阅 ——
    const letter = article('art-letter', '给新同事的一封信', t('2026-11-10T09:30:00+08:00'), [
      ['b1', '欢迎你加入我们团队！在接下来的几周里，你可能会收到非常多的信息，这是完全正常的事情，不用担心。'],
      ['b2', '第一周你不需要急着去写代码。我们更希望你先花一些时间去了解我们的产品是怎么被用户使用的，然后再去看代码。'],
      ['b3', '遇到不懂的问题，请随时在群里提问。在这里没有人会觉得你的问题很笨，我们每个人都是这样过来的。'],
      ['b4', '最后，祝你在这里工作愉快。'],
    ]);
    runRound(letter, {
      b1: { instruction: 'concise' },
      b2: { instruction: 'flow' },
      b3: { instruction: 'tone' },
    }, t('2026-11-10T10:02:00+08:00'), null);
    letter.updatedAt = t('2026-11-10T10:03:00+08:00');

    // —— Keeping a Notebook：英文草稿，还没有任何版本 ——
    const notebook = article('art-notebook', 'Keeping a Notebook', t('2026-11-06T07:50:00+08:00'), [
      ['c1', 'I started keeping a notebook last spring, mostly because I kept forgetting the small things that I really wanted to remember.'],
      ['c2', 'At first I basically wrote down everything, which was not very useful when I tried to find anything later.'],
      ['c3', 'Now I only write one page a day. It is usually about something I noticed, not something I did.'],
    ]);

    return {
      schema: 3,
      articles: [letter, shop, notebook],
      currentId: shop.id,
    };
  }

  global.RedraftSamples = { build };
})(typeof window !== 'undefined' ? window : globalThis);
