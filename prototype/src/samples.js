/*
 * Redraft 原型 · 示例文章
 * 历史版本不是手写的结果：第 1 轮通过与界面相同的会话流程生成（送审 → 预置改稿 → 按脚本取舍 → 定稿），
 * 因此示例里的差异、取舍记录和写作范例与真实操作产生的数据结构一致。
 */
(function (global) {
  'use strict';

  const S = global.RedraftSession;
  const AI = global.RedraftMockAI;
  const R = global.RedraftRich;
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

  /** 带排版的段落：spans 里的每一项是 [要加样式的那段文字, 字符样式]，按出现位置换算成 runs。 */
  function rich(pid, text, block = {}, spans = []) {
    const p = { id: pid, text, ...block };
    for (const [part, attrs] of spans) {
      const at = text.indexOf(part);
      if (at >= 0) R.patch(p, at, at + part.length, attrs);
    }
    return p;
  }

  function diary() {
    const at = t('2026-11-11T07:40:00+08:00');
    const paras = [
      rich('d1', '今天是我开始写日记的第一百天。说实话，我原本以为自己坚持不过一周。', {}, [['坚持不过一周', { b: true }]]),
      rich('d2', '为什么开始', { type: 'h2' }),
      rich('d3', '去年冬天，我发现自己已经记不清上个月都做过一些什么事情了。日子一天一天地过去，好像什么都没有留下来。我想给自己留一点证据，证明这些日子我真的认真活过。', {}, [['证据', { h: 'yellow' }]]),
      rich('d4', '写作不是记录生活，而是把生活再过一遍。', { type: 'quote' }, [['把生活再过一遍', { f: 'kai' }]]),
      rich('d5', '我给自己定的三条规矩', { type: 'h2' }),
      rich('d6', '每天只写一页，写不满也没关系。', { type: 'ol' }, [['一页', { b: true }]]),
      rich('d7', '不写“今天很开心”，只写让我开心的那件事。', { type: 'ol' }, [['那件事', { u: true }]]),
      rich('d8', '写完不改，第二天早上再读一遍。', { type: 'ol' }, [['第二天早上', { i: true }]]),
      rich('d9', '一百天之后', { type: 'h2' }),
      rich('d10', '我发现我其实是一个非常非常容易被小事打动的人，比如楼下面包店每天早上七点准时飘出来的那种香味，还有地铁上一个陌生人很认真地给我让了座。', {}, [['容易被小事打动', { b: true }]]),
      rich('d11', '读完的书：12 本', { type: 'ul' }),
      rich('d12', '用完的笔芯：7 支', { type: 'ul' }),
      rich('d13', '想认真道谢的人：很多', { type: 'ul' }, [['很多', { c: 'orange', b: true }]]),
      rich('d14', '—— 写于第一百天的夜里', { align: 'right' }, [['—— 写于第一百天的夜里', { i: true, c: 'gray' }]]),
    ];
    const a = {
      id: 'art-diary',
      title: '写日记的第一百天',
      createdAt: t('2026-11-10T23:05:00+08:00'),
      updatedAt: at,
      paragraphs: paras,
      marks: {},
      versions: [],
      rounds: [],
    };
    // 初稿只有文字；当前稿是排好版的同一篇。历史里对照两稿时，只会看到“格式”标签，文字修改为零。
    a.versions.push({
      id: 'v-diary-1', kind: 'snapshot', name: '初稿', at: a.createdAt, title: a.title,
      paragraphs: paras.map((p) => ({ id: p.id, text: p.text })),
    });
    a.marks = { d3: { instruction: 'concise' }, d10: { instruction: 'concise' } };
    return a;
  }

  /** 图文表示例：两张自绘插图、一张阳台作物表；图片、表格和一段文字已标记，可直接送审体验混合审阅。 */
  function balcony() {
    const ART = global.RedraftSampleArt;
    const img = (pid, asset, caption, w, alt) => ({ id: pid, kind: 'img', text: caption, img: { asset, w, alt, iw: ART[asset].iw, ih: ART[asset].ih } });
    const table = (pid, rows) => ({
      id: pid,
      kind: 'table',
      text: '',
      table: {
        cols: ['tm', 'tp', 'ts', 'tn'],
        head: true,
        rows: rows.map(([id, ...cells]) => ({ id, cells: Object.fromEntries(['tm', 'tp', 'ts', 'tn'].map((c, i) => [c, cells[i]]).filter(([, v]) => v)) })),
      },
    });
    const head = ['rh', '月份', '作物', '状态', '备注'];
    const draft = [
      { id: 'g1', text: '搬进这间小屋的第一个春天，我在朝南的阳台上摆了三个花盆。原本没指望它们能活过夏天。' },
      img('g2', 'sample-balcony', '三月的阳台，三个花盆刚刚摆好', 'l', '阳台上排着三个陶土花盆'),
      { id: 'g3', text: '种了什么', type: 'h2' },
      table('g4', [head, ['r3', '三月', '薄荷', '发芽', '我觉得长得非常非常慢'], ['r4', '四月', '番茄', '开花', '每天浇水']]),
      { id: 'g5', text: '番茄开花之后，我每天早上起来的第一件事情，就是去阳台上面看看它有没有结果。' },
    ];
    const paras = [
      ...draft.slice(0, 3),
      table('g4', [head, ['r3', '三月', '薄荷', '发芽', '我觉得长得非常非常慢'], ['r4', '四月', '番茄', '开花', '其实每天都要浇水'], ['r5', '五月', '罗勒', '收获', '摘了一把做青酱']]),
      draft[4],
      img('g6', 'sample-basil', '罗勒的新叶', 'm', '一株罗勒的嫩叶特写'),
      { id: 'g7', text: '明年想试试辣椒。' },
    ].map(R.sanitize);
    const a = {
      id: 'art-balcony',
      title: '阳台的一年',
      createdAt: t('2026-11-12T20:10:00+08:00'),
      updatedAt: t('2026-11-13T21:36:00+08:00'),
      paragraphs: paras,
      marks: { g2: { instruction: 'concise' }, g4: { instruction: 'concise' }, g5: { instruction: 'concise' } },
      versions: [],
      rounds: [],
    };
    a.versions.push({ id: 'v-balcony-1', kind: 'snapshot', name: '初稿', at: a.createdAt, title: a.title, paragraphs: draft.map(R.sanitize) });
    return a;
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

    const day = diary();
    const garden = balcony();
    return {
      schema: 5,
      articles: [garden, day, letter, shop, notebook],
      currentId: garden.id,
    };
  }

  global.RedraftSamples = { build, diary, balcony };
})(typeof window !== 'undefined' ? window : globalThis);
