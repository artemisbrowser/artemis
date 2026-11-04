// node tools/check.mjs [outDir]   static checks on a built site (spec §8.3); exit 1 on any failure
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { stripCss, sizes } from "../build.mjs";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const walk = (dir) =>
  fs
    .readdirSync(dir, { withFileTypes: true })
    .flatMap((d) =>
      d.isDirectory() ? walk(path.join(dir, d.name)) : [path.join(dir, d.name)],
    );
const ENTITIES = {
  nbsp: " ",
  amp: "&",
  lt: "<",
  gt: ">",
  quot: '"',
  apos: "'",
};
const decode = (s) =>
  s.replace(/&(#x[\da-f]+|#\d+|\w+);/gi, (m, e) =>
    e[0] === "#"
      ? String.fromCodePoint(
          e[1] === "x" || e[1] === "X" ? parseInt(e.slice(2), 16) : +e.slice(1),
        )
      : (ENTITIES[e] ?? m),
  );
const pngSize = (buf) =>
  buf.readUInt32BE(0) === 0x89504e47
    ? [buf.readUInt32BE(16), buf.readUInt32BE(20)]
    : null;

// The <section data-arc> block, matched across nested sections.
function withoutArc(html) {
  const start = html.search(/<section\b[^>]*\bdata-arc\b/);
  if (start < 0) return html;
  const re = /<(\/?)section\b/g;
  re.lastIndex = start;
  let depth = 0;
  for (let m; (m = re.exec(html));) {
    depth += m[1] ? -1 : 1;
    if (!depth)
      return html.slice(0, start) + html.slice(html.indexOf(">", m.index) + 1);
  }
  return html.slice(0, start);
}

const VOICE = [
  [/[—–]/, "em or en dash"],
  [/;/, "semicolon"],
  [/!(?!yt\b|w\b)/, "exclamation mark"],
  [
    /\b(seamless|effortless|unleash|elevate|supercharge|reimagine|revolutionary|game-changer|delve|empower|next-level|magic|blazing|journey|unlock)/i,
    "hype word",
  ],
  [/look no further|say goodbye/i, "hype phrase"],
  [/\b(color|favorite|organiz|center|gray\b)/i, "American spelling"],
  [/(?<!Public )\blicense\b/i, "licence is the noun"],
  [/\bfast\b|notari[sz]|\bsync|apple silicon/i, "claim the site never makes"],
  [
    /\b(iPhone|iPad|Intel|Safari|Chrome|Chromium|Firefox|Brave|Opera|Vivaldi|Edge(?! thickness)|Dia)\b/,
    "product or browser name",
  ],
];

export async function check(out) {
  const fails = [];
  const notes = [];
  const fail = (rule, msg) => fails.push(`${rule}: ${msg}`);
  const rel = (f) => path.relative(out, f).split(path.sep).join("/");
  const exists = (r) => fs.existsSync(path.join(out, r));
  const read = (r) => fs.readFileSync(path.join(out, r), "utf8");
  const cfg = await import(
    pathToFileURL(path.join(ROOT, "src/site.config.mjs")) + "?" + Date.now()
  );
  const files = walk(out);
  const textFiles = files.filter((f) =>
    /\.(html|css|js|txt|xml|json|webmanifest|svg)$|\/_(headers|redirects)$/.test(
      f,
    ),
  );
  const pages = [
    "index.html",
    "404.html",
    ...(cfg.DOWNLOAD_URL ? [] : ["download/index.html"]),
  ];
  for (const p of pages) if (!exists(p)) fail("files", `missing ${p}`);
  const index = exists("index.html") ? read("index.html") : "";
  const cssRel = index.match(/href="\/(assets\/site\.\w+\.css)"/)?.[1];
  const css = cssRel ? read(cssRel) : "";
  const js = files.filter((f) => rel(f).startsWith("assets/js/"));

  // 1. voice, over every text node and every attribute a person reads or hears
  for (const p of pages.filter(exists)) {
    const html = read(p)
      .replace(/<!--[\s\S]*?-->/g, "")
      .replace(/<(script|style)\b[\s\S]*?<\/\1>/gi, "");
    const strings = [
      ...[...html.matchAll(/>([^<]+)</g)].map((m) => m[1]),
      ...[
        ...html.matchAll(
          /\s(?:aria-label|alt|title|content|placeholder|data-tip)="([^"]*)"/g,
        ),
      ].map((m) => m[1]),
    ].map((s) => decode(s).replace(/\s+/g, " ").trim());
    for (const s of strings) {
      for (const [re, why] of VOICE)
        if (re.test(s)) fail("voice", `${why} in ${p}: “${s.slice(0, 90)}”`);
      if (!cfg.PRICE && /\bfree\b/i.test(s))
        fail("voice", `“free” without a PRICE in ${p}: “${s.slice(0, 90)}”`);
      if (/\bnot |rather than|instead of/i.test(s))
        notes.push(`read by a person (${p}): “${s.slice(0, 90)}”`);
    }
  }

  // 2. Arc appears only inside its own block, its CSS and its module
  const arcCss = path.join(ROOT, "src/css/sections/07-arc.css");
  const norm = (s) => s.replace(/\/assets\/[^)"'\s]+/g, "/assets/x");
  for (const f of textFiles) {
    const r = rel(f);
    if (/^assets\/js\/sections\/07-arc\.\w+\.js$/.test(r)) continue;
    let text = fs.readFileSync(f, "utf8");
    if (r.endsWith(".html")) text = withoutArc(text);
    // Fin's note may name Arc in either build
    if (r === "index.html")
      text = text.replace(/<p class="note">[^<]*<\/p>/, "");
    // while the block ships, the index head may name Arc in its title and descriptions
    if (r === "index.html" && /<section\b[^>]*\bdata-arc\b/.test(index))
      text = text.replace(
        /<title>[^<]*<\/title>|<meta\s+(?:name="description"|property="og:description")\s+content="[^"]*"\s*\/?>/g,
        "",
      );
    if (r === cssRel)
      text = fs.existsSync(arcCss)
        ? norm(text).replace(
            norm(stripCss(fs.readFileSync(arcCss, "utf8"))),
            "",
          )
        : text;
    const m = text.match(/.{0,40}\barc\b.{0,40}/i);
    if (m) fail("arc isolation", `${r}: …${m[0]}…`);
  }

  // 3. CSP hygiene
  for (const p of pages.filter(exists)) {
    const tags =
      read(p)
        .replace(/<!--[\s\S]*?-->/g, "")
        .match(/<[a-z][^>]*>/gi) ?? [];
    for (const t of tags) {
      if (/\sstyle\s*=/i.test(t))
        fail("csp", `style attribute in ${p}: ${t.slice(0, 80)}`);
      if (/\son[a-z]+\s*=/i.test(t))
        fail("csp", `handler attribute in ${p}: ${t.slice(0, 80)}`);
      if (
        /^<script\b/i.test(t) &&
        !/\ssrc=/.test(t) &&
        !/type="application\/ld\+json"/.test(t)
      )
        fail("csp", `inline script in ${p}`);
    }
  }

  // 4. motion hygiene
  if (/transition(-property)?\s*:\s*all\b/.test(css))
    fail("motion", "transition: all");
  if (/translate\s*:\s*none/.test(css))
    fail("motion", "translate: none (write translate: 0 0)");
  if (/backdrop-filter\s*:\s*url\(/.test(css))
    fail("motion", "backdrop-filter: url(), which WebKit drops entirely");
  if (/will-change/.test(css))
    fail(
      "motion",
      "will-change in a stylesheet (set it from JS for the interaction only)",
    );
  for (const m of css.matchAll(/@keyframes\s+([\w-]+)\s*\{/g)) {
    let depth = 1;
    let i = m.index + m[0].length;
    for (; depth && i < css.length; i++)
      depth += css[i] === "{" ? 1 : css[i] === "}" ? -1 : 0;
    const body = css.slice(m.index + m[0].length, i);
    const bad = body.match(
      /(?:^|[{;\s])((?:-webkit-)?(?:width|height|top|left|right|bottom|margin(?:-\w+)?|padding(?:-\w+)?|box-shadow|backdrop-filter|clip-path|background-position))\s*:/,
    );
    if (bad) fail("motion", `@keyframes ${m[1]} animates ${bad[1]}`);
  }

  // 5. JS hygiene
  for (const f of js) {
    const s = fs.readFileSync(f, "utf8");
    const r = rel(f);
    if (/\beval\s*\(|\bFunction\s*\(/.test(s))
      fail("js", `eval or Function in ${r}`);
    if (/\b(localStorage|sessionStorage|indexedDB)\b|document\.cookie/.test(s))
      fail("js", `storage or cookies in ${r}`);
    if (/\bXMLHttpRequest\b|fetch\(\s*["'`]https?:/.test(s))
      fail("js", `request to another origin in ${r}`);
    if (/addEventListener\(\s*["'](wheel|touchmove)["']/.test(s))
      fail("js", `wheel or touchmove listener in ${r}`);
    if (/innerHTML\s*=[^;]*\$\{/.test(s))
      notes.push(
        `innerHTML built from a template in ${r}: confirm visitor text is escaped`,
      );
  }

  // 6. structure
  for (const p of pages.filter(exists)) {
    const html = read(p).replace(/<template\b[\s\S]*?<\/template>/gi, "");
    if (!/<html lang="en-GB"/.test(html))
      fail("structure", `${p} lacks lang="en-GB"`);
    const levels = [...html.matchAll(/<h([1-6])\b/g)].map((m) => +m[1]);
    if (levels.filter((l) => l === 1).length !== 1)
      fail(
        "structure",
        `${p} has ${levels.filter((l) => l === 1).length} h1 elements`,
      );
    levels.forEach(
      (l, i) =>
        i &&
        l > levels[i - 1] + 1 &&
        fail("structure", `${p}: h${levels[i - 1]} is followed by h${l}`),
    );
    for (const img of html.match(/<img\b[^>]*>/g) ?? [])
      if (
        !/\swidth=/.test(img) ||
        !/\sheight=/.test(img) ||
        !/\salt=/.test(img)
      )
        fail(
          "structure",
          `${p}: <img> without width, height or alt: ${img.slice(0, 80)}`,
        );
  }
  for (const w of index.match(/<div\b[^>]*\bclass="win[\s"][^>]*>/g) ?? [])
    if (!/aria-hidden="true"/.test(w) && !/data-cmd=/.test(w))
      fail("structure", `replica window not aria-hidden: ${w.slice(0, 80)}`);
  if (
    !/<a class="skip" href="#main">/.test(index) ||
    !/<main id="main"/.test(index)
  )
    fail("structure", 'skip link must target <main id="main">');

  // 7. placeholders that must never ship
  for (const f of textFiles) {
    const s = fs.readFileSync(f, "utf8");
    for (const word of [
      "[FREE?]",
      "[FIN",
      "TODO",
      "localhost",
      "data:text/html",
    ])
      if (s.includes(word)) fail("placeholder", `${word} in ${rel(f)}`);
  }

  // 8. sizes, then the crawl and sharing files and every local reference
  fails.push(...sizes(out).errors.map((e) => "size: " + e));
  const headers = exists("_headers") ? read("_headers") : "";
  if (
    !/Content-Security-Policy: default-src 'self'/.test(headers) ||
    !/immutable/.test(headers)
  )
    fail("files", "_headers lacks the CSP or the immutable asset rule");
  if (
    !exists("robots.txt") ||
    !/^Sitemap: https:\/\/.+\/sitemap\.xml$/m.test(read("robots.txt"))
  )
    fail("files", "robots.txt lacks its Sitemap line");
  if (
    !exists("sitemap.xml") ||
    !/<urlset[^>]*>\s*<url><loc>https:\/\/[^<]+\/<\/loc><lastmod>\d{4}-\d\d-\d\d<\/lastmod><\/url>\s*<\/urlset>/.test(
      read("sitemap.xml"),
    )
  )
    fail("files", "sitemap.xml is not one <url> with a lastmod");
  const ico =
    exists("favicon.ico") && fs.readFileSync(path.join(out, "favicon.ico"));
  if (
    !ico ||
    ico.readUInt32LE(0) !== 0x10000 ||
    ico.readUInt16LE(4) !== 1 ||
    !pngSize(ico.subarray(22))
  )
    fail("files", "favicon.ico is not one embedded PNG");
  try {
    const m = JSON.parse(read("manifest.webmanifest"));
    for (const k of [
      "name",
      "short_name",
      "theme_color",
      "background_color",
      "display",
    ])
      if (!m[k]) fail("files", `manifest lacks ${k}`);
    for (const i of m.icons) {
      const size =
        exists(i.src.slice(1)) &&
        pngSize(fs.readFileSync(path.join(out, i.src.slice(1))));
      if (!size || `${size[0]}x${size[1]}` !== i.sizes)
        fail("files", `manifest icon ${i.src} is not ${i.sizes}`);
    }
  } catch (e) {
    fail("files", "manifest.webmanifest: " + e.message);
  }
  const og =
    exists("og/home.png") && fs.readFileSync(path.join(out, "og/home.png"));
  if (!og || pngSize(og)?.join("x") !== "1200x630" || og.length > 1024 * 1024)
    fail("files", "og/home.png must be a 1200x630 PNG under 1 MB");
  const ids = new Set([...index.matchAll(/\sid="([^"]+)"/g)].map((m) => m[1]));
  for (const p of pages.filter(exists)) {
    const html = read(p);
    for (const [, ref] of html.matchAll(/\s(?:href|src)="([^"]+)"/g)) {
      if (/^(https?:|mailto:)/.test(ref)) continue;
      if (ref.startsWith("#")) {
        if (p === "index.html" && ref.length > 1 && !ids.has(ref.slice(1)))
          fail("links", `${p}: no element for ${ref}`);
        continue;
      }
      const target = ref.split(/[?#]/)[0].replace(/^\//, "");
      if (
        !(exists(target) && fs.statSync(path.join(out, target)).isFile()) &&
        !exists(path.join(target, "index.html")) &&
        !(target === "download" && cfg.DOWNLOAD_URL)
      )
        fail("links", `${p}: ${ref} is not in the build`);
    }
    for (const [, set] of html.matchAll(/\ssrcset="([^"]+)"/g))
      for (const part of set.split(","))
        if (!exists(part.trim().split(/\s/)[0].slice(1)))
          fail("links", `${p}: srcset ${part.trim()} is not in the build`);
  }
  for (const [, ref] of css.matchAll(/url\("?(\/[^")]+)"?\)/g))
    if (!exists(ref.slice(1))) fail("links", `css: ${ref} is not in the build`);

  // the demo hosts in the build are exactly the gate-1 list in site.config.mjs
  const hosts = new Set(Object.values(cfg.HOSTS));
  const seen = new Set();
  for (const f of textFiles)
    for (const [h] of fs
      .readFileSync(f, "utf8")
      .matchAll(/\b[\w-]+(?:\.[\w-]+)*\.(?:press|kitchen|garden|studio)\b/g)) {
      seen.add(h);
      if (!hosts.has(h)) fail("hosts", `${rel(f)}: ${h} is not in HOSTS`);
    }
  for (const h of hosts)
    if (!seen.has(h)) fail("hosts", `${h} is in HOSTS but not in the build`);

  for (const n of notes) console.log("note: " + n);
  for (const f of fails) console.error("fail: " + f);
  console.log(
    fails.length ? `check: ${fails.length} failures` : "check: all passed",
  );
  return fails.length === 0;
}

if (
  process.argv[1] &&
  pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url
)
  process.exitCode = (await check(
    path.resolve(process.argv[2] ?? path.join(ROOT, "dist")),
  ))
    ? 0
    : 1;
