// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import WebKit

/// The script that understands address and payment forms in every frame, from an isolated world. It classifies
/// fields by their `autocomplete` tokens, then by name, id and label, groups them into sections, and fills one
/// section when native hands it a choice. Stored values reach a page only through `fill`.
enum AutofillPage {
    static let world = WKContentWorld.world(name: "Artemis.Autofill")
    static let messageName = "artemisAutofill"

    static let source = #"""
    (() => {
      if (globalThis.__artemisAutofill) return;
      const post = m => { try { webkit.messageHandlers.\#(messageName).postMessage(m); } catch (e) {} };
      const setters = new Map([HTMLInputElement, HTMLTextAreaElement]
        .map(c => [c, Object.getOwnPropertyDescriptor(c.prototype, "value").set]));
      const isSelect = el => el instanceof HTMLSelectElement;
      const fits = el => (el instanceof HTMLInputElement && ["text", "email", "tel", "number", "search", "url"].includes(el.type))
        || isSelect(el) || el instanceof HTMLTextAreaElement;
      // Shown, editable and inside the document, checked again at every fill, so no hidden or off-page field
      // ever takes a value: not hidden, inert or aria-hidden up the tree, not near-transparent, not outside the
      // scrollable document, and not clipped to nothing by a clip, clip-path or overflow-hidden ancestor
      const zeroClip = /inset\(\s*(50|100)%|circle\(\s*0|ellipse\(\s*0/;
      function visible(el) {
        if (el.disabled || el.readOnly || el.closest("[hidden],[inert],[aria-hidden=true]")) return false;
        if (!(el.checkVisibility?.({ opacityProperty: true, visibilityProperty: true }) ?? true)) return false;
        const b = el.getBoundingClientRect(), view = el.ownerDocument.defaultView, doc = el.ownerDocument.documentElement;
        if (b.width <= 1 || b.height <= 1) return false;
        if (b.right + view.scrollX <= 0 || b.bottom + view.scrollY <= 0 || b.left + view.scrollX >= doc.scrollWidth
          || b.top + view.scrollY >= doc.scrollHeight) return false;
        let opacity = 1, l = b.left, t = b.top, r = b.right, bottom = b.bottom;
        for (let n = el; n instanceof Element; n = n.parentElement) {
          const cs = view.getComputedStyle(n);
          opacity *= +cs.opacity;
          if (opacity < 0.05 || zeroClip.test(cs.clipPath) || cs.clip === "rect(0px, 0px, 0px, 0px)") return false;
          if (n !== el && /hidden|clip/.test(cs.overflowX + cs.overflowY)) {
            const c = n.getBoundingClientRect();
            l = Math.max(l, c.left); t = Math.max(t, c.top); r = Math.min(r, c.right); bottom = Math.min(bottom, c.bottom);
            if (r - l < 1 || bottom - t < 1) return false;
          }
        }
        return true;
      }
      const clean = s => String(s ?? "").replace(/([a-z])([A-Z])/g, "$1 $2").normalize("NFD").replace(/[̀-ͯ]/g, "")
        .toLowerCase().replace(/[_\-\[\].:*()]+/g, " ").replace(/\s+/g, " ").trim();

      // WHATWG autofill field names this script fills, and the ones that name something it must leave alone
      const known = new Set(["name", "given-name", "additional-name", "family-name", "organization", "street-address",
        "address-line1", "address-line2", "address-line3", "address-level1", "address-level2", "country", "country-name",
        "postal-code", "tel", "tel-country-code", "tel-national", "tel-area-code", "tel-local", "tel-local-prefix",
        "tel-local-suffix", "email", "cc-name", "cc-given-name", "cc-family-name", "cc-number", "cc-exp", "cc-exp-month",
        "cc-exp-year", "cc-csc", "cc-type"]);
      const foreign = /^(username|new-password|current-password|one-time-code|honorific-(prefix|suffix)|nickname|organization-title|address-level[34]|cc-additional-name|transaction-(currency|amount)|language|bday(-day|-month|-year)?|sex|url|photo|impp|tel-extension)$/;
      function token(el) {
        const parts = (el.getAttribute("autocomplete") || "").toLowerCase().trim().split(/\s+/).filter(Boolean);
        if (parts.at(-1) === "webauthn") parts.pop();
        const name = parts.pop();
        if (!name || name === "on" || name === "off") return null;
        if (foreign.test(name)) return { type: null };
        if (!known.has(name)) return null;
        if (["home", "work", "mobile", "fax", "pager"].includes(parts.at(-1))) parts.pop();
        const mode = ["shipping", "billing"].includes(parts.at(-1)) ? parts.pop() : "";
        const section = parts.at(-1)?.startsWith("section-") ? parts.pop() : "";
        return { type: name === "country-name" ? "country" : name, group: section + " " + mode, tagged: true };
      }

      // the text before a field without a label: its nearest preceding text, up to four ancestors out
      function nearby(el) {
        for (let n = el, depth = 0; n && n !== document.body && depth < 4; n = n.parentElement, depth++) {
          for (let s = n.previousSibling; s; s = s.previousSibling) {
            if (s.nodeType === 1 && s.matches("script,style,template")) continue;
            if (s.nodeType === 1 && (s.matches("input,select,textarea,button") || s.querySelector("input,select,textarea"))) return "";
            const t = s.nodeType === 1 || s.nodeType === 3 ? s.textContent.trim() : "";
            if (t) return t.length <= 80 ? t : "";
          }
        }
        return "";
      }
      function words(el) {
        const own = l => l.contains(el) ? l.textContent.replace(el.textContent, "") : l.textContent;
        const labels = [...(el.labels ?? [])].map(own).join(" ");
        const aria = (el.getAttribute("aria-labelledby") || "").split(/\s+/).filter(Boolean)
          .map(id => document.getElementById(id)?.textContent ?? "").join(" ");
        const said = [labels, aria, el.getAttribute("aria-label"), el.placeholder, el.title].join(" ").trim();
        return clean(el.name + " " + el.id) + " | " + clean(said || nearby(el));
      }

      // first match wins; English plus German, French, Spanish, Italian, Dutch, Portuguese, Polish and Swedish
      const rules = [
        [null, /user ?name|login|nick|search|captcha|coupon|promo|gift|voucher|password|passwort|one ?time|\botp\b|referr|discount|quantity|\bqty\b/],
        ["cc-csc", /verification|card ?ident|security ?(code|value|number)|card ?code|card ?pin|\bc ?v ?v|\bcvn|\bcvd|\bcvc|\bcsc|\bcid\b|\bccv|prufziffer|kartenprufnummer|cryptogramme|codigo de seguridad|codice di sicurezza|beveiligingscode|codigo de seguranca|kod (cvc|cvv|zabezpieczajacy)|sakerhetskod/],
        ["cc-name", /card ?(holder|owner)|name .*\bon\b .*card|(card|cc) ?name|cc ?full ?name|karteninhaber|nom .*(carte|titulaire)|titulaire|titular|nome .*(cartao|carta)|intestatario|kaarthouder|naam .*kaart|wlasciciel|kortinnehavare|namn pa kort/],
        ["cc-number", /(card|cc|acct|account) ?(number|num|nr|no\b|#)|ccnum|credit ?card|debit ?card|kartennummer|numero de (la )?(carte|tarjeta)|numero (della )?carta|kaartnummer|numero do cartao|numer karty|kortnummer/],
        ["cc-exp", /expir|\bexp\b|exp ?(date|mo|month|yr|year)|valid ?(thru|through|until|to)|gultig|ablauf|date d ?expiration|vencimiento|caducidad|fecha de venc|scadenza|vervaldatum|geldig tot|validade|vencimento|data waznosci|wazna do|giltig/],
        ["cc-type", /card ?(type|brand)|cc ?type|kartentyp|kartenart|type de carte|tipo de tarjeta|tipo (di )?carta/],
        ["email", /e ?mail|courriel|correo|posta elettronica|\be ?post\b|\bmail\b/],
        ["tel-country-code", /(phone|tel|dial|calling|mobile) ?(country )?code|country ?code|dial ?code|vorwahl|indicatif|prefijo|prefisso/],
        ["organization", /company|business|organi[sz]ation|\bfirma|firmenname|empresa|societe|azienda|ragione sociale|bedrijf|organizacja|foretag/],
        ["address-level2", /city|town|\bort\b|stadt|wohnort|ville|commune|localite|localidad|ciudad|poblacion|citta|comune|localita|\bstad\b|woonplaats|plaats|cidade|municipio|miasto|miejscowosc|postort|suburb/],
        ["address-level1", /\bstate\b|county|region|province|provinz|bundesland|provincia|departement|estado|\bstato\b|provincie|wojewodztwo|\blan\b|prefecture/],
        ["postal-code", /zip|postal|post ?code|pcode|postleitzahl|\bplz\b|code postal|codigo postal|\bcp\b|\bcap\b|postnummer|kod pocztowy|\bcep\b/],
        ["country", /country|countries|\bland\b|\bpays\b|\bpais\b|\bpaese\b|nazione|\bkraj\b/],
        ["address-line3", /address ?(line)? ?(3|three)|addr ?3|\bline ?3/],
        ["address-line2", /address ?(line)? ?(2|two)|addr ?2|street ?2|suite|\bunit\b|\bapt\b|apartment|adresszusatz|zusatz|complement|\bpiso\b|interno|toevoeging|\bline ?2|mieszkani|\blokal/],
        ["address-line1", /address|\baddr\b|addr ?1|street|strasse|hausnummer|\brue\b|direccion|domicilio|\bcalle\b|indirizzo|\bvia\b|straat|huisnummer|\badres\b|adresse|endereco|logradouro|morada|\bulica|gatuadress|\badress\b|\bline ?1/],
        ["tel", /phone|mobile|\bcell|contact ?number|telefon|telephone|telefono|\btel\b|\bhandy\b|celular|cellulare|portable|\bgsm\b|mobil/],
        ["name", /full ?name|your ?name|customer ?name|nombre y apellido|nombre completo|nom complet|nome completo|volledige naam|imie i nazwisko|vollstandiger name/],
        ["given-name", /first ?name|\bfirst\b|given ?name|fname|forename|vorname|prenom|\bnombre\b|\bnome\b|voornaam|\bimie\b|fornamn|initials/],
        ["additional-name", /middle ?name|mname|\bmiddle\b|segundo nombre|tussenvoegsel/],
        ["family-name", /last ?name|lname|surname|\blast\b|family ?name|nachname|\bnom\b|apellido|cognome|achternaam|sobrenome|nazwisko|efternamn/],
        ["name", /\bname\b|\bnamn\b|\bnaam\b|\bnome\b/],
      ];
      const monthWord = /month|\bmm\b|monat|\bmois\b|\bmes\b|\bmese\b|maand|miesiac|manad/;
      const yearWord = /year|\byy(yy)?\b|jahr|annee|\bano\b|\banno\b|jaar|\brok\b|\bar\b|\baa(aa)?\b|\bjj(jj)?\b/;

      let monthNames = null;
      function monthOf(o) {
        for (const s of [o.value, o.text]) {
          if (/^\s*\d{1,2}\b/.test(s) && +s.match(/\d+/)[0] >= 1 && +s.match(/\d+/)[0] <= 12) return +s.match(/\d+/)[0];
        }
        monthNames ??= [document.documentElement.lang || navigator.language, "en"].flatMap(l => ["long", "short"].flatMap(month => {
          try { const f = new Intl.DateTimeFormat(l, { month }); return [...Array(12).keys()].map(m => [clean(f.format(new Date(2000, m, 15))), m + 1]); }
          catch (e) { return []; }
        }));
        const text = clean(o.text);
        return text ? monthNames.find(([n]) => n && text.startsWith(n))?.[1] ?? 0 : 0;
      }
      function yearOf(o) {
        for (const s of [o.value, o.text]) {
          const m = String(s).trim().match(/^(\d{4}|\d{2})$/);
          if (m) return m[1].length === 2 ? 2000 + +m[1] : +m[1];
        }
        return 0;
      }
      const months = s => [...s.options].filter(monthOf).length >= 12;
      const now = new Date().getFullYear();
      const years = s => [...s.options].filter(o => { const y = yearOf(o); return y >= now - 1 && y <= now + 30; }).length >= 4;
      const plusCodes = s => [...s.options].filter(o => /^\s*\+\d/.test(o.text) || /^\s*\+\d/.test(o.value)).length >= 5;

      function expiry(el, text) {
        if (isSelect(el)) return months(el) ? "cc-exp-month" : years(el) ? "cc-exp-year" : null;
        const month = monthWord.test(text), year = yearWord.test(text);
        return month && !year ? "cc-exp-month" : year && !month ? "cc-exp-year" : "cc-exp";
      }
      function classify(el) {
        const t = token(el);
        if (t) return t.type && t;
        const text = words(el);
        let type = rules.find(([, re]) => re.test(text))?.[0];
        if (type === null) return null;
        if (!type && (el.type === "email" || el.type === "tel")) return { type: el.type, group: " ", text, weak: true };
        if (type === "cc-exp") type = expiry(el, text);
        if (type === "tel-country-code" && !/phone|tel|dial|calling|mobile/.test(text)
          && !(el.maxLength > 0 && el.maxLength <= 5) && !(isSelect(el) && plusCodes(el))) type = "country";
        return type && { type, group: " ", text };
      }

      const nonName = /^(organization|street-address|address-|postal-code|country|tel|email)/;
      const fromName = { "name": "cc-name", "given-name": "cc-given-name", "family-name": "cc-family-name" };
      // per field: { type, section, kind, live }
      let meta = new WeakMap(), sections = [];
      const initial = new WeakMap(), typed = new WeakSet(), filled = new WeakSet();

      function scan() {
        meta = new WeakMap();
        sections = [];
        const roots = new Map();
        for (const el of [...document.querySelectorAll("input,select,textarea")].slice(0, 600)) {
          if (!fits(el) || !visible(el)) continue;
          const r = el.form || el.closest("form") || document;
          if (!roots.has(r)) roots.set(r, []);
          roots.get(r).push({ el, group: " ", ...classify(el) });
          if (isSelect(el) && !initial.has(el)) initial.set(el, el.selectedIndex);
        }
        for (const list of roots.values()) {
          // split card numbers and phone numbers: short unlabelled boxes straight after a labelled one
          list.forEach((f, i) => {
            const prev = list[i - 1], short = n => n.el.maxLength > 0 && n.el.maxLength <= 6;
            if ((f.type && !f.weak) || !prev || isSelect(f.el) || !short(f)) return;
            if (prev.type === "cc-number" && short(prev)) Object.assign(f, { type: "cc-number", group: prev.group });
            else if (prev.type === "tel" && f.el.maxLength <= 4) Object.assign(f, { type: "tel", group: prev.group });
          });
          const card = list.some(f => f.type === "cc-number");
          if (card) {
            for (const f of list) {
              if (!f.type && isSelect(f.el)) f.type = months(f.el) ? "cc-exp-month" : years(f.el) ? "cc-exp-year" : null;
              else if (!f.type && f.text && /\bmm\b.*\byy/.test(f.text)) f.type = "cc-exp";
            }
            if (!list.some(f => f.type && nonName.test(f.type))) {
              for (const f of list) if (!f.tagged && fromName[f.type]) f.type = fromName[f.type];
            }
          }
          // a field with no section or mode of its own joins the last one its kind opened
          const open = new Map(), lastGroup = {};
          let last = null;
          for (const f of list.filter(f => f.type)) {
            const kind = f.type.startsWith("cc-") ? "card" : "address";
            if (f.group === " " && lastGroup[kind]) f.group = lastGroup[kind];
            lastGroup[kind] = f.group;
            const key = kind + f.group;
            let s = open.get(key);
            const continues = last?.section === s && last?.type === f.type && (f.type === "cc-number" || f.type.startsWith("tel"));
            if (!s || (s.types.has(f.type) && !continues)) {
              s = { kind, types: new Set(), fields: [], tagged: false };
              sections.push(s);
              open.set(key, s);
            }
            s.types.add(f.type);
            s.fields.push(f);
            s.tagged ||= !!f.tagged;
            f.section = s;
            last = f;
          }
        }
        for (const s of sections) {
          phoneParts(s);
          s.live = s.tagged || (s.kind === "card" ? s.types.has("cc-number") || s.types.size >= 2 : s.types.size >= 3);
          for (const f of s.fields) meta.set(f.el, { type: f.type, section: s });
        }
      }
      // a run of heuristic phone boxes takes its parts from how many there are and how long the first is
      function phoneParts(s) {
        const runs = [];
        s.fields.forEach((f, i) => {
          if (f.type !== "tel" || f.tagged) return;
          if (s.fields[i - 1]?.type === "tel" && !s.fields[i - 1].tagged) runs.at(-1).push(f); else runs.push([f]);
        });
        for (const run of runs.filter(r => r.length > 1)) {
          const first = run[0].el, country = (first.maxLength > 0 && first.maxLength <= 4 && /\+/.test(first.placeholder + first.value))
            || (isSelect(first) && plusCodes(first));
          const names = run.length >= 4 ? ["tel-country-code", "tel-area-code", "tel-local-prefix", "tel-local-suffix"]
            : run.length === 3 ? (country ? ["tel-country-code", "tel-area-code", "tel-local"] : ["tel-area-code", "tel-local-prefix", "tel-local-suffix"])
            : country || (first.maxLength > 0 && first.maxLength <= 4) ? ["tel-country-code", "tel-national"] : ["tel-area-code", "tel-local"];
          run.forEach((f, i) => { f.type = names[i] ?? "tel-local-suffix"; s.types.add(f.type); });
        }
        s.fields.forEach((f, i) => { if (f.type === "tel" && s.fields[i - 1]?.type === "tel-country-code") f.type = "tel-national"; });
      }

      // what to report: each kind's field types across its live sections
      let reported = "";
      function report() {
        scan();
        const kinds = {};
        for (const s of sections.filter(s => s.live)) kinds[s.kind] = [...new Set([...(kinds[s.kind] ?? []), ...s.types])];
        const sent = JSON.stringify(kinds);
        if (sent === reported) return;
        reported = sent;
        post({ type: "fields", kinds });
      }

      function phone(v) {
        const raw = v.phone ?? "", m = raw.match(/^\s*\+(\d{1,3})(?:[\s.\-(]|$)/);
        let digits = raw.replace(/\D/g, ""), code = "";
        if (m) { code = m[1]; digits = digits.slice(code.length); }
        else if (raw.trim().startsWith("+") && digits.length === 11 && digits[0] === "1") { code = "1"; digits = digits.slice(1); }
        return { code, national: digits };
      }
      function country(code) {
        const names = [];
        for (const l of [document.documentElement.lang || navigator.language, "en"]) {
          try { names.push(new Intl.DisplayNames([l], { type: "region" }).of(code)); } catch (e) {}
        }
        return names.filter(Boolean);
      }
      // the option to choose in a select, or -1
      function option(el, type, v) {
        const opts = [...el.options], same = (a, b) => !!a && clean(a) === clean(b);
        const find = test => opts.findIndex(o => !o.disabled && test(o));
        switch (type) {
          case "country": {
            const names = [...country(v.country), ...({ GB: ["United Kingdom", "UK"], US: ["United States", "USA"] }[v.country] ?? [])];
            return find(o => o.value.toUpperCase() === v.country || names.some(n => same(o.text, n)));
          }
          case "address-level1": return find(o => same(o.value, v.region) || same(o.text, v.region));
          case "cc-exp-month": return find(o => monthOf(o) === v.month);
          case "cc-exp-year": return find(o => yearOf(o) === v.year);
          case "cc-type": return find(o => clean(o.text).includes(clean(v.brand)) || same(o.value, v.brand));
          case "tel-country-code": return find(o => (o.value + " " + o.text).replace(/\D/g, " ").split(" ").includes(phone(v).code));
          default: {
            const want = text(el, type, v, null);
            return want ? find(o => same(o.value, want) || same(o.text, want)) : -1;
          }
        }
      }
      function expiryText(el, v) {
        const hint = (el.placeholder || "") + " " + (el.getAttribute("aria-label") || "");
        const yy = String(v.year % 100).padStart(2, "0"), mm = String(v.month).padStart(2, "0");
        const four = /yyyy|aaaa|jjjj|rrrr/i.test(hint);
        const sep = hint.match(/(?:mm|mo)\s*?([\/\-. ]+)\s*?(?:yy|aa|jj|rr)/i)?.[1] ?? "/";
        for (const out of [mm + sep + (four ? v.year : yy), mm + "/" + yy, mm + yy]) {
          if (!(el.maxLength > 0) || out.length <= el.maxLength) return out;
        }
        return mm + yy;
      }
      // a text value for one field of section `s`; split card and phone boxes take their slice
      function text(el, type, v, s) {
        const lines = v.street ?? [], p = () => phone(v);
        switch (type) {
          case "name": return [v.given, v.family].filter(Boolean).join(" ");
          case "given-name": return v.given;
          case "family-name": return v.family;
          case "organization": return v.organization;
          case "street-address": return lines.join(el instanceof HTMLTextAreaElement ? "\n" : ", ");
          case "address-line1": return s?.types.has("address-line2") ? lines[0] : lines.join(", ");
          case "address-line2": return s?.types.has("address-line3") ? lines[1] : lines.slice(1).join(", ");
          case "address-line3": return lines.slice(2).join(", ");
          case "address-level2": return v.city;
          case "address-level1": return v.region;
          case "postal-code": return v.postal;
          case "country": return country(v.country)[0] ?? v.country;
          case "email": return v.email;
          case "tel": return v.phone;
          case "tel-country-code": return p().code && "+" + p().code;
          case "tel-national": return p().national;
          case "tel-area-code":
          case "tel-local":
          case "tel-local-prefix":
          case "tel-local-suffix": {
            const area = s?.fields.find(f => f.type === "tel-area-code")?.el.maxLength, cut = area > 0 && area < 6 ? area : 3;
            const national = p().national, local = s?.types.has("tel-area-code") ? national.slice(cut) : national;
            return { "tel-area-code": national.slice(0, cut), "tel-local": local,
              "tel-local-prefix": local.slice(0, 3), "tel-local-suffix": local.slice(3) }[type];
          }
          case "cc-name": return v.name;
          case "cc-given-name": return (v.name ?? "").split(" ").slice(0, -1).join(" ") || v.name;
          case "cc-family-name": return (v.name ?? "").split(" ").length > 1 ? v.name.split(" ").at(-1) : "";
          case "cc-number": {
            const boxes = s?.fields.filter(f => f.type === "cc-number").map(f => f.el) ?? [el];
            if (boxes.length < 2) return v.number;
            let at = 0;
            for (const box of boxes) {
              const size = box === boxes.at(-1) ? Infinity : box.maxLength > 0 ? box.maxLength : 4;
              if (box === el) return v.number.slice(at, at + size);
              at += size;
            }
            return "";
          }
          case "cc-exp-month": return String(v.month).padStart(2, "0");
          case "cc-exp-year": return el.maxLength === 2 ? String(v.year % 100).padStart(2, "0") : String(v.year);
          case "cc-exp": return expiryText(el, v);
          case "cc-type": return v.brand;
        }
        return "";
      }
      // never over what the person typed or the page filled, but for the field they picked from: text only when
      // empty or still holding a fill of this script's, a select only at the option the page first showed
      const untouched = el => !typed.has(el)
        && (isSelect(el) ? filled.has(el) || el.selectedIndex === initial.get(el) : !el.value || filled.has(el));

      let filling = false;
      function put(el, value, index) {
        if (isSelect(el)) el.selectedIndex = index;
        else setters.get(el instanceof HTMLTextAreaElement ? HTMLTextAreaElement : HTMLInputElement)
          .call(el, el.maxLength > 0 ? value.slice(0, el.maxLength) : value);
        el.dispatchEvent(isSelect(el) ? new Event("input", { bubbles: true, composed: true })
          : new InputEvent("input", { bubbles: true, composed: true, inputType: "insertReplacementText", data: value }));
        el.dispatchEvent(new Event("change", { bubbles: true }));
        filled.add(el);
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

      // the list answers the person: a click, keyboard focus straight after a key press, or ↓ in a field
      let field = null, open = false, scrolledPosted = false, gesture = 0, listed = 0, chosen = -1;
      function offer(t) {
        if (filling || !(t instanceof Element) || !fits(t) || isSelect(t)) return;
        if (!meta.has(t)) scan();
        const m = meta.get(t);
        if (!m?.section.live || m.type === "cc-csc") return;
        field = t;
        open = true;
        scrolledPosted = false;
        listed = 0;
        chosen = -1;
        post({ type: "focus", kind: m.section.kind, field: m.type, text: t.value, rect: rect(t) });
      }
      function dismiss(e) {
        if (!open) return;
        const scrolled = e?.type === "scroll";
        if (scrolled && scrolledPosted) return;
        if (scrolled) scrolledPosted = true; else { open = false; listed = 0; }
        post({ type: "dismiss", scrolled });
      }
      addEventListener("keydown", e => {
        if (!e.isTrusted) return;
        gesture = Date.now();
        if (e.key === "ArrowDown" && !open && meta.has(e.target)) {
          offer(e.target);
          if (open) e.preventDefault();
          return;
        }
        const stop = () => { e.preventDefault(); e.stopPropagation(); };
        const listening = e.target === field && open;
        if (listening && listed && (e.key === "ArrowDown" || e.key === "ArrowUp")) {
          stop();
          chosen = e.key === "ArrowDown" ? Math.min(chosen + 1, listed - 1) : Math.max(chosen - 1, 0);
          post({ type: "highlight", index: chosen });
        } else if (listening && listed && e.key === "Enter" && chosen >= 0) {
          stop();
          post({ type: "pick", index: chosen });
          open = false;
          listed = 0;
        } else if (listening && e.key === "Escape" && listed) {
          stop();
          dismiss();
        } else if (listening && (e.key === "Tab" || e.key === "Enter")) {
          dismiss();
        }
        if (e.key === "Enter" && e.target instanceof HTMLInputElement && e.target.form && !e.defaultPrevented) arm(e.target.form);
      }, true);
      addEventListener("focusin", e => { if (e.isTrusted && Date.now() - gesture < 300) offer(e.target); }, true);
      addEventListener("focusout", e => { if (e.target === field) dismiss(); }, true);
      addEventListener("blur", e => { if (e.target === window) dismiss(); });
      addEventListener("scroll", dismiss, { capture: true, passive: true });
      for (const type of ["input", "change"]) {
        addEventListener(type, e => { if (e.isTrusted && !filling && e.target instanceof Element) typed.add(e.target); }, true);
      }
      // typing narrows the open list; native closes it once nothing matches
      addEventListener("input", e => {
        if (e.isTrusted && !filling && open && e.target === field) post({ type: "filter", text: field.value });
      }, true);
      addEventListener("click", e => {
        const t = e.target;
        if (!e.isTrusted || !(t instanceof Element)) return;
        if (fits(t) && !isSelect(t)) return offer(t);
        const button = t.closest("button,input[type=submit],input[type=image]");
        if (button?.form && ["submit", "image"].includes(button.type)) arm(button.form);
      }, true);

      // A save offer answers a real submission only: a submit event, or an Enter or submit-control click that
      // the page follows within 2 s by navigating, changing its history entry or removing the form. The form's
      // values are read at the click, before an SPA clears them.
      let armed = null, watcher = 0, sentAt = 0;
      function arm(form) {
        clearInterval(watcher);
        armed = { form, found: capture(form), at: Date.now(), href: location.href };
        watcher = setInterval(() => {
          if (!armed || Date.now() - armed.at > 2000) { armed = null; return clearInterval(watcher); }
          if (location.href !== armed.href || !armed.form.isConnected) offerSave(armed.found);
        }, 150);
      }
      function offerSave(found) {
        armed = null;
        clearInterval(watcher);
        if (!found || Date.now() - sentAt < 500) return;
        sentAt = Date.now();
        post({ type: "submit", ...found });
      }
      addEventListener("submit", e => {
        if (e.isTrusted || (armed && Date.now() - armed.at < 2000)) offerSave(capture(e.target));
      }, true);
      addEventListener("pagehide", () => {
        dismiss();
        if (armed && Date.now() - armed.at < 2000) offerSave(armed.found);
      });

      // what a form holds: the first address section with a street or postal code, the first card with a
      // number; a security code is never read. Null when it has neither
      function capture(r) {
        scan();
        const own = sections.filter(s => s.fields.some(f => r === document || r.contains(f.el)));
        const read = (s, type) => s.fields.filter(f => f.type === type).map(f => isSelect(f.el)
          ? (f.el.selectedIndex > 0 || f.el.options[0]?.value ? f.el.options[f.el.selectedIndex] : null) : f.el.value)
          .filter(Boolean);
        const one = (s, type) => { const v = read(s, type)[0]; return typeof v === "string" ? v.trim() : v?.text.trim() ?? ""; };
        let address = null, card = null;
        for (const s of own.filter(s => s.kind === "address")) {
          const lines = [...read(s, "street-address").flatMap(l => l.split(/\n/)), ...["address-line1", "address-line2", "address-line3"]
            .map(t => one(s, t))].map(l => l.trim()).filter(Boolean);
          const postal = one(s, "postal-code");
          if (!lines.length && !postal) continue;
          const full = one(s, "name").split(" "), countryField = read(s, "country")[0];
          const code = one(s, "tel-country-code").replace(/\D/g, "");
          const parts = ["tel-national", "tel-area-code", "tel-local", "tel-local-prefix", "tel-local-suffix"].map(t => one(s, t)).join("");
          address = {
            given: one(s, "given-name") || (full.length > 1 ? full.slice(0, -1).join(" ") : full[0]),
            family: one(s, "family-name") || (full.length > 1 ? full.at(-1) : ""),
            organization: one(s, "organization"), street: lines.join("\n"), city: one(s, "address-level2"),
            region: one(s, "address-level1"), postal,
            country: typeof countryField === "string" ? countryField : countryField ? [countryField.value, countryField.text] : "",
            phone: one(s, "tel") || (parts ? (code ? "+" + code + " " : "") + parts : ""), email: one(s, "email"),
          };
          break;
        }
        for (const s of own.filter(s => s.kind === "card")) {
          const number = read(s, "cc-number").join("").replace(/\D/g, "");
          if (number.length < 12) continue;
          let month = read(s, "cc-exp-month").map(o => typeof o === "string" ? +o : monthOf(o))[0] ?? 0;
          let year = read(s, "cc-exp-year").map(o => typeof o === "string" ? +o : yearOf(o))[0] ?? 0;
          const both = one(s, "cc-exp").match(/(\d{1,2})\s*[\/\-. ]?\s*(\d{4}|\d{2})/);
          if (both) { month = +both[1]; year = +both[2]; }
          if (year > 0 && year < 100) year += 2000;
          const name = one(s, "cc-name") || [one(s, "cc-given-name"), one(s, "cc-family-name")].filter(Boolean).join(" ");
          card = { number, name, month, year };
          break;
        }
        return address || card ? { address, card } : null;
      }

      let timer = 0;
      const observer = new MutationObserver(() => { timer ||= setTimeout(() => { timer = 0; report(); }, 300); });
      const start = () => {
        report();
        observer.observe(document.documentElement, { childList: true, subtree: true,
          attributes: true, attributeFilter: ["type", "style", "class", "hidden", "autocomplete"] });
      };
      if (document.readyState === "loading") addEventListener("DOMContentLoaded", start, { once: true });
      else start();

      // the window that first posted each frame nonce here; the page learns a nonce only from that post
      const posters = new Map(), waiters = new Map();
      addEventListener("message", e => {
        const nonce = typeof e.data === "string" && /^artemis-frame:([\w-]{36})$/.exec(e.data)?.[1];
        if (!e.isTrusted || !nonce || posters.has(nonce)) return;
        posters.set(nonce, e.source);
        waiters.get(nonce)?.();
      }, true);

      Object.defineProperty(globalThis, "__artemisAutofill", { value: Object.freeze({
        // `values` into one section of `kind`: the one the person picked from, else the first live one.
        // Returns how many fields took a value
        fill(origin, values, kind) {
          if (window.origin !== origin) return 0;
          scan();
          const picked = field?.isConnected && meta.get(field)?.section;
          const s = picked?.kind === kind && picked.live ? picked : sections.find(s => s.kind === kind && s.live);
          if (!s) return 0;
          let count = 0;
          filling = true;
          try {
            for (const { el, type } of s.fields) {
              if (type === "cc-csc" || !visible(el) || (el !== field && !untouched(el))) continue;
              if (isSelect(el)) {
                const i = option(el, type, values);
                if (i < 0 || i === el.selectedIndex) continue;
                put(el, "", i);
              } else {
                const value = text(el, type, values, s);
                if (!value) continue;
                put(el, String(value));
              }
              count++;
            }
          } finally {
            filling = false;
          }
          return count;
        },
        // whether the frame that posted `nonce` shows here: each iframe from this document down to it passes the
        // check a field must, and every document on the way is one this one can read
        async frameShown(nonce) {
          if (!posters.has(nonce)) {
            await new Promise(done => { waiters.set(nonce, done); setTimeout(done, 1000); });
            waiters.delete(nonce);
          }
          let w = posters.get(nonce);
          posters.delete(nonce);
          if (!w || w === window) return false;
          for (; w !== window; w = w.parent) {
            if (w.parent === w) return false;
            let doc;
            try { doc = w.parent.document; } catch (e) { return false; }
            const el = [...doc.querySelectorAll("iframe, frame")].find(f => f.contentWindow === w);
            if (!el || !visible(el)) return false;
          }
          return true;
        },
        // the list under the field shows `count` rows, which ↑ and ↓ walk; 0 is closed
        listing(count) {
          listed = open ? count : 0;
          open &&= count > 0;
          chosen = -1;
        },
        // every classified field, for the self-test
        fields() {
          scan();
          return sections.flatMap((s, i) => s.fields.map(f => ({ key: f.el.id || f.el.name, type: f.type, section: i,
            kind: s.kind, live: s.live })));
        },
      }) });
    })();
    """#
}
