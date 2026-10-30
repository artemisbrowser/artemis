import WebKit

/// the page half of the agent tools. Runs in its own content world, so page
/// scripts can't see the uid map or the helpers; the map lives on that world's
/// global object and so resets with each document. Every entry point returns a string
enum AgentPage {
    static let world = WKContentWorld.world(name: "Artemis.Agent")

    static let library = #"""
        const A = globalThis.__artemisAgent ??= (() => {
          const refs = new Map(), uids = new WeakMap();
          let counter = 0;
          const SKIP = new Set(['script', 'style', 'noscript', 'template', 'svg', 'head']);
          const TAG_ROLES = {
            a: 'link', button: 'button', select: 'combobox', textarea: 'textbox', img: 'img',
            h1: 'heading', h2: 'heading', h3: 'heading', h4: 'heading', h5: 'heading', h6: 'heading',
            nav: 'navigation', main: 'main', header: 'banner', footer: 'contentinfo',
            aside: 'complementary', form: 'form', dialog: 'dialog', summary: 'button',
            iframe: 'iframe', option: 'option', search: 'search',
          };
          const INPUT_ROLES = {
            checkbox: 'checkbox', radio: 'radio', button: 'button', submit: 'button', reset: 'button',
            image: 'button', range: 'slider', number: 'spinbutton', search: 'searchbox',
          };
          const INTERACTIVE = new Set(['link', 'button', 'checkbox', 'radio', 'switch', 'textbox',
            'searchbox', 'combobox', 'listbox', 'option', 'slider', 'spinbutton', 'tab', 'menuitem',
            'menuitemcheckbox', 'menuitemradio', 'treeitem']);
          const LANDMARK = new Set(['heading', 'navigation', 'main', 'banner', 'contentinfo',
            'complementary', 'form', 'dialog', 'alertdialog', 'search', 'region', 'img', 'iframe',
            'alert', 'tablist', 'menu', 'menubar', 'toolbar']);
          const FROM_CONTENT = new Set(['link', 'button', 'heading', 'tab', 'menuitem',
            'menuitemcheckbox', 'menuitemradio', 'option', 'treeitem', 'checkbox', 'radio', 'switch']);
          const MUTED = new Set([...FROM_CONTENT, 'textbox', 'searchbox', 'combobox', 'listbox']);
          const PASSWORD = 'That is a password field. Agents never enter passwords in Artemis; ask the user to type it themselves.';
          const SYNTHETIC = ' (synthetic DOM events; a site that checks isTrusted may ignore them)';

          const clean = s => (s ?? '').replace(/\s+/g, ' ').trim();
          const quote = s => JSON.stringify(s.length > 200 ? s.slice(0, 200) + '…' : s);
          const isPassword = el => el?.localName === 'input' && el.type === 'password';
          const isField = el => el?.localName === 'textarea' ||
            (el?.localName === 'input' && !['checkbox', 'radio', 'button', 'submit', 'reset', 'image', 'file', 'range', 'color'].includes(el.type));

          function active() {
            let a = document.activeElement;
            while (a?.shadowRoot?.activeElement) a = a.shadowRoot.activeElement;
            return a;
          }

          function role(el) {
            const explicit = el.getAttribute('role')?.trim().split(/\s+/)[0];
            if (explicit) return explicit;
            const tag = el.localName;
            if (tag === 'input') return el.type === 'hidden' ? null : (INPUT_ROLES[el.type] ?? 'textbox');
            if (tag === 'a') return el.hasAttribute('href') ? 'link' : null;
            if (tag === 'img') return el.getAttribute('alt') === '' ? null : 'img';
            if (tag === 'section') return el.hasAttribute('aria-label') || el.hasAttribute('aria-labelledby') ? 'region' : null;
            if (el.isContentEditable && !el.parentElement?.isContentEditable) return 'textbox';
            return TAG_ROLES[tag] ?? null;
          }

          function name(el, r) {
            let n = el.getAttribute('aria-label');
            const ids = !clean(n) && el.getAttribute('aria-labelledby');
            if (ids) {
              const root = el.getRootNode();
              n = ids.split(/\s+/).map(id => (root.getElementById?.(id) ?? document.getElementById(id))?.innerText ?? '').join(' ');
            }
            if (!clean(n) && el.labels?.length) n = [...el.labels].map(l => l.innerText).join(' ');
            if (!clean(n)) n = el.getAttribute('alt');
            if (!clean(n) && el.localName === 'input' && ['button', 'submit', 'reset'].includes(el.type)) n = el.value;
            if (!clean(n) && FROM_CONTENT.has(r)) n = el.innerText;
            if (!clean(n)) n = el.getAttribute('title') || el.getAttribute('placeholder');
            return clean(n);
          }

          function hidden(el) {
            if (el.hidden || el.getAttribute('aria-hidden') === 'true') return true;
            if (el.checkVisibility?.({ checkVisibilityCSS: true, visibilityProperty: true }) !== false) return false;
            return getComputedStyle(el).display !== 'contents';
          }

          function kids(node) {
            if (node.shadowRoot) return node.shadowRoot.childNodes;
            if (node.localName === 'slot') {
              const assigned = node.assignedNodes({ flatten: true });
              if (assigned.length) return assigned;
            }
            return node.childNodes;
          }

          function uid(el) {
            let u = uids.get(el);
            if (!u) {
              u = 'e' + ++counter;
              uids.set(el, u);
              refs.set(u, new WeakRef(el));
            }
            return u;
          }

          function snapshot() {
            const lines = [`Page: ${clean(document.title)}`, `URL: ${location.href}`, ''];
            const focused = active();
            let size = 0, truncated = false;
            const push = (depth, text) => {
              const line = '  '.repeat(depth) + text;
              size += line.length + 1;
              if (size > 60000) truncated = true;
              else lines.push(line);
            };
            const walk = (node, depth, muted) => {
              if (truncated) return;
              if (node.nodeType === Node.TEXT_NODE) {
                const text = clean(node.data);
                if (text && !muted) push(depth, `- text ${quote(text)}`);
                return;
              }
              if (node.nodeType !== Node.ELEMENT_NODE) return;
              const el = node;
              if (SKIP.has(el.localName) || hidden(el)) return;
              const r = role(el);
              if (r && (INTERACTIVE.has(r) || LANDMARK.has(r))) {
                let line = `- ${r}`;
                const n = name(el, r);
                if (n) line += ` ${quote(n)}`;
                line += ` [uid=${uid(el)}]`;
                if (el.disabled || el.getAttribute('aria-disabled') === 'true') line += ' [disabled]';
                if (el.checked || el.getAttribute('aria-checked') === 'true') line += ' [checked]';
                if (el.getAttribute('aria-selected') === 'true') line += ' [selected]';
                if (el === focused) line += ' [focused]';
                if (isPassword(el)) line += ' [password]';
                else if (isField(el) && el.value) line += ` [value=${quote(el.value)}]`;
                else if (el.localName === 'select' && el.selectedOptions[0]) line += ` [value=${quote(clean(el.selectedOptions[0].text))}]`;
                if (r === 'link' && el.href) line += ` [href=${el.href.slice(0, 300)}]`;
                push(depth, line);
                depth += 1;
                muted ||= MUTED.has(r);
              }
              if (el.localName === 'iframe') return;
              for (const child of kids(el)) walk(child, depth, muted);
            };
            walk(document.body ?? document.documentElement, 0, false);
            if (truncated) lines.push('… (snapshot truncated at 60k characters)');
            return lines.join('\n');
          }

          function element(id) {
            const el = refs.get(id)?.deref();
            if (!el?.isConnected) throw new Error(`No element ${id} on this page; take a new snapshot.`);
            return el;
          }

          function describe(el) {
            const r = role(el) ?? el.localName, n = name(el, r);
            return n ? `${r} ${quote(n)}` : r;
          }

          function pointAt(el) {
            el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
            const r = el.getBoundingClientRect();
            return { clientX: r.left + r.width / 2, clientY: r.top + r.height / 2 };
          }

          function fire(el, type, init, Kind = MouseEvent) {
            const bubbles = !type.endsWith('enter');
            return el.dispatchEvent(new Kind(type, { bubbles, cancelable: bubbles, composed: true, view: window, ...init }));
          }

          function hoverOver(el) {
            const p = pointAt(el), pointer = { ...p, pointerType: 'mouse', isPrimary: true };
            for (const type of ['pointerover', 'pointerenter', 'pointermove']) fire(el, type, pointer, PointerEvent);
            for (const type of ['mouseover', 'mouseenter', 'mousemove']) fire(el, type, p);
            return p;
          }

          function hover(id) {
            const el = element(id);
            hoverOver(el);
            return `Hovered ${describe(el)}` + SYNTHETIC;
          }

          function click(id) {
            const el = element(id), what = describe(el);
            const p = { ...hoverOver(el), button: 0 }, pointer = { ...p, pointerType: 'mouse', isPrimary: true };
            fire(el, 'pointerdown', { ...pointer, buttons: 1 }, PointerEvent);
            fire(el, 'mousedown', { ...p, buttons: 1, detail: 1 });
            if (el !== active()) el.focus?.({ preventScroll: true });
            fire(el, 'pointerup', pointer, PointerEvent);
            fire(el, 'mouseup', { ...p, detail: 1 });
            fire(el, 'click', { ...p, detail: 1 });
            return `Clicked ${what}` + SYNTHETIC;
          }

          function setValue(el, value) {
            const proto = el.localName === 'textarea' ? HTMLTextAreaElement : el.localName === 'select' ? HTMLSelectElement : HTMLInputElement;
            Object.getOwnPropertyDescriptor(proto.prototype, 'value').set.call(el, value);
          }

          function announce(el, data, inputType) {
            el.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, inputType, data }));
          }

          function fill(id, value) {
            const el = element(id);
            if (isPassword(el)) throw new Error(PASSWORD);
            el.scrollIntoView({ block: 'center', behavior: 'instant' });
            el.focus?.({ preventScroll: true });
            if (el.localName === 'input' && (el.type === 'checkbox' || el.type === 'radio')) {
              const want = !/^(false|0|off|no|unchecked)$/i.test(value.trim());
              if (el.checked !== want) el.click();
              return `${want ? 'Checked' : 'Unchecked'} ${describe(el)}` + SYNTHETIC;
            }
            if (el.localName === 'select') {
              const option = [...el.options].find(o => o.value === value || clean(o.text) === clean(value));
              if (!option) throw new Error(`No option "${value}". Options: ${[...el.options].map(o => clean(o.text)).join(', ')}`);
              setValue(el, option.value);
            } else if (isField(el)) {
              setValue(el, value);
            } else if (el.isContentEditable) {
              getSelection().selectAllChildren(el);
              document.execCommand('insertText', false, value);
              return `Filled ${describe(el)}` + SYNTHETIC;
            } else {
              throw new Error(`${id} is not a text field, select or checkbox.`);
            }
            announce(el, value, 'insertReplacementText');
            el.dispatchEvent(new Event('change', { bubbles: true }));
            return `Filled ${describe(el)}` + SYNTHETIC;
          }

          function insert(el, text) {
            if (isField(el)) {
              const v = el.value, start = el.selectionStart ?? v.length, end = el.selectionEnd ?? start;
              setValue(el, v.slice(0, start) + text + v.slice(end));
              try { el.setSelectionRange(start + text.length, start + text.length); } catch {}
              announce(el, text, 'insertText');
            } else if (el.isContentEditable) {
              document.execCommand('insertText', false, text);
            }
          }

          function focusedField() {
            const el = active();
            if (!el || el === document.body) throw new Error('Nothing is focused; click or fill a field first.');
            if (isPassword(el)) throw new Error(PASSWORD);
            return el;
          }

          function typeText(text) {
            const el = focusedField();
            for (const key of text) {
              const init = { key, bubbles: true, cancelable: true, composed: true };
              if (el.dispatchEvent(new KeyboardEvent('keydown', init)) &&
                  el.dispatchEvent(new KeyboardEvent('keypress', init))) insert(el, key);
              el.dispatchEvent(new KeyboardEvent('keyup', init));
            }
            return `Typed ${text.length} characters into ${describe(el)}` + SYNTHETIC;
          }

          function moveFocus(from, backwards) {
            const order = [...document.querySelectorAll('a[href], button, input, select, textarea, [tabindex], [contenteditable]')]
              .filter(e => e.tabIndex >= 0 && !e.disabled && e.checkVisibility?.() !== false);
            const next = order[(order.indexOf(from) + (backwards ? order.length - 1 : 1)) % order.length];
            next?.focus();
          }

          function pressKey(key, modifiers) {
            const mods = modifiers.map(m => m.toLowerCase());
            const el = active() ?? document.body;
            const init = {
              key, bubbles: true, cancelable: true, composed: true,
              code: key.length === 1 ? (/[a-z]/i.test(key) ? 'Key' + key.toUpperCase() : /\d/.test(key) ? 'Digit' + key : '') : key,
              shiftKey: mods.includes('shift'), ctrlKey: mods.includes('control'),
              altKey: mods.includes('alt'), metaKey: mods.includes('meta'),
            };
            const typing = key.length === 1 || key === 'Backspace';
            if (typing && isPassword(el)) throw new Error(PASSWORD);
            if (el.dispatchEvent(new KeyboardEvent('keydown', init))) {
              if (key === 'Enter') {
                if (el.localName === 'input' && el.form) el.form.requestSubmit();
                else if (['a', 'button', 'summary'].includes(el.localName) || el.getAttribute('role') === 'button') el.click();
              } else if (key === 'Tab') {
                moveFocus(el, init.shiftKey);
              } else if (key === 'Backspace' && isField(el)) {
                const v = el.value, start = el.selectionStart ?? v.length, end = el.selectionEnd ?? start;
                const from = start === end ? Math.max(0, start - 1) : start;
                setValue(el, v.slice(0, from) + v.slice(end));
                try { el.setSelectionRange(from, from); } catch {}
                announce(el, null, 'deleteContentBackward');
              } else if (key.length === 1 && !init.ctrlKey && !init.metaKey && !init.altKey) {
                insert(el, key);
              }
            }
            el.dispatchEvent(new KeyboardEvent('keyup', init));
            return `Pressed ${[...modifiers, key].join('+')} on ${describe(el)}` + SYNTHETIC;
          }

          function scroll(id, dy) {
            if (id && dy == null) {
              element(id).scrollIntoView({ block: 'center', behavior: 'instant' });
              return `Scrolled ${id} into view.`;
            }
            const target = id ? element(id) : (document.scrollingElement ?? document.documentElement);
            const before = target.scrollTop;
            target.scrollBy({ top: dy ?? innerHeight * 0.8, behavior: 'instant' });
            const max = target.scrollHeight - target.clientHeight;
            return `Scrolled ${Math.round(target.scrollTop - before)}px; now at ${Math.round(target.scrollTop)} of ${Math.round(max)}.`;
          }

          return { snapshot, click, hover, fill, typeText, pressKey, scroll };
        })();

        """#
}
