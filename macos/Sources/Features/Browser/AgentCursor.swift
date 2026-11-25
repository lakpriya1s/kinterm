/// The cursor an agent's clicks show on the page, so you can see what it's
/// doing: an arrow that glides along a curve to where it moves the mouse
/// (the event waits until it gets there), a ripple where it clicks, a ring
/// around the field it types into, and a tag that says what it's doing
/// ("Clicking", "Typing", "Navigating"…).
///
/// It follows the agent's mouse, not yours: the agent's MCP server
/// (kinterm-browser-mcp.mjs) sees each mouse event the agent sends and
/// tells the page first (`window.__kintermAgentPointer(x, y, type, ms)`),
/// in order on the same connection, and on each tool call says what it is
/// (`window.__kintermAgentAction(label)`). Your own mouse keeps its own pointer. It
/// only draws while KinTerm says an agent is active
/// (`window.__kintermAgent(true)`). Everything it draws is in a closed shadow
/// root that ignores the mouse and is hidden from accessibility, and it's
/// removed when the agent finishes.
enum AgentCursor {
    static let script = #"""
    (() => {
      if (window.__kintermAgent) return;
      let active = false, host = null, cursor = null, arrow = null, tag = null, root = null, hideTimer = 0;
      let x = innerWidth / 2, y = innerHeight / 3, glide = null;
      let action = 'Working', shown = '', labelTimer = 0;

      const css = `
        :host { all: initial; }
        .layer { position: fixed; inset: 0; pointer-events: none; z-index: 2147483647; }
        .cursor { position: absolute; left: 0; top: 0; width: 22px; height: 22px;
          transition: opacity 0.3s; will-change: transform; }
        .arrow { display: block; transform-origin: 3px 2px; transition: transform .12s ease-out;
          filter: drop-shadow(0 1px 2px rgba(0,0,0,.45)); }
        .arrow.down { transform: scale(.82); }
        .tag { position: absolute; left: 18px; top: 19px; font: 600 10.5px -apple-system, system-ui, sans-serif; letter-spacing: .01em;
          color: #fff; background: #5CA0FF; padding: 2px 7px; border-radius: 9px; white-space: nowrap;
          box-shadow: 0 1px 3px rgba(0,0,0,.3); }
        .text { display: inline-block; transition: opacity .15s, transform .15s; }
        .text.out { opacity: 0; transform: translateY(3px); }
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
          <div class="cursor"><svg class="arrow" width="22" height="22" viewBox="0 0 22 22">
            <path d="M3 2 L3 18 L7.5 13.8 L10.6 20.5 L13.4 19.2 L10.4 12.6 L16.5 12.6 Z"
              fill="#5CA0FF" stroke="#fff" stroke-width="1.6" stroke-linejoin="round"/></svg>
            <div class="tag"><span class="text"></span></div></div></div>`;
        root = shadow.querySelector('.layer');
        cursor = shadow.querySelector('.cursor');
        arrow = shadow.querySelector('.arrow');
        tag = shadow.querySelector('.text');
        shown = '';
        (document.documentElement || document.body).appendChild(host);
        place(x, y);
        label(action);
      }

      const at = (px, py) => `translate(${px - 3}px, ${py - 2}px)`;

      function place(px, py) {
        if (cursor) cursor.style.transform = at(px, py);
      }

      // Where the cursor is drawn now, partway along a glide or not.
      function drawn() {
        if (!glide || !cursor) return [x, y];
        const m = new DOMMatrixReadOnly(getComputedStyle(cursor).transform);
        return [m.e + 3, m.f + 2];
      }

      // Glides from where it's drawn to (nx, ny) in ms, along a gentle curve
      // the way a hand moves a mouse; ms 0 jumps.
      function move(nx, ny, ms) {
        const [fx, fy] = drawn();
        if (glide) { glide.cancel(); glide = null; }
        x = nx; y = ny;
        if (!cursor) return;
        place(nx, ny);
        const dx = nx - fx, dy = ny - fy, dist = Math.hypot(dx, dy);
        if (!ms || dist < 2) return;
        // Bow the path sideways, a little more for longer moves, upward-ish.
        const bow = Math.min(70, dist * 0.18) * (dx >= 0 ? -1 : 1);
        const cx = (fx + nx) / 2 - (dy / dist) * bow, cy = (fy + ny) / 2 + (dx / dist) * bow;
        const frames = [];
        for (let i = 0; i <= 16; i++) {
          const t = i / 16, u = 1 - t;
          frames.push({ transform: at(u * u * fx + 2 * u * t * cx + t * t * nx, u * u * fy + 2 * u * t * cy + t * t * ny) });
        }
        glide = cursor.animate(frames, { duration: ms, easing: 'cubic-bezier(.45,.05,.25,1)' });
        const mine = glide;
        glide.onfinish = () => { if (glide === mine) glide = null; };
      }

      // The tag's words: what the agent is doing.
      function label(text) {
        if (!tag || text === shown) return;
        shown = text;
        if (!tag.textContent) { tag.textContent = text; return; }
        tag.classList.add('out');
        setTimeout(() => { tag.textContent = shown; tag.classList.remove('out'); }, 150);
      }

      // Says something for a moment, then goes back to the tool's action.
      function flash(text, ms) {
        clearTimeout(labelTimer);
        label(text);
        labelTimer = setTimeout(() => label(action), ms);
      }

      function press() {
        if (!arrow) return;
        arrow.classList.add('down');
        setTimeout(() => arrow && arrow.classList.remove('down'), 160);
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

      // When the agent last pressed the mouse, and when you did: focus
      // that follows your click is yours, not the agent's.
      let agentPressAt = 0, userPressAt = 0;

      window.__kintermAgentPointer = (px, py, type, ms) => {
        if (type === 'mousePressed') agentPressAt = Date.now();
        if (!active) { x = px; y = py; return; }
        ensure();
        if (type === 'mouseWheel') { flash('Scrolling', 700); return; }
        move(px, py, ms || 0);
        if (type === 'mousePressed') {
          clearTimeout(labelTimer);
          label(action);
          press();
          ripple(px, py);
        }
      };

      window.__kintermAgentAction = text => {
        action = String(text || 'Working');
        clearTimeout(labelTimer);
        label(action);
      };

      const opts = { capture: true, passive: true };
      addEventListener('mousedown', () => { if (Date.now() - agentPressAt > 400) userPressAt = Date.now(); }, opts);
      addEventListener('focusin', e => {
        if (!active || Date.now() - userPressAt < 600) return;
        const el = e.target;
        if (el && el.matches && el.matches('input, textarea, select, [contenteditable=""], [contenteditable="true"]')) {
          const box = el.getBoundingClientRect();
          move(box.left + Math.min(24, box.width / 2), box.top + box.height / 2, 320);
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
          hideTimer = setTimeout(() => { if (!active && host) { host.remove(); host = null; glide = null; } }, 350);
        }
      };
    })();
    """#
}
