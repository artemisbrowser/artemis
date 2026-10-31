const MAX_BODY = 4 * 1024 * 1024;
const MAX_IMAGE = 2 * 1024 * 1024;
// Each signature costs up to three GitHub calls; the free plan allows 50 per request.
const MAX_SIGS = 12;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SIG = /^[0-9a-f]{1,64}$/i;
const JSON_TYPE = /^application\/json\s*(;|$)/i;
const NAME = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
const MAGIC = {
  "image/jpeg": [0xff, 0xd8, 0xff],
  "image/png": [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
};
// The first key is required for that kind, the rest optional.
const KINDS = {
  feedback: ["feedback", "diagnostics", "events", "attachments"],
  errors: ["events", "diagnostics"],
  crash: ["crashes", "diagnostics", "events"],
};

class Invalid extends Error {}

class GitHubError extends Error {
  constructor(status) {
    super(`GitHub ${status}`);
    this.status = status;
  }
}

export default {
  async fetch(request, env) {
    const { pathname } = new URL(request.url);
    if (pathname === "/" && request.method === "GET")
      return new Response("ok\n");
    if (pathname !== "/v1/reports") return reply(404, { error: "not found" });
    if (request.method !== "POST")
      return reply(405, { error: "method not allowed" }, { allow: "POST" });
    if (!JSON_TYPE.test(request.headers.get("content-type") ?? ""))
      return reply(400, { error: "content-type must be application/json" });

    const text = await readCapped(request);
    if (text === null) return reply(413, { error: "body over 4 MB" });
    let report;
    try {
      report = JSON.parse(text);
      validate(report);
    } catch (e) {
      return reply(400, {
        error: e instanceof Invalid ? `invalid ${e.message}` : "invalid json",
      });
    }

    // `install` is the sender's to choose; the address is Cloudflare's
    const ip = request.headers.get("cf-connecting-ip") ?? "";
    const allowed =
      (await env.ADDRESS_LIMITER.limit({ key: ip })).success &&
      (await env.LIMITER.limit({ key: `${report.install}:${ip}` })).success;
    if (!allowed)
      return reply(429, { error: "rate limited" }, { "retry-after": "60" });

    // a retry of the same body files under the same id
    const id = hex(
      await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)),
    );
    let issue;
    try {
      if (report.kind === "feedback") issue = await fileFeedback(env, report, id);
      else await fileSignatures(env, report);
    } catch (e) {
      if (e instanceof GitHubError)
        return reply(502, { error: "github unavailable" });
      throw e;
    }
    return reply(201, issue ? { id, issue } : { id });
  },
};

const reply = (status, data, headers) =>
  Response.json(data, { status, headers });

