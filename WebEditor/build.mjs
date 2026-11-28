import { build } from "esbuild";
import { copyFile, mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(fileURLToPath(import.meta.url));
const dist = join(root, "dist");
const text = file => readFile(join(root, file), "utf8");
const result = await build({
  absWorkingDir: root, entryPoints: ["src/editor.tsx"], outfile: "dist/editor.js",
  platform: "browser", target: "safari17", format: "iife", bundle: true,
  minify: true, charset: "utf8", legalComments: "eof", metafile: true, write: false,
  define: { "process.env.NODE_ENV": '"production"' },
  // BlockNoteView statically imports its optional emoji picker even when disabled.
  // Exclude both its network-capable provider and its multi-megabyte locale data.
  alias: { frimousse: "./src/no-emoji.ts", "@blocknote/core/emoji-data": "./src/no-emoji.ts" },
});

const inputs = new Set(Object.values(result.metafile.outputs).flatMap(output =>
  Object.entries(output.inputs).filter(([, value]) => value.bytesInOutput > 0).map(([file]) => file)));
const packages = new Set([...inputs].map(file => file.match(/^(.*node_modules\/(?:@[^/]+\/)?[^/]+)\//)?.[1]).filter(Boolean));
const notices = ["Redraft WebEditor — Third-party notices",
  "BlockNote Core, React and Mantine are used under MPL-2.0. Corresponding upstream source is available at the URLs under each package below. Redraft imports the packages without editing their covered source files.",
  await text("notices/bundled.txt"), await text("node_modules/typescript/LICENSE.txt")]; // Apache-2.0 for the embedded icon designs
const missingMIT = new Set(["react-remove-scroll-bar", "use-composed-ref"]); // Notices included in bundled.txt.
for (const directory of [...packages].sort()) {
  const pkg = JSON.parse(await text(`${directory}/package.json`));
  notices.push(`========== ${pkg.name} ${pkg.version} · ${pkg.license} ==========`);
  if (pkg.name.startsWith("@blocknote/")) {
    notices.push(`Source: https://github.com/TypeCellOS/BlockNote/tree/${pkg.gitHead || `v${pkg.version}`}/${pkg.repository.directory}`);
  }
  const licenses = (await readdir(join(root, directory), { withFileTypes: true }))
    .filter(file => file.isFile() && /^(licen[cs]e|copying|notice|copyright)(?:$|[. _-])/i.test(file.name))
    .map(file => file.name).sort();
  if (!licenses.length && !missingMIT.has(pkg.name)) throw new Error(`Missing license for ${pkg.name}`);
  for (const file of licenses) notices.push((await text(`${directory}/${file}`)).trimEnd());
}

await rm(dist, { recursive: true, force: true });
await mkdir(dist, { recursive: true });
for (const file of result.outputFiles) await writeFile(file.path, file.contents);
await copyFile(join(root, "index.html"), join(dist, "index.html"));
await writeFile(join(dist, "THIRD-PARTY-NOTICES.txt"), notices.join("\n\n") + "\n");
console.log(`Built offline editor: local HTML, CSS, JS and notices for ${packages.size} packaged dependencies.`);
