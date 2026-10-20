import WebKit

/// The scripts Scope puts into the pages of a task's browser. Standard web APIs only, so a WebKit update has nothing
/// private to break.
enum BrowserScripts {
    /// The world the page reader runs in: the page's own scripts cannot see it nor replace what it calls
    /// (`querySelectorAll`, `getAttribute`). It shares the DOM, so a hostile page can still lie with its markup.
    @MainActor static var world: WKContentWorld { .world(name: "scope") }

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

    /// The page as `BrowserPage` JSON: text blocks in document order, the interactive elements with a ref each.
    /// Refs live in this world's own map, so they survive between reads of one page and mean nothing to the page.
    static let readPage = """
    (() => {
      const store = (window.__scopeRefs = window.__scopeRefs || { next: 1, byElement: new WeakMap(), byRef: new Map() });
      const refOf = (el) => {
        let ref = store.byElement.get(el);
        if (!ref) {
          ref = 'e' + store.next++;
          store.byElement.set(el, ref);
          store.byRef.set(ref, new WeakRef(el));
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