const hex = (buffer) =>
  [...new Uint8Array(buffer, 0, 16)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");

// put throws past KV's daily write quota or one write a second per key; what
// GitHub already holds stays filed either way
const remember = (env, key, value) =>
  env.SIGS.put(key, value).catch((e) =>
    console.error("kv put", key, e.message),
  );

async function readCapped(request) {
  if (Number(request.headers.get("content-length")) > MAX_BODY) return null;
  if (!request.body) return "";
  const reader = request.body.getReader();
  const chunks = [];
  let size = 0;
  for (let r = await reader.read(); !r.done; r = await reader.read()) {
    size += r.value.byteLength;
    if (size > MAX_BODY) {
      await reader.cancel();
      return null;
    }
    chunks.push(r.value);
  }
  return new Blob(chunks).text();
}

const isObject = (v) =>
  typeof v === "object" && v !== null && !Array.isArray(v);

function check(ok, path) {
  if (!ok) throw new Invalid(path);
}

function only(v, path, keys) {
  check(isObject(v), path);
  for (const k of Object.keys(v))
    check(keys.includes(k), path ? `${path}.${k}` : k);
}

const text = (v, path, max) =>
  check(typeof v === "string" && v.trim() !== "" && v.length <= max, path);

function list(v, path, min, max, each) {
  check(Array.isArray(v) && v.length >= min && v.length <= max, path);
  v.forEach((x, i) => each(x, `${path}[${i}]`));
}

function event(e, path) {
  only(e, path, ["t", "level", "area", "message", "sig"]);
  check(
    typeof e.t === "string" &&
      e.t.length <= 40 &&
      !Number.isNaN(Date.parse(e.t)),
    `${path}.t`,
  );
  check(e.level === "error" || e.level === "warning", `${path}.level`);
  text(e.area, `${path}.area`, 64);
  text(e.message, `${path}.message`, 2000);
  check(typeof e.sig === "string" && SIG.test(e.sig), `${path}.sig`);
}

function crash(c, path) {
  only(c, path, ["sig", "summary", "payload"]);
  check(typeof c.sig === "string" && SIG.test(c.sig), `${path}.sig`);
  text(c.summary, `${path}.summary`, 300);
  check(
    isObject(c.payload) && JSON.stringify(c.payload).length <= 1024 * 1024,
    `${path}.payload`,
  );
}

function attachment(a, path) {
  only(a, path, ["name", "type", "data"]);
  check(typeof a.name === "string" && NAME.test(a.name), `${path}.name`);
  check(Object.hasOwn(MAGIC, a.type), `${path}.type`);
  const ok =
    typeof a.data === "string" &&
    a.data.length % 4 === 0 &&
    (a.data.length / 4) * 3 <= MAX_IMAGE &&
    /^[A-Za-z0-9+/]*={0,2}$/.test(a.data);
  check(ok, `${path}.data`);
  const head = atob(a.data.slice(0, 12));
  check(
    MAGIC[a.type].every((byte, i) => head.charCodeAt(i) === byte),
    `${path}.data`,
  );
}

function validate(r) {
  check(isObject(r) && Object.hasOwn(KINDS, r.kind), "kind");
  only(r, "", [
    "kind",
    "install",
    "app",
    "os",
    "model",
    "arch",
    ...KINDS[r.kind],
  ]);
  check(typeof r.install === "string" && UUID.test(r.install), "install");
  only(r.app, "app", ["version", "build"]);
  text(r.app.version, "app.version", 32);
  text(r.app.build, "app.build", 32);
  text(r.os, "os", 128);
  text(r.model, "model", 64);
  text(r.arch, "arch", 16);
  if (r.kind === "feedback") {
    const f = r.feedback;
    only(f, "feedback", ["category", "message", "email", "page", "private"]);
    if (f.private !== undefined)
      check(typeof f.private === "boolean", "feedback.private");
    check(["bug", "idea", "other"].includes(f.category), "feedback.category");
    text(f.message, "feedback.message", 8000);
    if (f.email !== undefined)
      check(
        typeof f.email === "string" &&
          f.email.length <= 254 &&
          /^[^\s@]+@[^\s@]+$/.test(f.email),
        "feedback.email",
      );
    if (f.page !== undefined) text(f.page, "feedback.page", 2048);
  }
  if (r.diagnostics !== undefined)
    check(
      isObject(r.diagnostics) &&
        JSON.stringify(r.diagnostics).length <= 32 * 1024,
      "diagnostics",
    );
  if (r.events !== undefined || r.kind === "errors")
    list(r.events, "events", r.kind === "errors" ? 1 : 0, 100, event);
  if (r.kind === "crash") list(r.crashes, "crashes", 1, 10, crash);
  if (r.attachments !== undefined) {
    list(r.attachments, "attachments", 0, 4, attachment);
    check(
      new Set(r.attachments.map((a) => a.name)).size === r.attachments.length,
      "attachments",
    );
  }
}

// PUBLIC_REPO gets a report's words only; everything else stays in PRIVATE_REPO
async function github(env, method, path, body, repo = env.PRIVATE_REPO) {
  const res = await fetch(
    `https://api.github.com/repos/${repo}${path}`,
    {
      method,
      headers: {
        accept: "application/vnd.github+json",
        // the public repo's token can file issues and nothing else
        authorization: `Bearer ${repo === env.PUBLIC_REPO ? env.PUBLIC_TOKEN : env.GITHUB_TOKEN}`,
        "content-type": "application/json",
        "user-agent": "artemis-feedback",
        "x-github-api-version": "2022-11-28",
      },
      body: body && JSON.stringify(body),
    },
  );
  if (!res.ok) {
    const why = (await res.json().catch(() => ({}))).message ?? "";
    console.error("github", method, repo, path, res.status, why.slice(0, 200));
    throw new GitHubError(res.status);
  }
  return res.json();
}

// the public issue's URL, which the sender is shown; none when kept private
async function fileFeedback(env, r, id) {
  const done = `report:${id}`;
  const filed = await env.SIGS.get(done);
  if (filed) return JSON.parse(filed).public ?? undefined;
  const f = r.feedback;
  const shared =
    !f.private &&
    (await github(
      env,
      "POST",
      "/issues",
      {
        title: title(`[${f.category}]`, f.message),
        body: [
          quote(f.message),
          facts({ ...r, publicOnly: true }, []),
          "_Sent from Artemis with Help › Send Feedback._",
        ].join("\n\n"),
        labels: ["from-app", f.category],
      },
      env.PUBLIC_REPO,
    ));
  const month = new Date().toISOString().slice(0, 7).replace("-", "/");
  const images = [];
  for (const a of r.attachments ?? []) {
    const path = `/contents/attachments/${month}/${id}-${a.name}`;
    const file = await github(env, "PUT", path, {
      message: `Attachment for report ${id}`,
      content: a.data,
    }).then(
      (res) => res.content,
      // 422: a retry's file is already committed
      (e) => (e.status === 422 ? github(env, "GET", path) : Promise.reject(e)),
    );
    images.push(`![${a.name}](${file.html_url}?raw=true)`);
  }
  const rows = [["Report", id]];
  if (shared) rows.push(["Public issue", shared.html_url]);
  if (f.email) rows.push(["Email", f.email]);
  if (f.page) rows.push(["Page", f.page]);
  const issue = await github(env, "POST", "/issues", {
    title: title(`[${f.category}]`, f.message),
    body: [
      quote(f.message),
      facts(r, rows),
      ...images,
      ...context(r, r.events ?? []),
    ]
      .filter(Boolean)
      .join("\n\n"),
    labels: ["feedback", f.category, ...(shared ? ["public"] : [])],
  });
  await remember(
    env,
    done,
    JSON.stringify({ private: issue.number, public: shared?.html_url ?? null }),
  );
  return shared?.html_url;
}

async function fileSignatures(env, r) {
  const label = r.kind === "crash" ? "crash" : "error";
  const groups = Map.groupBy(label === "crash" ? r.crashes : r.events, (x) =>
    x.sig.toLowerCase(),
  );
  for (const [sig, items] of [...groups].slice(0, MAX_SIGS))
    await track(env, r, label, sig, items);
}

// One issue per signature, one comment per signature and build; a comment reopens
// the issue unless it was closed as not planned. KV is written only when one of
// those happens.
async function track(env, r, label, sig, items) {
  const key = `${label}:${sig}`;
  const buildKey = `${key}@${r.app.build}`;
  const seen = await env.SIGS.get(key, "json");
  if (seen && (await env.SIGS.get(buildKey))) return;
  const body = evidence(r, label, sig, items).filter(Boolean).join("\n\n");
  const current =
    seen && (await github(env, "GET", `/issues/${seen.issue}`).catch(gone));
  if (current) {
    const reopen =
      current.state === "closed" && current.state_reason !== "not_planned";
    if (reopen)
      await github(env, "PATCH", `/issues/${seen.issue}`, { state: "open" });
    const note = `Build ${code(r.app.build)} hits this${reopen ? ", so it is open again" : ""}.`;
    await github(env, "POST", `/issues/${seen.issue}/comments`, {
      body: `${note}\n\n${body}`,
    });
  } else {
    const first = items[0];
    const name =
      label === "crash" ? first.summary : `${first.area}: ${first.message}`;
    const issue = await github(env, "POST", "/issues", {
      title: title(`[${label}]`, name),
      body,
      labels: [label],
    });
    await remember(env, key, JSON.stringify({ issue: issue.number }));
  }
  await remember(env, buildKey, "1");
}

function gone(e) {
  if (e.status === 404 || e.status === 410) return null;
  throw e;
}

// User text never reaches an issue as live markdown, HTML or @mention.

const clean = (s) =>
  s.replace(/\r\n?/g, "\n").replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g, "");
