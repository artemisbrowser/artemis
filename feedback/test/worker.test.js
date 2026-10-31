import assert from "node:assert/strict";
import { beforeEach, describe, test } from "node:test";
import worker from "../src/index.js";

const REPO = "artemisbrowser/artemis-feedback";
const PUBLIC = "artemisbrowser/artemis";
const PNG = Buffer.from([
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13,
]).toString("base64");
const JPEG = Buffer.from([
  0xff, 0xd8, 0xff, 0xe0, 0, 16, 0x4a, 0x46, 0x49,
]).toString("base64");

let env, gh;

// GitHub's issues, comments and contents endpoints, in memory.
function fakeGitHub() {
  const state = {
    issues: [],
    // issues filed on the public repo
    shared: [],
    comments: [],
    files: new Map(),
    calls: [],
    down: false,
    // (method, path) => true fails that call with a 503
    refuse: () => false,
  };
  globalThis.fetch = async (url, init = {}) => {
    const full = new URL(url).pathname;
    const method = init.method ?? "GET";
    const body = init.body && JSON.parse(init.body);
    if (full.startsWith(`/repos/${PUBLIC}/`)) {
      const path = full.slice(`/repos/${PUBLIC}`.length);
      state.calls.push({ method, path, body, headers: init.headers, public: true });
      if (state.down || state.refuse(method, path, true))
        return Response.json({ message: "down" }, { status: 503 });
      if (method !== "POST" || path !== "/issues")
        return Response.json({ message: "unexpected" }, { status: 418 });
      const n = state.shared.length + 1;
      const issue = { ...body, number: n, html_url: `https://github.com/${PUBLIC}/issues/${n}` };
      state.shared.push(issue);
      return Response.json(issue, { status: 201 });
    }
    const path = full.replace(`/repos/${REPO}`, "");
    state.calls.push({ method, path, body, headers: init.headers });
    if (state.down || state.refuse(method, path))
      return Response.json({ message: "down" }, { status: 503 });
    let m;
    if (method === "POST" && path === "/issues") {
      const issue = {
        ...body,
        number: state.issues.length + 1,
        state: "open",
        state_reason: null,
      };
      state.issues.push(issue);
      return Response.json(issue, { status: 201 });
    }
    if ((m = path.match(/^\/issues\/(\d+)$/))) {
      const issue = state.issues[m[1] - 1];
      if (!issue)
        return Response.json({ message: "Not Found" }, { status: 404 });
      if (method === "PATCH")
        Object.assign(issue, body, { state_reason: "reopened" });
      return Response.json(issue);
    }
    if (method === "POST" && (m = path.match(/^\/issues\/(\d+)\/comments$/))) {
      state.comments.push({ issue: Number(m[1]), ...body });
      return Response.json({ id: state.comments.length }, { status: 201 });
    }
    if ((m = path.match(/^\/contents\/(.+)$/))) {
      const file = { html_url: `https://github.com/${REPO}/blob/main/${m[1]}` };
      if (method === "GET")
        return state.files.has(m[1])
          ? Response.json(file)
          : Response.json({ message: "Not Found" }, { status: 404 });
      if (state.files.has(m[1]))
        return Response.json(
          { message: '"sha" wasn\'t supplied.' },
          { status: 422 },
        );
      state.files.set(m[1], body);
      return Response.json({ content: file }, { status: 201 });
    }
    return Response.json({ message: "unexpected" }, { status: 418 });
  };
  return state;
}

const limiter = (limit) => {
  const hits = new Map();
  return {
    async limit({ key }) {
      hits.set(key, (hits.get(key) ?? 0) + 1);
      return { success: hits.get(key) <= limit };
    },
  };
};

function makeEnv() {
  const kv = new Map();
  const env = {
    PUBLIC_REPO: PUBLIC,
    PRIVATE_REPO: REPO,
    GITHUB_TOKEN: "test-token",
    PUBLIC_TOKEN: "public-token",
    kv,
    writes: 0,
    // set to make every put throw, as KV does past its write limits
    kvFull: false,
    SIGS: {
      async get(key, type) {
        const v = kv.get(key) ?? null;
        return v !== null && type === "json" ? JSON.parse(v) : v;
      },
      async put(key, value) {
        if (env.kvFull) throw new Error("KV put() limit exceeded for the day.");
        env.writes++;
        kv.set(key, value);
      },
    },
    LIMITER: limiter(10),
    ADDRESS_LIMITER: limiter(30),
  };
  return env;
}

