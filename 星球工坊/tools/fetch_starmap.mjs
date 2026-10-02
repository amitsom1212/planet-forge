// Find and download a community Helldivers 2 galaxy-map image for the config generator's reference
// panel (view-only: the generator's search box is what actually picks planets).
//
//   node build/_fetch_starmap.mjs                 # discover candidates + download the best one
//   node build/_fetch_starmap.mjs --list          # only print candidates
//
// web_search times out on this machine and PowerShell cannot reach the network at all, but node's
// fetch works (that is how the reference source was pulled), so discovery and download both happen
// here and nothing large ever enters the conversation.
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';

const ROOT = path.resolve(import.meta.dirname, '..');  // 星球工坊/
const OUT = path.join(ROOT, '地图');
const LIST_ONLY = process.argv.includes('--list');
const ALL_IMAGES = process.argv.includes('--all-images');

const PAGES = [
  'https://helldivers.wiki.gg/wiki/Galactic_War',
  'https://helldivers.wiki.gg/wiki/Planets',
  'https://helldivers.wiki.gg/wiki/Sectors',
  'https://helldivers.wiki.gg/wiki/Galaxy',
  'https://helldivers.fandom.com/wiki/Galactic_War',
];
const COMMONS = 'https://commons.wikimedia.org/w/api.php?action=query&format=json&list=search'
  + '&srnamespace=6&srlimit=20&srsearch=Helldivers';
const UA = { 'user-agent': 'planetforge-personal-tool/1.0' };
const GOOD = /galaxy|galactic|map|sector|war|planet/i;
const IMAGE = /\.(png|jpe?g|webp|gif)(\?|$)/i;

async function get(url) {
  const response = await fetch(url, { headers: UA });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return response;
}

async function candidates() {
  const found = new Map();
  for (const page of PAGES) {
    try {
      const html = await (await get(page)).text();
      const urls = [...html.matchAll(/(?:src|href|content)="(https?:\/\/[^"]+?)"/g)].map(m => m[1]);
      for (const url of urls) {
        if (ALL_IMAGES) {
          if (/\/images\/[^"']+\.(png|jpe?g|webp)/i.test(url) && !found.has(url)) {
            found.set(url, 'page:' + page);
          }
          continue;
        }
        if (IMAGE.test(url) && GOOD.test(url) && !/logo|icon|favicon|avatar/i.test(url)) {
          if (!found.has(url)) found.set(url, 'page:' + page);
        }
      }
      console.log(`page ok   ${page}  (${urls.length} urls)`);
    } catch (error) {
      console.log(`page fail ${page}  ${error.message}`);
    }
  }
  try {
    const data = await (await get(COMMONS)).json();
    for (const hit of (data.query?.search ?? [])) {
      const title = hit.title ?? '';
      if (!GOOD.test(title)) continue;
      const url = 'https://commons.wikimedia.org/wiki/Special:FilePath/'
        + encodeURIComponent(title.replace(/^File:/, ''));
      if (!found.has(url)) found.set(url, 'commons:' + title);
    }
    console.log('commons ok');
  } catch (error) {
    console.log(`commons fail ${error.message}`);
  }
  return [...found.entries()];
}

function kind(buffer) {
  if (buffer.length > 8 && buffer[0] === 0x89 && buffer[1] === 0x50) return 'png';
  if (buffer.length > 3 && buffer[0] === 0xff && buffer[1] === 0xd8) return 'jpg';
  if (buffer.length > 12 && buffer.toString('ascii', 0, 4) === 'RIFF') return 'webp';
  if (buffer.length > 6 && buffer.toString('ascii', 0, 3) === 'GIF') return 'gif';
  return null;
}

const found = await candidates();
console.log(`\n${found.length} candidate(s):`);
for (const [url, where] of found) console.log(`  ${url}\n      from ${where}`);
if (LIST_ONLY || !found.length) process.exit(found.length ? 0 : 1);

// prefer something whose name says "galaxy/map", else the first; verify the magic bytes
found.sort((a, b) => (GOOD.test(b[0]) ? 1 : 0) - (GOOD.test(a[0]) ? 1 : 0));
await mkdir(OUT, { recursive: true });
let saved = 0;
for (const [url] of found.slice(0, 6)) {
  try {
    const buffer = Buffer.from(await (await get(url)).arrayBuffer());
    const type = kind(buffer);
    if (!type || buffer.length < 8000) {
      console.log(`skip ${url}  (${type ?? 'not an image'}, ${buffer.length} B)`);
      continue;
    }
    const target = path.join(OUT, `星图.${type}`);
    await writeFile(target, buffer);
    console.log(`saved ${target}  (${buffer.length} B, ${type}) from ${url}`);
    saved += 1;
    if (saved >= 1) break;      // one reference image is enough
  } catch (error) {
    console.log(`download fail ${url}  ${error.message}`);
  }
}
console.log(saved ? `done: ${saved} image(s) in 星球工坊/地图` : 'done: nothing downloaded');
process.exitCode = saved ? 0 : 1;