const plain = (s) => clean(s).replace(/(^|\W)@(?=\w)/g, "$1@\u200b");
// `$` math takes no backslash escape, so a zero-width space breaks it instead
const escape = (s) =>
  s
    .replace(/[\\`*_[\]<>#!|~&+=-]/g, "\\$&")
    .replace(/^([ \t]*\d+)([.)])/gm, "$1\\$2")
    .replace(/\$/g, "$&\u200b");
const quote = (s) =>
  escape(plain(s).trim())
    .split("\n")
    .map((line) => `> ${line}`)
    .join("\n");
const clip = (s, max) =>
  s.length > max
    ? `${s.slice(0, max)}\n… ${s.length - max} more characters cut`
    : s;
const fence = (s, min) =>
  "`".repeat(
    (s.match(/`+/g) ?? []).reduce((n, run) => Math.max(n, run.length + 1), min),
  );
const code = (s) =>
  `${fence(s, 1)} ${clean(s).replace(/\n/g, " ")} ${fence(s, 1)}`;
const block = (s, lang = "") => `${fence(s, 3)}${lang}\n${s}\n${fence(s, 3)}`;
const details = (summary, s, lang) =>
  `<details><summary>${summary}</summary>\n\n${block(s, lang)}\n\n</details>`;
const line = (e) => `${e.t} ${e.level} ${e.area}: ${e.message}`;

// JSON.stringify(value, null, 2) cut at `max` characters, which stops descending
// once the budget is spent: indentation grows with depth squared
function pretty(value, max) {
  let out = "";
  const walk = (v, pad) => {
    if (v === null || typeof v !== "object")
      return void (out += JSON.stringify(v));
    const keys = Array.isArray(v) ? null : Object.keys(v);
    const [open, close] = keys ? "{}" : "[]";
    const n = keys ? keys.length : v.length;
    if (n === 0) return void (out += open + close);
    const inner = `${pad}  `;
    out += open;
    for (let i = 0; i < n && out.length <= max; i++) {
      out += `${i ? "," : ""}\n${inner}${keys ? `${JSON.stringify(keys[i])}: ` : ""}`;
      walk(keys ? v[keys[i]] : v[i], inner);
    }
    out += `\n${pad}${close}`;
  };
  walk(value, "");
  return out.length > max ? `${out.slice(0, max)}\n… the rest is cut` : out;
}

function title(tag, s) {
  const first = plain(s).trim().split("\n")[0];
  return `${tag} ${first.length > 80 ? `${first.slice(0, 79)}…` : first}`;
}

function facts(r, rows) {
  const all = [
    ["App", `${r.app.version} (${r.app.build})`],
    ["OS", r.os],
    ...(r.publicOnly
      ? []
      : [
          ["Mac", `${r.model} ${r.arch}`],
          ["Install", r.install.slice(0, 8).toLowerCase()],
        ]),
    ...rows,
  ];
  return [
    "| | |",
    "|---|---|",
    ...all.map(([k, v]) => `| ${k} | ${code(v).replaceAll("|", "\\|")} |`),
  ].join("\n");
}

function context(r, events) {
  return [
    events.length > 0 &&
      details(
        `Events (${events.length})`,
        clip(clean(events.map(line).join("\n")), 12000),
      ),
    r.diagnostics &&
      details("Diagnostics", pretty(r.diagnostics, 8000), "json"),
  ];
}

function evidence(r, label, sig, items) {
  const first = items[0];
  if (label === "crash")
    return [
      quote(first.summary),
      facts(r, [["Signature", sig]]),
      details("Crash report", pretty(first.payload, 30000), "json"),
      ...context(r, r.events ?? []),
    ];
  return [
    block(clean(first.message)),
    facts(r, [
      ["Area", first.area],
      ["Level", first.level],
      ["Signature", sig],
      ["Time", first.t],
    ]),
    ...context(r, items),
  ];
}
