// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation

/// what both apps share of passkeys on pages: the script that answers `navigator.credentials`
/// for `publicKey` requests through a native handler, and how page-supplied names are shown
enum PasskeyPage {
    static let messageName = "artemisPasskeys"

    /// page-supplied account names, made safe to show: no control or format characters, one line,
    /// at most 64 characters
    static func clean(_ text: String) -> String {
        let scalars = text.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
        }
        let line = String(String.UnicodeScalarView(scalars)).split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return line.count > 64 ? String(line.prefix(63)) + "…" : line
    }

    static let source = """
    (() => {
      if (!isSecureContext || globalThis.__artemisPasskeys) return;
      Object.defineProperty(globalThis, "__artemisPasskeys", { value: true });
      const handler = webkit.messageHandlers.\(messageName);
      const send = handler.postMessage.bind(handler);
      const container = navigator.credentials;
      const originalCreate = container?.create?.bind(container);
      const originalGet = container?.get?.bind(container);
      const token = Symbol();

      const bytes = source => {
        if (source instanceof ArrayBuffer) return new Uint8Array(source);
        if (ArrayBuffer.isView(source)) return new Uint8Array(source.buffer, source.byteOffset, source.byteLength);
        throw new TypeError("Expected a BufferSource.");
      };
      const encode = source => {
        let s = "";
        for (const b of bytes(source)) s += String.fromCharCode(b);
        return btoa(s).replace(/\\+/g, "-").replace(/\\//g, "_").replace(/=+$/, "");
      };
      const decode = text => {
        const s = atob(text.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((text.length + 3) % 4));
        const out = new Uint8Array(s.length);
        for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
        return out.buffer;
      };
      const illegal = t => { if (t !== token) throw new TypeError("Illegal constructor"); };

      class AuthenticatorResponse {
        #clientData;
        constructor(t, clientData) { illegal(t); this.#clientData = decode(clientData); }
        get clientDataJSON() { return this.#clientData; }
      }
      class AuthenticatorAttestationResponse extends AuthenticatorResponse {
        #r;
        constructor(t, r) {
          super(t, r.clientDataJSON);
          this.#r = { ...r, attestationObject: decode(r.attestationObject),
            authenticatorData: decode(r.authenticatorData), publicKey: decode(r.publicKey) };
        }
        get attestationObject() { return this.#r.attestationObject; }
        getAuthenticatorData() { return this.#r.authenticatorData.slice(0); }
        getPublicKey() { return this.#r.publicKey.slice(0); }
        getPublicKeyAlgorithm() { return -7; }
        getTransports() { return ["internal"]; }
        toJSON() {
          return { clientDataJSON: this.#r.clientDataJSON, attestationObject: encode(this.#r.attestationObject),
            authenticatorData: this.#r.authenticatorData && encode(this.#r.authenticatorData),
            transports: ["internal"], publicKey: encode(this.#r.publicKey), publicKeyAlgorithm: -7 };
        }
      }
      class AuthenticatorAssertionResponse extends AuthenticatorResponse {
        #r;
        constructor(t, r) {
          super(t, r.clientDataJSON);
          this.#r = { ...r, authenticatorData: decode(r.authenticatorData), signature: decode(r.signature),
            userHandle: r.userHandle ? decode(r.userHandle) : null };
        }
        get authenticatorData() { return this.#r.authenticatorData; }
        get signature() { return this.#r.signature; }
        get userHandle() { return this.#r.userHandle; }
        toJSON() {
          return { clientDataJSON: this.#r.clientDataJSON, authenticatorData: encode(this.#r.authenticatorData),
            signature: encode(this.#r.signature), userHandle: this.#r.userHandle && encode(this.#r.userHandle) };
        }
      }
      class PublicKeyCredential {
        #id; #raw; #response; #extensions;
        constructor(t, id, response, extensions) {
          illegal(t);
          this.#id = id; this.#raw = decode(id); this.#response = response; this.#extensions = extensions;
        }
        get id() { return this.#id; }
        get rawId() { return this.#raw; }
        get type() { return "public-key"; }
        get response() { return this.#response; }
        get authenticatorAttachment() { return "platform"; }
        getClientExtensionResults() { return { ...this.#extensions }; }
        toJSON() {
          return { id: this.#id, rawId: this.#id, type: "public-key", authenticatorAttachment: "platform",
            clientExtensionResults: this.getClientExtensionResults(), response: this.#response.toJSON() };
        }
        static isUserVerifyingPlatformAuthenticatorAvailable() { return Promise.resolve(true); }
        static isConditionalMediationAvailable() { return Promise.resolve(false); }
      }
      if (globalThis.Credential) Object.setPrototypeOf(PublicKeyCredential.prototype, Credential.prototype);

      const aborted = signal => signal.reason ?? new DOMException("The operation was aborted.", "AbortError");
      async function ceremony(kind, options) {
        const pk = options.publicKey, signal = options.signal;
        if (signal?.aborted) throw aborted(signal);
        // conditional UI isn't offered; such a request waits until the page gives up on it
        if (kind === "get" && options.mediation === "conditional") {
          return new Promise((_, reject) => signal?.addEventListener("abort", () => reject(aborted(signal))));
        }
        const request = kind === "create" ? {
          type: "create", challenge: encode(pk.challenge), rpId: pk.rp?.id,
          user: { id: encode(pk.user.id), name: String(pk.user.name ?? ""),
            displayName: String(pk.user.displayName ?? "") },
          algorithms: (pk.pubKeyCredParams ?? []).map(p => p.alg),
          exclude: (pk.excludeCredentials ?? []).map(c => encode(c.id)),
        } : {
          type: "get", challenge: encode(pk.challenge), rpId: pk.rpId,
          allow: (pk.allowCredentials ?? []).map(c => encode(c.id)),
        };
        const reply = await new Promise((resolve, reject) => {
          signal?.addEventListener("abort", () => reject(aborted(signal)));
          send(request).then(resolve, reject);
        });
        if (reply.error === "TypeError") throw new TypeError(reply.message);
        if (reply.error) throw new DOMException(reply.message, reply.error);
        const extensions = kind === "create" && pk.extensions?.credProps ? { credProps: { rk: true } } : {};
        const response = kind === "create"
          ? new AuthenticatorAttestationResponse(token, reply)
          : new AuthenticatorAssertionResponse(token, reply);
        return new PublicKeyCredential(token, reply.id, response, extensions);
      }

      const unsupported = () => Promise.reject(new DOMException("Not supported.", "NotSupportedError"));
      const create = function create(options) {
        return options?.publicKey ? ceremony("create", options) : (originalCreate ?? unsupported)(options);
      };
      const get = function get(options) {
        return options?.publicKey ? ceremony("get", options) : (originalGet ?? unsupported)(options);
      };
      if (container) {
        Object.defineProperty(container, "create", { value: create, writable: true, configurable: true });
        Object.defineProperty(container, "get", { value: get, writable: true, configurable: true });
      } else {
        const fallback = { create, get, store: unsupported, preventSilentAccess: () => Promise.resolve() };
        Object.defineProperty(Navigator.prototype, "credentials", { get: () => fallback, configurable: true });
      }
      // as writable as the natives: password-manager extensions override the statics
      for (const [name, value] of Object.entries({ PublicKeyCredential, AuthenticatorResponse,
        AuthenticatorAttestationResponse, AuthenticatorAssertionResponse })) {
        Object.defineProperty(globalThis, name, { value, writable: true, configurable: true });
      }
    })();
    """
}
