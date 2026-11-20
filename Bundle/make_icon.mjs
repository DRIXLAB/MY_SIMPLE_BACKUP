#!/usr/bin/env node
// Génère Bundle/AppIcon.icns (et l'aperçu Bundle/AppIcon.png) à partir de Bundle/AppIcon.svg.
//
// Rendu du SVG par Chromium (Playwright) à chaque taille requise par macOS, puis
// assemblage du fichier .icns (entrées PNG). Nécessite Node.js et Playwright :
//   npm install playwright && npx playwright install chromium   # si absent
//   node Bundle/make_icon.mjs        (Playwright installé globalement : NODE_PATH=$(npm root -g) node …)
//
// Le .icns généré est versionné : build.sh se contente de le copier dans le bundle.

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const { chromium } = require("playwright");

const here = dirname(fileURLToPath(import.meta.url));
const svg = readFileSync(join(here, "AppIcon.svg"), "utf8")
  .replace('width="1024" height="1024"', 'width="100%" height="100%"');

// Types d'entrées .icns contenant un PNG, et taille en pixels.
const entries = [
  ["icp4", 16], ["ic11", 32],     // 16 pt @1x / @2x
  ["icp5", 32], ["ic12", 64],     // 32 pt
  ["ic07", 128], ["ic13", 256],   // 128 pt
  ["ic08", 256], ["ic14", 512],   // 256 pt
  ["ic09", 512], ["ic10", 1024],  // 512 pt
];

const browser = await chromium.launch();
const pngs = new Map();
for (const size of [...new Set(entries.map(([, s]) => s))]) {
  const page = await browser.newPage({ viewport: { width: size, height: size } });
  await page.setContent(
    `<html><body style="margin:0;background:transparent">` +
    `<div style="width:${size}px;height:${size}px">${svg}</div></body></html>`
  );
  pngs.set(size, await page.screenshot({ omitBackground: true, clip: { x: 0, y: 0, width: size, height: size } }));
  await page.close();
}
await browser.close();

const chunks = entries.map(([type, size]) => {
  const png = pngs.get(size);
  const header = Buffer.alloc(8);
  header.write(type, 0, "ascii");
  header.writeUInt32BE(8 + png.length, 4);
  return Buffer.concat([header, png]);
});
const body = Buffer.concat(chunks);
const header = Buffer.alloc(8);
header.write("icns", 0, "ascii");
header.writeUInt32BE(8 + body.length, 4);

writeFileSync(join(here, "AppIcon.icns"), Buffer.concat([header, body]));
writeFileSync(join(here, "AppIcon.png"), pngs.get(512));
console.log(`Bundle/AppIcon.icns : ${entries.length} images, ${Math.round((8 + body.length) / 1024)} Ko`);
