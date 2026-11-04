// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation
import WebKit

/// a save or update waiting on the url pill's key, raised only by the person submitting a login
struct LoginOffer: Identifiable {
    let id = UUID()
    let origin: String
    let username: String
    let password: String
    /// the saved login this would overwrite
    let replacing: SavedLogin?
    let at = Date()
    /// the key's popover has opened for it once
    var shown = false

    var host: String { URL(string: origin)?.host() ?? origin }
}

/// a submitted login that hasn't yet shown it signed in
struct LoginCandidate {
    let origin: String
    let topOrigin: String
    let username: String
    let password: String
    let isNew: Bool
    /// the current-password field's value on a change-password form
    let current: String
    let at = Date()
}

/// The frame a fill lands in, fixed when the suggestion list, key popover or command is built.
/// `frame` nil is the main frame.
struct LoginTarget {
    let frame: WKFrameInfo?
    let origin: String
    /// chosen by the person focusing a field in it, which no form report can displace
    let focused: Bool
}

/// what both apps share of password autofill: the script that watches login forms in every frame
/// from an isolated world, how it talks back, and the strong passwords it fills
enum PasswordPage {
    static let world = WKContentWorld.world(name: "Artemis.Passwords")
    static let messageName = "artemisPasswords"
    /// CSS pixels a field must show, each way, inside every viewport it can be measured in
    static let minimumShown = 10

    /// 20 characters, or as near as `rules` allow, of unambiguous letters and digits with one symbol
    /// inside, from `!#$@` (the ones sites that restrict symbols most often accept) or what the rules name
    static func strongPassword(_ rules: PasswordRules = PasswordRules(), symbols: Bool = true) -> String {
        let letters = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789".filter(rules.isAllowed))
        let named = (rules.required.flatMap { $0 } + rules.allowed).filter { $0.hasPrefix("[") }
        // a page's classes may name any characters; only the ASCII symbols a keyboard types are drawn
        let marks = Array(
            Set("!#$@" + named.map { $0.dropFirst().dropLast() }.joined())
                .filter { $0.isASCII && ($0.isPunctuation || $0.isSymbol) && rules.isAllowed($0) })
        let unmetByLetters = rules.required.filter { group in
            !letters.contains { c in group.contains { PasswordRules.matches(c, $0) } }
        }
        let symbolCount = marks.isEmpty ? 0 : max(unmetByLetters.count, symbols ? 1 : 0)
        let length = min(max(20, rules.minLength), rules.maxLength)
        var password = ""
        // the system generator is a CSPRNG on Apple platforms
        for _ in 0..<1000 where !letters.isEmpty && length > 2 {
            var chars = (0..<length).map { _ in letters.randomElement()! }
            for _ in 0..<min(symbolCount, length - 2) { chars[1 + Int.random(in: 0..<(length - 2))] = marks.randomElement()! }
            password = String(chars)
            let mixed = rules.required.isEmpty
                ? ["lower", "upper", "digit"].allSatisfy { kind in password.contains { PasswordRules.matches($0, kind) } }
                : true
            if mixed, rules.problem(with: password) == nil { return password }
        }
        return password
    }

    /// args `pattern` (a field's own `pattern`) and `candidates`: which of them it accepts, compiled
    /// once per page and run in the page's process, where WebKit can stop a runaway pattern
    static let patternFits = """
        const cache = globalThis.__artemisPatterns ??= new Map();
        if (!cache.has(pattern)) {
          let made = null;
          for (const flag of ["v", "u"]) { try { made = new RegExp("^(?:" + pattern + ")$", flag); break; } catch (e) {} }
          cache.set(pattern, made);
        }
        const compiled = cache.get(pattern);
        return candidates.map(c => !compiled || compiled.test(c));
        """

