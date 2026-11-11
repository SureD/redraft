/*
 * Redraft 原型 · 模拟 AI 改稿服务
 * 对应 design.md 中「AI 改稿服务」：接收作者标记的段落和要求，返回改写文本与逐处说明。
 * 这里没有任何网络请求：示例段落使用预置改法；作者新写的段落使用一组本地规则（删赘词、精简说法）。
 */
(function (global) {
  'use strict';

  const INSTRUCTIONS = [
    { id: 'concise', label: '更简洁' },
    { id: 'concrete', label: '更具体' },
    { id: 'flow', label: '更顺口' },
    { id: 'tone', label: '语气更自然' },
  ];

  /** 预置改法：按段落原文精确匹配，notes 用于给每一处修改配上说明。 */
  const PRESETS = {
    // —— 写日记的第一百天 · 当前稿 ——
    '去年冬天，我发现自己已经记不清上个月都做过一些什么事情了。日子一天一天地过去，好像什么都没有留下来。我想给自己留一点证据，证明这些日子我真的认真活过。': {
      text: '去年冬天，我发现自己记不清上个月做过什么。日子一天天过去，好像什么都没留下。我想给自己留一点证据，证明这些日子我真的认真活过。',
      notes: [
        { del: '已经', reason: '“已经”“都”“一些”只起填充作用，删去后句子更轻。', tag: '赘词' },
        { del: '都', reason: '“已经”“都”“一些”只起填充作用，删去后句子更轻。', tag: '赘词' },
        { del: '一些什么事情了', reason: '“做过一些什么事情了”压成“做过什么”，意思不变。', tag: '赘词' },
        { ins: '什么', reason: '“做过一些什么事情了”压成“做过什么”，意思不变。', tag: '赘词' },
        { ins: '一天天', reason: '“一天一天地”压成“一天天”，节奏更紧。', tag: '节奏' },
        { del: '一天一天地', reason: '“一天一天地”压成“一天天”，节奏更紧。', tag: '节奏' },
        { del: '有', reason: '“没有留下来”可以只说“没留下”。', tag: '赘词' },
        { del: '来', reason: '“留下”已经完整，“来”可以省。', tag: '赘词' },
      ],
    },
    '我发现我其实是一个非常非常容易被小事打动的人，比如楼下面包店每天早上七点准时飘出来的那种香味，还有地铁上一个陌生人很认真地给我让了座。': {
      text: '我发现自己很容易被小事打动：楼下面包店每天七点准时飘出的香味，地铁上一个陌生人认真地给我让座。',
      notes: [
        { ins: '自己', reason: '“我发现我”两个“我”挨在一起，第二个换成“自己”。', tag: '重复' },
        { del: '其实是一个非常非常', reason: '“其实”和叠用的“非常”都在加强语气，叠在一起显得用力；让后面的小事自己说话。', tag: '赘词' },
        { ins: '：', reason: '用冒号直接引出例子，代替“的人，比如”。', tag: '节奏' },
        { del: '比如', reason: '用冒号直接引出例子，代替“的人，比如”。', tag: '节奏' },
        { del: '早上', reason: '“七点”配上面包香，已经是早上。', tag: '赘词' },
        { del: '来的那种', reason: '“飘出来的那种香味”压成“飘出的香味”。', tag: '赘词' },
        { del: '还有', reason: '两个例子并列，用逗号就够了。', tag: '衔接' },
        { del: '很', reason: '“认真地”本身就有分量，“很”可以省。', tag: '赘词' },
        { del: '了', reason: '“让座”是一个完整的动作，“了”可以省。', tag: '赘词' },
      ],
    },
    // —— 雨季的旧书店 · 第 1 轮 ——
    '那天雨下得很大，我没带伞，就躲进了书店。店里的灯光是那种很暗的黄色，空气里有一股纸张受潮之后的味道。': {
      text: '那天雨下得很大，我没带伞，躲进了书店。店里亮着昏黄的灯，空气里是纸张受潮的气味。',
      notes: [
        { del: '就', reason: '“就”在这里只起连接作用，删去后两个动作接得更紧。', tag: '赘词' },
        { ins: '亮着昏黄的灯', reason: '“那种很暗的黄色”绕了一圈才说到颜色，“昏黄”一个词就够了。', tag: '用词' },
        { ins: '气味', reason: '“有一股……之后的味道”拆得太散，压成“是……的气味”更紧凑。', tag: '赘词' },
        { del: '有一股', reason: '“有一股……之后的味道”拆得太散，压成“是……的气味”更紧凑。', tag: '赘词' },
      ],
    },
    '老板是一个看起来大概六十多岁的老人，他坐在柜台后面看书，看到我进来也没有抬头。': {
      text: '老板六十多岁，坐在柜台后面看书，我进门时，他没有抬头。',
      notes: [
        { del: '看起来大概', reason: '“看起来”和“大概”都在表达不确定，叠在一起显得犹豫；直接写年龄更干净。', tag: '赘词' },
        { del: '是一个', reason: '“是一个……的老人”可以省掉，年龄本身就说明了他是老人。', tag: '赘词' },
        { del: '的老人', reason: '“是一个……的老人”可以省掉，年龄本身就说明了他是老人。', tag: '赘词' },
        { del: '他', reason: '主语和前半句相同，可以承前省略。', tag: '赘词' },
        { ins: '我进门时，他', reason: '把“他没有抬头”单独成句，把安静的停顿留给老板。', tag: '节奏' },
      ],
    },
    '我在书架之间走来走去，随便翻了几本书。有一本书里夹着一张电影票，日期是一九九八年。': {
      text: '我在书架间慢慢走，随手翻了几本。其中一本夹着一张电影票，日期是一九九八年。',
      notes: [
        { ins: '慢慢走', reason: '“走来走去”有些急躁，“慢慢走”更贴合雨天书店的节奏。', tag: '用词' },
        { ins: '随手', reason: '“随手”写的是动作，“随便”写的是态度；这里要写动作。', tag: '用词' },
        { ins: '其中一本', reason: '承接上句的“几本”，同时避免“书”字连续出现。', tag: '重复' },
      ],
    },
    // —— 雨季的旧书店 · 当前稿 ——
    '我家楼下有一家旧书店，开了很多年，我一直没有进去过。': {
      text: '楼下那家旧书店开了很多年，我一直没进去过。',
      notes: [
        { ins: '楼下那家', reason: '开篇直接落到“那家书店”，读者更快进入场景。', tag: '节奏' },
        { del: '有', reason: '“没有进去过”的“有”可省，口气更轻。', tag: '赘词' },
      ],
    },
    '雨停了以后我买了一本旧诗集，花了十二块钱。': {
      text: '雨停后，我买下了夹着电影票的那本旧诗集，十二块钱。',
      notes: [
        { ins: '夹着电影票的那本', reason: '点明买下的就是夹着电影票的那本，下一段“夹回诗集”才接得上。', tag: '衔接' },
        { del: '花了', reason: '价钱本身已经说明一切，“花了”可以省。', tag: '赘词' },
        { ins: '后，', reason: '“了以后”压成“后”，并用逗号留一个停顿。', tag: '节奏' },
      ],
    },
    '回家以后我把那张电影票夹回了诗集里面，我觉得它应该是属于那本书的。': {
      text: '回家后，我把电影票夹回诗集。它本来就属于那本书。',
      notes: [
        { del: '我觉得它应该是', reason: '去掉“我觉得”“应该”，判断更笃定，也更像你在前文的语气。', tag: '语气' },
        { del: '里面', reason: '“夹回诗集”已含方位，“里面”可省。', tag: '赘词' },
        { del: '以', reason: '“以后”在这里可以只留“后”。', tag: '赘词' },
        { del: '那张', reason: '上文刚提到电影票，指代可以省略。', tag: '赘词' },
      ],
    },
    '后来我又去过几次那家书店，老板还是不太说话，但是有一次他非常主动地给我推荐了一本书，我觉得这件事情让我非常开心。': {
      text: '后来我又去过几次。老板还是很少说话，只有一次，他从柜台下面抽出一本书递给我，说：“你应该会喜欢。”那天我高兴了很久。',
      notes: [
        { ins: '从柜台下面抽出一本书递给我', reason: '用一个具体动作代替“非常主动地推荐”，让读者自己感到他的主动。', tag: '具体' },
        { ins: '“你应该会喜欢。”', reason: '补了一句老板的话。这是改稿时补写的细节，请确认是否与事实相符。', tag: '具体' },
        { ins: '那天我高兴了很久', reason: '用时间的长度写开心的程度，比“非常开心”更可感。', tag: '具体' },
        { del: '那家书店', reason: '上文已交代书店，可以省。', tag: '重复' },
        { ins: '很少', reason: '“很少说话”比“不太说话”更像一种性格，而不是一时的状态。', tag: '用词' },
      ],
    },
    // —— 给新同事的一封信 · 第 1 轮 ——
    '欢迎你加入我们团队！在接下来的几周里，你可能会收到非常多的信息，这是完全正常的事情，不用担心。': {
      text: '欢迎加入团队！接下来几周，你会收到很多信息，这很正常，不必担心。',
      notes: [
        { del: '你', reason: '欢迎语短一点更有温度。', tag: '节奏' },
        { del: '我们', reason: '信是团队写的，“我们”可以省。', tag: '赘词' },
        { del: '的几周里', reason: '时间状语去掉“在……的……里”，句子起得更快。', tag: '赘词' },
        { del: '在', reason: '时间状语去掉“在……的……里”，句子起得更快。', tag: '赘词' },
        { ins: '会收到很多', reason: '“可能”和“非常”叠在一起反而显得不确定。', tag: '赘词' },
        { ins: '很正常', reason: '“是完全正常的事情”可以压成“很正常”，语气更轻松。', tag: '赘词' },
        { ins: '必', reason: '“不必”比“不用”稍正式，适合写在信里。', tag: '用词' },
      ],
    },
    '第一周你不需要急着去写代码。我们更希望你先花一些时间去了解我们的产品是怎么被用户使用的，然后再去看代码。': {
      text: '第一周不必急着写代码。先花些时间看看用户怎样使用我们的产品，再去读代码。',
      notes: [
        { ins: '不必', reason: '“你不需要”有些像规定，“不必”更像建议。', tag: '语气' },
        { del: '去写', reason: '“急着去写”的“去”可以省。', tag: '赘词' },
        { ins: '看看用户怎样使用我们的产品', reason: '把被动的“产品是怎么被用户使用的”改成主动句，读起来更顺。', tag: '语序' },
        { ins: '读', reason: '“读代码”和前面的“看看用户”区分开两种动作。', tag: '用词' },
        { del: '然后', reason: '“先……再……”已经表示顺序，“然后”重复。', tag: '赘词' },
      ],
    },
    '遇到不懂的问题，请随时在群里提问。在这里没有人会觉得你的问题很笨，我们每个人都是这样过来的。': {
      text: '有不懂的地方，随时在群里问。这里没人会觉得你的问题笨——我们都是这样过来的。',
      notes: [
        { del: '请', reason: '去掉“请”，像同事之间说话，而不是一则通知。', tag: '语气' },
        { ins: '有不懂的地方', reason: '“遇到……问题”略显正式，“有不懂的地方”更口语。', tag: '语气' },
        { ins: '——', reason: '用破折号把后半句变成补充，语气更亲近。', tag: '标点' },
        { del: '每个人', reason: '“我们都”已经包含每个人。', tag: '赘词' },
        { del: '在这里没有', reason: '“在这里没有人”压成“这里没人”，更口语。', tag: '赘词' },
        { ins: '问', reason: '“提问”换成“问”，和整封信的口语一致。', tag: '用词' },
      ],
    },
    '最后，祝你在这里工作愉快。': {
      text: '最后，希望你在这里过得开心。',
      notes: [
        { ins: '希望你在这里过得开心', reason: '“工作愉快”是套话，换成更日常的说法。', tag: '语气' },
      ],
    },
    // —— Keeping a Notebook ——
    'I started keeping a notebook last spring, mostly because I kept forgetting the small things that I really wanted to remember.': {
      text: 'I started keeping a notebook last spring because I kept forgetting the small things I wanted to remember.',
      notes: [
        { del: 'mostly', reason: '“mostly” 给理由加了一层保留，而你随后把理由说得很明确。', tag: '赘词' },
        { del: 'really', reason: '省去关系代词 that 和强调词 really，句尾更轻。', tag: '赘词' },
        { del: 'that', reason: '省去关系代词 that，句尾更轻。', tag: '赘词' },
      ],
    },
    'At first I basically wrote down everything, which was not very useful when I tried to find anything later.': {
      text: 'At first I wrote down everything, which made it hard to find anything later.',
      notes: [
        { del: 'basically', reason: '“basically” 不增加信息。', tag: '赘词' },
        { ins: 'made it hard', reason: '直接说结果，比 “not very useful” 更具体。', tag: '具体' },
      ],
    },
    'Now I only write one page a day. It is usually about something I noticed, not something I did.': {
      text: 'Now I write one page a day, usually about something I noticed rather than something I did.',
      notes: [
        { del: 'only', reason: '“one page” 已经说明了限度。', tag: '赘词' },
        { ins: ', usually', reason: '两句合并，节奏更连贯。', tag: '节奏' },
        { ins: 'rather than', reason: '“rather than” 让两者的取舍更明确。', tag: '用词' },
      ],
    },
  };

  /** 本地规则：只做确定、低风险的精简，避免假装理解语义。 */
  const RULES = [
    { re: /我觉得(?=[\u4e00-\u9fa5])/g, to: '', reason: '去掉“我觉得”，判断更笃定。', tag: '语气' },
    { re: /其实/g, to: '', reason: '“其实”通常不增加信息，删去后句子更干脆。', tag: '赘词' },
    { re: /，然后(?:就)?/g, to: '，', reason: '逗号已经承接了顺序，“然后”可以省。', tag: '赘词' },
    { re: /然后就/g, to: '就', reason: '“然后就”留一个“就”即可。', tag: '赘词' },
    { re: /进行了([\u4e00-\u9fa5]{2})/g, to: '$1了', reason: '“进行了 + 动词”是名词化说法，直接用动词更有力。', tag: '用词' },
    { re: /进行([\u4e00-\u9fa5]{2})/g, to: '$1', reason: '“进行 + 动词”是名词化说法，直接用动词更有力。', tag: '用词' },
    { re: /非常非常/g, to: '非常', reason: '叠用程度副词会稀释强调。', tag: '赘词' },
    { re: /这件事情/g, to: '这件事', reason: '“事情”在这里可以只留“事”。', tag: '赘词' },
    { re: /(?<=[\u4e00-\u9fa5])(?<!了)的时候/g, to: '时', reason: '“……的时候”压成“……时”，节奏更紧。', tag: '节奏' },
    { re: /(?<=[\u4e00-\u9fa5])(?<!了)之后/g, to: '后', reason: '“之后”在这里可以只留“后”。', tag: '赘词' },
    { re: /里面(?=[，。！？、；\s]|$)/g, to: '里', reason: '方位词“里面”可以只留“里”。', tag: '赘词' },
    { re: /所以说/g, to: '所以', reason: '“所以说”是口头禅，留“所以”即可。', tag: '赘词' },
    { re: /的的/g, to: '的', reason: '重复的“的”。', tag: '标点' },
    { re: /([，。！？；])\1+/g, to: '$1', reason: '重复的标点。', tag: '标点' },
    { re: /\b(?:very|really|basically|actually|just) (?=\w)/gi, to: '', reason: '这个强调词不增加信息。', tag: '赘词' },
    { re: /\bin order to\b/gi, to: 'to', reason: '“in order to” 通常可以只写 “to”。', tag: '赘词' },
    { re: / {2,}/g, to: ' ', reason: '多余的空格。', tag: '标点' },
  ];

  function applyRules(text) {
    let out = text;
    const notes = [];
    for (const rule of RULES) {
      rule.re.lastIndex = 0;
      const matches = out.match(rule.re);
      if (!matches) continue;
      for (const m of new Set(matches)) notes.push({ del: m.trim(), reason: rule.reason, tag: rule.tag });
      out = out.replace(rule.re, rule.to);
    }
    out = out.replace(/(^|[.!?]\s+)([a-z])/g, (m, p, c) => p + c.toUpperCase());
    return { text: out, notes };
  }

  function delay(ms, signal) {
    return new Promise((resolve, reject) => {
      const t = setTimeout(resolve, ms);
      if (signal) {
        signal.addEventListener('abort', () => {
          clearTimeout(t);
          reject(new DOMException('aborted', 'AbortError'));
        }, { once: true });
      }
    });
  }

  /**
   * 改写一段。返回 { text, notes, source }：
   * source = 'preset'（预置改法）| 'rules'（本地规则）| 'none'（模拟服务未作修改）
   */
  async function revise(paragraphText, instruction, options = {}) {
    const latency = Math.min(1500, 650 + [...paragraphText].length * 9);
    await delay(options.fast ? 30 : latency, options.signal);
    const preset = PRESETS[paragraphText.trim()];
    if (preset) return { text: preset.text, notes: preset.notes, source: 'preset' };
    const ruled = applyRules(paragraphText);
    if (ruled.text !== paragraphText) return { text: ruled.text, notes: ruled.notes, source: 'rules' };
    return { text: paragraphText, notes: [], source: 'none' };
  }

  /** 为一处修改找说明：优先匹配删去的文字，其次匹配新增的文字。 */
  function explain(hunk, notes) {
    const list = notes || [];
    const del = hunk.del.trim();
    const ins = hunk.ins.trim();
    const hit = list.find((n) => n.ins && ins && ins.includes(n.ins))
      || list.find((n) => n.del && del && del.includes(n.del))
      || list.find((n) => n.ins && [...ins].length >= 2 && n.ins.includes(ins))
      || list.find((n) => n.del && [...del].length >= 2 && n.del.includes(del));
    if (hit) return { reason: hit.reason, tag: hit.tag };
    if (!hunk.ins) return { reason: '删去了这部分文字。', tag: '删减' };
    if (!hunk.del) return { reason: '补上了这部分文字。', tag: '补充' };
    return { reason: '调整了措辞。', tag: '用词' };
  }

  global.RedraftMockAI = {
    INSTRUCTIONS,
    revise,
    explain,
    presetFor: (t) => PRESETS[t.trim()] || null,
  };
})(typeof window !== 'undefined' ? window : globalThis);
