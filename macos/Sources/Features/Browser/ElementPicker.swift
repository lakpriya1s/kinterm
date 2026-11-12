import Foundation

/// Pick elements on a page and hand them to the tab's agent: the toolbar's
/// target button puts the page in picking mode, the element under the mouse
/// is outlined, a click picks it (⇧-click picks several, a plain click
/// finishes) and Esc stops. What was picked is typed into the agent's
/// prompt, without pressing Return.
///
/// The script talks back with `console.debug("__kintermPick:<nonce>:<json>")`,
/// which the browser module hands to KinTerm instead of the console. The
/// nonce is new each time, so a page can't send picks of its own.
enum ElementPicker {
    struct Element: Decodable {
        let selector: String
        let tag: String
        let html: String
        let text: String?
        let rect: [Double]?
        let component: String?
        let source: String?
    }

    struct Message: Decodable {
        let type: String
        let url: String?
        let elements: [Element]?
    }

    /// Start picking: run in the page's main frame.
    static func startScript(nonce: String) -> String {
        script.replacingOccurrences(of: "__NONCE__", with: nonce)
    }

    static let cancelScript = "window.__kintermPicker && window.__kintermPicker.cancel();"

    /// What the agent gets for a pick.
    static func prompt(for elements: [Element], url: String) -> String {
        var lines: [String] = []
        lines.append(elements.count == 1
            ? "Selected element in the browser (\(url)):"
            : "\(elements.count) selected elements in the browser (\(url)):")
        for (index, element) in elements.enumerated() {
            lines.append("")
            if elements.count > 1 { lines.append("\(index + 1).") }
            lines.append("selector: \(element.selector)")
            if let component = element.component, !component.isEmpty {
                var line = "component: \(component)"
                if let source = element.source, !source.isEmpty { line += " (\(source))" }
                lines.append(line)
            }
            if let text = element.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                lines.append("text: \(text)")
            }
            if let rect = element.rect, rect.count == 4 {
                lines.append("box: \(Int(rect[2]))×\(Int(rect[3])) at \(Int(rect[0])),\(Int(rect[1]))")
            }
            lines.append("html: \(element.html)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static let script = #"""
    (() => {
      if (window.__kintermPicker) window.__kintermPicker.cancel(true);
      const nonce = "__NONCE__";
      const post = console.debug.bind(console);
      const send = (message) => post("__kintermPick:" + nonce + ":" + JSON.stringify(message));

      const host = document.createElement('kinterm-element-picker');
      host.setAttribute('aria-hidden', 'true');
      const shadow = host.attachShadow({ mode: 'closed' });
      shadow.innerHTML = `<style>
        :host { all: initial; }
        .layer { position: fixed; inset: 0; pointer-events: none; z-index: 2147483647; }
        .box { position: absolute; border: 2px solid #5CA0FF; background: rgba(92,160,255,.14);
          border-radius: 2px; transition: all .06s ease-out; display: none; }
        .picked { position: absolute; border: 2px solid #5CA0FF; background: rgba(92,160,255,.28); border-radius: 2px; }
        .label { position: absolute; font: 600 11px -apple-system, system-ui, sans-serif; color: #fff;
          background: #5CA0FF; padding: 2px 6px; border-radius: 4px; white-space: nowrap; display: none;
          max-width: 60vw; overflow: hidden; text-overflow: ellipsis; }
        .hint { position: fixed; left: 50%; bottom: 14px; transform: translateX(-50%);
          font: 500 12px -apple-system, system-ui, sans-serif; color: #fff; background: rgba(20,22,28,.92);
          padding: 6px 12px; border-radius: 8px; box-shadow: 0 2px 12px rgba(0,0,0,.35); }
      </style><div class="layer"><div class="box"></div><div class="label"></div>
        <div class="hint">Click an element to send it to the agent · ⇧-click to pick several · Esc to stop</div></div>`;
      const layer = shadow.querySelector('.layer');
      const box = shadow.querySelector('.box');
      const label = shadow.querySelector('.label');
      (document.documentElement || document.body).appendChild(host);

      const picked = [];
      let current = null;

      function cssEscape(s) { return window.CSS && CSS.escape ? CSS.escape(s) : s.replace(/[^a-zA-Z0-9_-]/g, '\\$&'); }

      function selectorFor(el) {
        if (!(el instanceof Element)) return '';
        if (el.id && document.querySelectorAll('#' + cssEscape(el.id)).length === 1) return '#' + cssEscape(el.id);
        const parts = [];
        let node = el;
        while (node && node.nodeType === 1 && node !== document.documentElement) {
          let part = node.localName;
          const testId = node.getAttribute('data-testid') || node.getAttribute('data-test-id');
          if (testId) { parts.unshift(`${part}[data-testid="${testId.replace(/"/g, '\\"')}"]`); break; }
          if (node.id && document.querySelectorAll('#' + cssEscape(node.id)).length === 1) {
            parts.unshift('#' + cssEscape(node.id));
            break;
          }
          const classes = [...node.classList].filter(c => !/^(css|sc|jsx|svelte|emotion)-|^[a-z]+-[a-zA-Z0-9]{5,}$/.test(c)).slice(0, 2);
          if (classes.length) part += '.' + classes.map(cssEscape).join('.');
          const parent = node.parentElement;
          if (parent) {
            const same = [...parent.children].filter(c => c.localName === node.localName);
            if (same.length > 1) part += `:nth-of-type(${same.indexOf(node) + 1})`;
          }
          parts.unshift(part);
          node = parent;
          if (parts.length >= 6) break;
        }
        return parts.join(' > ');
      }

      // React (development builds) names the component and where it's
      // written; good hints for an agent looking for the code.
      function component(el) {
        const key = Object.keys(el).find(k => k.startsWith('__reactFiber$') || k.startsWith('__reactInternalInstance$'));
        if (!key) return null;
        let fiber = el[key];
        for (let i = 0; fiber && i < 40; i++, fiber = fiber.return) {
          const type = fiber.type;
          if (typeof type === 'function' || (type && typeof type === 'object' && (type.render || type.type))) {
            const name = type.displayName || type.name || (type.render && (type.render.displayName || type.render.name))
              || (type.type && (type.type.displayName || type.type.name));
            if (!name) continue;
            const src = fiber._debugSource;
            return { name, source: src ? `${src.fileName}:${src.lineNumber}` : null };
          }
        }
        return null;
      }

      function describe(el) {
        const r = el.getBoundingClientRect();
        let html = el.outerHTML || '';
        if (html.length > 800) {
          const open = html.match(/^<[^>]*>/);
          html = (open ? open[0] : html.slice(0, 400)) + ' … ' + `</${el.localName}>`;
        }
        const text = (el.innerText || el.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 300);
        const c = component(el);
        return {
          selector: selectorFor(el), tag: el.localName, html, text,
          rect: [Math.round(r.left + scrollX), Math.round(r.top + scrollY), Math.round(r.width), Math.round(r.height)],
          component: c ? c.name : null, source: c ? c.source : null,
        };
      }

      function target(e) {
        const path = e.composedPath ? e.composedPath() : [e.target];
        return path.find(n => n instanceof Element && n !== host) || null;
      }

      function show(el) {
        current = el;
        if (!el) { box.style.display = 'none'; label.style.display = 'none'; return; }
        const r = el.getBoundingClientRect();
        Object.assign(box.style, { display: 'block', left: r.left + 'px', top: r.top + 'px', width: r.width + 'px', height: r.height + 'px' });
        const name = el.localName + (el.id ? '#' + el.id : '') + (el.classList.length ? '.' + [...el.classList].slice(0, 2).join('.') : '');
        label.textContent = `${name}  ${Math.round(r.width)}×${Math.round(r.height)}`;
        label.style.display = 'block';
        const top = r.top > 22 ? r.top - 22 : r.bottom + 4;
        Object.assign(label.style, { left: Math.max(4, r.left) + 'px', top: top + 'px' });
      }

      function mark(el) {
        const r = el.getBoundingClientRect();
        const m = document.createElement('div');
        m.className = 'picked';
        Object.assign(m.style, { left: r.left + 'px', top: r.top + 'px', width: r.width + 'px', height: r.height + 'px' });
        layer.appendChild(m);
      }

      const stop = (e) => { e.preventDefault(); e.stopPropagation(); e.stopImmediatePropagation(); };
      const onMove = (e) => { const el = target(e); if (el !== current) show(el); };
      const onDown = (e) => { if (e.button === 0) stop(e); };
      const onClick = (e) => {
        if (e.button !== 0) return;
        stop(e);
        const el = target(e) || current;
        if (!el) return;
        picked.push(describe(el));
        if (e.shiftKey) { mark(el); return; }
        finish({ type: 'pick', url: location.href, elements: picked });
      };
      const onKey = (e) => {
        if (e.key === 'Escape') {
          stop(e);
          if (picked.length) finish({ type: 'pick', url: location.href, elements: picked });
          else finish({ type: 'cancel' });
        }
      };
      const onScroll = () => show(current);

      const opts = { capture: true };
      addEventListener('mousemove', onMove, opts);
      addEventListener('mousedown', onDown, opts);
      addEventListener('mouseup', stop, opts);
      addEventListener('pointerdown', onDown, opts);
      addEventListener('click', onClick, opts);
      addEventListener('keydown', onKey, opts);
      addEventListener('scroll', onScroll, { capture: true, passive: true });
      const previousCursor = document.documentElement.style.cursor;
      document.documentElement.style.cursor = 'crosshair';

      function finish(message, quiet) {
        removeEventListener('mousemove', onMove, opts);
        removeEventListener('mousedown', onDown, opts);
        removeEventListener('mouseup', stop, opts);
        removeEventListener('pointerdown', onDown, opts);
        removeEventListener('click', onClick, opts);
        removeEventListener('keydown', onKey, opts);
        removeEventListener('scroll', onScroll, { capture: true });
        document.documentElement.style.cursor = previousCursor;
        host.remove();
        if (window.__kintermPicker === api) delete window.__kintermPicker;
        if (!quiet) send(message);
      }

      const api = { cancel: (quiet) => finish({ type: 'cancel' }, quiet) };
      window.__kintermPicker = api;
    })();
    """#
}