beforeEach(() => {
  gh = fakeGitHub();
  env = makeEnv();
});

const base = (kind, build = "100") => ({
  kind,
  install: "3F2504E0-4F89-41D3-9A0C-0305E82C3301",
  app: { version: "1.0", build },
  os: "macOS 27.2 (26C5)",
  model: "Mac14,2",
  arch: "arm64",
});
const feedback = (extra = {}) => ({
  ...base("feedback"),
  feedback: {
    category: "bug",
    message: "The sidebar flickers.\nSecond line.",
    ...extra,
  },
});
const ev = (
  sig,
  message = "WebContent process crashed",
  t = "2026-10-29T12:00:00Z",
) => ({
  t,
  level: "error",
  area: "webcontent",
  message,
  sig,
});
const errors = (build, ...events) => ({ ...base("errors", build), events });
const crashReport = (build, sig = "c0ffee") => ({
  ...base("crash", build),
  crashes: [
    {
      sig,
      summary: "EXC_BAD_ACCESS in TabManager.select",
      payload: { callStackTree: { frames: ["a", "b"] } },
    },
  ],
});

function post(body, headers = {}) {
  return worker.fetch(
    new Request("https://feedback.test/v1/reports", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "cf-connecting-ip": "203.0.113.7",
        ...headers,
      },
      body: typeof body === "string" ? body : JSON.stringify(body),
    }),
    env,
  );
}

async function rejects(body, field) {
  const res = await post(body);
  assert.equal(res.status, 400, JSON.stringify(body).slice(0, 200));
  if (field) assert.equal((await res.json()).error, `invalid ${field}`);
}

describe("routing", () => {
  test("GET / is a one-line ok, other paths 404, other methods 405", async () => {
    assert.equal(
      await (
        await worker.fetch(new Request("https://feedback.test/"), env)
      ).text(),
      "ok\n",
    );
    assert.equal(
      (await worker.fetch(new Request("https://feedback.test/v1/other"), env))
        .status,
      404,
    );
    const res = await worker.fetch(
      new Request("https://feedback.test/v1/reports"),
      env,
    );
    assert.equal(res.status, 405);
    assert.equal(res.headers.get("allow"), "POST");
  });
});

