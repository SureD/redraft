import Foundation
import RedraftCore

/// Demo content enters the app through the same contracts as a future article library and service.
@MainActor
struct DemoWorkspaceContentSource: WorkspaceContentSource {
  func load() -> WorkspaceSeed { DemoContent.makeSeed() }
}

struct DemoReviewProvider: ReviewProviding {
  var delay: Duration = .milliseconds(1100)

  func changes(for request: ReviewRequest) async throws -> [ReviewChange] {
    try await Task.sleep(for: delay)
    try Task.checkCancellation()
    return DemoContent.changes(for: request.article)
  }
}

private enum DemoContent {
  static func text(_ value: String, heading: Bool = false) -> DocumentBlock {
    DocumentBlock(
      text: RichTextContent(
        string: value, defaultStyle: TextStyle(fontSize: heading ? 22 : nil, bold: heading),
        paragraphStyle: ParagraphStyle(kind: heading ? .heading(level: 1) : .body, lineSpacing: 8)))
  }

  static func makeSeed() -> WorkspaceSeed {
    let balconyBlocks = [
      text("搬进这间小屋的第一个春天，我在朝南的阳台上摆了三个花盆。原本没指望它们能活过夏天。"),
      DocumentBlock(
        image: ImageContent(
          assetName: "sample-balcony", caption: "三月的阳台，三个花盆刚刚摆好", altText: "阳台上排着三个陶土花盆")),
      text("种了什么", heading: true),
      DocumentBlock(
        table: TableContent(rows: [
          ["月份", "作物", "状态", "备注"],
          ["三月", "薄荷", "发芽", "我觉得长得非常非常慢"],
          ["四月", "番茄", "开花", "其实每天都要浇水"],
          ["五月", "罗勒", "收获", "摘了一把做青酱"],
        ])),
      text("番茄开花之后，我每天早上起来的第一件事情，就是去阳台上面看看它有没有结果。"),
      DocumentBlock(
        image: ImageContent(
          assetName: "sample-basil", caption: "罗勒的新叶", altText: "一株罗勒的嫩叶特写", width: 0.72)),
      text("明年想试试辣椒。"),
    ]
    var initialBalcony = balconyBlocks
    initialBalcony.removeLast(2)
    initialBalcony[3].table?.rows.removeLast()
    initialBalcony[3].table?.rowIDs.removeLast()
    var balcony = Article(title: "阳台的一年", updatedAt: date(13), blocks: balconyBlocks)
    balcony.marks = [
      balconyBlocks[1].id: "更简洁", balconyBlocks[3].id: "更简洁", balconyBlocks[4].id: "更简洁",
    ]
    let balconyVersions = [
      version(for: balcony, title: "初稿", date: date(12), blocks: initialBalcony),
      version(for: balcony, title: "当前稿 · 示例", date: date(13), blocks: balconyBlocks),
    ]

    let bold = TextStyle(bold: true)
    let italic = TextStyle(italic: true)
    let diaryBlocks = [
      styled(
        text("今天是我开始写日记的第一百天。说实话，我原本以为自己坚持不过一周。"),
        spans: [("坚持不过一周", bold)]),
      text("为什么开始", heading: true),
      styled(
        text("去年冬天，我发现自己已经记不清上个月都做过一些什么事情了。日子一天一天地过去，好像什么都没有留下来。我想给自己留一点证据，证明这些日子我真的认真活过。"),
        spans: [("证据", TextStyle(background: .highlight))]),
      styled(
        text("写作不是记录生活，而是把生活再过一遍。"),
        spans: [("把生活再过一遍", TextStyle(fontFamily: "Kaiti SC"))],
        paragraph: {
          $0.headIndent = 18
          $0.firstLineHeadIndent = 18
        }),
      text("我给自己定的三条规矩", heading: true),
      styled(
        listItem("每天只写一页，写不满也没关系。", number: 1), spans: [("一页", bold)]),
      styled(
        listItem("不写“今天很开心”，只写让我开心的那件事。", number: 2),
        spans: [("那件事", TextStyle(underline: true))]),
      styled(
        listItem("写完不改，第二天早上再读一遍。", number: 3), spans: [("第二天早上", italic)]),
      text("一百天之后", heading: true),
      styled(
        text("我发现我其实是一个非常非常容易被小事打动的人，比如楼下面包店每天早上七点准时飘出来的那种香味，还有地铁上一个陌生人很认真地给我让了座。"),
        spans: [("容易被小事打动", bold)]),
      listItem("读完的书：12 本"),
      listItem("用完的笔芯：7 支"),
      styled(
        listItem("想认真道谢的人：很多"),
        spans: [("很多", TextStyle(bold: true, foreground: .rgba(1, 0.5, 0, 1)))]),
      styled(
        text("—— 写于第一百天的夜里"),
        spans: [("—— 写于第一百天的夜里", TextStyle(italic: true, foreground: .secondary))],
        paragraph: { $0.alignment = .right }),
    ]
    var diary = Article(title: "写日记的第一百天", updatedAt: date(11), blocks: diaryBlocks)
    diary.marks = [diaryBlocks[2].id: "更简洁", diaryBlocks[9].id: "更简洁"]
    let unformattedDiary = diaryBlocks.map { block in
      var plain = block
      plain.text = text(block.plainText).text
      return plain
    }
    let diaryVersions = [
      version(for: diary, title: "初稿", date: date(10), blocks: unformattedDiary),
      version(for: diary, title: "排版后 · 示例", date: date(11), blocks: diaryBlocks),
    ]

    let letterBlocks = [
      text("欢迎你加入我们团队！在接下来的几周里，你可能会收到非常多的信息，这是完全正常的事情，不用担心。"),
      text("第一周你不需要急着去写代码。我们更希望你先花一些时间去了解我们的产品是怎么被用户使用的，然后再去看代码。"),
      text("遇到不懂的问题，请随时在群里提问。在这里没有人会觉得你的问题很笨，我们每个人都是这样过来的。"),
      text("最后，祝你在这里工作愉快。"),
    ]
    var letter = Article(title: "给新同事的一封信", updatedAt: date(10), blocks: letterBlocks)
    letter.marks = Dictionary(uniqueKeysWithValues: letterBlocks.prefix(3).map { ($0.id, "更自然") })
    let letterReview = ReviewBatch(
      articleID: letter.id, baseRevisionID: letter.revisionID, changes: changes(for: letter))
    let letterVersions = [
      version(for: letter, title: "送审稿 · 示例", date: date(10), blocks: letterBlocks),
      version(
        for: letter,
        title: "改稿 · 示例", date: date(10).addingTimeInterval(60),
        blocks: suggestedBlocks(for: letter)),
    ]

    let shopBlocks = [
      text("我家楼下有一家旧书店，开了很多年，我一直没有进去过。"),
      text("那天雨下得很大，我没带伞，躲进了书店。店里亮着昏黄的灯，空气里有纸张受潮后的味道。"),
      text("老板六十多岁，坐在柜台后面看书，看到我进来也没有抬头。"),
      text("我在书架之间走来走去，随手翻了几本。其中一本夹着一张电影票，日期是一九九八年。"),
      text("雨停后，我买下了夹着电影票的那本旧诗集，十二块钱。"),
      text("回家以后我把那张电影票夹回了诗集里面，我觉得它应该是属于那本书的。"),
      text("后来我又去过几次那家书店，老板还是不太说话，但是有一次他非常主动地给我推荐了一本书，我觉得这件事情让我非常开心。"),
    ]
    var shop = Article(title: "雨季的旧书店", updatedAt: date(9), blocks: shopBlocks)
    shop.marks = [shopBlocks[5].id: "更简洁", shopBlocks[6].id: "更具体"]
    var shopInitial = shopBlocks
    shopInitial[1].text = text("那天下了很大的雨，我没有带伞，然后就躲进了书店里面。店里面的灯光是那种很暗的黄色，空气里有一股纸张受潮之后的味道。").text
    shopInitial.removeLast(2)
    let shopVersions = [
      version(for: shop, title: "初稿", date: date(3), blocks: shopInitial),
      version(
        for: shop, title: "第 1 轮定稿 · 示例", date: date(4), blocks: Array(shopBlocks.dropLast(2))),
      version(for: shop, title: "当前稿 · 示例", date: date(9), blocks: shopBlocks),
    ]

    let notebook = Article(
      title: "Keeping a Notebook", updatedAt: date(6),
      blocks: [
        text(
          "I started keeping a notebook last spring, mostly because I kept forgetting the small things that I really wanted to remember."
        ),
        text(
          "At first I basically wrote down everything, which was not very useful when I tried to find anything later."
        ),
        text(
          "Now I only write one page a day. It is usually about something I noticed, not something I did."
        ),
      ])
    let examples = [
      RewriteExample(
        articleID: shop.id, blockID: shopBlocks[1].id, before: "那种很暗的黄色", after: "昏黄的灯",
        decision: .accept,
        reason: "一个准确的词，比一串形容更有画面。", tag: "用词"),
      RewriteExample(
        articleID: shop.id, blockID: shopBlocks[2].id, before: "看到我进来也没有抬头", after: "看到我进来也没有抬头",
        decision: .keep,
        reason: "保留原来安静、缓慢的语气。", tag: "语气"),
      RewriteExample(
        articleID: shop.id, blockID: shopBlocks[1].id, before: "有一股纸张受潮之后的味道", after: "有纸张受潮后的味道",
        decision: .rewrite,
        reason: "删去赘词，留下我熟悉的表达。", tag: "赘词"),
    ]
    return WorkspaceSeed(
      articles: [
        ArticleSeed(document: balcony, versions: balconyVersions),
        ArticleSeed(document: diary, versions: diaryVersions),
        ArticleSeed(document: letter, versions: letterVersions, review: letterReview),
        ArticleSeed(document: shop, versions: shopVersions),
        ArticleSeed(document: notebook),
      ], examples: examples)
  }

