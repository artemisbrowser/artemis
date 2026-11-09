// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

// node build.mjs [--out dir] [--serve port | --port port] [--check]
import fs from "node:fs";
import path from "node:path";
import http from "node:http";
import zlib from "node:zlib";
import crypto from "node:crypto";
import { execFileSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";

const ROOT = path.dirname(fileURLToPath(import.meta.url));
const SRC = path.join(ROOT, "src");
const ASSETS = path.join(ROOT, "assets");
// HTML sources open with the licence header, which stays out of the built pages
const read = (f) =>
  fs
    .readFileSync(f, "utf8")
    .replace(/^<!-- SPDX-License-Identifier:[\s\S]*?-->\n/, "");
const hash = (buf) =>
  crypto.createHash("sha256").update(buf).digest("hex").slice(0, 10);
const gz = (buf) => zlib.gzipSync(buf, { level: 9 }).length;
const kb = (n) => (n / 1024).toFixed(1) + " KB";

// Page order. A missing partial becomes an empty stub; 07-arc never gets one (it is deletable).
const SECTIONS = [
  ["01-hero", "top", "Overview"],
  ["02-out-of-the-way", "native", "Native"],
  ["06-privacy", "privacy", "Privacy"],
  ["03-spaces", "spaces", "Spaces"],
  ["04-command-bar", "command-bar", "Command bar"],
  ["05-split-view", "split-view", "Split view"],
  ["06-shape", "shape", "Make it yours"],
  ["06-open-source", "open-source", "Open source"],
  ["07-arc", "arc", null],
  ["08-close", "fin", "Made by Fin"],
];
const PAGES = {
  "index.html": {
    robots: '<meta name="robots" content="max-image-preview:large" />',
  },
  "404.html": {
    title: "Page not found · Artemis",
    body: "404",
    robots: '<meta name="robots" content="noindex" />',
  },
  "download/index.html": {
    title: "Download · Artemis",
    body: "download",
    robots: '<meta name="robots" content="noindex" />',
  },
};
const HEADERS = `/*
  Content-Security-Policy: default-src 'self'; img-src 'self' data:; media-src 'self'; style-src 'self'; script-src 'self'; connect-src 'self'; font-src 'self'; manifest-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'; upgrade-insecure-requests
  Strict-Transport-Security: max-age=63072000; includeSubDomains
  X-Content-Type-Options: nosniff
  Referrer-Policy: strict-origin-when-cross-origin
  Permissions-Policy: camera=(), microphone=(), geolocation=(), browsing-topics=()
  Cross-Origin-Opener-Policy: same-origin
/assets/*
  Cache-Control: public, max-age=31536000, immutable
/icon.svg
  ! Content-Security-Policy
https://:worker.:subdomain.workers.dev/*
  X-Robots-Tag: noindex
`;

// Drops comments, the whitespace no token needs and trailing commas. A newline goes only after an operator or
// opening bracket, or before a closing one, where no semicolon can be inserted; strings, template text and regex
// literals are copied verbatim.
export function minifyJs(src) {
  const id = (c) => !!c && /[\w$\u0080-\uffff]/.test(c);
  const KW =
    /^(return|typeof|case|do|else|in|of|new|delete|void|throw|instanceof|yield|await)$/;
  const templates = []; // brace depth inside each open ${ of a template literal
  let out = "";
  let last = "";
  let gap = "";
  let i = 0;
  const emit = (tok) => {
    if (
      gap === "\n" &&
      ((last.length === 1 &&
        "{([,;:?=<>&|^!~*%+-/.".includes(last) &&
        !/(\+\+|--)$/.test(out)) ||
        ")]},.?:;".includes(tok[0]))
    )
      gap = " ";
    if (/^[)\]}]$/.test(tok) && /[^,[(],$/.test(out)) out = out.slice(0, -1);
    const a = out.at(-1);
    if (gap === "\n") out += "\n";
    else if (
      gap &&
      ((id(a) && id(tok[0])) ||
        (/[+\-/]/.test(a) && a === tok[0]) ||
        (/^\d+$/.test(last) && tok[0] === "."))
    )
      out += " ";
    gap = "";
    out += tok;
    last = tok;
  };
  while (i < src.length) {
    const c = src[i];
    const space = (from, to) => {
      if (src.slice(from, to).includes("\n") && out) gap = "\n";
      else if (gap !== "\n") gap = " ";
      i = to;
    };
    if (/\s/.test(c)) {
      let j = i;
      while (/\s/.test(src[j] ?? "")) j++;
      space(i, j);
    } else if (c === "/" && src[i + 1] === "/") {
      while (i < src.length && src[i] !== "\n") i++;
    } else if (c === "/" && src[i + 1] === "*")
      space(i, src.indexOf("*/", i + 2) + 2);
    else if (c === '"' || c === "'") {
      let j = i + 1;
      while (src[j] !== c) j += src[j] === "\\" ? 2 : 1;
      emit(src.slice(i, j + 1));
      i = j + 1;
    } else if (c === "`" || (c === "}" && templates.at(-1) === 0)) {
      if (c === "}") templates.pop();
      let j = i + 1;
      while (src[j] !== "`" && !(src[j] === "$" && src[j + 1] === "{"))
        j += src[j] === "\\" ? 2 : 1;
      const open = src[j] === "$";
      emit(src.slice(i, j + (open ? 2 : 1)));
      if (open) templates.push(0);
      i = j + (open ? 2 : 1);
    } else if (
      c === "/" &&
      (!last ||
        (/[^\w$)\]}]$/.test(last) && !/^\d/.test(last)) ||
        KW.test(last))
    ) {
      let j = i + 1;
      for (let cls = false; cls || src[j] !== "/"; j++) {
        if (src[j] === "\\") j++;
        else if (src[j] === "[") cls = true;
        else if (src[j] === "]") cls = false;
      }
      j++;
      while (id(src[j])) j++;
      emit(src.slice(i, j));
      i = j;
    } else if (id(c)) {
      let j = i;
      while (id(src[j])) j++;
      emit(src.slice(i, j));
      i = j;
    } else {
      if (templates.length && c === "{") templates[templates.length - 1]++;
      if (templates.length && c === "}") templates[templates.length - 1]--;
      emit(c);
      i++;
    }
  }
  return out + "\n";
}

