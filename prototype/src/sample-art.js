/*
 * Redraft 原型 · 示例插图
 * 项目自绘的简笔 SVG，只用中性的纸色、灰色和低饱和的叶绿，不依赖任何图像服务。
 * 以内置编号注册，不占用本机存储。
 */
(function (global) {
  'use strict';

  const B = global.RedraftBlocks;
  const svg = (w, h, body) => `data:image/svg+xml;charset=utf-8,${encodeURIComponent(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${w} ${h}" width="${w}" height="${h}">${body}</svg>`)}`;

  const leaf = (x, y, rx, ry, rot, fill) => `<ellipse cx="${x}" cy="${y}" rx="${rx}" ry="${ry}" transform="rotate(${rot} ${x} ${y})" fill="${fill}"/>`;
  const pot = (cx, base, w, h, fill, rim) => {
    const top = base - h;
    return `<path d="M${cx - w / 2} ${top} L${cx + w / 2} ${top} L${cx + w * 0.38} ${base} L${cx - w * 0.38} ${base} Z" fill="${fill}"/>`
      + `<rect x="${cx - w / 2 - 8}" y="${top - 16}" width="${w + 16}" height="22" rx="4" fill="${rim}"/>`;
  };

  /* 三月的阳台：窗、栏杆、三个陶土盆和一把浇水壶。 */
  const balcony = svg(1200, 800, [
    '<rect width="1200" height="800" fill="#ece6dc"/>',
    '<rect x="120" y="70" width="960" height="460" fill="#e2e8ea"/>',
    '<rect x="170" y="300" width="150" height="230" fill="#d2d9dc"/><rect x="340" y="250" width="110" height="280" fill="#d8dee0"/>',
    '<rect x="760" y="280" width="170" height="250" fill="#d2d9dc"/><rect x="950" y="340" width="90" height="190" fill="#d8dee0"/>',
    '<circle cx="880" cy="160" r="46" fill="#f1ede4"/>',
    '<rect x="120" y="70" width="960" height="460" fill="none" stroke="#cbc2b4" stroke-width="18"/>',
    '<rect x="591" y="70" width="18" height="460" fill="#cbc2b4"/>',
    '<rect x="0" y="640" width="1200" height="160" fill="#d8cdbd"/>',
    '<rect x="60" y="548" width="1080" height="12" rx="6" fill="#b5ab9d"/>',
    ...Array.from({ length: 19 }, (_, i) => `<rect x="${86 + i * 58}" y="556" width="6" height="88" fill="#bfb6a9"/>`),
    '<rect x="0" y="636" width="1200" height="8" fill="#c6bbab"/>',
    pot(300, 720, 150, 120, '#c39b7e', '#b58d70'),
    leaf(270, 520, 26, 62, -24, '#93a891'), leaf(330, 515, 24, 58, 22, '#829a80'), leaf(300, 490, 22, 60, 0, '#9cb09a'),
    pot(600, 724, 170, 128, '#b98f72', '#ab8366'),
    '<rect x="597" y="440" width="6" height="150" fill="#7f967d"/>',
    leaf(560, 470, 30, 14, -30, '#879d84'), leaf(640, 500, 32, 14, 28, '#93a891'), leaf(565, 540, 28, 13, -18, '#7b937a'), leaf(636, 440, 26, 12, 24, '#9cb09a'),
    pot(890, 720, 140, 110, '#c6a386', '#b8957a'),
    leaf(860, 560, 20, 40, -40, '#9cb09a'), leaf(920, 560, 20, 40, 40, '#879d84'), leaf(890, 545, 18, 44, 0, '#93a891'),
    '<path d="M1010 700 h96 l-10 -86 h-76 Z" fill="#a3a39f"/><path d="M1020 640 l-56 -40" stroke="#a3a39f" stroke-width="12" stroke-linecap="round"/>',
    '<path d="M1096 630 q40 10 30 50" fill="none" stroke="#a3a39f" stroke-width="10"/>',
  ].join(''));

  /* 同一处阳台的近景：番茄的叶子和第一朵花。 */
  const tomatoClose = svg(1200, 800, [
    '<rect width="1200" height="800" fill="#e9e3d8"/>',
    '<circle cx="980" cy="150" r="230" fill="#f0ebe1"/>',
    '<path d="M600 800 C590 640 610 520 640 380" fill="none" stroke="#7c937a" stroke-width="16"/>',
    '<path d="M626 470 C540 430 470 440 400 470" fill="none" stroke="#7c937a" stroke-width="10"/>',
    '<path d="M634 420 C720 380 800 380 860 410" fill="none" stroke="#7c937a" stroke-width="10"/>',
    leaf(420, 450, 80, 34, -18, '#8ea48b'), leaf(360, 520, 70, 30, 24, '#7e977c'), leaf(500, 520, 64, 28, -40, '#9ab098'),
    leaf(840, 390, 84, 34, 16, '#8ea48b'), leaf(900, 470, 70, 30, -26, '#7e977c'), leaf(760, 460, 60, 26, 36, '#9ab098'),
    leaf(560, 640, 90, 36, -30, '#87a085'), leaf(700, 660, 90, 34, 28, '#93a891'),
    '<g transform="translate(652 340)">',
    ...[0, 72, 144, 216, 288].map((r) => `<ellipse cx="0" cy="-34" rx="16" ry="34" transform="rotate(${r})" fill="#e4cf8f"/>`),
    '<circle r="14" fill="#c9ad62"/></g>',
    '<rect x="0" y="740" width="1200" height="60" fill="#c3a083"/><rect x="0" y="728" width="1200" height="18" fill="#b5916f"/>',
  ].join(''));

  /* 罗勒的新叶。 */
  const basil = svg(1000, 750, [
    '<rect width="1000" height="750" fill="#eee9e0"/>',
    '<ellipse cx="500" cy="700" rx="300" ry="60" fill="#d9cfc1"/>',
    '<path d="M500 700 C498 600 500 520 504 420" fill="none" stroke="#7c937a" stroke-width="12"/>',
    leaf(420, 470, 92, 50, -30, '#8aa287'), leaf(590, 470, 92, 50, 30, '#7d977b'),
    leaf(440, 360, 74, 40, -46, '#98ae95'), leaf(570, 360, 74, 40, 46, '#8aa287'),
    leaf(505, 300, 34, 60, 0, '#a4b8a1'),
    '<path d="M420 470 L500 470 M590 470 L504 470" stroke="#6f876d" stroke-width="3" opacity=".5"/>',
  ].join(''));

  const ART = {
    'sample-balcony': { url: balcony, iw: 1200, ih: 800 },
    'sample-tomato': { url: tomatoClose, iw: 1200, ih: 800 },
    'sample-basil': { url: basil, iw: 1000, ih: 750 },
  };
  for (const [id, a] of Object.entries(ART)) B.registerAsset(id, a.url);

  global.RedraftSampleArt = ART;
})(typeof window !== 'undefined' ? window : globalThis);
