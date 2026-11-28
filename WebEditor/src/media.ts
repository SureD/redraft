export const rasterTypes = ["image/png", "image/jpeg", "image/gif", "image/webp"];
const asset = /^redraft-image:\/\/asset\/[\da-fA-F]{8}-(?:[\da-fA-F]{4}-){3}[\da-fA-F]{12}$/;

export function isAssetURL(value: unknown): value is string {
  return typeof value === "string" && asset.test(value);
}

export function checkRaster(file: File) {
  if (!rasterTypes.includes(file.type) || !file.size || file.size > 12 * 1024 * 1024) {
    throw new Error("请选择不超过 12 MiB 的 PNG、JPEG、GIF 或 WebP 图片。");
  }
}

export async function uploadRaster(file: File, token: string, isCurrent: () => boolean) {
  checkRaster(file);
  const bytes = new Uint8Array(await file.slice(0, 12).arrayBuffer());
  const starts = (...prefix: number[]) => prefix.every((v, i) => v === bytes[i]);
  const ascii = String.fromCharCode(...bytes);
  const matches = file.type === "image/png" ? starts(137, 80, 78, 71, 13, 10, 26, 10)
    : file.type === "image/jpeg" ? starts(255, 216, 255)
    : file.type === "image/gif" ? /^(GIF87a|GIF89a)/.test(ascii)
    : ascii.startsWith("RIFF") && ascii.slice(8) === "WEBP";
  if (!matches) throw new Error("图片内容与声明的格式不符。");
  const dataURL = await new Promise<string>((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result as string);
    reader.onerror = reader.onabort = () => reject(new Error("无法读取图片。"));
    reader.readAsDataURL(file);
  });
  if (!isCurrent()) throw new Error("文稿已切换。");
  const url = await window.webkit.messageHandlers.redraftImage.postMessage({ token, dataURL });
  if (!isCurrent()) throw new Error("文稿已切换。");
  if (!isAssetURL(url)) throw new Error("无法保存本地图片。");
  return url;
}