// Drops comments and the whitespace no token needs; quoted strings are copied verbatim.
export const stripCss = (css) =>
  css
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .split(/("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')/)
    .map((s, i) =>
      i % 2
        ? s
        : s
            .replace(/\s+/g, " ")
            .replace(/ ?([{};,]) ?/g, "$1")
            .replace(/: /g, ":")
            .replace(/;}/g, "}"),
    )
    .join("")
    .trim();

const walk = (dir) =>
  fs.existsSync(dir)
    ? fs
        .readdirSync(dir, { withFileTypes: true })
        .flatMap((d) =>
          d.isDirectory()
            ? walk(path.join(dir, d.name))
            : [path.join(dir, d.name)],
        )
    : [];

export async function build(out) {
  const warnings = [],
    errors = [];
  const cfg = await import(
    pathToFileURL(path.join(SRC, "site.config.mjs")) + "?" + Date.now()
  );
  const write = (rel, data) => {
    const f = path.join(out, rel);
    fs.mkdirSync(path.dirname(f), { recursive: true });
    fs.writeFileSync(f, data);
  };

  // Asset map: source reference -> published path. Hashed under /assets, icons the platform asks for at the root.
  const assets = new Map();
  const ROOT_FILES = {
    "apple-touch-icon.png": "apple-touch-icon.png",
    "og-home.png": "og/home.png",
  };
  const plan = (ref, file, rootName) => {
    const buf = fs.readFileSync(file);
    const ext = path.extname(file);
    const dest =
      rootName ?? `assets/${path.basename(file, ext)}.${hash(buf)}${ext}`;
    assets.set(ref, { file, dest, size: buf.length });
    write(dest, buf);
  };
  for (const f of walk(path.join(SRC, "img")))
    if (path.basename(f) !== "favicon-32.png")
      plan(`/assets/img/${path.basename(f)}`, f, ROOT_FILES[path.basename(f)]);
  for (const f of walk(path.join(SRC, "static")))
    plan(`/assets/static/${path.basename(f)}`, f, path.basename(f));
  for (const f of walk(path.join(SRC, "video")))
    plan(`/assets/video/${path.basename(f)}`, f);
  for (const f of walk(path.join(ASSETS, "spaces")))
    if (
      /-(880x592|110x74)\.png$|^grain-tile-128\.png$/.test(path.basename(f)) &&
      !/^space-incognito-/.test(path.basename(f))
    )
      plan(`/assets/spaces/${path.basename(f)}`, f);
  const rewrite = (text, where) =>
    text.replace(/\/assets\/(?!js\/)[\w./-]+/g, (ref) => {
      const a = assets.get(ref);
      if (!a) errors.push(`${where}: unknown asset ${ref}`);
      return a ? "/" + a.dest : ref;
    });
  const url = (ref) => "/" + assets.get(ref)?.dest;

  // JS: the modules on the page run from one bundle, in the order ES modules would evaluate them. The Arc
  // module stays a file of its own, linked from inside its block, and imports what it needs from the bundle.
  const jsDir = path.join(SRC, "js");
  const IMPORT =
    /\bimport\s*(?:\{([^}]*)\}\s*from\s*)?["'](\.{1,2}\/[^"']+)["'];?/g;
  const sources = new Map(); // rel -> minified code
  for (const f of walk(jsDir).filter(
    (f) => f.endsWith(".js") && (cfg.ARC_BLOCK || !f.endsWith("07-arc.js")),
  )) {
    const rel = path.relative(jsDir, f).split(path.sep).join("/");
    sources.set(rel, minifyJs(rewrite(read(f), `js/${rel}`)));
  }
  const target = (rel, spec) => path.posix.join(path.posix.dirname(rel), spec);
  const imports = (code, fn) =>
    code.replace(IMPORT, (m, list, spec) => fn(list, spec));
  const order = [];
  const visit = (rel, trail = []) => {
    if (order.includes(rel)) return;
    if (trail.includes(rel)) throw new Error(`import cycle through ${rel}`);
    if (!sources.has(rel)) throw new Error(`missing module ${rel}`);
    for (const m of sources.get(rel).matchAll(IMPORT))
      visit(target(rel, m[2]), [...trail, rel]);
    order.push(rel);
  };
  let bundle = "const __m={};\n";
  try {
    visit("main.js");
    for (const [file] of SECTIONS)
      if (
        file !== "07-arc" &&
        sources.has(`sections/${file}.js`) &&
        fs.existsSync(path.join(SRC, `partials/${file}.html`))
      )
        visit(`sections/${file}.js`);
  } catch (e) {
    errors.push(e.message);
  }
  for (const rel of order) {
    const names = [];
    const body = imports(sources.get(rel), (list, spec) =>
      list
        ? `const{${list.replace(/\s+as\s+/g, ":")}}=__m["${target(rel, spec)}"];`
        : "",
    ).replace(
      /\bexport\s+((?:async\s+)?function\*?|const|let|class)\s*([\w$]+)/g,
      (m, kind, name) => (names.push(name), `${kind} ${name}`),
    );
    bundle += `__m["${rel}"]=(()=>{${body}return{${names}}})();\n`;
  }
  const arcJs =
    cfg.ARC_BLOCK &&
    fs.existsSync(path.join(SRC, "partials/07-arc.html")) &&
    sources.get("sections/07-arc.js");
  if (arcJs)
    imports(arcJs, (list, spec) => {
      const from = target("sections/07-arc.js", spec);
      if (!order.includes(from))
        errors.push(`js/sections/07-arc.js: ${spec} is not in the bundle`);
      bundle += `export const{${list.replace(/\s+as\s+[\w$]+/g, "")}}=__m["${from}"];\n`;
    });
  // hashed names, so the year-long immutable /assets/* cache never pairs a page with another build's code
  const site = `site.${hash(bundle)}.js`;
  const shipped = new Map([["site.js", [site, bundle]]]);
  if (arcJs) {
    const code = imports(arcJs, (list) => `import{${list}}from"../${site}";`);
    shipped.set("sections/07-arc.js", [
      `sections/07-arc.${hash(code)}.js`,
      code,
    ]);
  }
  const dl = sources.get("download.js");
  if (dl) shipped.set("download.js", [`download.${hash(dl)}.js`, dl]);
  const jsUrl = {};
  for (const [rel, [file, code]] of shipped) {
    write(`assets/js/${file}`, code);
    jsUrl[rel] = `/assets/js/${file}`;
  }

  // CSS
  const cssParts = ["tokens", "base", "components", "window", "pages"].map(
    (n) => `css/${n}.css`,
  );
  for (const f of fs.readdirSync(path.join(SRC, "css/sections")).sort())
    if (f.endsWith(".css") && (cfg.ARC_BLOCK || f !== "07-arc.css"))
      cssParts.push(`css/sections/${f}`);
  const css = rewrite(
    cssParts
      .filter(
        (p) =>
          fs.existsSync(path.join(SRC, p)) ||
          (warnings.push(`missing ${p}, skipped`), false),
      )
      .map((p) => stripCss(read(path.join(SRC, p))))
      .join("\n"),
    "css",
  );
  const cssDest = `assets/site.${hash(css)}.css`;
  write(cssDest, css);

  // HTML
  const partial = (name) => path.join(SRC, "partials", name + ".html");
  const include = (text, depth) =>
    text.replace(/<!-- @include ([\w/-]+) -->/g, (m, name) => {
      if (depth > 6)
        return (errors.push(`include depth over 6 at ${name}`), "");
      if (fs.existsSync(partial(name)))
        return include(read(partial(name)), depth + 1);
      if (/^\d\d-/.test(name))
        return (
          warnings.push(`missing section partial ${name}, left empty`),
          ""
        );
      return (errors.push(`missing include ${name}`), "");
    });
  const priced = (text) =>
    text
      .replace(/<!-- @price -->/g, () => (cfg.PRICE ? ` ${cfg.PRICE}.` : ""))
      .replace(/<!-- @stage -->/g, () =>
        cfg.STAGE ? `<span class="stage-tag">${cfg.STAGE}</span> ` : "",
      )
      .replace(
        /<!-- @if (\w+) -->([\s\S]*?)<!-- @endif -->/g,
        (m, key, body) => (cfg[key] ? body : ""),
      );

  let mainHtml = "";
  for (const [file, id, name] of SECTIONS) {
    if (file === "07-arc") {
      if (!cfg.ARC_BLOCK || !fs.existsSync(partial(file))) continue;
      // the block's module is linked inside the block, so nothing outside it names it
      let arc = include(read(partial(file)), 1);
      if (arcJs)
        arc = arc.replace(
          /<\/section>\s*$/,
          `<link rel="modulepreload" href="${jsUrl["sections/07-arc.js"]}" />\n</section>\n`,
        );
      mainHtml += arc;
      continue;
    }
    if (fs.existsSync(partial(file))) {
      mainHtml += include(read(partial(file)), 1);
      if (!fs.existsSync(path.join(SRC, `css/sections/${file}.css`)))
        warnings.push(`missing css/sections/${file}.css, skipped`);
    } else {
      warnings.push(`missing section partial ${file}, stubbed`);
      mainHtml += `<section class="sec" id="${id}" data-name="${name}"></section>\n`;
    }
  }
  const missingFoundation = [
    "00-head",
    "00-sprite",
    "00-nav",
    "09-footer",
    "10-templates",
  ].filter((n) => !fs.existsSync(partial(n)));
  if (missingFoundation.length)
    errors.push(`missing partials: ${missingFoundation.join(", ")}`);
  const part = (n) =>
    fs.existsSync(partial(n)) ? include(read(partial(n)), 1) : "";

  const preloads = [];
  // the hero paints Personal's mesh from the small render (01-hero.css); the nav brand lands with the first paint
  if (assets.has("/assets/spaces/space-tide-110x74.png"))
    preloads.push(
      `<link rel="preload" as="image" href="${url("/assets/spaces/space-tide-110x74.png")}" />`,
    );
  for (const scheme of ["dark", "light"])
    if (assets.has(`/assets/img/icon-rigel-${scheme}-64.png`))
      preloads.push(
        `<link rel="preload" as="image" href="${url(`/assets/img/icon-rigel-${scheme}-64.png`)}" media="(prefers-color-scheme: ${scheme})" />`,
      );

  // Arc may be named only in the index head and only while its block ships (tools/check.mjs rule 2).
  const arc = cfg.ARC_BLOCK && fs.existsSync(partial("07-arc"));
  const free = /^free$/i.test(cfg.PRICE ?? "") ? " free," : "";
  const stage = cfg.STAGE ? `, in ${cfg.STAGE.toLowerCase()}` : "";
  // the offer's price: "0" only when the meta says free, otherwise the digits of PRICE or no offer
  const amount = free ? "0" : cfg.PRICE?.replace(/[^\d.]/g, "");
  const moveIn =
    "Bring your Arc spaces and tabs over before Arc stops working on 22 December.";
  const about = `Artemis is a${free} native, private browser for macOS 26${stage}. Spaces, profiles and a sidebar, shaped how you like. Ads and trackers blocked out of the box. Open source, no account, no telemetry.`;
  const share = `A${free} native, private Mac browser you can make your own${stage}.`;
  const home = {
    ...PAGES["index.html"],
    title: `Artemis: a native, private Mac browser you can make your own${arc ? ". Move in from Arc." : ""}`,
    description: arc
      ? `A${free} native, private browser for macOS 26${stage}. Spaces, profiles and a sidebar, shaped how you like. ${moveIn}`
      : about,
    og: arc ? `${share} ${moveIn}` : share,
  };
  const og = assets.get("/assets/img/og-home.png");
  const ogImage = `https://${cfg.DOMAIN}/og/home.png${og ? "?v=" + hash(fs.readFileSync(og.file)) : ""}`;
  const ogAlt =
    "A native, private Mac browser you can make your own. The Artemis window, with tabs down the side and a Wikipedia article open.";
  // Discord shows this card in place of the Open Graph preview; it drops the whole card past 3000 bytes
  const discord = JSON.stringify({
    component: {
      type: 17,
      accent_color: 0x2a75c5,
      components: [
        {
          type: 10,
          content: `## [Artemis for Mac](https://${cfg.DOMAIN}/)\n${home.og}`,
        },
        { type: 12, items: [{ media: { url: ogImage }, description: ogAlt }] },
        {
          type: 1,
          components: [
            ...(cfg.DOWNLOAD_URL
              ? [["Download for Mac", `https://${cfg.DOMAIN}/download`]]
              : []),
            ["Website", `https://${cfg.DOMAIN}/`],
            ["GitHub", "https://github.com/artemisbrowser/artemis"],
          ].map(([label, url]) => ({ type: 2, style: 5, label, url })),
        },
      ],
    },
  }).replace(/</g, "\\u003c");
  if (Buffer.byteLength(discord) > 3000)
    errors.push(
      `Discord card is ${Buffer.byteLength(discord)} bytes, over 3000`,
    );
  const jsonld = {
    "@context": "https://schema.org",
    "@graph": [
      {
        "@type": "WebSite",
        name: "Artemis",
        alternateName: ["Artemis Browser", "Artemis for Mac"],
        url: `https://${cfg.DOMAIN}/`,
        inLanguage: "en-GB",
      },
      {
        "@type": "SoftwareApplication",
        name: "Artemis",
        operatingSystem: "macOS 26 or later",
        processorRequirements: "arm64 (M1 or newer)",
        applicationCategory: "BrowserApplication",
        description: about,
        featureList: [
          "Vertical tabs in a sidebar",
          "Spaces",
          "Profiles with their own logins",
          "Command bar",
          "Split view with up to four pages",
          "Ad and tracker blocking",
          "Fingerprinting defence",
          "Copy Link drops tracking parameters",
          "Incognito windows that can lock with Touch ID",
          "Built-in passwords",
          "Import from other browsers",
          "Open source under GPL 3.0",
        ],
        license: "https://www.gnu.org/licenses/gpl-3.0.html",
        author: { "@type": "Person", name: "Fin" },
        url: `https://${cfg.DOMAIN}/`,
        image: ogImage,
        ...(cfg.DOWNLOAD_URL && {
          downloadUrl: `https://${cfg.DOMAIN}/download`,
        }),
        ...(amount && {
          offers: {
            "@type": "Offer",
            price: amount,
            priceCurrency:
              { "£": "GBP", "€": "EUR" }[cfg.PRICE.trim()[0]] ?? "USD",
          },
        }),
      },
    ],
  };
  const year = String(new Date().getFullYear());
  const escape = (s) =>
    s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/"/g, "&quot;");
  // The noindex pages carry no canonical and no structured data.
  const finish = (html, page, isIndex) =>
    rewrite(
      priced(html)
        .replace(/<!-- @note -->/g, escape(cfg.NOTE))
        .replace(/\{\{TITLE\}\}/g, escape(page.title))
        .replace(/\{\{DESCRIPTION\}\}/g, escape(page.description ?? about))
        .replace(/\{\{OG_DESCRIPTION\}\}/g, escape(page.og ?? share))
        .replace(/\{\{OG_IMAGE\}\}/g, ogImage)
        .replace(/\{\{OG_IMAGE_ALT\}\}/g, escape(ogAlt))
        .replace(/\{\{ROBOTS\}\}/g, page.robots)
        .replace(/\{\{DOWNLOAD_URL\}\}/g, escape(cfg.DOWNLOAD_URL ?? ""))
        .replace(/\{\{DOWNLOAD_JS\}\}/g, jsUrl["download.js"])
        .replace(
          /<!-- @canonical -->/g,
          isIndex
            ? `<link rel="canonical" href="https://${cfg.DOMAIN}/" />`
            : "",
        )
        .replace(
          /<!-- @jsonld -->/g,
          isIndex
            ? `<script type="application/ld+json">${JSON.stringify(jsonld).replace(/</g, "\\u003c")}</script>`
            : "",
        )
        .replace(
          /<!-- @discord -->/g,
          isIndex
            ? `<script id="discord:component-embed" type="application/json">${discord}</script>`
            : "",
        )
        // replica windows hold demo pages, whose text must never feed search snippets or AI answers
        .replace(/<div(\s+)class="win"/g, '<div$1data-nosnippet$1class="win"')
        .replace(/\{\{YEAR\}\}/g, year)
        .replace(/\{\{DOMAIN\}\}/g, cfg.DOMAIN),
      page.title,
    )
      .replace(/\{\{CSS\}\}/g, "/" + cssDest)
      .replace(/\{\{PRELOADS\}\}/g, isIndex ? preloads.join("\n") : "")
      .replace(/\{\{MAIN\}\}/g, jsUrl["site.js"]);
  const shell = (body, page, isIndex) =>
    finish(
      `<!doctype html>\n<html lang="en-GB" data-accent="tide">\n<head>\n${part("00-head")}</head>\n<body>\n${body}</body>\n</html>\n`,
      page,
      isIndex,
    );

  write(
    "index.html",
    shell(
      part("00-sprite") +
        part("00-nav") +
        `<main id="main">\n${mainHtml}</main>\n` +
        part("09-footer") +
        part("10-templates") +
        `<script type="module" src="{{MAIN}}"></script>\n`,
      home,
      true,
    ),
  );
  write(
    "404.html",
    shell(
      include(read(path.join(SRC, "pages/404.html")), 1),
      PAGES["404.html"],
    ),
  );
  // with a release, /download shows how to open it and starts it, by script once the steps load
  write(
    "download/index.html",
    cfg.DOWNLOAD_URL
      ? shell(include(read(path.join(SRC, "pages/download.html")), 1), {
          ...PAGES["download/index.html"],
          robots: `${PAGES["download/index.html"].robots}\n<noscript><meta http-equiv="refresh" content="1;url=${escape(cfg.DOWNLOAD_URL)}" /></noscript>`,
        })
      : shell(
          include(read(path.join(SRC, "pages/download-none.html")), 1),
          PAGES["download/index.html"],
        ),
  );

  // Crawl and sharing files
  let lastmod = new Date().toISOString().slice(0, 10);
  try {
    lastmod =
      execFileSync("git", ["log", "-1", "--format=%cs", "--", "src"], {
        cwd: ROOT,
        encoding: "utf8",
      }).trim() || lastmod;
  } catch {}
  write(
    "robots.txt",
    `User-agent: *\nAllow: /\nSitemap: https://${cfg.DOMAIN}/sitemap.xml\n`,
  );
  write(
    "sitemap.xml",
    `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n  <url><loc>https://${cfg.DOMAIN}/</loc><lastmod>${lastmod}</lastmod></url>\n</urlset>\n`,
  );
  const icon = (n, size, purpose) => ({
    src: url(`/assets/img/${n}`),
    sizes: `${size}x${size}`,
    type: "image/png",
    ...(purpose && { purpose }),
  });
  write(
    "manifest.webmanifest",
    JSON.stringify(
      {
        name: "Artemis",
        short_name: "Artemis",
        lang: "en-GB",
        start_url: "/",
        display: "browser",
        theme_color: "#FFFFFF",
        background_color: "#FFFFFF",
        icons: [
          icon("icon-192.png", 192),
          icon("icon-512.png", 512),
          icon("icon-maskable-512.png", 512, "maskable"),
        ],
      },
      null,
      2,
    ) + "\n",
  );
  const fav = path.join(SRC, "img/favicon-32.png");
  if (fs.existsSync(fav)) {
    const png = fs.readFileSync(fav);
    const ico = Buffer.alloc(22);
    ico.writeUInt16LE(1, 2);
    ico.writeUInt16LE(1, 4);
    ico.writeUInt8(32, 6);
    ico.writeUInt8(32, 7);
    ico.writeUInt16LE(1, 10);
    ico.writeUInt16LE(32, 12);
    ico.writeUInt32LE(png.length, 14);
    ico.writeUInt32LE(22, 18);
    write("favicon.ico", Buffer.concat([ico, png]));
  } else
    errors.push("missing src/img/favicon-32.png (run tools/prep-assets.sh)");
  if (!og) warnings.push("missing src/img/og-home.png (render tools/og.html)");
  else if (og.size > 1024 * 1024)
    errors.push(`og-home.png is ${kb(og.size)}, over 1 MB`);
  write("_headers", HEADERS);

  const sized = sizes(out, sources);
  return { warnings, errors: [...errors, ...sized.errors], lines: sized.lines };
}

