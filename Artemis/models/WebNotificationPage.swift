// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation

/// the page half of the Notification web API: the page-world `window.Notification` that
/// posts to a native handler, and what that handler calls back with
enum WebNotificationPage {
    static let messageName = "artemisNotifications"
    /// carries the dismiss action, so closing a notification reports back too
    static let category = "page"
    static let receive = "globalThis.__artemisNotifications?.receive(m)"

    static let source = """
    (() => {
      // WebKit's own Notification can't deliver, and the API is secure-context only
      if (!isSecureContext) return void delete globalThis.Notification;
      if (globalThis.__artemisNotifications) return;
      const handler = webkit.messageHandlers.\(messageName);
      const send = handler.postMessage.bind(handler);
      const activation = navigator.userActivation;
      const live = new Map(), asking = new Map();
      let permission = "default", requests = 0;
      const later = (target, type) => setTimeout(() => target.dispatchEvent(new Event(type)));
      const fields = ["title", "dir", "lang", "body", "tag", "icon", "badge", "image", "data",
        "requireInteraction", "silent", "renotify", "timestamp", "actions"];

      class Notification extends EventTarget {
        #id = crypto.randomUUID();
        #on = {};
        #o;
        static get permission() { return permission; }
        static get maxActions() { return 0; }
        static requestPermission(callback) {
          return new Promise(resolve => {
            const request = ++requests;
            asking.set(request, resolve);
            send({ type: "requestPermission", request, userActivation: !!activation?.isActive });
          }).then(result => {
            if (typeof callback === "function") callback(result);
            return result;
          });
        }
        constructor(title, options) {
          if (arguments.length < 1) {
            throw new TypeError("Failed to construct 'Notification': 1 argument required.");
          }
          options = options ?? {};
          if (options.actions?.length) {
            throw new TypeError("Actions are only supported for persistent notifications.");
          }
          if (options.renotify && !options.tag) {
            throw new TypeError("Notifications that set renotify must also set a tag.");
          }
          super();
          this.#o = {
            title: String(title), dir: options.dir ?? "auto", lang: String(options.lang ?? ""),
            body: String(options.body ?? ""), tag: String(options.tag ?? ""),
            icon: String(options.icon ?? ""), badge: String(options.badge ?? ""),
            image: String(options.image ?? ""), data: options.data ?? null,
            requireInteraction: !!options.requireInteraction, silent: options.silent ?? null,
            renotify: !!options.renotify, timestamp: options.timestamp ?? Date.now(),
            actions: Object.freeze([]),
          };
          if (permission !== "granted") { later(this, "error"); return; }
          const tag = this.#o.tag;
          // a tag names a slot: the newer notification takes the older one's place, natively
          if (tag) for (const [id, other] of live) if (other.tag === tag) live.delete(id);
          live.set(this.#id, this);
          send({ type: "create", id: this.#id, title: this.#o.title, body: this.#o.body,
            silent: this.#o.silent === true, tag, renotify: this.#o.renotify });
        }
        close() {
          if (!live.delete(this.#id)) return;
          send({ type: "close", id: this.#id });
          later(this, "close");
        }
        static {
          for (const f of fields) Object.defineProperty(this.prototype, f, {
            get() { return this.#o[f]; }, enumerable: true, configurable: true,
          });
          for (const type of ["click", "show", "close", "error"]) {
            Object.defineProperty(this.prototype, "on" + type, {
              get() { return this.#on[type] ?? null; },
              set(fn) {
                if (this.#on[type]) this.removeEventListener(type, this.#on[type]);
                this.#on[type] = typeof fn === "function" ? fn : null;
                if (this.#on[type]) this.addEventListener(type, this.#on[type]);
              },
              enumerable: true, configurable: true,
            });
          }
        }
      }
      Object.defineProperty(globalThis, "__artemisNotifications", { value: Object.freeze({
        receive(m) {
          if (m.permission) permission = m.permission;
          if (m.type === "permission") {
            asking.get(m.request)?.(permission);
            asking.delete(m.request);
            return;
          }
          const n = live.get(m.id);
          if (!n) return;
          if (m.type === "close" || m.type === "error") live.delete(m.id);
          n.dispatchEvent(new Event(m.type));
        },
      }) });
      // as writable as the native: blockers and extensions wrap requestPermission
      Object.defineProperty(globalThis, "Notification", {
        value: Notification, writable: true, configurable: true,
      });
      send({ type: "hello" });
    })();
    """
}