  static func changes(for article: Article) -> [ReviewChange] {
    article.blocks.flatMap { block -> [ReviewChange] in
      guard article.marks[block.id] != nil else { return [] }
      if block.image?.assetName == "sample-balcony" {
        var after = block
        after.image?.assetName = "sample-tomato"
        after.image?.altText = "番茄的叶子和第一朵花"
        var caption = block
        caption.image?.caption = "四月，番茄开了第一朵花"
        return [
          ReviewChange(
            blockID: block.id, kind: .image, before: "阳台全景",
            after: "番茄近景", explanation: "图片 · 用番茄近景承接下一段。",
            beforeBlock: block, afterBlock: after),
          ReviewChange(
            blockID: block.id, before: block.plainText,
            after: caption.plainText, explanation: "图注 · 补上番茄开花的时间和细节。",
            beforeBlock: block, afterBlock: caption),
        ]
      }
      if let table = block.table,
        table.rows == balconyTableRows
      {
        var march = block
        march.table?.rows[1][3] = "长得很慢"
        var april = block
        april.table?.rows[2][3] = "每天浇水"
        var column = block
        column.table?.rows = table.rows.map { row in
          var cells = row
          cells.remove(at: 2)
          return cells
        }
        column.table?.columnIDs.remove(at: 2)
        var row = block
        row.table?.rows.append(["六月", "辣椒", "移栽", "刚移栽，还没开花"])
        row.table?.rowIDs.append(UUID())
        return [
          ReviewChange(
            blockID: block.id, before: table.rows[1][3], after: "长得很慢",
            explanation: "表格 · 三月 / 备注：删去重复的程度词。", beforeBlock: block, afterBlock: march),
          ReviewChange(
            blockID: block.id, before: table.rows[2][3], after: "每天浇水",
            explanation: "表格 · 四月 / 备注：直接写下需要做的事。", beforeBlock: block, afterBlock: april),
          ReviewChange(
            blockID: block.id, kind: .tableColumn, before: "状态：发芽 / 开花 / 收获", after: "删除“状态”列",
            explanation: "表格结构 · 去掉与备注重复的状态信息。", beforeBlock: block, afterBlock: column),
          ReviewChange(
            blockID: block.id, kind: .tableRow, before: "三月至五月的记录",
            after: "六月 · 辣椒 · 移栽 · 刚移栽，还没开花",
            explanation: "表格结构 · 单独确认新增的六月记录。", beforeBlock: block, afterBlock: row),
        ]
      }
      guard let after = textSuggestions[block.plainText] else { return [] }
      var result = block
      result.text = RichTextContent(
        string: after, defaultStyle: block.text.defaultStyle,
        paragraphStyle: block.text.paragraphStyle)
      return [
        ReviewChange(
          blockID: block.id, before: block.plainText, after: after,
          explanation: "精简重复表达，让动作和画面更清楚。", beforeBlock: block, afterBlock: result)
      ]
    }
  }

