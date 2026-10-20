import WebKit

/// The scripts Scope puts into the pages of a task's browser. Standard web APIs only, so a WebKit update has nothing
/// private to break.
enum BrowserScripts {
    /// The world the page reader runs in: the page's own scripts cannot see it nor replace what it calls
    /// (`querySelectorAll`, `getAttribute`). It shares the DOM, so a hostile page can still lie with its markup.
    /// Held for the app's life: WebKit drops a world nobody retains, and with it the globals the page reader keeps
    /// between calls (its refs).
    @MainActor static let world = WKContentWorld.world(name: "scope")

    /// The name the console relay posts to.
    static let consoleHandler = "scopeConsole"

    /// `console.*`, uncaught errors and rejections, relayed as they happen. It runs in the page's world — the only
    /// place `console` can be wrapped — so the page can undo it: a debugging aid, not evidence.
    static let consoleRelay = """
    (() => {
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(consoleHandler);
      if (!handler) return;
      const text = (args) => args.map((a) => {
        try {
          if (a instanceof Error) return a.stack || String(a);
          if (typeof a === 'object' && a !== null) return JSON.stringify(a);
          return String(a);
        } catch (e) { return String(a); }
      }).join(' ').slice(0, 4000);
      const send = (level, args, source) => { try { handler.postMessage({ level, text: text(args), source }); } catch (e) {} };
      for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
        const original = console[level];
        console[level] = function (...args) { send(level, args, null); return original.apply(this, args); };
      }
      window.addEventListener('error', (event) => {
        let where = null;
        try { where = event.filename ? new URL(event.filename).pathname + ':' + event.lineno : null; } catch (e) {}
        send('error', [event.message || String(event.error)], where);
      });
      window.addEventListener('unhandledrejection', (event) => {
        const reason = event.reason;
        send('error', ['Unhandled rejection: ' + ((reason && (reason.stack || reason.message)) || String(reason))], null);
      });
    })();
    """

    /// The name the network relay posts to.
    static let networkHandler = "scopeNetwork"

    /// fetch and XMLHttpRequest wrapped to report their status — the only requests WebKit lets a page see one for.
    /// In the page's world, like the console relay, and as forgeable.
    static let networkRelay = """
    (() => {
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(networkHandler);
      if (!handler) return;
      const post = (entry) => { try { handler.postMessage(entry); } catch (e) {} };
      const absolute = (url) => { try { return new URL(url, location.href).href; } catch (e) { return String(url); } };
      const originalFetch = window.fetch;
      if (originalFetch) {
        window.fetch = function (input, init) {
          const started = performance.now();
          const url = absolute(input && input.url ? input.url : input);
          const method = ((init && init.method) || (input && input.method) || 'GET').toUpperCase();
          return originalFetch.apply(this, arguments).then((response) => {
            post({ url, method, type: 'fetch', status: response.status, ms: Math.round(performance.now() - started) });
            return response;
          }, (error) => {
            post({ url, method, type: 'fetch', failed: true, ms: Math.round(performance.now() - started) });
            throw error;
          });
        };
      }
      const open = XMLHttpRequest.prototype.open;
      const send = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (method, url) {
        this.__scope = { method: String(method || 'GET').toUpperCase(), url: absolute(url) };
        return open.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function () {
        const info = this.__scope;
        if (info) {
          const started = performance.now();
          this.addEventListener('loadend', () => {
            post({ url: info.url, method: info.method, type: 'xmlhttprequest', status: this.status || undefined,
                   failed: this.status === 0, ms: Math.round(performance.now() - started) });
          });
        }
        return send.apply(this, arguments);
      };
    })();
    """

    /// The element a ref names, in the reader's world; the body of a `callAsyncJavaScript` taking `ref`.
    private static let element = """
      const store = window.__scopeRefs;
      const el = store && store.byRef.get(ref);
      if (!el || !el.isConnected) return { ok: false, error: 'no element ' + ref + ' on this page: read it again' };
    """

    /// Clicks the element `ref` names. `isTrusted` stays false: WebKit has no public trusted input.
    static let click = element + """
      el.scrollIntoView({ block: 'center', inline: 'center' });
      if (el.focus) el.focus();
      el.click();
      return { ok: true, tag: el.tagName.toLowerCase() };
    """

    /// Types `text` into the field `ref` names: focus, optionally empty it, then `insertText` — which fires the input
    /// events a framework listens to — falling back to the native value setter. `submit` then submits its form.
    static let type = element + """
      el.scrollIntoView({ block: 'center' });
      el.focus();
      const field = el.tagName === 'INPUT' || el.tagName === 'TEXTAREA';
      if (clear) {
        if (field) { el.select(); } else { document.getSelection().selectAllChildren(el); }
        if (!document.execCommand('delete')) {
          if (field) el.value = '';
          else el.textContent = '';
        }
      } else if (field) {
        const end = el.value.length;
        try { el.setSelectionRange(end, end); } catch (e) {}
      }
      let inserted = document.execCommand('insertText', false, text);
      if (!inserted && field) {
        const proto = el.tagName === 'INPUT' ? HTMLInputElement.prototype : HTMLTextAreaElement.prototype;
        const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
        setter.call(el, (clear ? '' : el.value) + text);
        el.dispatchEvent(new Event('input', { bubbles: true }));
        inserted = true;
      }
      el.dispatchEvent(new Event('change', { bubbles: true }));
      let submitted = false;
      if (submit) {
        if (el.form) {
          if (el.form.requestSubmit) el.form.requestSubmit(); else el.form.submit();
          submitted = true;
        } else {
          const options = { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true };
          el.dispatchEvent(new KeyboardEvent('keydown', options));
          el.dispatchEvent(new KeyboardEvent('keyup', options));
          submitted = true;
        }
      }
      return { ok: inserted, value: field ? (el.type === 'password' ? '••••' : el.value) : el.textContent, submitted };
    """