describe("validation", () => {
  test("accepts a minimal feedback report", async () => {
    const res = await post(feedback());
    assert.equal(res.status, 201);
    assert.match((await res.json()).id, /^[0-9a-f]{32}$/);
  });

  test("rejects malformed shapes", async () => {
    await rejects("{not json");
    await rejects("[]", "kind");
    await rejects({ ...feedback(), kind: "spam" }, "kind");
    await rejects({ ...feedback(), extra: 1 }, "extra");
    await rejects({ ...feedback(), crashes: [] }, "crashes");
    await rejects({ ...feedback(), install: "not-a-uuid" }, "install");
    await rejects({ ...feedback(), app: { version: "1.0" } }, "app.build");
    await rejects({ ...feedback(), os: "" }, "os");
    await rejects({ ...feedback(), model: "x".repeat(65) }, "model");
    await rejects({ ...base("feedback") }, "feedback");
    await rejects(feedback({ category: "rant" }), "feedback.category");
    await rejects(feedback({ message: "   " }), "feedback.message");
    await rejects(feedback({ message: "x".repeat(8001) }), "feedback.message");
    await rejects(feedback({ email: "nope" }), "feedback.email");
    await rejects(feedback({ page: "" }), "feedback.page");
    await rejects({ ...feedback(), diagnostics: [] }, "diagnostics");
    await rejects(
      { ...feedback(), diagnostics: { blob: "x".repeat(33 * 1024) } },
      "diagnostics",
    );
    await rejects({ ...errors("1"), events: [] }, "events");
    await rejects(
      errors("1", { ...ev("ab"), level: "info" }),
      "events[0].level",
    );
    await rejects(errors("1", { ...ev("ab"), t: "yesterday" }), "events[0].t");
    await rejects(errors("1", ev("not hex")), "events[0].sig");
    await rejects(
      errors("1", ...Array.from({ length: 101 }, () => ev("ab"))),
      "events",
    );
    await rejects(
      { ...base("errors"), events: [ev("ab")], feedback: feedback().feedback },
      "feedback",
    );
    await rejects(
      {
        ...crashReport("1"),
        crashes: [{ sig: "ab", summary: "x", payload: "text" }],
      },
      "crashes[0].payload",
    );
    const nested = "[".repeat(200000) + "]".repeat(200000);
    await rejects(
      JSON.stringify({
        ...crashReport("1"),
        diagnostics: { a: "DEEP" },
      }).replace('"DEEP"', nested),
    );
    await rejects(
      JSON.stringify(crashReport("1")).replace(
        '{"callStackTree"',
        `{"x":${nested},"callStackTree"`,
      ),
    );
  });

  test("rejects attachments by type, content, size, count and name", async () => {
    const shot = (a) => ({
      ...feedback(),
      attachments: [
        { name: "screenshot.png", type: "image/png", data: PNG, ...a },
      ],
    });
    await rejects(shot({ type: "image/gif" }), "attachments[0].type");
    await rejects(shot({ type: "image/jpeg" }), "attachments[0].data");
    await rejects(shot({ data: "!!!!" }), "attachments[0].data");
    await rejects(shot({ data: PNG.slice(0, -1) }), "attachments[0].data");
    await rejects(shot({ name: "../etc/passwd" }), "attachments[0].name");
    const big = Buffer.alloc(2 * 1024 * 1024 + 3);
    Buffer.from(PNG, "base64").copy(big);
    await rejects(
      shot({ data: big.toString("base64") }),
      "attachments[0].data",
    );
    const one = { name: "a.png", type: "image/png", data: PNG };
    await rejects({ ...feedback(), attachments: [one, one] }, "attachments");
    const five = ["a", "b", "c", "d", "e"].map((n) => ({
      ...one,
      name: `${n}.png`,
    }));
    await rejects({ ...feedback(), attachments: five }, "attachments");
    assert.equal(gh.calls.length, 0);
  });

  test("413 on a declared or actual body over 4 MB, 400 on the wrong content type", async () => {
    assert.equal(
      (
        await post(feedback(), {
          "content-length": String(4 * 1024 * 1024 + 1),
        })
      ).status,
      413,
    );
    const huge = JSON.stringify(
      feedback({ message: "x".repeat(4 * 1024 * 1024) }),
    );
    assert.equal((await post(huge)).status, 413);
    assert.equal(
      (await post(feedback(), { "content-type": "text/plain" })).status,
      400,
    );
    assert.equal(gh.calls.length, 0);
  });

  test("429 past ten reports a minute from one install and address", async () => {
    for (let i = 0; i < 10; i++)
      assert.equal((await post(feedback())).status, 201);
    const res = await post(feedback());
    assert.equal(res.status, 429);
    assert.equal(res.headers.get("retry-after"), "60");
    assert.equal(
      (await post(feedback(), { "cf-connecting-ip": "198.51.100.1" })).status,
      201,
    );
  });

  test("429 past thirty reports a minute from one address, whatever the install", async () => {
    const from = (i) => ({
      ...feedback(),
      install: `3F2504E0-4F89-41D3-9A0C-${String(i).padStart(12, "0")}`,
    });
    for (let i = 0; i < 30; i++)
      assert.equal((await post(from(i))).status, 201);
    assert.equal((await post(from(30))).status, 429);
  });

  test("502 when GitHub fails", async () => {
    gh.down = true;
    assert.equal((await post(feedback())).status, 502);
    assert.equal((await post(errors("1", ev("ab")))).status, 502);
  });
});

