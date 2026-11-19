// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

// Artemis compatibility layer — injected at install by ExtensionCompat.
(() => {
  "use strict";
  const api = globalThis.browser ?? globalThis.chrome;
  // taken now: sandboxes (LavaMoat) later make reading an undeclared global throw
  const { URL, location, navigator } = globalThis;
  if (!api || api.__artemisCompat) return;
  // never let the shim itself be the thing that breaks an extension: a
  // throw here would abort this injection before the extension's own code
  // ran. every step below is individually guarded, and the whole body is
  // wrapped at the end
  try {
    Object.defineProperty(api, "__artemisCompat", { value: 1, enumerable: false });
  } catch (e) {
    try { api.__artemisCompat = 1; } catch (e2) { /* read-only api object */ }
  }

  // WebKit's API prototypes are rebuilt once their last object is collected, losing any
  // patch on them; whatever the shim patches stays reachable from here
  const kept = [];
  try { Object.defineProperty(globalThis, "__artemisKept", { value: kept }); } catch (e) {}
  const keep = (object) => { kept.push(object); return object; };

  // WebKit delivers events through the context's own `chrome`/`browser` globals, and
  // with both replaced nothing arrives (Proton Pass locks them behind proxies)
  try {
    const real = globalThis.chrome;
    if (real) {
      Object.defineProperty(globalThis, "chrome", {
        get: () => real, set: () => {}, enumerable: true, configurable: false,
      });
    }
  } catch (e) {}

  try {

  // === 1. detached-method fix (the big generic one) =====================
  // WebKit's runtime returns `undefined` from tabs.query / windows.getAll
  // (and friends) when the method is called detached from its namespace —
  // `const q = browser.tabs.query; q({})`. That's precisely what
  // webextension-polyfill and every hand-rolled promisify wrapper does, so
  // extensions get `undefined` where they expect an array and die on
  // `.filter`/destructuring. Rebinding each function to its owner makes a
  // detached reference behave exactly like an attached call.
  // The methods live on each namespace's PROTOTYPE (only events and
  // constants are own properties), so walking own properties alone finds
  // nothing to fix. Walk the prototype chain and shadow each method with a
  // bound own property.
  const objectProto = Object.prototype;
  const keysOf = (obj) => {
    const keys = new Set();
    let cursor = obj;
    while (cursor && cursor !== objectProto) {
      try { Object.getOwnPropertyNames(cursor).forEach((k) => keys.add(k)); } catch (e) {}
      cursor = Object.getPrototypeOf(cursor);
    }
    return keys;
  };
  const skipKeys = new Set(["constructor", "lastError", "__artemisCompat", "__proto__"]);
  const bindAll = (obj, depth, seen) => {
    if (!obj || depth > 3 || seen.has(obj)) return;
    seen.add(obj);
    keep(obj);  // a collected namespace or event comes back without its patches
    for (const key of keysOf(obj)) {
      if (skipKeys.has(key)) continue;
      let value;
      try { value = obj[key]; } catch (e) { continue; }
      if (typeof value === "function") {
        try { obj[key] = value.bind(obj); } catch (e) { /* frozen — leave it */ }
      } else if (value && typeof value === "object") {
        bindAll(value, depth + 1, seen);
      }
    }
  };
  bindAll(api, 0, new Set());

  // A namespace WebKit has rebuilt after collection would lose the shadowing above;
  // bindAll keeps every object it touches, and these pins re-resolve the live
  // instance where defineProperty on a namespace still holds.
  // namespace -> (event name, event) => the listener methods extensions see.
  // copied onto each live event object (WebKit ignores defineProperty on a
  // namespace, so pinning can't carry them), and reapplied by the pins where they hold
  const eventHooks = new Map();
  const hookedEvents = new WeakMap();
  const hookEvents = (namespace, hook) => {
    eventHooks.set(namespace, hook);
    const target = api[namespace];
    if (!target) return;
    for (const name of Object.keys(target)) {
      const event = target[name];
      if (event && typeof event === "object" && !hookedEvents.has(event)) {
        const methods = hook(name, event);
        if (methods) Object.assign(event, methods);
        hookedEvents.set(event, event);
      }
    }
  };
  const boundCache = new WeakMap();  // instance -> Map(prop -> bound fn)
  const stabilizeNamespaces = () => {
    for (const key of keysOf(api)) {
      if (skipKeys.has(key)) continue;
      let value;
      try { value = api[key]; } catch (e) { continue; }
      if (!value || typeof value !== "object") continue;
      let desc = null, cursor = api;
      while (cursor && !(desc = Object.getOwnPropertyDescriptor(cursor, key))) {
        cursor = Object.getPrototypeOf(cursor);
      }
      const getter = desc && desc.get;
      const fresh = getter
        ? () => { try { return getter.call(api) ?? value; } catch (e) { return value; } }
        : () => value;
      // anything written through the proxy (our API fills, an extension's
      // own wrappers) lives in this overlay, so a later instance swap
      // can't silently un-fill detectLanguage & co.
      const overlay = new Map();
      const proxy = new Proxy({}, {
        get(_, prop) {
          if (overlay.has(prop)) return overlay.get(prop);
          const target = fresh();
          let v;
          try { v = target[prop]; } catch (e) { return undefined; }
          if (typeof v !== "function") {
            const hook = v && typeof v === "object" && eventHooks.get(key);
            if (!hook) return v;
            if (!hookedEvents.has(v)) {
              const methods = hook(prop, v);
              if (methods) Object.assign(v, methods);
              hookedEvents.set(v, v);
            }
            return v;
          }
          let perTarget = boundCache.get(target);
          if (!perTarget) { perTarget = new Map(); boundCache.set(target, perTarget); }
          let bound = perTarget.get(prop);
          if (!bound) { bound = v.bind(target); perTarget.set(prop, bound); }
          return bound;
        },
        set(_, prop, v) {
          overlay.set(prop, v);
          try { fresh()[prop] = v; } catch (e) {}
          return true;
        },
        has(_, prop) {
          if (overlay.has(prop)) return true;
          try { return prop in fresh(); } catch (e) { return false; }
        },
        ownKeys() {
          try {
            const keys = Reflect.ownKeys(fresh());
            for (const k of overlay.keys()) if (!keys.includes(k)) keys.push(k);
            return keys;
          } catch (e) { return Array.from(overlay.keys()); }
        },
        getOwnPropertyDescriptor(_, prop) {
          if (overlay.has(prop)) {
            return { value: overlay.get(prop), writable: true,
                     enumerable: true, configurable: true };
          }
          try {
            const d = Object.getOwnPropertyDescriptor(fresh(), prop);
            if (d) d.configurable = true;
            return d;
          } catch (e) { return undefined; }
        },
      });
      try {
        Object.defineProperty(api, key,
          { value: proxy, writable: true, configurable: true, enumerable: true });
      } catch (e) {}
    }
  };
  try { stabilizeNamespaces(); } catch (e) {}

  // === 2. missing-API fills ============================================
  // chrome.i18n.detectLanguage isn't implemented by WebKit. Report "not
  // reliable" rather than guessing a language: every caller we've seen
  // treats that as "unknown" and moves on, which is the honest answer.
  api.i18n = api.i18n || {};
  if (!api.i18n.detectLanguage) {
    api.i18n.detectLanguage = (text, cb) => {
      const result = { isReliable: false, languages: [] };
      if (typeof cb === "function") { cb(result); return; }
      return Promise.resolve(result);
    };
  }

  // chrome.action.setBadgeTextColor (Chrome 110+) isn't implemented by
  // WebKit. It's purely cosmetic, but calling a missing method throws —
  // and when that happens inside an extension's reactive startup chain it
  // takes the whole extension down with it (this exact call was killing
  // Surfshark's init from its badge code). Accept and ignore.
  if (api.action && typeof api.action.setBadgeTextColor !== "function") {
    api.action.setBadgeTextColor = (details, cb) => {
      if (typeof cb === "function") { cb(); return; }
      return Promise.resolve();
    };
  }

  // WebKit keeps requestIdleCallback behind an off-by-default flag
  if (typeof globalThis.requestIdleCallback !== "function" && typeof setTimeout === "function") {
    globalThis.requestIdleCallback = (callback) => setTimeout(() => {
      const start = Date.now();
      callback({ didTimeout: false, timeRemaining: () => Math.max(0, 50 - (Date.now() - start)) });
    }, 1);
    globalThis.cancelIdleCallback = (id) => clearTimeout(id);
  }

  // Chrome takes a callback after the alarm info; WebKit reads a third argument as a bad info
  if (api.alarms && typeof api.alarms.create === "function") {
    const create = api.alarms.create;
    api.alarms.create = (...args) => {
      const cb = typeof args[args.length - 1] === "function" ? args.pop() : null;
      const created = create.apply(api.alarms, args);
      if (!cb) return created;
      Promise.resolve(created).then(() => cb(), () => cb());
    };
  }

  // WebKit delivers nothing, and reports no error, to a target naming both a documentId and a frameId
  if (api.tabs) for (const [name, at] of [["sendMessage", 1], ["connect", 0]]) {
    const original = api.tabs[name];
    if (typeof original !== "function") continue;
    api.tabs[name] = (tabId, ...rest) => {
      const options = rest[at];
      if (options && typeof options === "object" && options.documentId !== undefined && "frameId" in options) {
        const { frameId, ...byDocument } = options;
        rest[at] = byDocument;
      }
      return original.call(api.tabs, tabId, ...rest);
    };
  }

  // Chrome answers an empty message name with ""; WebKit throws
  if (api.i18n && typeof api.i18n.getMessage === "function") {
    const getMessage = api.i18n.getMessage;
    api.i18n.getMessage = (name, ...rest) => name === "" ? "" : getMessage(name, ...rest);
  }

  const NATIVE_ID = "app.artemis.compat";

  let traceRPC = false;
  // the app turns verbose RPC tracing on only for ARTEMIS_DIAG runs;
  // errors and auth steps are always reported regardless
  try {
    api.runtime.sendNativeMessage(NATIVE_ID, { artemisCompat: "trace.enabled" })
      .then((answer) => { traceRPC = !!(answer && answer.enabled); })
      .catch(() => {});
  } catch (e) {}

  // === diagnostics ======================================================
  // WebKit surfaces only a truncated prefix of an extension's console
  // errors (mobx's "uncaught error in Reaction[…]" arrives without the
  // error it is reporting), which makes real breakage unreadable. Forward
  // them to the app: extension pages can reach native directly, content
  // scripts relay through the background (which forwards below).
  // a report may never leave an unobserved promise and may never travel
  // through the traced sendMessage below: either feeds the listeners that
  // call report, and one failed report then becomes 2ⁿ per round-trip
  const report = (() => {
    const BUDGET = 200;
    const sendNative = api.runtime?.sendNativeMessage?.bind(api.runtime);
    const sendRelay = api.runtime?.sendMessage?.bind(api.runtime);
    let spent = 0, previous = null;
    return (level, text) => {
      const body = String(text).slice(0, 900);
      if (spent >= BUDGET || body === previous) return;
      previous = body; spent += 1;
      const payload = { artemisCompat: "log", level, text: body };
      try {
        const pending = sendNative ? sendNative(NATIVE_ID, payload)
          : sendRelay ? sendRelay({ __artemisCompatLog: payload }) : null;
        pending?.then?.(null, () => {});
      } catch (e) {}
    };
  })();
  const describe = (value) => {
    if (!value || typeof value !== "object") return String(value);
    if (value.stack || value.message) return String(value.stack || value.message);
    let json = "";
    try { json = JSON.stringify(value); } catch (e) {}
    return json && json !== "{}" ? json : Object.prototype.toString.call(value) + " " + String(value);
  };
  const nativeError = console.error;
  console.error = function (...args) {
    try { report("error", args.map(describe).join(" ")); } catch (e) {}
    return nativeError.apply(console, args);
  };
  globalThis.addEventListener?.("unhandledrejection", (event) => {
    report("rejection", describe(event && event.reason));
  });
  globalThis.addEventListener?.("error", (event) => {
    report("uncaught", (event && (event.error?.stack || event.message)) || "?");
  });

  // WebKit's storage set() refuses an items object whose prototype isn't Object's
  // (Object.create(null), a class instance); Chrome stores its own enumerable keys.
  // patched on the shared prototype too: sandboxes (LavaMoat) reach the method there
  if (api.storage) {
    const plain = (items) => items && typeof items === "object"
      && Object.getPrototypeOf(items) !== Object.prototype ? Object.assign({}, items) : items;
    const wrapped = new WeakSet();
    const wrap = (set) => {
      const fixed = function (items, ...rest) { return set.call(this, plain(items), ...rest); };
      wrapped.add(fixed);
      return fixed;
    };
    for (const name of ["local", "sync", "session", "managed"]) {
      const area = api.storage[name];
      if (!area || typeof area.set !== "function") continue;
      const proto = Object.getPrototypeOf(area);
      if (proto && typeof proto.set === "function" && !wrapped.has(proto.set)) {
        try {
          Object.defineProperty(keep(proto), "set", { value: wrap(proto.set), writable: true, configurable: true });
        } catch (e) {}
      }
      if (Object.prototype.hasOwnProperty.call(area, "set") && !wrapped.has(area.set)) {
        const own = area.set;
        area.set = (items, ...rest) => own.call(area, plain(items), ...rest);
      }
    }
  }

  // === sendMessage failures ===============================================
  // reported, since an extension's own RPC layer may swallow them; a message
  // to another extension, unreachable here, fails asynchronously as in Chrome
  if (api.runtime && typeof api.runtime.sendMessage === "function") {
    const send = api.runtime.sendMessage;
    const outgoing = (args) => {
      const from = location ? " from " + String(location.href).slice(0, 120) : "";
      try { return JSON.stringify(args[0]).slice(0, 200) + from; } catch (e) { return "?" + from; }
    };
    api.runtime.sendMessage = function (...args) {
      let result;
      try {
        result = send.apply(api.runtime, args);
      } catch (e) {
        report("rpc", "sendMessage threw for " + outgoing(args) + ": " + e.message);
        if (!/cross-extension messaging/.test(String(e && e.message))) throw e;
        const callback = typeof args[args.length - 1] === "function" ? args[args.length - 1] : null;
        if (callback) { callback(); return; }
        return Promise.reject(new Error("Could not establish connection. Receiving end does not exist."));
      }
      if (result && typeof result.then === "function") {
        return result.then(
          (reply) => {
            if ((reply === undefined || reply === null) && traceRPC) {
              report("rpc", "empty reply for " + outgoing(args));
            }
            return reply;
          },
          (error) => {
            report("rpc", "rejected for " + outgoing(args) + ": "
              + (error && error.message ? error.message : error));
            throw error;
          });
      }
      return result;
    };
  }

  // the generic fixes are done — content scripts stop here (everything
  // below needs the native bridge, which only extension pages have)
  globalThis.__artemisCompatReady = true;
  const call = (type, payload) => {
    try {
      const r = api.runtime.sendNativeMessage(
        NATIVE_ID, Object.assign({ artemisCompat: type }, payload || {}));
      return r && typeof r.then === "function" ? r : Promise.resolve(r);
    } catch (e) {
      return Promise.reject(e);
    }
  };

  const makeEvent = () => {
    const listeners = new Set();
    return {
      addListener: (fn) => listeners.add(fn),
      removeListener: (fn) => listeners.delete(fn),
      hasListener: (fn) => listeners.has(fn),
      hasListeners: () => listeners.size > 0,
      _listeners: listeners,
      _fire: (...args) => listeners.forEach((fn) => { try { fn(...args); } catch (e) { console.error("[artemis-compat]", e); } }),
    };
  };

  // callback form or promise form, as the caller chose; a failure reaches a
  // callback with no arguments, which is how Chrome reports one there
  const settle = (cb, promise) => {
    if (typeof cb !== "function") return promise;
    promise.then((value) => cb(value), () => cb());
  };

  // storage.managed is enterprise policy, which Artemis never sets: an empty
  // read-only area, reachable from content scripts too
  if (api.storage && !api.storage.managed) {
    const readOnly = () => Promise.reject(new Error("storage.managed is read-only."));
    api.storage.managed = {
      get: (keys, cb) => settle(typeof keys === "function" ? keys : cb, Promise.resolve({})),
      getBytesInUse: (keys, cb) => settle(typeof keys === "function" ? keys : cb, Promise.resolve(0)),
      set: readOnly, remove: readOnly, clear: readOnly,
      onChanged: makeEvent(),
    };
  }

  // a port whose real counterpart arrives later: messages queue until then
  const pendingPort = (name, open) => {
    const onMessage = makeEvent(), onDisconnect = makeEvent();
    const queue = [];
    let real = null, closed = false;
    const port = {
      name, sender: undefined, onMessage, onDisconnect,
      postMessage: (message) => { if (real) real.postMessage(message); else if (!closed) queue.push(message); },
      disconnect: () => { closed = true; if (real) real.disconnect(); },
    };
    open((connected) => {
      if (closed) { if (connected) connected.disconnect(); return; }
      if (!connected) { closed = true; onDisconnect._fire(port); return; }
      real = connected;
      real.onMessage.addListener((message) => onMessage._fire(message, port));
      real.onDisconnect.addListener(() => { closed = true; onDisconnect._fire(port); });
      queue.splice(0).forEach((message) => real.postMessage(message));
    });
    return port;
  };

  // WebKit throws when the background hasn't registered onConnect yet (it is
  // still starting); Chrome waits for it. retry for up to 10s, then give up
  // the way Chrome does, with a disconnect
  if (api.runtime && typeof api.runtime.connect === "function") {
    const connect = api.runtime.connect;
    const notReady = (error) => /onConnect listeners/.test(String(error && error.message));
    // another extension is unreachable here; Chrome hands back a port that disconnects
    const elsewhere = (error) => /cross-extension messaging/.test(String(error && error.message));
    api.runtime.connect = (...args) => {
      try {
        return connect(...args);
      } catch (error) {
        if (elsewhere(error)) {
          return pendingPort("", (deliver) => setTimeout(() => deliver(null), 0));
        }
        if (!notReady(error) || typeof setTimeout !== "function") throw error;
        const info = args.find((arg) => arg && typeof arg === "object") || {};
        return pendingPort(info.name || "", (deliver) => {
          let tries = 0;
          const attempt = () => {
            try { deliver(connect(...args)); } catch (e) {
              if (notReady(e) && ++tries < 100) setTimeout(attempt, 100); else deliver(null);
            }
          };
          setTimeout(attempt, 100);
        });
      }
    };
  }

  // a missing native host disconnects in Chrome; WebKit throws instead
  if (api.runtime && typeof api.runtime.connectNative === "function") {
    const connectNative = api.runtime.connectNative;
    api.runtime.connectNative = (application) => {
      try {
        return connectNative(application);
      } catch (error) {
        return pendingPort(String(application || ""), (deliver) => setTimeout(() => deliver(null), 0));
      }
    };
  }

  // @content-cut: content scripts get everything above and the closing below.
  // the rest needs sendNativeMessage, which only extension pages have
  if (!api.runtime || !api.runtime.sendNativeMessage) return;

  // === UA identity for extension pages =================================
  // WebKit hands extension pages a bare UA — "…AppleWebKit/605.1.15
  // (KHTML, like Gecko)" — with no browser token at all. Extensions that
  // branch on the browser (Bitwarden's device detection) match *nothing*
  // and crash on the null (their background died at
  // `this.device.toString`). Pages already read as Safari (Artemis' UA
  // tracks the installed Safari), so completing the extension-page UA to
  // Safari makes detection consistent — and routes Safari-specific code
  // paths at us, which we service (PasswordManagerBridge)
  try {
    const ua = navigator.userAgent;
    if (ua && !/ (Safari|Chrome|Chromium|Firefox)\//.test(ua)) {
      const patched = ua + " Version/26.0 Safari/605.1.15";
      try {
        Object.defineProperty(Navigator.prototype, "userAgent",
          { get: () => patched, configurable: true });
      } catch (e) {
        Object.defineProperty(navigator, "userAgent",
          { get: () => patched, configurable: true });
      }
    }
  } catch (e) {}

  const manifest = (() => {
    try { return api.runtime.getManifest() || {}; } catch (e) { return {}; }
  })();
  // required only: nothing grants an optional permission WebKit doesn't know
  const declared = manifest.permissions || [];

  // === 6. chrome.idle — bridged to real system idle =====================
  // WebKit leaves chrome.idle undefined. Password managers use it for the
  // "lock the vault when the machine goes idle / locks" timeout — a real
  // security feature, not cosmetics — so the fill is backed by the actual
  // system idle clock (CGEventSource) and the real screen-lock state,
  // polled through the native bridge only while someone is listening.
  if (declared.includes("idle") && (!api.idle || typeof api.idle.queryState !== "function")) {
    const onStateChanged = makeEvent();
    let detectionInterval = 60;  // Chrome's default and minimum, seconds
    let lastState = "active";
    let pollTimer = null;
    const stateFrom = (reply, threshold) =>
      reply && reply.locked ? "locked"
        : (reply && reply.seconds >= threshold ? "idle" : "active");
    const poll = () => {
      call("idle.query", {}).then((reply) => {
        const state = stateFrom(reply, detectionInterval);
        if (state !== lastState) { lastState = state; onStateChanged._fire(state); }
      }).catch(() => {});
    };
    const ensurePolling = () => {
      // bare JS engines (the self-test's JSContext) have no setInterval;
      // queryState still works there, polling just can't
      if (!pollTimer && typeof setInterval === "function") {
        pollTimer = setInterval(poll, 15000);
      }
    };
    api.idle = {
      onStateChanged: {
        addListener: (fn) => { onStateChanged.addListener(fn); ensurePolling(); },
        removeListener: (fn) => onStateChanged.removeListener(fn),
        hasListener: (fn) => onStateChanged.hasListener(fn),
        hasListeners: () => onStateChanged.hasListeners(),
      },
      setDetectionInterval: (seconds) => {
        detectionInterval = Math.max(15, Number(seconds) || 60);
        ensurePolling();
      },
      queryState: (threshold, cb) => {
        const pending = call("idle.query", {})
          .then((reply) => stateFrom(reply, Math.max(15, Number(threshold) || 60)))
          .catch(() => "active");
        if (typeof cb === "function") { pending.then(cb); return; }
        return pending;
      },
    };
  }


  // WebKit's importScripts drains microtasks even for an empty or missing file
  // (Chrome's doesn't), closing a worker's startup window; those never reach it
  const inertImports = manifest.artemis_inert_imports;
  if (inertImports && typeof importScripts === "function") {
    const nativeImport = importScripts;
    self.importScripts = function (...urls) {
      const live = [];
      for (const url of urls) {
        const exists = inertImports[new URL(String(url), location.href).pathname];
        if (exists === false) throw new DOMException("Failed to load worker script", "NetworkError");
        if (exists !== true) live.push(url);
      }
      if (live.length || !urls.length) return nativeImport.apply(this, live);
    };
  }
  const base64 = (buffer) => {
    const bytes = new Uint8Array(buffer);
    let binary = "";
    for (let i = 0; i < bytes.length; i += 0x8000) {
      binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    }
    return btoa(binary);
  };
  const expect = (reply, failure) => {
    if (!(reply && reply.ok)) throw new Error((reply && reply.error) || failure);
  };

  // WebKit fires onInstalled "install" for any extension loaded more than five
  // seconds after launch (a slow start, a re-patch); Chrome fires nothing on a
  // restart. only an extension Artemis installed this session hears "install"
  const installed = api.runtime.onInstalled;
  if (installed && typeof installed.addListener === "function") {
    const { addListener, removeListener, hasListener } = installed;
    const fresh = () => call("runtime.installedNow").then((reply) => !reply || reply.fresh !== false, () => true);
    const filtered = new WeakMap();
    const filter = (fn) => {
      if (!filtered.has(fn)) filtered.set(fn, function (details, ...rest) {
        if (!details || details.reason !== "install") return fn.call(this, details, ...rest);
        fresh().then((isFresh) => { if (isFresh) fn.call(this, details, ...rest); });
      });
      return filtered.get(fn);
    };
    Object.assign(installed, {
      addListener: (fn, ...rest) => addListener(filter(fn), ...rest),
      removeListener: (fn) => removeListener(filtered.get(fn) || fn),
      hasListener: (fn) => hasListener(filtered.get(fn) || fn),
    });
  }

  // native → page events ride connectNative ports, one per page, opened by
  // the first listener or call that needs one; native broadcasts to all
  const pushHandlers = new Map();
  let pushPort = null;
  const openPushPort = () => {
    if (pushPort || typeof api.runtime.connectNative !== "function") return;
    try {
      pushPort = api.runtime.connectNative(NATIVE_ID);
      pushPort.onMessage.addListener((message) => {
        const handler = message && pushHandlers.get(message.event);
        if (handler) { try { handler(message); } catch (e) {} }
      });
      pushPort.onDisconnect.addListener(() => { pushPort = null; });
    } catch (e) { pushPort = null; }
  };
  const pushedEvent = (name, deliver) => {
    const event = makeEvent();
    const add = event.addListener;
    event.addListener = (fn) => { add(fn); openPushPort(); };
    pushHandlers.set(name, (message) => deliver(event, message));
    return event;
  };

  // === 7. chrome.notifications — Notification Center ===================
  // create() hands its id to a callback synchronously: one that never fires
  // strands the caller's promise chain
  if (declared.includes("notifications")
    && (!api.notifications || typeof api.notifications.create !== "function")) {
    let counter = 0;
    const finishWith = (cb, value) => {
      if (typeof cb === "function") { try { cb(value); } catch (e) {} return; }
      return Promise.resolve(value);
    };
    api.notifications = Object.assign(api.notifications || {}, {
      create: (a, b, c) => {
        const id = typeof a === "string" && a ? a : "artemis-note-" + (++counter);
        const cb = typeof b === "function" ? b : c;
        const options = ((a && typeof a === "object") ? a : b) || {};
        openPushPort();
        call("notifications.show", {
          id,
          title: options.title || "",
          body: options.message || "",
          context: options.contextMessage || "",
          silent: !!options.silent,
        }).catch(() => {});
        return finishWith(cb, id);
      },
      update: (id, options, cb) => finishWith(cb, false),
      clear: (id, cb) => settle(cb, call("notifications.clear", { id: String(id) })
        .then((reply) => !!(reply && reply.wasCleared), () => false)),
      getAll: (cb) => settle(cb, call("notifications.list").then(
        (reply) => Object.fromEntries(((reply && reply.ids) || []).map((id) => [id, true])),
        () => ({}))),
      getPermissionLevel: (cb) => finishWith(cb, "granted"),
      onClicked: pushedEvent("notifications.clicked", (event, m) => event._fire(m.id)),
      onClosed: pushedEvent("notifications.closed", (event, m) => event._fire(m.id, true)),
      onButtonClicked: makeEvent(),
      onPermissionLevelChanged: makeEvent(),
      onShowSettings: makeEvent(),
    });
  }

  // === 8. offscreen documents + runtime.getContexts =====================
  // native holds the document as a windowless extension page, which has the
  // full API and runtime messaging with the background
  const extensionURL = (path) =>
    /^[a-z][a-z0-9+.-]*:/i.test(path) ? path : api.runtime.getURL(path);
  if (!api.offscreen && declared.includes("offscreen")) {
    const reasons = ["TESTING", "AUDIO_PLAYBACK", "IFRAME_SCRIPTING", "DOM_SCRAPING",
      "BLOBS", "DOM_PARSER", "USER_MEDIA", "DISPLAY_MEDIA", "WEB_RTC", "CLIPBOARD",
      "LOCAL_STORAGE", "WORKERS", "BATTERY_STATUS", "MATCH_MEDIA", "GEOLOCATION"];
    api.offscreen = {
      Reason: Object.fromEntries(reasons.map((reason) => [reason, reason])),
      createDocument: (parameters, cb) => settle(cb, call("offscreen.create", {
        url: extensionURL(String((parameters && parameters.url) || "")),
      }).then((reply) => expect(reply, "Unable to create the offscreen document."))),
      closeDocument: (cb) => settle(cb, call("offscreen.close")
        .then((reply) => expect(reply, "No current offscreen document."))),
      hasDocument: (cb) => settle(cb, call("contexts.list")
        .then((reply) => !!(reply && reply.offscreen))),
    };
  }
  if (typeof api.runtime.getContexts !== "function") {
    const types = ["TAB", "POPUP", "BACKGROUND", "OFFSCREEN_DOCUMENT", "SIDE_PANEL",
      "DEVELOPER_TOOLS"];
    if (!api.runtime.ContextType) {
      api.runtime.ContextType = Object.fromEntries(types.map((type) => [type, type]));
    }
    api.runtime.getContexts = (filter, cb) => settle(cb, call("contexts.list").then((reply) => {
      const found = [{ contextType: "BACKGROUND" }];
      if (reply && reply.offscreen) {
        found.push({ contextType: "OFFSCREEN_DOCUMENT", documentUrl: reply.offscreen });
      }
      if (reply && reply.sidePanel) {
        found.push({ contextType: "SIDE_PANEL", documentUrl: reply.sidePanel });
      }
      const wanted = filter || {};
      return found
        .map((context, index) => Object.assign({ contextId: "artemis-" + index,
          frameId: -1, incognito: false, tabId: -1, windowId: -1 }, context))
        .filter((context) => !wanted.contextTypes
          || wanted.contextTypes.includes(context.contextType))
        .filter((context) => !wanted.documentUrls
          || wanted.documentUrls.includes(context.documentUrl));
    }));
  }

  // === service worker ↔ extension pages ====================================
  // WebKit's extension worker lists no page among its clients and pages see no
  // controller: both ends meet on a BroadcastChannel, which only this origin shares
  const workerScript = manifest.background && manifest.background.service_worker;
  if (workerScript && typeof BroadcastChannel === "function") {
    const channel = keep(new BroadcastChannel("__artemis_sw"));
    const Message = globalThis.ExtendableMessageEvent || MessageEvent;
    const sourced = (target, data, source) => {
      const event = new Message("message", { data });
      Object.defineProperty(event, "source", { value: source });
      target.dispatchEvent(event);
    };
    if (typeof ServiceWorkerGlobalScope === "function" && globalThis instanceof ServiceWorkerGlobalScope) {
      const pages = new Map();
      channel.onmessage = ({ data: m }) => {
        if (!m || typeof m.from !== "string") return;
        const page = pages.get(m.from) || { id: m.from, url: m.url, type: "window",
          frameType: "top-level", focused: false, visibilityState: "visible",
          postMessage: (data) => channel.postMessage({ to: m.from, data }) };
        page.seen = Date.now();
        pages.set(m.from, page);
        if ("data" in m) sourced(globalThis, m.data, page);
      };
      const clients = globalThis.clients;
      const matchAll = clients.matchAll.bind(clients), get = clients.get.bind(clients);
      // a census: each open page answers within 50 ms, a closed one never
      clients.matchAll = async (options) => {
        const found = await matchAll(options);
        if (options && options.type && options.type !== "window" && options.type !== "all") return found;
        const since = Date.now();
        channel.postMessage({ who: true });
        await new Promise((resolve) => setTimeout(resolve, 50));
        return found.concat([...pages.values()].filter((page) => page.seen >= since));
      };
      clients.get = async (id) => pages.get(id) || get(id);
    } else if (navigator && navigator.serviceWorker && !navigator.serviceWorker.controller) {
      const container = navigator.serviceWorker;
      const id = crypto.randomUUID();
      const send = (extra) => channel.postMessage(Object.assign({ from: id, url: location.href }, extra));
      // an idle worker is unloaded and hears no channel until something loads it
      let woken = Promise.resolve();
      const worker = Object.assign(new EventTarget(), {
        scriptURL: api.runtime.getURL(workerScript), state: "activated",
        postMessage: (data) => {
          const copy = structuredClone(data);
          woken = woken.then(() => call("background.wake")).catch(() => {}).then(() => send({ data: copy }));
        },
      });
      channel.onmessage = ({ data: m }) => {
        if (m && m.who) send();
        else if (m && m.to === id) sourced(container, m.data, worker);
      };
      const registration = { active: worker, installing: null, waiting: null, scope: api.runtime.getURL("") };
      Object.defineProperty(container, "controller", { get: () => worker, configurable: true });
      Object.defineProperty(container, "ready", { value: Promise.resolve(registration), configurable: true });
    }
  }

  // === 9. identity — OAuth through a sign-in window =====================
  // the redirect host is the one the store registered for this package;
  // native stops the flow at that host and hands back the URL
  if (!api.identity && declared.includes("identity")) {
    const redirectHost = manifest.artemis_redirect_host;
    const notSignedIn = () => Promise.reject(new Error("The user is not signed in."));
    api.identity = {
      getRedirectURL: (path) =>
        "https://" + redirectHost + "/" + String(path || "").replace(/^\/+/, ""),
      launchWebAuthFlow: (details, cb) => settle(cb, call("identity.launch", {
        url: String((details && details.url) || ""),
        interactive: !!(details && details.interactive),
      }).then((reply) => {
        if (reply && reply.url) return reply.url;
        throw new Error((reply && reply.error) || "Authorization page could not be loaded.");
      })),
      getAuthToken: (details, cb) =>
        settle(typeof details === "function" ? details : cb, notSignedIn()),
      getProfileUserInfo: (details, cb) => settle(typeof details === "function" ? details : cb,
        Promise.resolve({ email: "", id: "" })),
      getAccounts: (cb) => settle(cb, Promise.resolve([])),
      removeCachedAuthToken: (details, cb) => settle(cb, Promise.resolve()),
      clearAllCachedAuthTokens: (cb) => settle(cb, Promise.resolve()),
      onSignInChanged: makeEvent(),
    };
  }

  // === 10. sidePanel — a panel window on the browser's edge =============
  // per-tab options live in this page; the global ones and the action-click
  // behaviour live natively, where the action click is handled
  if (!api.sidePanel && declared.includes("sidePanel")) {
    const perTab = new Map();
    const tabOptions = (options) =>
      options && options.tabId !== undefined ? perTab.get(options.tabId) : undefined;
    const state = () => call("sidePanel.state").then((reply) => reply || {});
    api.sidePanel = {
      setOptions: (options, cb) => {
        const o = options || {};
        if (o.tabId !== undefined) {
          perTab.set(o.tabId, Object.assign({}, perTab.get(o.tabId), o));
          return settle(cb, Promise.resolve());
        }
        return settle(cb, call("sidePanel.configure", { path: o.path, enabled: o.enabled })
          .then(() => {}));
      },
      getOptions: (options, cb) => settle(cb, state().then((s) =>
        Object.assign({ enabled: s.enabled !== false, path: s.path }, tabOptions(options)))),
      setPanelBehavior: (behavior, cb) => settle(cb, call("sidePanel.configure", {
        openPanelOnActionClick: !!(behavior && behavior.openPanelOnActionClick),
      }).then(() => {})),
      getPanelBehavior: (cb) => settle(cb, state()
        .then((s) => ({ openPanelOnActionClick: !!s.openPanelOnActionClick }))),
      open: (options, cb) => {
        const tab = tabOptions(options);
        if (tab && tab.enabled === false) {
          return settle(cb, Promise.reject(new Error("The side panel is disabled for this tab.")));
        }
        return settle(cb, call("sidePanel.open", { path: (tab && tab.path) || "" })
          .then((reply) => expect(reply, "No active side panel for this extension.")));
      },
      close: (options, cb) => settle(cb, call("sidePanel.close").then(() => {})),
      onOpened: makeEvent(),
      onClosed: makeEvent(),
    };
  }

  // === 11. tabGroups — Artemis has none =================================
  // queries answer "no groups", grouping is refused, and tabs carry the
  // groupId an ungrouped Chrome tab has. only for manifests that ask
  if (api.tabs && !api.tabGroups && declared.includes("tabGroups")) {
    const NONE = -1;
    const refuse = () => Promise.reject(new Error("Tab groups are not supported in Artemis."));
    const colors = ["grey", "blue", "red", "yellow", "green", "pink", "purple", "cyan", "orange"];
    api.tabGroups = {
      TAB_GROUP_ID_NONE: NONE,
      Color: Object.fromEntries(colors.map((color) => [color.toUpperCase(), color])),
      query: (info, cb) => settle(cb, Promise.resolve([])),
      get: (id, cb) => settle(cb, refuse()),
      update: (id, properties, cb) => settle(cb, refuse()),
      move: (id, properties, cb) => settle(cb, refuse()),
      onCreated: makeEvent(),
      onUpdated: makeEvent(),
      onMoved: makeEvent(),
      onRemoved: makeEvent(),
    };
    if (typeof api.tabs.group !== "function") {
      api.tabs.group = (options, cb) => settle(cb, refuse());
    }
    if (typeof api.tabs.ungroup !== "function") {
      api.tabs.ungroup = (ids, cb) => settle(cb, Promise.resolve());
    }
    const ungrouped = (tab) => {
      if (tab && typeof tab === "object" && tab.groupId === undefined) tab.groupId = NONE;
      return tab;
    };
    const shaped = (result) => Array.isArray(result) ? result.map(ungrouped) : ungrouped(result);
    for (const name of ["query", "get", "getCurrent", "create", "update", "duplicate"]) {
      const original = api.tabs[name];
      if (typeof original !== "function") continue;
      // the callback stays WebKit's own, so runtime.lastError is set inside it
      api.tabs[name] = (...args) => {
        if (typeof args[args.length - 1] === "function") {
          const cb = args.pop();
          return original(...args, (result) => cb(shaped(result)));
        }
        return Promise.resolve(original(...args)).then(shaped);
      };
    }
  }

  // === 12. management — this extension's own record =====================
  if (!api.management) {
    const localized = (value) => {
      const key = /^__MSG_(\w+)__$/.exec(String(value || ""));
      return key ? (api.i18n.getMessage(key[1]) || String(value)) : String(value || "");
    };
    const optionsPage = manifest.options_ui ? manifest.options_ui.page : manifest.options_page;
    const self = () => ({
      id: api.runtime.id,
      name: localized(manifest.name),
      shortName: localized(manifest.short_name || manifest.name),
      description: localized(manifest.description),
      version: manifest.version,
      versionName: manifest.version_name,
      enabled: true, mayDisable: true, isApp: false,
      installType: "normal", type: "extension",
      offlineEnabled: !!manifest.offline_enabled,
      homepageUrl: manifest.homepage_url || "",
      optionsUrl: optionsPage ? api.runtime.getURL(optionsPage) : "",
      permissions: declared.filter((p) => typeof p === "string" && !p.includes("://")),
      hostPermissions: manifest.host_permissions || [],
      icons: [],
    });
    api.management = {
      getSelf: (cb) => settle(cb, Promise.resolve(self())),
      get: (id, cb) => settle(cb, id === api.runtime.id ? Promise.resolve(self())
        : Promise.reject(new Error("Failed to find extension with id " + id + "."))),
      getAll: (cb) => settle(cb, Promise.resolve([self()])),
      getPermissionWarningsById: (id, cb) => settle(cb, Promise.resolve([])),
      getPermissionWarningsByManifest: (text, cb) => settle(cb, Promise.resolve([])),
      setEnabled: (id, enabled, cb) => settle(cb,
        Promise.reject(new Error("Extensions are switched on and off in Settings."))),
      uninstallSelf: (options, cb) => settle(typeof options === "function" ? options : cb,
        call("management.uninstallSelf")
          .then((reply) => expect(reply, "User cancelled uninstall."))),
      onInstalled: makeEvent(),
      onUninstalled: makeEvent(),
      onEnabled: makeEvent(),
      onDisabled: makeEvent(),
    };
  }

  if (api.action && typeof api.action.getUserSettings !== "function") {
    api.action.getUserSettings = (cb) => settle(cb, call("action.userSettings")
      .then((reply) => ({ isOnToolbar: !!(reply && reply.isOnToolbar) })));
    if (!api.action.onUserSettingsChanged) api.action.onUserSettingsChanged = makeEvent();
  }

  // === 13. downloads — into ~/Downloads ==================================
  // web URLs download through the current tab's session; blob: and data:
  // URLs resolve only in this page, so their bytes travel to native
  if (!api.downloads && declared.includes("downloads")) {
    let nextID = 1;
    const done = (cb, value) => settle(cb, Promise.resolve(value));
    api.downloads = {
      download: (options, cb) => settle(cb, (async () => {
        const o = options || {};
        const url = String(o.url || "");
        const payload = { filename: String(o.filename || ""), saveAs: !!o.saveAs };
        if (/^(blob|data):/i.test(url)) {
          payload.bytesBase64 = base64(await (await fetch(url)).arrayBuffer());
        } else {
          payload.url = new URL(url, location && location.href).href;
        }
        expect(await call("downloads.download", payload), "Download failed.");
        return nextID++;
      })()),
      search: (query, cb) => done(cb, []),
      erase: (query, cb) => done(cb, []),
      cancel: (id, cb) => done(cb),
      pause: (id, cb) => done(cb),
      resume: (id, cb) => done(cb),
      open: () => {},
      show: () => {},
      showDefaultFolder: () => { call("downloads.showFolder").catch(() => {}); },
      onCreated: makeEvent(),
      onChanged: makeEvent(),
      onErased: makeEvent(),
      onDeterminingFilename: makeEvent(),
    };
  }

  // === 14. search — the user's engine; Chrome's and Firefox's spellings ==
  if (!api.search && declared.includes("search")) {
    const query = (text, disposition, cb) => settle(cb, call("search.query", {
      text: String(text || ""), disposition: disposition || "CURRENT_TAB",
    }).then(() => {}));
    api.search = {
      query: (info, cb) => query(info && info.text, info && info.disposition, cb),
      search: (info) => query(info && info.query, info && info.disposition),
    };
  }

  // === 15. clipboard writes without a focused page ======================
  // an offscreen or background document never has focus, so WebKit refuses
  // its copies; the text goes through native, gated on clipboardWrite
  try {
    if (typeof document !== "undefined" && typeof document.execCommand === "function") {
      const exec = document.execCommand;
      document.execCommand = function (command, ...rest) {
        const copied = exec.call(document, command, ...rest);
        if (copied || String(command).toLowerCase() !== "copy") return copied;
        const field = document.activeElement;
        const text = field && typeof field.value === "string"
            && typeof field.selectionStart === "number"
          ? field.value.slice(field.selectionStart, field.selectionEnd)
          : String(globalThis.getSelection ? getSelection() : "");
        if (!text) return copied;
        call("clipboard.write", { text }).catch(() => {});
        return true;
      };
    }
    const clipboard = navigator && navigator.clipboard;
    if (clipboard && typeof clipboard.writeText === "function") {
      const writeText = clipboard.writeText.bind(clipboard);
      clipboard.writeText = (text) => writeText(text).catch((error) =>
        call("clipboard.write", { text: String(text) }).then((reply) => {
          if (!(reply && reply.ok)) throw error;
        }));
    }
  } catch (e) {}

  // === 5. SameSite bridge for host-permitted fetches ===================
  // Chrome exempts an extension's host-permitted requests from SameSite
  // cookie enforcement; WebKit doesn't, so a background fetch to a site
  // whose session cookie is SameSite=Lax arrives logged-out (Surfshark's
  // token exchange 401'd exactly here — proven by replaying the call
  // natively with cookies attached, which returned 200). When the target
  // host holds Lax/Strict cookies the fetch is performed natively with
  // them attached; everything else stays on the normal path.
  try {
    const nativeFetch = globalThis.fetch;
    if (typeof nativeFetch === "function" && typeof Request === "function") {
      const bridgeByHost = new Map();  // host -> {bridge, at}
      globalThis.fetch = async function (input, init) {
        let refused = false;
        try {
          const probe = new Request(input, init);
          if (/^https?:/.test(probe.url)) {
            const host = new URL(probe.url).host;
            let cached = bridgeByHost.get(host);
            if (!cached || Date.now() - cached.at > 10000) {
              const answer = await call("fetch.needsBridge", { url: probe.url }).catch(() => null);
              cached = { bridge: !!(answer && answer.bridge), at: Date.now() };
              bridgeByHost.set(host, cached);
            }
            if (cached.bridge) {
              const method = probe.method || "GET";
              const bodyBase64 = method !== "GET" && method !== "HEAD"
                ? base64(await probe.clone().arrayBuffer()) : null;
              const headers = {};
              probe.headers.forEach((value, key) => { headers[key] = value; });
              const reply = await call("fetch.perform",
                { url: probe.url, method, headers, bodyBase64 });
              if (reply && reply.networkError) {
                refused = true;
              } else if (reply && typeof reply.status === "number") {
                const bytes = reply.bodyBase64
                  ? Uint8Array.from(atob(reply.bodyBase64), (c) => c.charCodeAt(0))
                  : null;
                return new Response(bytes, {
                  status: reply.status,
                  statusText: reply.statusText || "",
                  headers: reply.headers || {},
                });
              } else {
                report("fetch-bridge", "bridge failed for " + probe.url + ", falling through");
              }
            }
          }
        } catch (e) {
          report("fetch-bridge", (e && e.message) || String(e));
        }
        // a redirect out of the extension's reach fails as Chrome's CORS check would, unretried
        if (refused) throw new TypeError("Failed to fetch");
        return nativeFetch.apply(this, arguments);
      };
    }
  } catch (e) {}

  // relay content-script diagnostics (they have no native channel) and
  // report what the runtime says about this context, which is how a
  // "you look like a private window" refusal gets diagnosed
  try {
    api.runtime.onMessage?.addListener((message) => {
      const relayed = message && message.__artemisCompatLog;
      // a content world relays its console reports and nothing else
      if (relayed && relayed.artemisCompat === "log") {
        try { api.runtime.sendNativeMessage(NATIVE_ID, relayed); } catch (e) {}
      }
    });
  } catch (e) {}

  // === 4. declarativeNetRequest =======================================
  // WebKit compiles every enabled ruleset into one content-rule-list and
  // fails the whole atomic batch over a single rule it can't translate.
  // Extensions leave that rejection unhandled, which kills their init chain.
  const dnr = api.declarativeNetRequest;
  if (dnr) {
    // Chrome's global static-rule pool; ExtensionCompat trims what WebKit can't hold
    if (typeof dnr.getAvailableStaticRuleCount !== "function") {
      dnr.getAvailableStaticRuleCount = (cb) => settle(cb, Promise.resolve(30000));
    }
    // Artemis never switches off single static rules
    if (typeof dnr.getDisabledRuleIds !== "function") {
      dnr.getDisabledRuleIds = (options, cb) => settle(cb, Promise.resolve([]));
    }
    const badRuleIndex = (error) => {
      const message = error && error.message ? error.message : String(error || "");
      const match = /rule at index (\d+)/.exec(message);
      return match ? Number(match[1]) : -1;
    };
    // WebKit's rule regex has no alternation and no \d \w \s. a regexFilter using them is spelt
    // out, one rule per branch: the first under the rule's own id, the rest under ids the
    // extension never sees
    const splitBase = 1e9, lastBase = 15e8, splitMost = 16;
    const sets = { d: "0-9", w: "A-Za-z0-9_", s: " \\t\\n\\r\\f" }, capture = "\u0001";
    const spelledOut = (source) => {
      let at = 0;
      const branches = (nested) => {
        const done = [];
        let open = [""];
        const add = (parts) => { open = open.flatMap((head) => parts.map((part) => head + part)); };
        while (at < source.length) {
          const c = source[at];
          if (c === ")") { if (!nested) throw 0; break; }
          if (c === "|") { done.push(...open); open = [""]; at++; }
          else if (c === "\\") {
            const name = source[at + 1] || "", set = sets[name.toLowerCase()];
            add([set ? (name in sets ? "[" : "[^") + set + "]" : c + name]); at += 2;
          } else if (c === "[") {
            const set = /^\[\^?\]?(?:\\.|[^\]\\])*\]/.exec(source.slice(at));
            if (!set) throw 0;
            add([set[0].replace(/\\(.)/g, (whole, name) => sets[name] || whole)]); at += set[0].length;
          } else if (c === "(") {
            const head = /^\((\?:)?/.exec(source.slice(at))[0];
            at += head.length;
            if (source[at] === "?") throw 0;
            const inner = branches(true);
            if (source[at++] !== ")") throw 0;
            const count = /^(?:[*+?]|\{\d+(?:,\d*)?\})?\??/.exec(source.slice(at))[0];
            at += count.length;
            // a repeated choice has no finite list of branches; an optional one does
            if (inner.length > 1 && count && count[0] !== "?") throw 0;
            add(inner.map((body) => head === "(" || count
              ? (head === "(" ? capture : head) + body + ")" + count : body));
          } else { add([c]); at++; }
          if (done.length + open.length > splitMost) throw 0;
        }
        // a group captured inside one branch would change number once the branches part
        if (done.length && done.concat(open).some((branch) => branch.includes(capture))) throw 0;
        return done.concat(open);
      };
      try {
        const all = branches(false);
        return at === source.length ? all.map((branch) => branch.split(capture).join("(")) : null;
      } catch (e) { return null; }
    };
    const splittable = (id) => Number.isInteger(id) && id > 0 && id < (lastBase - splitBase) / splitMost;
    const split = (options) => {
      if (!options || typeof options !== "object") return options;
      const addRules = (options.addRules || []).flatMap((rule) => {
        if (!rule || !rule.condition) return [rule];
        const condition = Object.assign({}, rule.condition);
        const excludes = (condition.excludedRequestDomains || []).length > 0;
        // WebKit compiles no list holding a rule with both of these and no excludedRequestMethods;
        // given the same methods there, its stop on the excluded domains covers just those
        if (excludes && condition.requestMethods && !condition.excludedRequestMethods) {
          condition.excludedRequestMethods = condition.requestMethods;
        }
        const filter = condition.regexFilter;
        const spelt = typeof filter === "string" && /[|]|\\[dwsDWS]/.test(filter) ? spelledOut(filter) : null;
        const parts = spelt && (spelt.length === 1 || splittable(rule.id)) ? spelt : null;
        // on the domains it excludes WebKit stops at such a rule, and rules of one priority run
        // in id order: held wholly above every other id, it stops no rule but its like
        const base = excludes && splittable(rule.id) ? lastBase : splitBase;
        return (parts || [filter]).map((part, n) => Object.assign({}, rule, {
          id: n || base === lastBase ? base + rule.id * splitMost + n : rule.id,
          condition: parts ? Object.assign({}, condition, { regexFilter: part }) : condition,
        }));
      });
      const removeRuleIds = (options.removeRuleIds || []).flatMap((id) => splittable(id)
        ? [id].concat([splitBase, lastBase].flatMap((base) =>
          Array.from({ length: splitMost }, (_, n) => base + id * splitMost + n))) : [id]);
      return Object.assign({}, options, options.addRules && { addRules }, options.removeRuleIds && { removeRuleIds });
    };
    for (const name of ["getDynamicRules", "getSessionRules"]) {
      const original = dnr[name];
      if (typeof original !== "function") continue;
      dnr[name] = (...args) => {
        const callback = typeof args[args.length - 1] === "function" ? args.pop() : null;
        return settle(callback, Promise.resolve(original.apply(dnr, args))
          .then((rules) => (rules || []).flatMap((rule) => rule.id < splitBase ? [rule]
            : rule.id < lastBase || rule.id % splitMost ? []
              : [Object.assign({}, rule, { id: (rule.id - lastBase) / splitMost })])));
      };
    }
    for (const name of ["updateEnabledRulesets", "updateDynamicRules", "updateSessionRules"]) {
      const original = dnr[name];
      if (typeof original !== "function") continue;
      dnr[name] = function (...args) {
        const callback = typeof args[args.length - 1] === "function" ? args.pop() : null;
        const finish = (value) => {
          if (callback) { try { callback(value); } catch (e) {} }
          return value;
        };
        // resend without the rule WebKit named; a partial batch beats none
        const attempt = (options, dropped) => {
          let pending;
          try { pending = original.apply(dnr, [options]); } catch (e) { pending = Promise.reject(e); }
          return Promise.resolve(pending).then((value) => {
            if (dropped) report("dnr", name + " dropped " + dropped + " rules WebKit cannot hold");
            return finish(value);
          }, (error) => {
            const index = badRuleIndex(error);
            const rules = options && options.addRules;
            if (index >= 0 && dropped < 50 && Array.isArray(rules) && index < rules.length) {
              const trimmed = Object.assign({}, options, {
                addRules: rules.slice(0, index).concat(rules.slice(index + 1)),
              });
              return attempt(trimmed, dropped + 1);
            }
            report("dnr", name + " failed"
              + (dropped ? " after dropping " + dropped + " unsupported rules" : "")
              + ": " + (error && error.message ? error.message : error));
            return finish(undefined);
          });
        };
        return attempt(name === "updateEnabledRulesets" ? args[0] : split(args[0]), 0);
      };
    }
    // WebKit answers getMatchedRules without the `rule` a caller buckets on,
    // so a blocking panel reads 0 however much was blocked. native keeps the
    // real ledger of blocked requests for the page and answers from it.
    if (typeof dnr.getMatchedRules === "function") {
      dnr.getMatchedRules = function (filter, callback) {
        if (typeof filter === "function") { callback = filter; filter = {}; }
        const asked = filter || {};
        // native keeps the ledger of the active tab only; any other tab reads empty
        const active = asked.tabId === undefined || !api.tabs ? Promise.resolve(true)
          : Promise.resolve(api.tabs.query({ active: true, currentWindow: true }))
            .then((tabs) => !!tabs && tabs.some((tab) => tab.id === asked.tabId), () => false);
        return active.then((ours) => ours ? call("dnr.matchedRules", {
          tabId: asked.tabId, minTimeStamp: asked.minTimeStamp,
        }) : { rulesMatchedInfo: [] }).then((reply) => {
          const result = { rulesMatchedInfo: (reply && reply.rulesMatchedInfo) || [] };
          if (callback) { try { callback(result); } catch (e) {} }
          return result;
        }, () => {
          const empty = { rulesMatchedInfo: [] };
          if (callback) { try { callback(empty); } catch (e) {} }
          return empty;
        });
      };
    }

    // the enabled set is WebKit's, not the manifest's: a failed compile rolls
    // it back and an extension can disable rulesets across a restart
    try {
      Promise.resolve(dnr.getEnabledRulesets()).then((ids) => {
        report("dnr", "enabled rulesets: " + ((ids && ids.length) ? ids.join(", ") : "none"));
      }, () => {});
    } catch (e) {}
  }

  // Firefox packages ask which Firefox they run in; Chrome ones treat the
  // function's absence as "this is Chrome", so only gecko manifests get it
  // installed from Firefox's store (served as moz-extension:) or declared for Firefox
  const gecko = (manifest.browser_specific_settings || manifest.applications || {}).gecko
    || (location && location.protocol === "moz-extension:");
  if (gecko && typeof api.runtime.getBrowserInfo !== "function") {
    api.runtime.getBrowserInfo = (cb) => settle(cb, Promise.resolve(
      { name: "Firefox", vendor: "Mozilla", version: "140.0", buildID: "20260101000000" }));
  }
  // a Firefox build sees the Firefox it was told it runs in: some pick their code
  // path from the user agent (Browsec). its own pages only; the web never sees it
  if (gecko && navigator && !/Firefox\//.test(navigator.userAgent)) {
    try {
      Object.defineProperty(navigator, "userAgent", {
        value: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:140.0) Gecko/20100101 Firefox/140.0",
        configurable: true,
      });
    } catch (e) {}
  }

  // a permission WebKit has never heard of is one this extension doesn't hold
  if (api.permissions) {
    for (const name of ["contains", "request"]) {
      const original = api.permissions[name];
      if (typeof original !== "function") continue;
      api.permissions[name] = (permissions, cb) => {
        const answer = (async () => {
          try { return await original(permissions); } catch (error) {
            if (/not a valid permission/.test(String(error && error.message))) return false;
            throw error;
          }
        })();
        return settle(cb, answer);
      };
    }
  }

  // WebKit refuses a whole filter over one pattern or type it can't parse, where
  // Chrome and Firefox accept them; those are dropped, and a filter left with
  // nothing it can match is never registered
  const parsablePattern = (pattern) => pattern === "<all_urls>"
    || /^(\*|https?|file|chrome-extension|moz-extension|webkit-extension):\/\//.test(pattern);
  const webRequestTypes = new Set(["main_frame", "sub_frame", "stylesheet", "script", "image",
    "font", "object", "xmlhttprequest", "ping", "csp_report", "media", "beacon", "web_manifest",
    "xslt", "other"]);
  const parsableFilter = (filter) => {
    if (!filter || typeof filter !== "object") return filter;
    const urls = Array.isArray(filter.urls) ? filter.urls.filter(parsablePattern) : filter.urls;
    const types = Array.isArray(filter.types)
      ? filter.types.filter((type) => webRequestTypes.has(type)) : filter.types;
    if ((urls && !urls.length) || (types && !types.length)) return null;
    return urls === filter.urls && types === filter.types ? filter
      : Object.assign({}, filter, { urls, types });
  };
  const filtering = (addListener) => function (fn, filter, ...rest) {
    const parsable = parsableFilter(filter);
    if (parsable === null) return;
    return addListener.call(this, fn, parsable, ...rest);
  };
  hookEvents("webRequest", (name, event) =>
    typeof event.addListener === "function" ? { addListener: filtering(event.addListener) } : null);
  // instances WebKit builds later have no own addListener and read the shared prototype
  try {
    // native events are accessors, not own values, so take one by name
    const sample = api.webRequest && api.webRequest.onBeforeRequest;
    const proto = sample && Object.getPrototypeOf(sample);
    if (proto && proto !== Object.prototype && typeof proto.addListener === "function") {
      // the prototype's methods are non-writable but configurable, so assignment throws
      Object.defineProperty(keep(proto), "addListener", {
        value: filtering(proto.addListener), writable: true, configurable: true,
      });
    }
  } catch (e) {}
  if (api.webRequest && typeof api.webRequest.handlerBehaviorChanged !== "function") {
    // WebKit keeps no webRequest cache, so there is nothing to flush
    api.webRequest.handlerBehaviorChanged = (cb) => settle(cb, Promise.resolve());
  }
  for (const namespace of ["menus", "contextMenus"]) {
    const menus = api[namespace];
    if (!menus) continue;
    // WebKit takes only its own manifest version's action context, and no null parent
    const actionContext = manifest.manifest_version >= 3 ? "action" : "browser_action";
    const parsable = (properties) => {
      if (!properties || typeof properties !== "object") return properties;
      const copy = Object.assign({}, properties);
      for (const key of ["documentUrlPatterns", "targetUrlPatterns"]) {
        if (Array.isArray(copy[key])) copy[key] = copy[key].filter(parsablePattern);
      }
      if (copy.parentId === null) delete copy.parentId;
      if (Array.isArray(copy.contexts)) {
        copy.contexts = [...new Set(copy.contexts.map((context) =>
          ["action", "browser_action"].includes(context)
            || (context === "page_action" && actionContext === "action") ? actionContext : context))];
      }
      return copy;
    };
    const create = menus.create, update = menus.update;
    if (typeof create === "function") menus.create = (properties, cb) => create(parsable(properties), cb);
    if (typeof update === "function") {
      menus.update = (id, properties, cb) => update(id, parsable(properties), cb);
    }
  }

  // WebKit fires cookies.onChanged with no details, in bursts; Chrome sends one
  // {removed, cookie, cause} per changed cookie, so diff snapshots of the jar
  if (api.cookies && api.cookies.onChanged) {
    const changed = makeEvent();
    const identity = (c) => [c.storeId, c.domain, c.path, c.name].join("\n");
    let jar = null, running = null, again = false, watching = false;
    const diff = async () => {
      const next = new Map((await api.cookies.getAll({})).map((c) => [identity(c), c]));
      const previous = jar;
      jar = next;
      if (!previous) return;
      for (const [key, old] of previous) {
        const now = next.get(key);
        if (!now) {
          const expired = old.expirationDate !== undefined && old.expirationDate * 1000 <= Date.now();
          changed._fire({ removed: true, cookie: old, cause: expired ? "expired" : "explicit" });
        } else if (JSON.stringify(now) !== JSON.stringify(old)) {
          changed._fire({ removed: true, cookie: old, cause: "overwrite" });
          changed._fire({ removed: false, cookie: now, cause: "explicit" });
        }
      }
      for (const [key, now] of next) {
        if (!previous.has(key)) changed._fire({ removed: false, cookie: now, cause: "explicit" });
      }
    };
    const refresh = () => {
      if (running) { again = true; return; }
      running = diff().catch(() => {}).then(() => {
        running = null;
        if (again) { again = false; refresh(); }
      });
    };
    hookEvents("cookies", (name, event) => {
      if (name !== "onChanged" || typeof event.addListener !== "function") return null;
      const nativeAdd = event.addListener;
      return {
        addListener: (fn) => {
          if (!watching) { watching = true; nativeAdd.call(event, refresh); refresh(); }
          changed.addListener(fn);
        },
        removeListener: changed.removeListener, hasListener: changed.hasListener,
        hasListeners: changed.hasListeners,
      };
    });
  }

  // Chrome answers null for a tab with no document yet (restored, hibernated);
  // WebKit throws "Main frame not found"
  if (api.webNavigation) {
    for (const name of ["getAllFrames", "getFrame"]) {
      const original = api.webNavigation[name];
      if (typeof original !== "function") continue;
      api.webNavigation[name] = (details, cb) => settle(cb, Promise.resolve()
        .then(() => original(details))
        .catch((error) => {
          if (/frame not found/i.test(String(error && error.message))) return null;
          throw error;
        }));
    }
  }

  // === history, topSites, sessions — the current profile's, natively ======
  // history keeps one record per page, so a page's visits are its latest one
  if (!api.history && declared.includes("history")) {
    const item = (entry) => ({ id: entry.url, url: entry.url, title: entry.title,
      lastVisitTime: entry.lastVisitTime, visitCount: entry.visitCount, typedCount: entry.typedCount });
    const search = (query) => call("history.search", query)
      .then((reply) => ((reply && reply.items) || []).map(item));
    const visited = makeEvent(), removed = makeEvent();
    const forget = (payload, all) => call("history.delete", payload).then((reply) => {
      removed._fire({ allHistory: all, urls: (reply && reply.urls) || [] });
    });
    let watching = false;
    const onVisited = Object.assign({}, visited, {
      addListener: (fn) => {
        visited.addListener(fn);
        if (watching || !api.tabs || !api.tabs.onUpdated) return;
        watching = true;
        api.tabs.onUpdated.addListener((tabId, change, tab) => {
          if (!change || change.status !== "complete" || !tab || tab.incognito) return;
          if (!/^https?:/.test(tab.url || "")) return;
          search({ url: tab.url }).then((items) => items[0] && visited._fire(items[0]), () => {});
        });
      },
    });
    api.history = {
      search: (query, cb) => settle(cb, search(query || {})),
      getVisits: (details, cb) => settle(cb, search({ url: details && details.url }).then((items) =>
        items.map((entry) => ({ id: entry.id, visitId: entry.id, visitTime: entry.lastVisitTime,
          referringVisitId: "0", transition: "link", isLocal: true })))),
      addUrl: (details, cb) => settle(cb, call("history.add", details || {}).then(() => {})),
      deleteUrl: (details, cb) => settle(cb, forget({ url: details && details.url }, false)),
      deleteRange: (range, cb) => settle(cb, forget(
        { start: range && range.startTime, end: range && range.endTime }, false)),
      deleteAll: (cb) => settle(cb, forget({ all: true }, true)),
      onVisited,
      onVisitRemoved: removed,
    };
  }
  if (!api.topSites && declared.includes("topSites")) {
    api.topSites = {
      get: (cb) => settle(cb, call("topSites.get").then((reply) => (reply && reply.sites) || [])),
    };
  }
  if (!api.sessions && declared.includes("sessions")) {
    api.sessions = {
      getRecentlyClosed: (filter, cb) => settle(typeof filter === "function" ? filter : cb,
        call("sessions.recent", { maxResults: filter && filter.maxResults })
          .then((reply) => (reply && reply.sessions) || [])),
      restore: (sessionId, cb) => settle(typeof sessionId === "function" ? sessionId : cb,
        call("sessions.restore", { sessionId: typeof sessionId === "string" ? sessionId : null })
          .then((reply) => (reply && reply.session) || null)),
      getDevices: (filter, cb) => settle(typeof filter === "function" ? filter : cb, Promise.resolve([])),
      onChanged: makeEvent(),
    };
    // Firefox's per-tab and per-window values, kept for this browser session
    if (gecko) {
      const values = new Map();  // "tab:<id>" / "window:<id>" -> Map(key -> JSON)
      const slot = (kind, id) => {
        const name = kind + ":" + id;
        if (!values.has(name)) values.set(name, new Map());
        return values.get(name);
      };
      for (const [kind, Kind] of [["tab", "Tab"], ["window", "Window"]]) {
        api.sessions["set" + Kind + "Value"] = (id, key, value) =>
          Promise.resolve(void slot(kind, id).set(key, JSON.stringify(value)));
        api.sessions["get" + Kind + "Value"] = (id, key) => {
          const json = slot(kind, id).get(key);
          return Promise.resolve(json === undefined ? undefined : JSON.parse(json));
        };
        api.sessions["remove" + Kind + "Value"] = (id, key) => Promise.resolve(void slot(kind, id).delete(key));
      }
      api.tabs?.onRemoved?.addListener((id) => values.delete("tab:" + id));
      api.windows?.onRemoved?.addListener((id) => values.delete("window:" + id));
    }
  }

  // === browsingData — cleared from the current profile's data store ========
  if (!api.browsingData && declared.includes("browsingData")) {
    const all = ["appcache", "cache", "cacheStorage", "cookies", "downloads", "fileSystems",
      "formData", "history", "indexedDB", "localStorage", "passwords", "serviceWorkers", "webSQL"];
    const remove = (options, types) => call("browsingData.remove", {
      since: (options && options.since) || 0, origins: options && options.origins,
      excludeOrigins: options && options.excludeOrigins,
      types: Object.keys(types || {}).filter((type) => types[type]),
    }).then((reply) => expect(reply, "Removing browsing data failed."));
    api.browsingData = {
      remove: (options, types, cb) => settle(cb, remove(options, types)),
      settings: (cb) => settle(cb, Promise.resolve({
        options: { since: 0 },
        dataToRemove: Object.fromEntries(all.map((type) => [type, false])),
        dataRemovalPermitted: Object.fromEntries(all.map((type) => [type, true])),
      })),
    };
    const single = { removeAppcache: "appcache", removeCache: "cache", removeCacheStorage: "cacheStorage",
      removeCookies: "cookies", removeDownloads: "downloads", removeFileSystems: "fileSystems",
      removeFormData: "formData", removeHistory: "history", removeIndexedDB: "indexedDB",
      removeLocalStorage: "localStorage", removePasswords: "passwords",
      removeServiceWorkers: "serviceWorkers", removeWebSQL: "webSQL" };
    for (const [name, type] of Object.entries(single)) {
      api.browsingData[name] = (options, cb) => settle(cb, remove(options, { [type]: true }));
    }
  }

  // === fontSettings — the Mac's installed font families ====================
  if (!api.fontSettings && declared.includes("fontSettings")) {
    const generic = (details) => ({ fontId: "", levelOfControl: "not_controllable" });
    api.fontSettings = {
      getFontList: (cb) => settle(cb, call("fontSettings.list").then((reply) => (reply && reply.fonts) || [])),
      getFont: (details, cb) => settle(cb, Promise.resolve(generic(details))),
      getDefaultFontSize: (details, cb) => settle(typeof details === "function" ? details : cb,
        Promise.resolve({ pixelSize: 16, levelOfControl: "not_controllable" })),
      getDefaultFixedFontSize: (details, cb) => settle(typeof details === "function" ? details : cb,
        Promise.resolve({ pixelSize: 13, levelOfControl: "not_controllable" })),
      getMinimumFontSize: (details, cb) => settle(typeof details === "function" ? details : cb,
        Promise.resolve({ pixelSize: 0, levelOfControl: "not_controllable" })),
    };
  }

  // === system.display — the Mac's screens ==================================
  if (declared.includes("system.display") && !(api.system && api.system.display)) {
    api.system = api.system || {};
    api.system.display = {
      getInfo: (flags, cb) => settle(typeof flags === "function" ? flags : cb,
        call("system.display").then((reply) => (reply && reply.displays) || [])),
      onDisplayChanged: makeEvent(),
    };
  }

  // === tts — the background page's own speech synthesis ===================
  if (!api.tts && declared.includes("tts") && globalThis.speechSynthesis) {
    const synth = globalThis.speechSynthesis;
    // the voice list loads asynchronously; an early read is empty
    const loaded = () => synth.getVoices().length ? Promise.resolve() : new Promise((done) => {
      synth.addEventListener("voiceschanged", done, { once: true });
      setTimeout(done, 1000);
    });
    const voices = () => loaded().then(() => synth.getVoices().map((voice) => ({ voiceName: voice.name,
      lang: voice.lang, remote: !voice.localService,
      eventTypes: ["start", "end", "interrupted", "error", "word"] })));
    api.tts = {
      speak: (text, options, cb) => {
        if (typeof options === "function") { cb = options; options = {}; }
        const o = options || {};
        if (!o.enqueue) synth.cancel();
        const utterance = new SpeechSynthesisUtterance(String(text || ""));
        if (o.lang) utterance.lang = o.lang;
        if (o.rate) utterance.rate = o.rate;
        if (o.pitch) utterance.pitch = o.pitch;
        if (o.volume !== undefined) utterance.volume = o.volume;
        const voice = o.voiceName && synth.getVoices().find((v) => v.name === o.voiceName);
        if (voice) utterance.voice = voice;
        const report = (type, extra) => { try { o.onEvent && o.onEvent(Object.assign({ type }, extra)); } catch (e) {} };
        utterance.onstart = () => report("start", { charIndex: 0 });
        utterance.onend = () => report("end", { charIndex: String(text || "").length });
        utterance.onerror = (event) => report(event.error === "interrupted" ? "interrupted" : "error",
          { errorMessage: event.error });
        utterance.onboundary = (event) => report("word", { charIndex: event.charIndex });
        synth.speak(utterance);
        return settle(cb, Promise.resolve());
      },
      stop: () => synth.cancel(),
      pause: () => synth.pause(),
      resume: () => synth.resume(),
      isSpeaking: (cb) => settle(cb, Promise.resolve(synth.speaking)),
      getVoices: (cb) => settle(cb, voices()),
      onVoicesChanged: makeEvent(),
    };
  }

  // === tabs.highlight — one window, one selection: the first index wins ====
  if (api.tabs && typeof api.tabs.highlight !== "function") {
    api.tabs.highlight = (info, cb) => settle(cb, (async () => {
      const indices = [].concat((info && info.tabs) ?? []);
      const query = info && info.windowId !== undefined ? { windowId: info.windowId } : { currentWindow: true };
      const tabs = await api.tabs.query(query);
      const target = tabs.find((tab) => tab.index === indices[0]);
      if (!target) throw new Error("No tab at index: " + indices[0] + ".");
      await api.tabs.update(target.id, { active: true });
      return api.windows ? api.windows.get(target.windowId, { populate: true }) : undefined;
    })());
  }

  // Artemis installs updates itself; there is never one waiting to apply
  if (typeof api.runtime.requestUpdateCheck !== "function") {
    api.runtime.requestUpdateCheck = (cb) => settle(cb, Promise.resolve({ status: "no_update" }));
  }

  // === contentScripts.register (Firefox) — onto scripting's registry ======
  if (gecko && !api.contentScripts && api.scripting
    && typeof api.scripting.registerContentScripts === "function") {
    let counter = 0;
    const files = (list) => (list || []).filter((entry) => entry && entry.file).map((entry) => entry.file);
    api.contentScripts = {
      register: (options, cb) => settle(cb, (async () => {
        const o = options || {};
        const id = "artemis-content-" + (++counter);
        await api.scripting.registerContentScripts([{
          id, matches: o.matches || [], excludeMatches: o.excludeMatches, js: files(o.js),
          css: files(o.css), allFrames: !!o.allFrames, runAt: o.runAt || "document_idle",
          matchOriginAsFallback: !!o.matchAboutBlank, persistAcrossSessions: false,
        }]);
        return { unregister: () => api.scripting.unregisterContentScripts({ ids: [id] }) };
      })()),
    };
  }

  // === userScripts — a content world of the extension's own ===============
  // a USER_SCRIPT-world script's code is written into the package and run natively in a
  // world where `chrome` is only the messaging configureWorld allows; a MAIN-world one
  // is registered as a content script. globs are checked in the file
  if (!api.userScripts && declared.includes("userScripts") && api.scripting
    && typeof api.scripting.registerContentScripts === "function") {
    const PREFIX = "artemis-user:", VERSION = 2;
    let registry = null;  // { scripts: id -> script with its files, world: { messaging } }
    // Chrome applies each call whole, in call order; here one spans many awaits
    let turn = Promise.resolve();
    const serial = (work) => {
      const run = turn.then(work);
      turn = run.catch(() => {});
      return run;
    };
    const globSource = (pattern) => "^" + String(pattern).replace(/[.+^${}()|[\]\\]/g, "\\$&")
      .replace(/\*/g, ".*").replace(/\?/g, ".") + "$";
    const wrap = (script, code) => {
      const include = (script.includeGlobs || []).map(globSource);
      const exclude = (script.excludeGlobs || []).map(globSource);
      const lines = ["artemisUserScript: {"];
      if (include.length) {
        lines.push("if (!" + JSON.stringify(include) + ".some((g) => new RegExp(g).test(location.href))) break artemisUserScript;");
      }
      if (exclude.length) {
        lines.push("if (" + JSON.stringify(exclude) + ".some((g) => new RegExp(g).test(location.href))) break artemisUserScript;");
      }
      lines.push(code, "}");
      return lines.join("\n");
    };
    const source = async (entry) => (entry.code !== undefined ? String(entry.code)
      : (await fetch(api.runtime.getURL(entry.file))).text());
    // WebKit keeps serving a content-script path's first contents: changed code needs a new name
    const digest = (text) => {
      let hash = 0x811c9dc5;
      for (let i = 0; i < text.length; i++) hash = Math.imul(hash ^ text.charCodeAt(i), 0x01000193);
      return (hash >>> 0).toString(36);
    };
    const write = async (script) => {
      const paths = [];
      for (const [index, entry] of (script.js || []).entries()) {
        const code = wrap(script, await source(entry));
        const reply = await call("userScripts.write", { name: script.id + "-" + index + "-" + digest(code), code });
        expect(reply, "Couldn't store user script " + script.id + ".");
        paths.push(reply.path);
      }
      return paths;
    };
    // native rebuilds the world from every registry it is handed
    const save = () => call("userScripts.registry",
      { set: Object.assign({ version: VERSION, order: Object.keys(registry.scripts) }, registry) });
    const load = async () => {
      if (!registry) {
        const stored = ((await call("userScripts.registry")) || {}).registry || {};
        registry = { scripts: stored.scripts || {}, world: stored.world || {} };
        if (stored.version !== VERSION && Object.keys(registry.scripts).length) {
          for (const script of Object.values(registry.scripts)) script.files = await write(script);
          await save();
        }
      }
      return registry;
    };
    const fileNames = (paths) => paths.map((path) => path.split("/").pop().replace(/\.js$/, ""));
    const asContentScript = (script) => ({
      id: PREFIX + script.id, matches: script.matches || [], excludeMatches: script.excludeMatches,
      js: script.files, allFrames: !!script.allFrames, runAt: script.runAt || "document_idle",
      world: "MAIN", persistAcrossSessions: true,
    });
    const registered = async () => (await api.scripting.getRegisteredContentScripts())
      .map((script) => script.id).filter((id) => id.startsWith(PREFIX));
    // only a MAIN-world script is a content script; whatever WebKit holds under its id goes first
    const place = async (scripts) => {
      const ids = scripts.map((script) => PREFIX + script.id);
      const stale = (await registered()).filter((id) => ids.includes(id));
      if (stale.length) await api.scripting.unregisterContentScripts({ ids: stale });
      const main = scripts.filter((script) => script.world === "MAIN");
      if (main.length) await api.scripting.registerContentScripts(main.map(asContentScript));
    };
    const visible = ({ files, ...script }) => script;
    // names a document the same in every world of its frame; native reads this same expression
    const frameKey = () => [performance.timeOrigin, (performance.getEntriesByType("navigation")[0] || {}).name, document.referrer].join("|");
    api.userScripts = {
      register: (scripts, cb) => settle(cb, serial(async () => {
        const known = (await load()).scripts;
        for (const script of scripts) {
          if (known[script.id]) throw new Error("Duplicate script ID '" + script.id + "'");
        }
        const added = [];
        for (const script of scripts) {
          added.push(known[script.id] = Object.assign({}, script, { files: await write(script) }));
        }
        await place(added);
        await save();
      })),
      update: (scripts, cb) => settle(cb, serial(async () => {
        const known = (await load()).scripts;
        const changed = [], replaced = [];
        for (const update of scripts) {
          if (!known[update.id]) throw new Error("Script with ID '" + update.id + "' does not exist.");
          const script = Object.assign({}, known[update.id], update);
          replaced.push(...(known[update.id].files || []));
          changed.push(known[script.id] = Object.assign(script, { files: await write(script) }));
        }
        await place(changed);
        await save();
        const kept = changed.flatMap((script) => script.files);
        await call("userScripts.delete", { names: fileNames(replaced.filter((file) => !kept.includes(file))) });
      })),
      unregister: (filter, cb) => settle(typeof filter === "function" ? filter : cb, serial(async () => {
        const known = (await load()).scripts;
        const wanted = filter && typeof filter === "object" && filter.ids;
        const ids = Object.keys(known).filter((id) => !wanted || wanted.includes(id));
        if (!ids.length) return;
        await place(ids.map((id) => ({ id })));
        await call("userScripts.delete", { names: ids.flatMap((id) => fileNames(known[id].files || [])) });
        ids.forEach((id) => delete known[id]);
        await save();
      })),
      getScripts: (filter, cb) => settle(typeof filter === "function" ? filter : cb, serial(() => load()).then(
        (state) => Object.values(state.scripts).map(visible)
          .filter((script) => !(filter && filter.ids) || filter.ids.includes(script.id)))),
      execute: (injection, cb) => settle(cb, (async () => {
        const o = injection || {};
        if (o.world === "MAIN") {
          const files = await write({ id: "execute-" + Date.now(), js: o.js });
          try {
            return await api.scripting.executeScript({ target: o.target, files, world: "MAIN",
              injectImmediately: !!o.injectImmediately });
          } finally {
            call("userScripts.delete", { names: fileNames(files) }).catch(() => {});
          }
        }
        const code = [];
        for (const entry of o.js || []) code.push(await source(entry));
        // the world is reached natively, which finds the tab by its main document
        const frames = await api.scripting.executeScript({ target: { tabId: o.target.tabId }, func: frameKey });
        const reply = await call("userScripts.execute", { keys: frames.map((frame) => frame.result), code });
        expect(reply, "Couldn't run the script in that tab.");
        return [{ frameId: 0, result: reply.result }];
      })()),
      configureWorld: (properties, cb) => settle(cb, serial(() => load().then((state) => {
        state.world = { messaging: !!(properties && properties.messaging) };
        return save();
      })).then(() => {})),
      getWorldConfigurations: (cb) => settle(cb, serial(() => load()).then((state) => [state.world])),
      resetWorldConfiguration: (worldId, cb) => settle(typeof worldId === "function" ? worldId : cb,
        serial(() => load().then((state) => { state.world = {}; return save(); })).then(() => {})),
    };

    // the world's messages arrive on the push port, and only once this page has said it listens.
    // WebKit hands a message posted before the port connected back to the page: it is sent again
    const announce = () => {
      openPushPort();
      if (pushPort) pushPort.postMessage({ event: "userScripts.listening" });
    };
    pushHandlers.set("userScripts.listening", announce);
    const listened = () => {
      const event = makeEvent();
      const add = event.addListener;
      event.addListener = (fn) => { add(fn); announce(); };
      return event;
    };
    const userMessage = api.runtime.onUserScriptMessage = listened();
    const userConnect = api.runtime.onUserScriptConnect = listened();
    const text = (message) => JSON.stringify(message === undefined ? null : message);
    const senders = new Map();  // frame key -> { tab, frameId }, empty when no tab shows it
    const senderOf = async (frame) => {
      if (!senders.has(frame.key)) {
        if (senders.size > 500) senders.clear();
        let found = {};
        const tabs = await api.tabs.query({});
        tabs.sort((a, b) => (b.url === frame.page) - (a.url === frame.page));
        for (const tab of tabs) {
          const hit = (await api.scripting.executeScript({ target: { tabId: tab.id, allFrames: true }, func: frameKey })
            .catch(() => [])).find((result) => result.result === frame.key);
          if (hit) { found = { tab, frameId: hit.frameId }; break; }
        }
        senders.set(frame.key, found);
      }
      return Object.assign({ id: api.runtime.id, url: frame.url, origin: new URL(frame.url).origin },
        senders.get(frame.key));
    };
    // one at a time, so a port's messages keep the order its page sent them in
    let arriving = Promise.resolve();
    const arrive = (name, handle) => pushHandlers.set(name, (message) => {
      arriving = arriving.then(() => handle(message)).catch(() => {});
    });
    const ports = new Map();
    arrive("userScripts.message", async (pushed) => {
      const sender = await senderOf(pushed.frame);
      let waits = false, answered = false;
      const respond = (value) => {
        if (answered) return;
        answered = true;
        call("userScripts.reply", value === undefined ? { id: pushed.id } : { id: pushed.id, message: text(value) });
      };
      for (const fn of userMessage._listeners) {
        try {
          const result = fn(JSON.parse(pushed.message), sender, respond);
          if (result === true) waits = true;
          else if (result && typeof result.then === "function") { waits = true; result.then(respond, () => respond()); }
        } catch (e) {}
      }
      if (!waits) respond();
    });
    arrive("userScripts.connect", async (pushed) => {
      const id = pushed.port;
      const port = { name: pushed.name, sender: await senderOf(pushed.frame),
        onMessage: makeEvent(), onDisconnect: makeEvent(),
        postMessage: (message) => { call("userScripts.port", { port: id, message: text(message) }); },
        disconnect: () => { if (ports.delete(id)) call("userScripts.port", { port: id, closed: true }); } };
      ports.set(id, port);
      userConnect._fire(port);
    });
    arrive("userScripts.port", (pushed) => {
      const port = ports.get(pushed.port);
      if (!port) return;
      if (!pushed.closed) return port.onMessage._fire(JSON.parse(pushed.message), port);
      ports.delete(pushed.port);
      port.onDisconnect._fire(port);
    });

    // a tab's user scripts hear tabs.sendMessage beside its content scripts, as in Chrome: the
    // first answer from either wins, and the call fails only when neither side listens
    if (api.tabs && typeof api.tabs.sendMessage === "function") {
      const toContent = api.tabs.sendMessage;
      api.tabs.sendMessage = (tabId, message, ...rest) => {
        const callback = typeof rest[rest.length - 1] === "function" ? rest.pop() : null;
        const frameId = (rest[0] || {}).frameId;
        const target = frameId === undefined ? { tabId, allFrames: true } : { tabId, frameIds: [frameId] };
        const toWorld = call("userScripts.tabMessage", {}).then((any) => (any && any.heard
          ? api.scripting.executeScript({ target, func: frameKey }).then((frames) => call("userScripts.tabMessage",
            { keys: frames.map((frame) => frame.result), message: text(message) }))
          : {})).catch(() => ({}));
        return settle(callback, new Promise((resolve, reject) => {
          let left = 2, heard = false, error;
          const done = (listened, answered, value, failure) => {
            if (answered) return resolve(value);
            heard = heard || listened;
            error = error || failure;
            if (--left === 0) { if (heard) resolve(); else reject(error); }
          };
          Promise.resolve().then(() => toContent.call(api.tabs, tabId, message, ...rest))
            .then((value) => done(true, value !== undefined, value), (failure) => done(false, false, undefined, failure));
          toWorld.then((reply) => done(!!(reply && reply.heard), !!reply && typeof reply.reply === "string",
            reply && typeof reply.reply === "string" ? JSON.parse(reply.reply) : undefined));
        }));
      };
    }

    // a MAIN-world registration WebKit didn't keep across a relaunch is put back, and any
    // other under the prefix is taken off
    load().then(async (state) => {
      const live = await registered();
      const main = Object.values(state.scripts).filter((script) => script.world === "MAIN");
      const missing = main.filter((script) => !live.includes(PREFIX + script.id));
      if (missing.length) await api.scripting.registerContentScripts(missing.map(asContentScript));
      const stray = live.filter((id) => !main.some((script) => PREFIX + script.id === id));
      if (stray.length) await api.scripting.unregisterContentScripts({ ids: stray });
    }).catch(() => {});
  }

  // === webNavigation same-document events, derived from tabs.onUpdated ====
  // a URL change on a tab that isn't loading is a pushState or a fragment
  // jump. tabs.onUpdated is only watched once someone subscribes
  if (api.webNavigation && api.tabs && api.tabs.onUpdated
    && !api.webNavigation.onHistoryStateUpdated) {
    const urls = new Map();
    const historyState = makeEvent(), fragment = makeEvent();
    let watching = false;
    const watch = () => {
      if (watching) return;
      watching = true;
      Promise.resolve(api.tabs.query({}))
        .then((tabs) => (tabs || []).forEach((tab) => urls.has(tab.id) || urls.set(tab.id, tab.url)),
          () => {});
      api.tabs.onUpdated.addListener((tabId, change, tab) => {
        if (!change || !change.url) return;
        const previous = urls.get(tabId);
        urls.set(tabId, change.url);
        if (change.status === "loading" || (tab && tab.status === "loading")) return;
        const details = { tabId, url: change.url, frameId: 0, parentFrameId: -1, processId: -1,
          transitionType: "link", transitionQualifiers: [], timeStamp: Date.now() };
        const page = (url) => url.split("#")[0];
        // a tab not seen before can't be a fragment jump: there's no page to compare
        (previous && page(previous) === page(change.url) ? fragment : historyState)._fire(details);
      });
      api.tabs.onRemoved && api.tabs.onRemoved.addListener((tabId) => urls.delete(tabId));
    };
    // Chrome's UrlFilter: every key in one filter must hold, any filter may match
    const matchesFilter = (filter, raw) => {
      // parsed by hand: a bare JavaScriptCore context has no URL constructor
      const parts = /^([a-z][a-z0-9+.-]*):\/\/(?:[^@/?#]*@)?(\[[^\]]*\]|[^/?#:]*)(?::\d+)?([^?#]*)(?:\?([^#]*))?/i
        .exec(String(raw));
      if (!parts) return false;
      const scheme = parts[1].toLowerCase(), host = parts[2].toLowerCase();
      const path = parts[3] || "/", query = parts[4] || "";
      const tests = {
        hostContains: (v) => host.includes(v), hostEquals: (v) => host === v,
        hostPrefix: (v) => host.startsWith(v), hostSuffix: (v) => host.endsWith(v),
        pathContains: (v) => path.includes(v), pathEquals: (v) => path === v,
        pathPrefix: (v) => path.startsWith(v), pathSuffix: (v) => path.endsWith(v),
        queryContains: (v) => query.includes(v), queryEquals: (v) => query === v,
        queryPrefix: (v) => query.startsWith(v), querySuffix: (v) => query.endsWith(v),
        urlContains: (v) => raw.includes(v), urlEquals: (v) => raw === v,
        urlPrefix: (v) => raw.startsWith(v), urlSuffix: (v) => raw.endsWith(v),
        urlMatches: (v) => new RegExp(v).test(raw),
        schemes: (v) => v.includes(scheme),
      };
      return Object.entries(filter).every(([key, value]) => !tests[key] || tests[key](value));
    };
    const filtered = (event) => {
      const wrappers = new Map();
      return {
        addListener: (fn, filter) => {
          const urlFilters = filter && Array.isArray(filter.url) ? filter.url : null;
          const wrapper = urlFilters
            ? (details) => { if (urlFilters.some((f) => matchesFilter(f, details.url))) fn(details); }
            : fn;
          wrappers.set(fn, wrapper);
          event.addListener(wrapper);
          watch();
        },
        removeListener: (fn) => { event.removeListener(wrappers.get(fn) || fn); wrappers.delete(fn); },
        hasListener: (fn) => wrappers.has(fn),
        hasListeners: () => wrappers.size > 0,
      };
    };
    api.webNavigation.onHistoryStateUpdated = filtered(historyState);
    api.webNavigation.onReferenceFragmentUpdated = filtered(fragment);
  }

  // === 3. Chrome's enums, constants and events, where WebKit lacks them ====
  // read at boot (`runtime.OnInstalledReason.INSTALL`), a missing one throws.
  // the events never fire; functions are never stubbed, only implemented
  const inertEvent = () => ({
    addListener() {}, removeListener() {}, hasListener: () => false, hasListeners: () => false,
  });
  // a namespace the manifest declares that WebKit can't provide at all (debugger,
  // tabCapture…) gets its enums and inert events, so registering a listener at
  // boot doesn't kill the extension. no functions: a stub would pass a feature check
  for (const [path, entry] of Object.entries(/*@gaps*/{})) {
    let ns = api;
    for (const key of path.split(".")) ns = ns && ns[key];
    if (!ns || typeof ns !== "object") {
      const root = path.split(".")[0];
      if (!declared.includes(path) && !declared.includes(root) && !(root === "omnibox" && manifest.omnibox)) continue;
      ns = api;
      for (const key of path.split(".")) {
        if (!ns[key] || typeof ns[key] !== "object") ns[key] = {};
        ns = ns[key];
      }
    }
    for (const [name, values] of Object.entries(entry.enums || {})) {
      if (!(name in ns)) ns[name] = Object.freeze(values);
    }
    for (const [name, value] of Object.entries(entry.consts || {})) {
      if (!(name in ns)) ns[name] = value;
    }
    for (const name of entry.events || []) {
      if (!(name in ns)) ns[name] = inertEvent();
    }
  }
  // WebKit reports an empty url for a blank tab (about:blank is outside every host
  // permission); Chrome says "about:blank" to an extension that may see tab URLs
  if (api.tabs && (declared.includes("tabs") || (manifest.host_permissions || []).length
      || declared.some((p) => p.includes("://") || p === "<all_urls>"))) {
    const blank = (tab) => {
      if (tab && typeof tab === "object" && tab.url === "") tab.url = "about:blank";
      return tab;
    };
    const proto = Object.getPrototypeOf(api.tabs);
    for (const [name, fix] of [["query", (tabs) => (Array.isArray(tabs) ? tabs.map(blank) : tabs)],
      ["get", blank], ["getCurrent", blank]]) {
      const original = proto && proto[name];
      if (typeof original !== "function") continue;
      const fixed = function (...args) {
        const cb = typeof args[args.length - 1] === "function" ? args.pop() : null;
        return settle(cb, Promise.resolve(original.apply(this, args)).then(fix));
      };
      try {
        Object.defineProperty(keep(proto), name, { value: fixed, writable: true, configurable: true });
      } catch (e) {}
      // the detached-method fix put a bound copy of the original on the instance
      if (Object.prototype.hasOwnProperty.call(api.tabs, name)) api.tabs[name] = fixed.bind(api.tabs);
    }
    const tabArg = { onCreated: 0, onUpdated: 2 };
    hookEvents("tabs", (name, event) => {
      if (!(name in tabArg) || typeof event.addListener !== "function") return null;
      const { addListener, removeListener, hasListener } = event;
      const wrapped = new WeakMap();
      const wrap = (fn) => {
        if (typeof fn !== "function") return fn;
        if (!wrapped.has(fn)) wrapped.set(fn, function (...args) {
          blank(args[tabArg[name]]);
          return fn.apply(this, args);
        });
        return wrapped.get(fn);
      };
      return {
        addListener: (fn, ...rest) => addListener.call(event, wrap(fn), ...rest),
        removeListener: (fn) => removeListener.call(event, wrapped.get(fn) || fn),
        hasListener: (fn) => hasListener.call(event, wrapped.get(fn) || fn),
      };
    });
  }
  // Chrome and Firefox give a popup or a background no current tab; WebKit hands them the
  // active one (Proton Pass lays its popup out as a full tab when it gets one)
  if (api.tabs && typeof api.tabs.getCurrent === "function") {
    const original = api.tabs.getCurrent;
    const tabless = () => {
      if (typeof document === "undefined") return true;
      try {
        return api.extension.getViews({ type: "popup" }).includes(globalThis)
          || api.extension.getBackgroundPage() === globalThis;
      } catch (e) { return false; }
    };
    try {
      api.tabs.getCurrent = (cb) => settle(cb, tabless() ? Promise.resolve() : Promise.resolve(original.call(api.tabs)));
    } catch (e) {}
  }
  // there is no keyword mode for a default suggestion to show in
  if (api.omnibox && typeof api.omnibox.setDefaultSuggestion !== "function") {
    api.omnibox.setDefaultSuggestion = (suggestion, cb) => settle(cb, Promise.resolve());
  }
  // Firefox's menu-shown events never fire: Artemis builds its menu without telling
  // extensions, so a refresh has nothing to redo
  if (api.menus) {
    for (const name of ["onShown", "onHidden"]) if (!(name in api.menus)) api.menus[name] = inertEvent();
    if (typeof api.menus.refresh !== "function") api.menus.refresh = (cb) => settle(cb, Promise.resolve());
  }
  // Firefox's badge text colour: Artemis draws badges in one colour
  for (const action of gecko ? [api.action, api.browserAction] : []) {
    if (!action || typeof action.setBadgeTextColor === "function") continue;
    action.setBadgeTextColor = (details, cb) => settle(cb, Promise.resolve());
    action.getBadgeTextColor = (details, cb) => settle(cb, Promise.resolve([255, 255, 255, 255]));
  }
  // Firefox's theme API with nothing themed: Artemis has no Firefox themes
  if (gecko && !api.theme) {
    api.theme = { getCurrent: (windowId, cb) => settle(typeof windowId === "function" ? windowId : cb,
      Promise.resolve({ colors: null, images: null, properties: null })), onUpdated: inertEvent() };
  }
  // answered as Firefox does with containers turned off
  if (!api.contextualIdentities && declared.includes("contextualIdentities")) {
    const disabled = () => Promise.reject(new Error("Contextual identities are currently disabled"));
    api.contextualIdentities = {
      query: disabled, get: disabled, create: disabled, update: disabled, remove: disabled, move: disabled,
      onCreated: inertEvent(), onUpdated: inertEvent(), onRemoved: inertEvent(),
    };
  }

  if ((api.proxy && api.proxy.settings)
    || !(declared.includes("proxy") || declared.includes("privacy"))) return;

  // --- ChromeSetting emulation (chrome.types.ChromeSetting) -------------
  // native owns the truth; a local cache answers get() when native is slow.
  const makeSetting = (name, defaultValue) => {
    let cached = { value: defaultValue, levelOfControl: "controllable_by_this_extension" };
    const onChange = makeEvent();
    const finish = (cb, result) => { if (typeof cb === "function") cb(result); return Promise.resolve(result); };
    return {
      onChange,
      get(details, cb) {
        if (typeof details === "function") { cb = details; details = {}; }
        return call("setting.get", { name })
          .then((r) => { if (r && r.value !== undefined) cached = r; return finish(cb, Object.assign({}, cached)); })
          .catch(() => finish(cb, Object.assign({}, cached)));
      },
      set(details, cb) {
        const value = details && details.value;
        return call("setting.set", { name, value, scope: details && details.scope })
          .catch(() => {})
          .then(() => {
            cached = { value, levelOfControl: "controlled_by_this_extension" };
            onChange._fire(Object.assign({}, cached));
            if (name === "proxy") solicitProxyCredentials(value);
            return finish(cb, undefined);
          });
      },
      clear(details, cb) {
        if (typeof details === "function") { cb = details; details = {}; }
        return call("setting.clear", { name, scope: details && details.scope })
          .catch(() => {})
          .then(() => {
            cached = { value: defaultValue, levelOfControl: "controllable_by_this_extension" };
            onChange._fire(Object.assign({}, cached));
            return finish(cb, undefined);
          });
      },
    };
  };

  // --- chrome.proxy ----------------------------------------------------
  if (declared.includes("proxy")) {
    api.proxy = {
      settings: makeSetting("proxy", { mode: "system" }),
      onProxyError: makeEvent(),   // native has no push channel yet; inert
      onError: makeEvent(),        // firefox alias some bundles fall back to
    };
  }

  // --- Firefox proxy.onRequest -----------------------------------------
  // Firefox asks the extension per request; WebKit takes one proxy per data
  // store. the handlers answer for a representative request, that answer is
  // applied as a fixed proxy, and they are asked again whenever it may move
  if (gecko && declared.includes("proxy")) {
    const handlers = [];
    let applied = "", polling = null;
    const sample = () => ({ requestId: "artemis", url: "https://www.example.com/", method: "GET",
      type: "main_frame", tabId: -1, frameId: 0, parentFrameId: -1, incognito: false,
      thirdParty: false, fromCache: false, timeStamp: Date.now() });
    const credentialsOf = (info) => {
      if (info.username) return { username: info.username, password: info.password || "" };
      const basic = /^Basic\s+(.+)$/i.exec(info.proxyAuthorizationHeader || "");
      if (!basic) return null;
      try {
        const [username, ...rest] = atob(basic[1]).split(":");
        return { username, password: rest.join(":") };
      } catch (e) { return null; }
    };
    const resolve = async () => {
      if (!handlers.length && !applied) return;
      let info = null;
      for (const handler of handlers.slice()) {
        try { info = await handler(sample()); } catch (e) {}
        if (Array.isArray(info)) info = info[0];
        if (info) break;
      }
      const proxied = info && info.type && info.type !== "direct" && info.host;
      const value = proxied ? { mode: "fixed_servers", rules: { singleProxy: {
        scheme: info.type === "socks" ? "socks5" : info.type, host: info.host, port: Number(info.port),
      } } } : null;
      const key = JSON.stringify(value);
      if (key === applied) return;
      applied = key;
      if (!value) return call("setting.clear", { name: "proxy" }).catch(() => {});
      const credentials = credentialsOf(info);
      if (credentials) await call("proxy.credentials", credentials).catch(() => {});
      await call("setting.set", { name: "proxy", value }).catch(() => {});
    };
    api.proxy.onRequest = {
      addListener: (fn) => {
        if (!handlers.includes(fn)) handlers.push(fn);
        if (!polling) polling = setInterval(resolve, 5000);
        resolve();
      },
      removeListener: (fn) => {
        const index = handlers.indexOf(fn);
        if (index >= 0) handlers.splice(index, 1);
        if (!handlers.length && polling) { clearInterval(polling); polling = null; }
        resolve();
      },
      hasListener: (fn) => handlers.includes(fn),
      hasListeners: () => handlers.length > 0,
    };
    if (api.storage && api.storage.onChanged) api.storage.onChanged.addListener(() => resolve());
  }

  // --- chrome.privacy ---------------------------------------------------
  if (declared.includes("privacy")) {
    api.privacy = api.privacy || {};
    api.privacy.network = api.privacy.network || {};
    api.privacy.network.webRTCIPHandlingPolicy = makeSetting("webRTCIPHandlingPolicy", "default");
    api.privacy.network.peerConnectionEnabled = makeSetting("peerConnectionEnabled", true);
    api.privacy.services = api.privacy.services || {};
    // password managers flip these to disable a built-in password manager;
    // Artemis doesn't have one, so an inert setting is the truthful answer
    if (!api.privacy.services.passwordSavingEnabled) {
      api.privacy.services.passwordSavingEnabled = makeSetting("passwordSavingEnabled", false);
    }
    if (!api.privacy.services.autofillAddressEnabled) {
      api.privacy.services.autofillAddressEnabled = makeSetting("autofillAddressEnabled", false);
    }
    api.privacy.websites = api.privacy.websites || {};
  }

  // --- proxy credentials (webRequest.onAuthRequired) ---------------------
  // WebKit fires onAuthRequired observationally and IGNORES listener return
  // values, so an extension can never answer a 407 through it. the shim
  // keeps its own listener list, and when a proxy config lands it invokes
  // the handler with a synthetic proxy challenge (asyncBlocking-style) and
  // ships the credentials to native, which bakes them into the proxy config.
  const authListeners = [];
  let pendingProxyValue = null;

  // Replace onAuthRequired with a STABLE event object we own. WebKit
  // exposes it via a getter that mints a fresh wrapper on every access,
  // so hooking the per-access object's addListener patches a throwaway —
  // the extension's real registration lands on a different object and we
  // never see it (creds=false, every CONNECT 407s, macOS shows its own
  // proxy-password dialog). Installing a stable object on the webRequest
  // namespace (which IS stable/assignable, unlike its event getters)
  // means every access — the extension's included — returns ours.
  if (declared.includes("proxy")) try {
    const wr = api.webRequest;
    if (wr) {
      // capture the real event once, for observational continuity
      let realEvent = null;
      try { realEvent = wr.onAuthRequired; } catch (e) {}
      // capture the originals BEFORE patching: strategy (a) overwrites
      // realEvent.addListener with ours, so a dynamic lookup here would
      // call us back — infinite recursion (34,879 registrations deep on
      // the first run that got this far)
      const origAdd = realEvent && typeof realEvent.addListener === "function"
        ? realEvent.addListener.bind(realEvent) : null;
      const origRemove = realEvent && typeof realEvent.removeListener === "function"
        ? realEvent.removeListener.bind(realEvent) : null;
      const stableAuth = {
        addListener: (fn, filter, extraInfoSpec) => {
          if (authListeners.indexOf(fn) >= 0) return;  // idempotent
          authListeners.push(fn);
          try { origAdd && origAdd(fn, filter); } catch (e) {}
          report("auth", "listener registered (" + authListeners.length + ")");
          if (pendingProxyValue) solicitProxyCredentials(pendingProxyValue);
        },
        removeListener: (fn) => {
          const i = authListeners.indexOf(fn);
          if (i >= 0) authListeners.splice(i, 1);
          try { origRemove && origRemove(fn); } catch (e) {}
        },
        hasListener: (fn) => authListeners.indexOf(fn) >= 0,
      };
      // Redefining the real property is refused: WebKit exposes
      // onAuthRequired as a non-writable data property whose bindings
      // reject redefinition (the descriptor claims configurable, and
      // defineProperty still doesn't take). The event object itself IS
      // stable, so patch its addListener first; if that's locked too,
      // shadow the whole webRequest namespace on the api object — the
      // level that already accepts our method shadowing.
      let installed = false;
      let how = "none";

      // (a) patch the stable event object's addListener
      try {
        if (realEvent) {
          Object.defineProperty(realEvent, "addListener", {
            value: stableAuth.addListener, configurable: true, writable: true });
          Object.defineProperty(realEvent, "removeListener", {
            value: stableAuth.removeListener, configurable: true, writable: true });
          installed = realEvent.addListener === stableAuth.addListener;
          if (installed) how = "event.addListener";
        }
      } catch (e) {}

      // (b) shadow the namespace with a proxy that hands out our event
      // object; every other member stays bound to the real namespace
      if (!installed) {
        try {
          const wrProxy = new Proxy(wr, {
            get(target, prop, receiver) {
              if (prop === "onAuthRequired") return stableAuth;
              const value = Reflect.get(target, prop, target);
              return typeof value === "function" ? value.bind(target) : value;
            },
          });
          try {
            Object.defineProperty(api, "webRequest", {
              value: wrProxy, configurable: true, writable: true, enumerable: true });
          } catch (e) { api.webRequest = wrProxy; }
          installed = api.webRequest.onAuthRequired === stableAuth;
          if (installed) how = "namespace proxy";
        } catch (e) { how = "proxy threw: " + (e && e.message); }
      }

      if (!installed) {
        // report exactly HOW it refused, so the next attempt isn't a guess
        let why = "unknown";
        try {
          const own = Object.getOwnPropertyDescriptor(wr, "onAuthRequired");
          const proto = Object.getOwnPropertyDescriptor(
            Object.getPrototypeOf(wr) || {}, "onAuthRequired");
          const d = own || proto;
          why += "onWr=" + !!own + " onProto=" + !!proto
            + " configurable=" + (d && d.configurable)
            + " hasGet=" + !!(d && d.get) + " hasSet=" + !!(d && d.set)
            + " writable=" + (d && d.writable)
            + " frozen=" + Object.isFrozen(wr)
            + " extensible=" + Object.isExtensible(wr)
            + " stableEvent=" + (wr.onAuthRequired === wr.onAuthRequired);
        } catch (e) { why = "probe threw: " + e.message; }
        report("auth", "onAuthRequired hook FAILED to install — " + why);
      } else {
        report("auth", "onAuthRequired hook installed via " + how);
      }
    } else {
      report("auth", "no webRequest namespace");
    }
  } catch (e) { report("auth", "hook threw: " + (e && e.message)); }

  const proxyServerOf = (value) => {
    const rules = value && value.rules;
    return rules && (rules.singleProxy || rules.proxyForHttps || rules.fallbackProxy);
  };

  function solicitProxyCredentials(value) {
    const server = proxyServerOf(value);
    if (!server) { pendingProxyValue = null; return; }
    if (!authListeners.length) {
      report("auth", "no auth listeners yet, holding solicitation");
      pendingProxyValue = value;
      return;  // retried when one registers
    }
    report("auth", "soliciting credentials for " + server.host + " from " + authListeners.length + " listener(s)");
    pendingProxyValue = null;
    const details = {
      // unique per solicitation: their handler keeps a retry count keyed
      // on requestId and cancels past the second attempt, so a constant id
      // would poison every reconnect after the first
      requestId: "artemis-proxy-preflight-" + Date.now(),
      url: (server.scheme || "https") + "://" + server.host + ":" + (server.port || 443) + "/",
      method: "CONNECT",
      isProxy: true,
      challenger: { host: server.host, port: server.port || 443 },
      scheme: "basic",
      realm: "",
      statusCode: 407,
      statusLine: "HTTP/1.1 407 Proxy Authentication Required",
      responseHeaders: [],
      frameId: 0, parentFrameId: -1, tabId: -1, type: "other",
      timeStamp: Date.now(),
    };
    const deliver = (result) => {
      const creds = result && result.authCredentials;
      if (creds && creds.username !== undefined) {
        report("auth", "credentials obtained, forwarding");
        call("proxy.credentials", { username: String(creds.username), password: String(creds.password || "") }).catch(() => {});
      }
    };
    // an asyncBlocking handler delivers through the CALLBACK and its own
    // promise resolves to undefined (Surfshark's is exactly
    // `async (d, cb) => { if (!cb) return di(d); di(d).then(cb) }`), so
    // watch both paths and take whichever actually yields credentials
    let settled = false;
    const consider = (result) => {
      if (settled) return;
      const creds = result && result.authCredentials;
      if (!(creds && creds.username !== undefined)) return;
      settled = true;
      deliver(result);
    };
    for (const fn of authListeners.slice()) {
      try {
        let returned;
        const fromCallback = new Promise((resolve) => {
          returned = fn(details, resolve);
        });
        Promise.resolve(fromCallback).then(consider).catch(() => {});
        if (returned !== undefined) {
          Promise.resolve(returned).then(consider).catch(() => {});
        }
      } catch (e) { console.error("[artemis-compat] auth listener", e); }
    }
    setTimeout(() => {
      if (!settled) report("auth", "no credentials delivered within 10s");
    }, 10000);
  }

  // @content-resume
  } catch (e) {
    // a compat-layer failure must never be the extension's problem: log
    // and let it run exactly as it would have without us
    try { console.error("[artemis-compat] shim failed:", e && e.message); } catch (e2) {}
  }
})();