    static let source = """
    (() => {
      if (globalThis.__artemisPasswords) return;
      const post = m => { try { webkit.messageHandlers.\(messageName).postMessage(m); } catch (e) {} };
      const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set;
      const visible = el => !el.disabled && el.type !== "hidden" && el.offsetWidth > 1 && el.offsetHeight > 1
        && (el.checkVisibility?.({ opacityProperty: true, visibilityProperty: true }) ?? true);
      const texty = el => el instanceof HTMLInputElement && ["text", "email", "tel"].includes(el.type) && visible(el);
      const has = (el, token) => (el.getAttribute("autocomplete") || "").toLowerCase().split(/\\s+/).includes(token);
      const root = el => el.form || el.closest("form,[role=form]") || document.body;
      const passwords = r => [...r.querySelectorAll("input[type=password]")].filter(visible);
      // a verification-code field is tagged, or named like one and shaped for a short number
      const codeName = /one.?time|otp|mfa|2fa|two.?factor|verif|passcode|security.?code|auth\\w*.?code|sms.?code/i;
      const notCode = /post|zip|promo|coupon|discount|gift|voucher|referr|country|area|captcha/i;
      function codeField(el) {
        if (!(el instanceof HTMLInputElement) || !["text", "tel", "number"].includes(el.type) || !visible(el)) return false;
        if (has(el, "one-time-code")) return true;
        const label = [el.name, el.id, el.placeholder, el.getAttribute("aria-label")].join(" ");
        if (notCode.test(label)) return false;
        const short = el.maxLength === 1 || (el.maxLength >= 4 && el.maxLength <= 8) || el.inputMode === "numeric";
        return codeName.test(label) || (/code|pin|token/i.test(label) && short);
      }

      // new-password fields are tagged, or are every field but a leading current one
      function roles(r) {
        const all = passwords(r), tagged = all.filter(p => has(p, "new-password"));
        if (tagged.length) return { current: all.find(p => !tagged.includes(p)) ?? null, fresh: tagged };
        if (all.length >= 3) return { current: all[0], fresh: all.slice(1) };
        if (all.length === 2) return has(all[0], "current-password")
          ? { current: all[0], fresh: [all[1]] } : { current: null, fresh: all };
        return { current: all[0] ?? null, fresh: [] };
      }
      function username(r, anchor) {
        const inputs = [...r.querySelectorAll("input")].filter(i => texty(i) && !codeField(i));
        const hinted = inputs.find(i => has(i, "username")) ?? inputs.find(i => i.type === "email" || has(i, "email"));
        if (hinted) return hinted;
        if (!anchor) return inputs.find(i => /user|login|email|account|ident/i.test(i.name + " " + i.id)) ?? null;
        const before = inputs.filter(i => i.compareDocumentPosition(anchor) & Node.DOCUMENT_POSITION_FOLLOWING);
        return before[before.length - 1] ?? null;
      }
      function rect(el) {
        const b = el.getBoundingClientRect();
        let x = b.left, y = b.top, w = window;
        while (w !== w.top) {
          let frame = null;
          try { frame = w.frameElement; } catch (e) {}
          if (!frame) break;
          const f = frame.getBoundingClientRect();
          x += f.left + frame.clientLeft;
          y += f.top + frame.clientTop;
          w = w.parent;
        }
        return { x, y, width: b.width, height: b.height, resolved: w === w.top };
      }
      // what the suggestion list offers in a field, or null when it serves none; `seen` keeps each
      // form's roles for a pass over many fields
      function kind(t, seen = new Map()) {
        const r = root(t);
        if (!seen.has(r)) {
          const { current, fresh } = roles(r);
          seen.set(r, { current, fresh, user: username(r, current ?? fresh[0] ?? null) });
        }
        const { current, fresh, user } = seen.get(r);
        return codeField(t) ? "code" : fresh.includes(t) ? "new" : t === current ? "password"
          : texty(t) && t === user ? "username" : null;
      }

      // `listed` rows are shown under the open field, which ↑ and ↓ walk to `chosen`
      let field = null, open = false, scrolledPosted = false, gesture = 0, filling = false, sentAt = 0, watcher = 0;
      let listed = 0, chosen = -1;
      function offer(t) {
        if (filling || !(t instanceof HTMLInputElement) || !visible(t)) return;
        const k = kind(t);
        if (!k) return;
        field = t;
        open = true;
        scrolledPosted = false;
        listed = 0;
        chosen = -1;
        const rules = k === "new"
          ? { min: t.minLength, max: t.maxLength, rules: t.getAttribute("passwordrules") ?? "", pattern: t.pattern } : null;
        post({ type: "focus", kind: k, rect: rect(t), rules });
      }
      // a scroll moves the field without blurring it: the field stays open and the post, made once
      // per open field, says `scrolled`
      function dismiss(e) {
        if (!open) return;
        const scrolled = e?.type === "scroll";
        if (scrolled && scrolledPosted) return;
        if (scrolled) scrolledPosted = true; else { open = false; listed = 0; }
        post({ type: "dismiss", scrolled });
      }
      function watch(pw) {
        clearInterval(watcher);
        const until = Date.now() + 45000;
        watcher = setInterval(() => {
          if (Date.now() > until) return clearInterval(watcher);
          if (pw.isConnected && visible(pw)) return;
          clearInterval(watcher);
          post({ type: "gone" });
        }, 500);
      }
      function submitted(r) {
        if (Date.now() - sentAt < 500) return;
        const { current, fresh } = roles(r);
        const pw = fresh.length ? fresh[fresh.length - 1] : current;
        const user = username(r, current ?? fresh[0] ?? null);
        if (pw?.value) {
          sentAt = Date.now();
          post({ type: "submit", username: user?.value ?? "", password: pw.value, isNew: fresh.length > 0,
            current: fresh.length && current ? current.value : "" });
          watch(pw);
        } else if (!pw && user?.value) {
          sentAt = Date.now();
          post({ type: "username", username: user.value });
        }
      }
      function put(el, value) {
        el.focus();
        setter.call(el, value);
        el.dispatchEvent(new InputEvent("input",
          { bubbles: true, composed: true, inputType: "insertReplacementText", data: value }));
        el.dispatchEvent(new Event("change", { bubbles: true }));
      }

      // suggestions answer the person: a click, keyboard focus straight after a key press, or ↓ in a field
      addEventListener("keydown", e => {
        if (!e.isTrusted) return;
        gesture = Date.now();
        if (e.key === "ArrowDown" && !open && e.target instanceof HTMLInputElement && kind(e.target)) {
          offer(e.target);
          if (open) e.preventDefault();
          return;
        }
        const stop = () => { e.preventDefault(); e.stopPropagation(); };
        const listening = e.target === field && open && listed;
        if (listening && (e.key === "ArrowDown" || e.key === "ArrowUp")) {
          stop();
          chosen = e.key === "ArrowDown" ? Math.min(chosen + 1, listed - 1) : Math.max(chosen - 1, 0);
          return post({ type: "highlight", index: chosen });
        }
        if (listening && e.key === "Enter" && chosen >= 0) {
          stop();
          post({ type: "pick", index: chosen });
          open = false;
          listed = 0;
          return;
        }
        if (listening && e.key === "Escape") stop();
        if (e.target === field && e.key !== "Tab" && e.key !== "Shift") dismiss();
        if (e.key === "Enter" && e.target instanceof HTMLInputElement) submitted(root(e.target));
      }, true);
      addEventListener("focusin", e => { if (e.isTrusted && Date.now() - gesture < 300) offer(e.target); }, true);
      addEventListener("focusout", e => { if (e.target === field) dismiss(); }, true);
      addEventListener("blur", e => { if (e.target === window) dismiss(); });
      addEventListener("scroll", dismiss, { capture: true, passive: true });
      addEventListener("click", e => {
        const t = e.target;
        if (!e.isTrusted || !(t instanceof Element)) return;
        if (t instanceof HTMLInputElement && !["submit", "image", "button"].includes(t.type)) return offer(t);
        const button = t.closest("button,input[type=submit],input[type=image],input[type=button],[role=button]");
        if (button) submitted(root(button));
      }, true);
      addEventListener("submit", e => { if (e.isTrusted) submitted(e.target); }, true);
      addEventListener("pagehide", () => {
        if (window !== top && Date.now() - sentAt < 45000) post({ type: "gone" });
        if (keyKinds) post({ type: "keys", keys: null });
      });

      let reported = false, timer = 0;
      const scan = () => {
        timer = 0;
        const all = passwords(document);
        if (reported || !all.length) return;
        reported = true;
        observer.disconnect();
        post({ type: "fields", fresh: all.some(p => roles(root(p)).fresh.includes(p)) });
      };
      const observer = new MutationObserver(() => { timer ||= setTimeout(scan, 400); });
      const start = () => {
        scan();
        if (!reported) observer.observe(document.documentElement, { childList: true, subtree: true,
          attributes: true, attributeFilter: ["type", "style", "class", "hidden"] });
      };
      if (document.readyState === "loading") addEventListener("DOMContentLoaded", start, { once: true });
      else start();

      // Keys: native buttons over the empty fields the list serves, reported once native turns them on
      // for this document. This world only measures; an element reaches native as an id kept here.
      // `keySize` is a key's side in CSS px, and `shade` keeps each field's onDark until the page restyles.
      let keyKinds = null, keySize = 22, keyTimer = 0, keyPoll = 0, lastKeys = "", keyCount = 0, movedAt = 0;
      let paint = null, keyIDs = new WeakMap(), shade = new WeakMap();
      const keyed = new Map();
      const keysSoon = ms => { if (keyKinds) keyTimer ||= setTimeout(keys, ms); };
      const restyled = () => { shade = new WeakMap(); keysSoon(150); };
      const stopPoll = () => { clearInterval(keyPoll); keyPoll = 0; };
      const resized = new ResizeObserver(() => keysSoon(150));
      const reshaped = new MutationObserver(restyled);
      // whether a click at (x, y) of this viewport reaches `el`, through every same-origin parent
      function topmost(el, x, y) {
        let w = window, hit = el;
        for (;;) {
          if (w.document.elementFromPoint(x, y) !== hit) return false;
          let frame = null;
          try { frame = w.frameElement; } catch (e) {}
          if (!frame) return true;
          const f = frame.getBoundingClientRect();
          x += f.left + frame.clientLeft;
          y += f.top + frame.clientTop;
          hit = frame;
          w = w.parent;
        }
      }
      // the key's centre as an offset from the field's left, and its side: at the field's end (its left
      // when right-to-left), stepping inward past the site's own controls there; null once that would
      // cover the field's far half
      function keyAt(el) {
        const b = el.getBoundingClientRect(), y = b.top + b.height / 2, mid = b.left + b.width / 2;
        const size = Math.min(keySize, b.height), dir = getComputedStyle(el).direction === "rtl" ? -1 : 1;
        for (let x = dir > 0 ? b.right - 4 - size / 2 : b.left + 4 + size / 2; (x - mid) * dir >= size / 2; x -= dir * size) {
          if ([x - size / 2 + 1, x, x + size / 2 - 1].every(p => topmost(el, p, y))) return { x: x - b.left, size };
        }
        return null;
      }
      // whether the field sits on a dark background: the nearest opaque one, else the opposite of its
      // text; a canvas reads every colour syntax a computed style keeps
      function onDark(el) {
        paint ??= new OffscreenCanvas(1, 1).getContext("2d", { willReadFrequently: true });
        const luma = c => {
          paint.clearRect(0, 0, 1, 1);
          paint.fillStyle = "transparent";
          paint.fillStyle = c;
          paint.fillRect(0, 0, 1, 1);
          const [r, g, b, a] = paint.getImageData(0, 0, 1, 1).data;
          return a >= 128 ? 0.2126 * r + 0.7152 * g + 0.0722 * b : null;
        };
        for (let n = el; n; n = n.parentElement) {
          const l = luma(getComputedStyle(n).backgroundColor);
          if (l !== null) return l < 128;
        }
        return luma(getComputedStyle(el).color) >= 128;
      }
      // the fields a key could serve; a code split across one-digit boxes fills from any of them, so
      // only its first box counts
      function candidates() {
        const found = [], seen = new Map(), boxed = new Set();
        for (const el of document.querySelectorAll("input")) {
          if (!["password", "text", "email", "tel", "number"].includes(el.type)) continue;
          const k = kind(el, seen);
          if (!keyKinds.includes(k)) continue;
          if (k === "code" && el.maxLength === 1) {
            if (boxed.has(root(el))) continue;
            boxed.add(root(el));
          }
          found.push(el);
        }
        return found;
      }
      // a frame that can't see where it sits in the page posts every pass, for native to place it again;
      // shown keys are measured again every 300 ms while the page is visible, and a hidden page posts nothing
      function keys() {
        keyTimer = 0;
        if (document.hidden) return stopPoll();
        for (const [id, ref] of keyed) {
          const el = ref.deref();
          if (el?.isConnected) continue;
          keyed.delete(id);
          if (el) { resized.unobserve(el); keyIDs.delete(el); }
        }
        const list = [];
        for (const el of candidates()) {
          const at = !el.value && keyAt(el);
          if (!at) continue;
          let id = keyIDs.get(el);
          if (id === undefined) {
            id = ++keyCount;
            keyIDs.set(el, id);
            keyed.set(id, new WeakRef(el));
            resized.observe(el);
          }
          const r = rect(el);
          if (!shade.has(el)) shade.set(el, onDark(el));
          list.push({ id, x: r.x + at.x, y: r.y + r.height / 2, size: at.size, dark: shade.get(el), resolved: r.resolved });
        }
        if (list.length) keyPoll ||= setInterval(keys, 300);
        else stopPoll();
        const sent = JSON.stringify(list);
        if (sent === lastKeys && list.every(k => k.resolved)) return;
        lastKeys = sent;
        post({ type: "keys", keys: list });
      }
      // native hides every key while the page, a box holding a keyed field or a frame, or the window
      // moves, and asks for them again once the tab holds still
      function moved(e) {
        const t = e.target;
        if (!keyKinds || Date.now() - movedAt < 100) return;
        const holds = t === document || t === window || t.querySelector?.("iframe")
          || [...keyed.values()].some(ref => { const el = ref.deref(); return el && el !== t && t.contains?.(el); });
        if (!holds) return;
        movedAt = Date.now();
        post({ type: "moved" });
      }
      addEventListener("scroll", moved, { capture: true, passive: true });
      addEventListener("resize", moved);
      for (const type of ["input", "toggle", "transitionend", "animationend"]) addEventListener(type, restyled, true);
      document.addEventListener("visibilitychange", () => { if (!document.hidden) restyled(); });
      matchMedia("(prefers-color-scheme: dark)").addEventListener("change", restyled);
      addEventListener("pageshow", e => {
        if (!e.persisted) return;
        lastKeys = "";
        keysSoon(150);
      });

      // the field's box clipped by its own viewport and each same-origin parent's above it
      function shows(el, minimum) {
        const b = el.getBoundingClientRect();
        let l = Math.max(b.left, 0), t = Math.max(b.top, 0);
        let r = Math.min(b.right, innerWidth), bottom = Math.min(b.bottom, innerHeight), w = window;
        while (w !== w.top) {
          let frame = null;
          try { frame = w.frameElement; } catch (e) {}
          if (!frame) break;
          const f = frame.getBoundingClientRect(), x = f.left + frame.clientLeft, y = f.top + frame.clientTop;
          w = w.parent;
          l = Math.max(l + x, 0); t = Math.max(t + y, 0);
          r = Math.min(r + x, w.innerWidth); bottom = Math.min(bottom + y, w.innerHeight);
        }
        return r - l >= minimum && bottom - t >= minimum;
      }

      Object.defineProperty(globalThis, "__artemisPasswords", { value: Object.freeze({
        fill(origin, user, password, generated, minimum) {
          if (window.origin !== origin) return false;
          const anchor = field?.isConnected ? field : passwords(document)[0] ?? username(document.body, null);
          if (!anchor) return false;
          const r = root(anchor), { current, fresh } = roles(r);
          const name = username(r, current ?? fresh[0] ?? null);
          const targets = generated ? fresh : [user ? name : null, current].filter(Boolean);
          if (!targets.length || !targets.every(el => shows(el, minimum))) return false;
          filling = true;
          try {
            if (generated) fresh.forEach(f => put(f, password));
            else {
              if (user && name) put(name, user);
              if (current) put(current, password);
            }
            return true;
          } finally {
            filling = false;
          }
        },
        // a code split across one-digit boxes fills them in order
        fillCode(origin, code, minimum) {
          if (window.origin !== origin || !field?.isConnected || !codeField(field) || !shows(field, minimum)) return false;
          const boxes = field.maxLength === 1
            ? [...root(field).querySelectorAll("input")].filter(i => i.maxLength === 1 && visible(i)) : [];
          filling = true;
          try {
            if (boxes.length === code.length) boxes.forEach((box, i) => put(box, code[i]));
            else put(field, code);
            return true;
          } finally {
            filling = false;
          }
        },
        // `kinds` are the field kinds with something to offer in this frame, and `size` is a key's side in
        // CSS px; an `optional` call leaves a document with no such field untracked
        track(kinds, size, optional) {
          const armed = keyKinds !== null;
          keyKinds = kinds;
          if (optional && !armed && !candidates().length) {
            keyKinds = null;
            return false;
          }
          if (!armed) reshaped.observe(document.documentElement, { childList: true, subtree: true,
            attributes: true, attributeFilter: ["type", "style", "class", "hidden", "open"] });
          keySize = size;
          lastKeys = "";
          clearTimeout(keyTimer);
          keys();
          return true;
        },
        // ends key reports here until the next `track`
        stop() {
          keyKinds = null;
          clearTimeout(keyTimer);
          keyTimer = 0;
          stopPoll();
          resized.disconnect();
          reshaped.disconnect();
          keyed.clear();
          keyIDs = new WeakMap();
          shade = new WeakMap();
        },
        // what the suggestion list offers in the focused field, as a focus there reports it
        focusedKind() {
          const el = document.activeElement;
          return el instanceof HTMLInputElement ? kind(el) : null;
        },
        // the list under the open field shows `count` rows; 0 is closed
        listing(count) {
          listed = open ? count : 0;
          open &&= count > 0;
          chosen = -1;
        },
        // a key's click: its field takes focus and the list opens under it, or the list `shown` for it
        // closes; a field covered since it was measured loses its key instead
        open(id, shown) {
          const el = keyed.get(id)?.deref();
          if (!el?.isConnected || !visible(el) || !keyAt(el)) return keysSoon(0);
          if (shown && open && field === el) return dismiss();
          el.focus({ preventScroll: true });
          offer(el);
        },
      }) });
    })();
    """
}