  static func suggestedBlocks(for article: Article) -> [DocumentBlock] {
    let suggestions = changes(for: article)
    return article.blocks.map { block in
      if article.marks[block.id] != nil, block.image?.assetName == "sample-balcony" {
        var after = block
        after.image?.assetName = "sample-tomato"
        after.image?.caption = "四月，番茄开了第一朵花"
        after.image?.altText = "番茄的叶子和第一朵花"
        return after
      }
      if article.marks[block.id] != nil, block.table?.rows == balconyTableRows {
        var after = block
        after.table?.rows = [
          ["月份", "作物", "备注"], ["三月", "薄荷", "长得很慢"], ["四月", "番茄", "每天浇水"], ["五月", "罗勒", "摘了一把做青酱"],
          ["六月", "辣椒", "刚移栽，还没开花"],
        ]
        after.table?.rowIDs.append(UUID())
        after.table?.columnIDs.remove(at: 2)
        return after
      }
      return suggestions.first(where: { $0.blockID == block.id })?.afterBlock ?? block
    }
  }

  private static func date(_ day: Int) -> Date {
    Calendar(identifier: .gregorian).date(
      from: DateComponents(year: 2026, month: 11, day: day, hour: 20))!
  }

  private static let balconyTableRows = [
    ["月份", "作物", "状态", "备注"], ["三月", "薄荷", "发芽", "我觉得长得非常非常慢"],
    ["四月", "番茄", "开花", "其实每天都要浇水"], ["五月", "罗勒", "收获", "摘了一把做青酱"],
  ]