describe("feedback issues", () => {
  test("title, labels, metadata table and authenticated call", async () => {
    await post(
      feedback({
        email: "tester@example.com",
        page: "https://example.com/a|b",
      }),
    );
    const [issue] = gh.issues;
    assert.equal(issue.title, "[bug] The sidebar flickers.");
    assert.deepEqual(issue.labels, ["feedback", "bug", "public"]);
    assert.match(issue.body, /\| App \| ` 1\.0 \(100\) ` \|/);
    assert.match(issue.body, /\| Install \| ` 3f2504e0 ` \|/);
    assert.match(issue.body, /\| Email \| ` tester@example\.com ` \|/);
    assert.match(
      issue.body,
      /\| Page \| ` https:\/\/example\.com\/a\\\|b ` \|/,
    );
    const call = gh.calls.find((c) => !c.public);
    assert.equal(call.headers.authorization, "Bearer test-token");
    assert.equal(call.headers["user-agent"], "artemis-feedback");
  });

  test("the public issue carries the words only, and the reply links it", async () => {
    const res = await post(
      feedback({ email: "tester@example.com", page: "https://bank.example/acct" }),
    );
    const [shared] = gh.shared;
    assert.equal(shared.title, "[bug] The sidebar flickers.");
    assert.deepEqual(shared.labels, ["from-app", "bug"]);
    assert.match(shared.body, /\| App \| ` 1\.0 \(100\) ` \|/);
    for (const secret of ["tester@example.com", "bank.example", "3f2504e0", "Mac14,2"])
      assert.ok(!shared.body.includes(secret), `public issue leaks ${secret}`);
    assert.equal((await res.json()).issue, shared.html_url);
    assert.equal(gh.calls.find((c) => c.public).headers.authorization, "Bearer public-token");
    assert.match(gh.issues[0].body, /Public issue \| ` https:\/\/github\.com\/artemisbrowser\/artemis\/issues\/1 `/);
  });

  test("a private report files nothing public", async () => {
    const res = await post(feedback({ private: true }));
    assert.equal(gh.shared.length, 0);
    assert.equal(gh.issues.length, 1);
    assert.deepEqual(gh.issues[0].labels, ["feedback", "bug"]);
    assert.equal((await res.json()).issue, undefined);
  });

  test("a retried report links the same public issue without filing again", async () => {
    const report = feedback();
    const first = await (await post(report)).json();
    const again = await (await post(report)).json();
    assert.equal(gh.shared.length, 1);
    assert.equal(again.issue, first.issue);
  });

  test("long first lines are cut to 80 characters", async () => {
    await post(feedback({ message: "y".repeat(200) }));
    assert.equal(gh.issues[0].title, `[bug] ${"y".repeat(79)}…`);
  });

  test("mentions, HTML, images and links in the message are neutralised", async () => {
    const message = [
      "Hey @fin and @artemis/team, (@admin)",
      '<img src="https://evil.test/x.png"> <script>alert(1)</script>',
      "![pixel](https://evil.test/p.png) [click me](https://evil.test)",
      "&#64;fin **bold** `code` | table |",
      "```",
      "</details>",
    ].join("\n");
    await post({
      ...feedback({ message }),
      diagnostics: { note: "```\n@fin" },
    });
    const { body, title } = gh.issues[0];
    assert.doesNotMatch(body, /(^|\W)@\w/, "no live mention");
    assert.doesNotMatch(title, /(^|\W)@\w/, "no live mention in the title");
    assert.match(body, /@\u200bfin and @\u200bartemis\/team, \(@\u200badmin\)/);
    assert.doesNotMatch(body, /(^|[^\\])<(img|script)/);
    assert.doesNotMatch(body, /(^|[^\\])!\[/);
    assert.doesNotMatch(body, /(^|[^\\])\[click/);
    assert.match(body, /\\!\\\[pixel\\\]\(https:\/\/evil\.test\/p\.png\)/);
    assert.match(
      body,
      /\\&\\#64;fin \\\*\\\*bold\\\*\\\* \\`code\\` \\\| table \\\|/,
    );
    assert.ok(
      body
        .split("\n")
        .slice(0, 6)
        .every((line) => line.startsWith("> ")),
      "every message line is quoted",
    );
    assert.equal(
      body.match(/<\/details>/g).length,
      1,
      "user text cannot close the details block",
    );
    assert.match(
      body,
      /````json\n[^]*```\\n@fin[^]*\n````/,
      "fence outgrows backtick runs in the content",
    );
  });

  test("math, setext headings, rules and lists in the message stay literal", async () => {
    const message = [
      "$$\\huge x$$ and $`y`$",
      "Heading",
      "---",
      "Other",
      "===",
      "- item",
      "+ item",
      "  12. item",
      "3) item",
    ].join("\n");
    await post(feedback({ message }));
    const quoted = gh.issues[0].body.split("\n\n")[0];
    assert.equal(
      quoted,
      [
        "> $\u200b$\u200b\\\\huge x$\u200b$\u200b and $\u200b\\`y\\`$\u200b",
        "> Heading",
        "> \\-\\-\\-",
        "> Other",
        "> \\=\\=\\=",
        "> \\- item",
        "> \\+ item",
        ">   12\\. item",
        "> 3\\) item",
      ].join("\n"),
    );
  });

  test("an email address is not a mention and stays intact", async () => {
    await post(feedback({ message: "Reach me at tester@example.com" }));
    assert.match(gh.issues[0].body, /> Reach me at tester@example\.com/);
  });

  test("attachments are committed by month and embedded as raw blob images", async () => {
    const report = {
      ...feedback(),
      attachments: [
        { name: "screenshot.jpg", type: "image/jpeg", data: JPEG },
        { name: "detail.png", type: "image/png", data: PNG },
      ],
    };
    const { id } = await (await post(report)).json();
    const month = new Date().toISOString().slice(0, 7).replace("-", "/");
    const shot = `attachments/${month}/${id}-screenshot.jpg`;
    assert.deepEqual(
      [...gh.files.keys()],
      [shot, `attachments/${month}/${id}-detail.png`],
    );
    assert.equal(gh.files.get(shot).content, JPEG);
    assert.deepEqual(
      gh.calls.filter((c) => !c.public).map((c) => c.method),
      ["PUT", "PUT", "POST"],
      "files land before the issue that embeds them",
    );
    assert.ok(
      gh.issues[0].body.includes(
        `![screenshot.jpg](https://github.com/${REPO}/blob/main/${shot}?raw=true)`,
      ),
    );
  });

  test("a retry reuses its committed attachments and never files twice", async () => {
    const report = {
      ...feedback(),
      attachments: [{ name: "screenshot.jpg", type: "image/jpeg", data: JPEG }],
    };
    gh.refuse = (method, path) => method === "POST" && path === "/issues";
    assert.equal((await post(report)).status, 502);
    gh.refuse = () => false;
    const first = await (await post(report)).json();
    assert.equal(gh.files.size, 1);
    assert.equal(gh.issues.length, 1);
    assert.ok(
      gh.issues[0].body.includes(`${first.id}-screenshot.jpg?raw=true`),
    );

    const again = await post(report);
    assert.equal(again.status, 201);
    assert.equal((await again.json()).id, first.id);
    assert.equal(gh.issues.length, 1);
    assert.equal(gh.files.size, 1);
  });

  test("events and diagnostics sit in collapsed details", async () => {
    await post({
      ...feedback(),
      events: [ev("ab", "boom")],
      diagnostics: { tabs: 3 },
    });
    const { body } = gh.issues[0];
    assert.match(
      body,
      /<details><summary>Events \(1\)<\/summary>\n\n```\n2026-10-29T12:00:00Z error webcontent: boom\n```\n\n<\/details>/,
    );
    assert.match(
      body,
      /<details><summary>Diagnostics<\/summary>\n\n```json\n\{\n  "tabs": 3\n\}\n```/,
    );
  });
});

describe("signature grouping", () => {
  test("one issue per signature; repeats on the same build write nothing", async () => {
    assert.equal(
      (await post(errors("100", ev("AB"), ev("ab"), ev("cd", "other")))).status,
      201,
    );
    assert.equal(gh.issues.length, 2);
    assert.equal(
      gh.issues[0].title,
      "[error] webcontent: WebContent process crashed",
    );
    assert.deepEqual(gh.issues[0].labels, ["error"]);
    assert.match(gh.issues[0].body, /Events \(2\)/);
    assert.deepEqual(JSON.parse(env.kv.get("error:ab")), { issue: 1 });
    const writes = env.writes;

    await post(errors("100", ev("ab")));
    await post(errors("100", ev("ab", "again", "2026-10-29T13:00:00Z")));
    assert.equal(gh.issues.length, 2);
    assert.equal(gh.comments.length, 0);
    assert.equal(env.writes, writes);
  });

  test("a failed KV write leaves a filed report filed", async () => {
    env.kvFull = true;
    assert.equal((await post(errors("100", ev("ab")))).status, 201);
    assert.equal((await post(feedback())).status, 201);
    assert.equal(gh.issues.length, 2);
  });

  test("a new build comments once and reopens an issue closed as completed", async () => {
    await post(errors("100", ev("ab")));
    Object.assign(gh.issues[0], { state: "closed", state_reason: "completed" });

    await post(errors("101", ev("ab")));
    await post(errors("101", ev("ab")));
    assert.equal(gh.comments.length, 1);
    assert.equal(gh.comments[0].issue, 1);
    assert.match(
      gh.comments[0].body,
      /^Build ` 101 ` hits this, so it is open again\.\n/,
    );
    assert.equal(gh.issues[0].state, "open");
    assert.deepEqual(JSON.parse(env.kv.get("error:ab")), { issue: 1 });
  });

  test("an issue closed as not planned gets the comment but stays closed", async () => {
    await post(errors("100", ev("ab")));
    Object.assign(gh.issues[0], {
      state: "closed",
      state_reason: "not_planned",
    });
    await post(errors("101", ev("ab")));
    assert.equal(gh.comments.length, 1);
    assert.match(gh.comments[0].body, /^Build ` 101 ` hits this\.\n/);
    assert.equal(gh.issues[0].state, "closed");
    assert.ok(!gh.calls.some((c) => c.method === "PATCH"));
  });

  test("a deleted issue is replaced by a new one", async () => {
    await post(errors("100", ev("ab")));
    env.kv.set("error:ab", JSON.stringify({ issue: 99 }));
    await post(errors("101", ev("ab")));
    assert.equal(gh.issues.length, 2);
    assert.equal(JSON.parse(env.kv.get("error:ab")).issue, 2);
  });

  test("crashes group apart from errors and carry their payload", async () => {
    await post(crashReport("100", "ab"));
    await post(errors("100", ev("ab")));
    assert.equal(gh.issues.length, 2);
    const [crash] = gh.issues;
    assert.equal(crash.title, "[crash] EXC_BAD_ACCESS in TabManager.select");
    assert.deepEqual(crash.labels, ["crash"]);
    assert.match(
      crash.body,
      /<summary>Crash report<\/summary>\n\n```json\n\{\n  "callStackTree"/,
    );
    await post(crashReport("100", "ab"));
    assert.equal(gh.comments.length, 0);
    assert.deepEqual(JSON.parse(env.kv.get("crash:ab")), { issue: 1 });
  });

  test("a huge crash payload is cut to fit an issue body", async () => {
    const report = crashReport("100");
    report.crashes[0].payload = {
      frames: Array.from({ length: 20000 }, (_, i) => `frame ${i}`),
    };
    report.diagnostics = Object.fromEntries(
      Array.from({ length: 900 }, (_, i) => [`k${i}`, "v".repeat(20)]),
    );
    await post(report);
    const { body } = gh.issues[0];
    assert.ok(body.length < 65536, `${body.length}`);
    assert.match(body, /the rest is cut/);
  });

  test("a deep stack is shown down to what fits the issue", async () => {
    const report = crashReport("100");
    let frame = { binaryName: "Artemis", offsetIntoBinaryTextSegment: 1 };
    for (let i = 0; i < 2000; i++)
      frame = {
        binaryName: "AppKit",
        offsetIntoBinaryTextSegment: i,
        subFrames: [frame],
      };
    report.crashes[0].payload = { callStackTree: { callStacks: [frame] } };
    report.diagnostics = {
      deep: JSON.parse("[".repeat(3000) + "]".repeat(3000)),
    };
    assert.equal((await post(report)).status, 201);
    const { body } = gh.issues[0];
    assert.ok(body.length < 65536, `${body.length}`);
    assert.match(body, /"subFrames": \[\n/);
    assert.match(body, /the rest is cut/);
  });

  test("at most twelve signatures are filed per report", async () => {
    const events = Array.from({ length: 20 }, (_, i) =>
      ev(i.toString(16).padStart(2, "0")),
    );
    await post(errors("100", ...events));
    assert.equal(gh.issues.length, 12);
  });
});
