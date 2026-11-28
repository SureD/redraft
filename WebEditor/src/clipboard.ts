import { isAssetURL } from "./media";

const supportedStyles = ["font-weight", "font-style", "text-decoration-line", "text-decoration", "text-align",
  "vertical-align", "color", "background-color", "white-space", "width", "height"];
const attributes = new Set(["align", "alt", "checked", "class", "colspan", "height", "rowspan", "start", "type", "width"]);

/** An inert template never loads clipboard resources. Clean them *before*
 * BlockNote parses/serializes HTML: a detached HTMLImageElement with a src can
 * already initiate a fetch, even if its block is later removed by ProseMirror. */
export function localHTML(html: string): string {
  const template = document.createElement("template");
  template.innerHTML = html;
  const fragment = template.content;
  fragment.querySelectorAll("script,style,link,base,meta,iframe,frame,object,embed,audio,video,source,svg,math,noscript,template")
    .forEach(el => el.remove());
  for (const el of fragment.querySelectorAll<HTMLElement>("*")) {
    if (el.tagName === "IMG" && !isAssetURL(el.getAttribute("src"))) {
      el.replaceWith(el.getAttribute("alt") || "");
      continue;
    }
    for (const attr of el.getAttributeNames()) {
      if (attr === "style") {
        const safe = supportedStyles.map(prop => [prop, el.style.getPropertyValue(prop)]);
        el.removeAttribute("style");
        for (const [prop, value] of safe) if (value) el.style.setProperty(prop, value);
      } else if (attr === "data-url" && !isAssetURL(el.dataset.url)) {
        el.removeAttribute(attr);
      } else if (!(attr.startsWith("data-") || attributes.has(attr) ||
        (el.tagName === "A" && attr === "href") || (el.tagName === "IMG" && attr === "src"))) {
        el.removeAttribute(attr);
      }
    }
  }
  for (const table of fragment.querySelectorAll("table")) {
    const width = table.rows[0]?.cells.length;
    if (!width || [...table.rows].some(row => row.cells.length !== width || [...row.cells].some(cell => cell.colSpan !== 1 || cell.rowSpan !== 1))) {
      throw new Error("暂不支持合并单元格或不规则表格；请先将其拆分为普通行列。");
    }
  }
  return template.innerHTML;
}