// Size report and budgets (spec §6.3 step 9)
export function sizes(out, sources) {
  const lines = [],
    errors = [];
  const file = (rel) => fs.readFileSync(path.join(out, rel));
  const html = file("index.html");
  const cssRel = html
    .toString()
    .match(/href="\/(assets\/site\.\w+\.css)"/)?.[1];
  const css = cssRel ? file(cssRel) : Buffer.alloc(0);
  const row = (name, buf, note = "") =>
    `  ${name.padEnd(38)} ${kb(buf.length).padStart(9)} ${kb(gz(buf)).padStart(9)} gz${note}`;
  // per module, as minified; only the shipped files count against the 24 KB total
  const jsLines = [...(sources ?? [])]
    .sort()
    .map(([rel, code]) => row(`src/js/${rel}`, Buffer.from(code)));
  let jsTotal = 0;
  for (const f of walk(path.join(out, "assets/js"))) {
    const buf = fs.readFileSync(f);
    jsTotal += gz(buf);
    jsLines.push(row(path.relative(out, f).split(path.sep).join("/"), buf));
  }
  // a template's images load only once cloned, a 2x screen takes the last srcset candidate,
  // and the hero's page shot is a CSS background that paints at once
  const eager = [
    ...html
      .toString()
      .replace(/<template\b[\s\S]*?<\/template>/g, "")
      .matchAll(/<img\b[^>]*>|<link rel="preload" as="image"[^>]*>/g),
  ]
    .filter((m) => !/loading="lazy"/.test(m[0]))
    .map(
      (m) =>
        m[0].match(/srcset="(?:[^"]*,)?\s*\/([^"\s,?]+)[^",]*"/)?.[1] ??
        m[0].match(/(?:src|href)="\/([^"?]+)"/)?.[1],
    )
    .concat(
      [
        ...css
          .toString()
          .matchAll(/url\("?\/(assets\/shot-[\w-]+-hero-light\.[\w.]+)"?\)/g),
      ].map((m) => m[1]),
    )
    .filter((rel) => rel && fs.existsSync(path.join(out, rel)));
  const images = [...new Set(eager)].reduce(
    (n, rel) => n + fs.statSync(path.join(out, rel)).size,
    0,
  );
  const initial = gz(html) + gz(css) + jsTotal + images;
  lines.push(
    row("index.html", html, "  (budget 30 KB)"),
    row(cssRel ?? "css", css, "  (budget 25 KB)"),
    ...jsLines,
  );
  lines.push(
    `  js total${" ".repeat(26)} ${" ".repeat(9)} ${kb(jsTotal).padStart(9)} gz  (budget 24 KB)`,
  );
  lines.push(
    `  eager images ${kb(images)}, initial transfer ${kb(initial)} (budget 600 KB)`,
  );
  if (gz(html) > 30 * 1024) errors.push("index.html over 30 KB gz");
  if (gz(css) > 25 * 1024) errors.push("CSS over 25 KB gz");
  if (jsTotal > 24 * 1024) errors.push("JS over 24 KB gz");
  if (initial > 600 * 1024) errors.push("initial transfer over 600 KB");
  return { lines, errors };
}