  private static func version(
    for article: Article, title: String, date: Date, blocks: [DocumentBlock]
  ) -> ArticleVersion {
    var snapshot = article
    snapshot.updatedAt = date
    snapshot.blocks = blocks
    snapshot.marks = snapshot.marks.filter { id, _ in blocks.contains { $0.id == id } }
    if snapshot != article { snapshot.revisionID = UUID() }
    return ArticleVersion(title: title, date: date, document: snapshot)
  }

  private static func styled(
    _ block: DocumentBlock, spans: [(String, TextStyle)] = [],
    paragraph: ((inout ParagraphStyle) -> Void)? = nil
  ) -> DocumentBlock {
    var styled = block
    var content = block.text
    if let paragraph { paragraph(&content.paragraphStyle) }
    for (fragment, style) in spans {
      let range = (content.string as NSString).range(of: fragment)
      if range.location != NSNotFound {
        content.runs.append(
          RichTextRun(range: range, style: style, paragraphStyle: content.paragraphStyle))
      }
    }
    styled.text = content
    return styled
  }

  private static func listItem(_ value: String, number: Int? = nil) -> DocumentBlock {
    styled(text(value)) {
      $0.list = ListStyle(
        marker: number == nil ? .bullet : .decimal, startingItemNumber: number ?? 1)
      $0.headIndent = 24
      $0.firstLineHeadIndent = 0
    }
  }

  private static let textSuggestions: [String: String] = [
    "番茄开花之后，我每天早上起来的第一件事情，就是去阳台上面看看它有没有结果。": "番茄开花后，我每天起床第一件事，就是去阳台看看它结果了没有。",
    "去年冬天，我发现自己已经记不清上个月都做过一些什么事情了。日子一天一天地过去，好像什么都没有留下来。我想给自己留一点证据，证明这些日子我真的认真活过。":
      "去年冬天，我发现自己记不清上个月做过什么。日子一天天过去，好像什么都没留下。我想给自己留一点证据，证明这些日子我真的认真活过。",
    "我发现我其实是一个非常非常容易被小事打动的人，比如楼下面包店每天早上七点准时飘出来的那种香味，还有地铁上一个陌生人很认真地给我让了座。":
      "我发现自己很容易被小事打动：楼下面包店每天七点准时飘出的香味，地铁上一个陌生人认真地给我让座。",
    "欢迎你加入我们团队！在接下来的几周里，你可能会收到非常多的信息，这是完全正常的事情，不用担心。": "欢迎加入我们！接下来几周，信息可能有点多，别担心，慢慢来。",
    "第一周你不需要急着去写代码。我们更希望你先花一些时间去了解我们的产品是怎么被用户使用的，然后再去看代码。": "第一周不用急着写代码。先看看用户怎样使用我们的产品，再去读代码。",
    "遇到不懂的问题，请随时在群里提问。在这里没有人会觉得你的问题很笨，我们每个人都是这样过来的。": "遇到不懂的，随时在群里问。这里没人会觉得你的问题很笨——我们都是这样过来的。",
    "回家以后我把那张电影票夹回了诗集里面，我觉得它应该是属于那本书的。": "回家后，我把电影票夹回诗集。它本来就属于那本书。",
    "后来我又去过几次那家书店，老板还是不太说话，但是有一次他非常主动地给我推荐了一本书，我觉得这件事情让我非常开心。":
      "后来又去了几次。老板话还是不多。有一天，他从柜台后递来一本书：“你可能会喜欢。”",
    "I started keeping a notebook last spring, mostly because I kept forgetting the small things that I really wanted to remember.":
      "I started keeping a notebook last spring because I kept forgetting the small things I wanted to remember.",
  ]
}
