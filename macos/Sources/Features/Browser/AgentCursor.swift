/// The cursor an agent's clicks show on the page, so you can see what it's
/// doing: an arrow that glides to where it moves the mouse, a ripple where
/// it clicks, and a ring around the field it types into.
///
/// Agents' input reaches the page as real mouse and key events, so the
/// script follows those. It only draws while KinTerm says an agent is
/// active (`window.__kintermAgent(true)`); the rest of the time it just
/// remembers where the mouse is. Everything it draws is in a closed shadow
/// root that ignores the mouse and is hidden from accessibility, and it's
/// removed when the agent finishes.
enum AgentCursor {
    static let script = #"""
    (() => {
      if (window.__kintermAgent) return;
      let active = false, host = null, cursor = null, root = null, x = innerWidth / 2, y = innerHeight / 3, hideTimer = 0;

      const css = `
        :host { all: initial; }
        .layer { position: fixed; inset: 0; pointer-events: none; z-index: 2147483647; }
        .cursor { position: absolute; left: 0; top: 0; width: 22px; height: 22px;
          transition: transform 0.22s cubic-bezier(.2,.8,.2,1), opacity 0.3s; will-change: transform;
          filter: drop-shadow(0 1px 2px rgba(0,0,0,.45)); }
        .tag { position: absolute; left: 18px; top: 18px; font: 600 10px -apple-system, system-ui, sans-serif;
          color: #fff; background: #5CA0FF; padding: 2px 6px; border-radius: 8px; white-space: nowrap; }
        .ripple { position: absolute; width: 36px; height: 36px; margin: -18px 0 0 -18px; border-radius: 50%;
          border: 2px solid #5CA0FF; background: rgba(92,160,255,.25); animation: ripple .5s ease-out forwards; }
        @keyframes ripple { from { transform: scale(.3); opacity: 1; } to { transform: scale(1.6); opacity: 0; } }
        .ring { position: absolute; border: 2px solid #5CA0FF; border-radius: 4px; box-shadow: 0 0 0 4px rgba(92,160,255,.25);
          transition: opacity .4s; }`;

      function ensure() {
        if (host && host.isConnected) return;
        host = document.createElement('kinterm-agent-cursor');
        host.setAttribute('aria-hidden', 'true');
        const shadow = host.attachShadow({ mode: 'closed' });
        shadow.innerHTML = `<style>${css}</style><div class="layer">
          <div class="cursor"><svg width="22" height="22" viewBox="0 0 22 22">
            <path d="M3 2 L3 18 L7.5 13.8 L10.6 20.5 L13.4 19.2 L10.4 12.6 L16.5 12.6 Z"
              fill="#5CA0FF" stroke="#fff" stroke-width="1.6" stroke-linejoin="round"/></svg>
            <div class="tag">Agent</div></div></div>`;
        root = shadow.querySelector('.layer');
        cursor = shadow.querySelector('.cursor');
        (document.documentElement || document.body).appendChild(host);
        move(x, y);
      }

      function move(nx, ny) {
        x = nx; y = ny;
        if (cursor) cursor.style.transform = `translate(${x - 3}px, ${y - 2}px)`;
      }

      function ripple(px, py) {
        const r = document.createElement('div');
        r.className = 'ripple';
        r.style.left = px + 'px';
        r.style.top = py + 'px';
        root.appendChild(r);
        setTimeout(() => r.remove(), 600);
      }

      function ring(el) {
        const box = el.getBoundingClientRect();
        if (!box.width && !box.height) return;
        const r = document.createElement('div');
        r.className = 'ring';
        Object.assign(r.style, { left: box.left - 3 + 'px', top: box.top - 3 + 'px',
          width: box.width + 2 + 'px', height: box.height + 2 + 'px' });
        root.appendChild(r);
        setTimeout(() => { r.style.opacity = '0'; setTimeout(() => r.remove(), 400); }, 900);
      }

      const opts = { capture: true, passive: true };
      addEventListener('mousemove', e => { if (active) move(e.clientX, e.clientY); else { x = e.clientX; y = e.clientY; } }, opts);
      addEventListener('mousedown', e => { if (!active) return; move(e.clientX, e.clientY); ripple(e.clientX, e.clientY); }, opts);
      addEventListener('focusin', e => {
        if (!active) return;
        const el = e.target;
        if (el && el.matches && el.matches('input, textarea, select, [contenteditable=""], [contenteditable="true"]')) {
          const box = el.getBoundingClientRect();
          move(box.left + Math.min(24, box.width / 2), box.top + box.height / 2);
          ring(el);
        }
      }, opts);

      window.__kintermAgent = on => {
        active = on;
        clearTimeout(hideTimer);
        if (on) {
          ensure();
          cursor.style.opacity = '1';
        } else if (host) {
          if (cursor) cursor.style.opacity = '0';
          hideTimer = setTimeout(() => { if (!active && host) { host.remove(); host = null; } }, 350);
        }
      };
    })();
    """#
}