async function run(out) {
  const tmp = out + ".building";
  fs.rmSync(tmp, { recursive: true, force: true });
  const r = await build(tmp);
  fs.rmSync(out, { recursive: true, force: true });
  fs.renameSync(tmp, out);
  for (const w of r.warnings) console.warn("warn: " + w);
  console.log(
    `built ${path.relative(process.cwd(), out) || "."}\n` + r.lines.join("\n"),
  );
  for (const e of r.errors) console.error("error: " + e);
  return r.errors.length === 0;
}

const CONTENT_TYPES = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".png": "image/png",
  ".webp": "image/webp",
  ".avif": "image/avif",
  ".svg": "image/svg+xml",
  ".ico": "image/x-icon",
  ".json": "application/json",
  ".webmanifest": "application/manifest+json",
  ".xml": "application/xml",
  ".txt": "text/plain; charset=utf-8",
};

function serve(out, port) {
  // the production CSP minus upgrade-insecure-requests, so plain-http renders still catch inline styles and scripts
  const csp = HEADERS.match(/Content-Security-Policy: (.*)/)[1].replace(
    /; upgrade-insecure-requests/,
    "",
  );
  http
    .createServer((req, res) => {
      const rel = decodeURIComponent(
        new URL(req.url.replace(/^\/+/, "/"), "http://x").pathname,
      );
      let f = path.join(out, rel);
      if (!f.startsWith(out)) f = out;
      if (fs.existsSync(f) && fs.statSync(f).isDirectory())
        f = path.join(f, "index.html");
      const found = fs.existsSync(f);
      if (!found) f = path.join(out, "404.html");
      res.writeHead(found ? 200 : 404, {
        "Content-Type":
          CONTENT_TYPES[path.extname(f)] ?? "application/octet-stream",
        // as in _headers, the favicon is exempt so its embedded <style> applies
        ...(rel !== "/icon.svg" && { "Content-Security-Policy": csp }),
        "X-Content-Type-Options": "nosniff",
        "Cache-Control": "no-store",
      });
      res.end(
        req.method === "HEAD"
          ? undefined
          : fs.existsSync(f)
            ? fs.readFileSync(f)
            : "",
      );
    })
    .listen(port, () =>
      console.log(`serving ${out} at http://127.0.0.1:${port}/`),
    );
  let timer;
  for (const dir of [SRC, ASSETS])
    fs.watch(dir, { recursive: true }, () => {
      clearTimeout(timer);
      timer = setTimeout(() => run(out).catch((e) => console.error(e)), 150);
    });
}

if (
  process.argv[1] &&
  pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url
) {
  const args = process.argv.slice(2);
  const opt = (k) => {
    const i = args.indexOf(k);
    return i < 0
      ? undefined
      : args[i + 1] && !args[i + 1].startsWith("--")
        ? args[i + 1]
        : true;
  };
  const out = path.resolve(
    typeof opt("--out") === "string" ? opt("--out") : path.join(ROOT, "dist"),
  );
  if (
    [ROOT, SRC, ASSETS, path.parse(out).root].includes(out) ||
    ROOT.startsWith(out + path.sep)
  )
    throw new Error(`refusing to build into ${out}`);
  const port = +(typeof opt("--port") === "string"
    ? opt("--port")
    : opt("--serve") === true
      ? 8080
      : opt("--serve"));
  const ok = await run(out);
  if (port) serve(out, port);
  else if (opt("--check")) {
    // a child process: check.mjs imports this module, so importing it here would wait on itself
    let checked = true;
    try {
      execFileSync(
        process.execPath,
        [path.join(ROOT, "tools/check.mjs"), out],
        { stdio: "inherit" },
      );
    } catch {
      checked = false;
    }
    process.exitCode = checked && ok ? 0 : 1;
  } else process.exitCode = ok ? 0 : 1;
}