    /// One look for `wait`: whether `selector` matches a visible element, or `text` is on the page, and how many
    /// resources the page has loaded so far (the quiet check compares two looks).
    static let probe = """
      let found = null;
      if (selector) {
        const el = document.querySelector(selector);
        found = !!el && (!el.checkVisibility || el.checkVisibility());
      } else if (text) {
        found = !!document.body && document.body.innerText.includes(text);
      }
      return { found, resources: performance.getEntriesByType('resource').length, ready: document.readyState };
    """

    /// What the page has requested since it opened, from the resource timeline: URL, type, duration. fetch and XHR
    /// are left to the relay, which has their status.
    static let resources = """
      const entries = performance.getEntriesByType('navigation').concat(performance.getEntriesByType('resource'));
      return entries
        .filter((e) => e.initiatorType !== 'fetch' && e.initiatorType !== 'xmlhttprequest')
        .map((e) => ({ url: e.name, type: e.entryType === 'navigation' ? 'navigation' : (e.initiatorType || 'other'),
                       ms: Math.round(e.duration), start: e.startTime }));
    """

    /// The page as `BrowserPage` JSON: text blocks in document order, the interactive elements with a ref each.
    /// Refs live in this world's own map, so they survive between reads of one page and mean nothing to the page. The
    /// map holds the elements strongly: a weak reference to this world's wrapper is collected while the node lives.
    static let readPage = """
    (() => {
      const store = (window.__scopeRefs = window.__scopeRefs || { next: 1, byElement: new WeakMap(), byRef: new Map() });
      const refOf = (el) => {
        let ref = store.byElement.get(el);
        if (!ref) {
          ref = 'e' + store.next++;
          store.byElement.set(el, ref);
          store.byRef.set(ref, el);
        }
        return ref;
      };
      const visible = (el) => {
        try {
          if (el.checkVisibility) return el.checkVisibility({ opacityProperty: true, visibilityProperty: true });
          return !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length);
        } catch (e) { return true; }
      };
      const squash = (s) => String(s || '').replace(/\\s+/g, ' ').trim();
      const interactive = 'a[href],button,input:not([type=hidden]),select,textarea,summary,[role=button],[role=link],' +
        '[role=checkbox],[role=radio],[role=tab],[role=menuitem],[role=switch],[role=textbox],[contenteditable=""],[contenteditable=true]';
      const textTags = 'h1,h2,h3,h4,h5,h6,p,li,td,th,label,pre,blockquote,figcaption,dt,dd,caption,legend';
      const roleOf = (el) => {
        const explicit = el.getAttribute('role');
        if (explicit) return explicit;
        const tag = el.tagName.toLowerCase();
        if (tag === 'a') return 'link';
        if (tag === 'select') return 'combobox';
        if (tag === 'textarea' || el.isContentEditable) return 'textbox';
        if (tag === 'input') {
          const type = (el.type || 'text').toLowerCase();
          if (type === 'checkbox' || type === 'radio') return type;
          if (['submit', 'button', 'reset', 'image'].includes(type)) return 'button';
          return 'textbox';
        }
        if (tag === 'summary') return 'button';
        return tag;
      };
      const nameOf = (el) => {
        const aria = el.getAttribute('aria-label');
        if (aria) return aria;
        if (el.labels && el.labels.length) return Array.from(el.labels).map((l) => l.innerText).join(' ');
        if (el.tagName === 'INPUT' && ['submit', 'button', 'reset'].includes(el.type)) return el.value;
        const inner = squash(el.innerText);
        if (inner) return inner.slice(0, 200);
        return el.getAttribute('title') || el.getAttribute('placeholder') || el.getAttribute('alt') || el.getAttribute('name') || '';
      };
      const valueOf = (el) => {
        if (el.tagName === 'SELECT') return el.selectedOptions[0] ? squash(el.selectedOptions[0].text) : '';
        if (el.tagName === 'INPUT' && (el.type === 'checkbox' || el.type === 'radio')) return el.checked ? 'checked' : 'unchecked';
        if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') return el.type === 'password' ? (el.value ? '••••' : '') : el.value;
        return null;
      };
      const blocks = [];
      const elements = [];
      const root = document.body || document.documentElement;
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
      let node;
      let seen = 0;
      while ((node = walker.nextNode()) && seen < 20000) {
        seen++;
        if (node.nodeType === Node.TEXT_NODE) {
          // Loose text in a div or a span: kept when nothing above it is a block or a control already read.
          const parent = node.parentElement;
          const text = squash(node.textContent);
          if (!text || !parent || parent.closest(textTags) || parent.closest(interactive)) continue;
          if (['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE'].includes(parent.tagName)) continue;
          blocks.push({ kind: 'text', text, hidden: !visible(parent) });
          continue;
        }
        const el = node;
        if (['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'svg'].includes(el.tagName)) continue;
        if (el.matches(interactive)) {
          elements.push({
            ref: refOf(el), role: roleOf(el), name: squash(nameOf(el)), value: valueOf(el),
            href: el.tagName === 'A' ? el.getAttribute('href') : null, hidden: !visible(el), disabled: !!el.disabled,
          });
        } else if (el.matches(textTags) && !(el.parentElement && el.parentElement.closest(textTags)) && !el.closest(interactive)) {
          const text = squash(el.innerText !== undefined ? el.innerText : el.textContent);
          if (text) blocks.push({ kind: el.tagName.toLowerCase(), text: text.slice(0, 4000), hidden: !visible(el) });
        }
      }
      return JSON.stringify({ url: location.href, title: document.title, blocks, elements });
    })()
    """
}
