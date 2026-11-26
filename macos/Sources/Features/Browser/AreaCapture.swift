import Foundation

/// Screenshot an area of a page for the tab's agent: the toolbar's
/// screenshot button puts the page in capture mode, you drag out a box,
/// and KinTerm saves that part of the page as a PNG and pastes its path
/// into the agent's prompt, without pressing Return. Claude Code and Codex
/// turn a pasted image path into an image attachment.
///
/// The selection script talks back the way the element picker's does
/// (`console.debug("__kintermPick:<nonce>:<json>")`), and the picture
/// comes from Chromium itself over the DevTools Protocol, so it's the
/// page's pixels, without the selection box, and needs no screen
/// recording permission.
enum AreaCapture {
    struct Message: Decodable {
        let type: String
        let url: String?
        /// The box in CSS pixels, from the top left of the document.
        let rect: [Double]?
    }

    enum Failure: LocalizedError {
        case noPage, badReply, protocolError(String), timedOut

        var errorDescription: String? {
            switch self {
            case .noPage: return "The page isn't ready for a screenshot."
            case .badReply: return "Chromium sent back something unexpected."
            case .protocolError(let message): return message
            case .timedOut: return "The screenshot took too long."
            }
        }
    }

    /// Start selecting: run in the page's main frame.
    static func startScript(nonce: String) -> String {
        script.replacingOccurrences(of: "__NONCE__", with: nonce)
    }

    static let cancelScript = "window.__kintermArea && window.__kintermArea.cancel(true);"

    /// Take a screenshot of `rect` (document CSS pixels) in the page with
    /// DevTools target `targetID`.
    static func screenshot(targetID: String, rect: [Double]) async throws -> Data {
        guard rect.count == 4,
              let url = URL(string: "ws://127.0.0.1:\(BrowserEngine.debugPort)/devtools/page/\(targetID)")
        else { throw Failure.noPage }

        let socket = URLSession.shared.webSocketTask(with: url)
        // A big page area is several megabytes of base64; the default is 1 MB.
        socket.maximumMessageSize = 64 << 20
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        let started = Date()
        let limit: TimeInterval = 15
        let timeout = Task {
            try await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
            socket.cancel(with: .goingAway, reason: nil)
        }
        defer { timeout.cancel() }

        let request: [String: Any] = [
            "id": 1,
            "method": "Page.captureScreenshot",
            "params": [
                "format": "png",
                "captureBeyondViewport": false,
                "clip": ["x": rect[0], "y": rect[1], "width": rect[2], "height": rect[3], "scale": 1],
            ],
        ]
        let body = try JSONSerialization.data(withJSONObject: request)
        guard let text = String(bytes: body, encoding: .utf8) else { throw Failure.badReply }
        try await socket.send(.string(text))

        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await socket.receive()
            } catch {
                throw Date().timeIntervalSince(started) >= limit ? Failure.timedOut : error
            }
            let data: Data
            switch message {
            case .string(let text): data = Data(text.utf8)
            case .data(let bytes): data = bytes
            @unknown default: continue
            }
            guard let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  reply["id"] as? Int == 1 else { continue }
            if let error = reply["error"] as? [String: Any] {
                throw Failure.protocolError(error["message"] as? String ?? "The screenshot failed.")
            }
            guard let result = reply["result"] as? [String: Any],
                  let base64 = result["data"] as? String,
                  let png = Data(base64Encoded: base64) else { throw Failure.badReply }
            return png
        }
    }

    /// Save a screenshot where the agent can read it, and return its path.
    static func save(_ png: Data) throws -> String {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinterm-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let file = folder.appendingPathComponent("browser-area-\(formatter.string(from: Date())).png")
        try png.write(to: file, options: .atomic)
        return file.path
    }

    private static let script = #"""
    (() => {
      if (window.__kintermArea) window.__kintermArea.cancel(true);
      if (window.__kintermPicker) window.__kintermPicker.cancel(true);
      const nonce = "__NONCE__";
      const post = console.debug.bind(console);
      const send = (message) => post("__kintermPick:" + nonce + ":" + JSON.stringify(message));

      const host = document.createElement('kinterm-area-capture');
      host.setAttribute('aria-hidden', 'true');
      const shadow = host.attachShadow({ mode: 'closed' });
      shadow.innerHTML = `<style>
        :host { all: initial; }
        .layer { position: fixed; inset: 0; z-index: 2147483647; cursor: crosshair;
          background: rgba(0,0,0,.18); }
        .layer.dragging { background: transparent; }
        .box { position: absolute; display: none; border: 1.5px solid #5CA0FF;
          box-shadow: 0 0 0 100vmax rgba(0,0,0,.32); }
        .size { position: absolute; font: 600 11px -apple-system, system-ui, sans-serif; color: #fff;
          background: #5CA0FF; padding: 2px 6px; border-radius: 4px; white-space: nowrap; display: none; }
        .hint { position: fixed; left: 50%; bottom: 14px; transform: translateX(-50%);
          font: 500 12px -apple-system, system-ui, sans-serif; color: #fff; background: rgba(20,22,28,.92);
          padding: 6px 12px; border-radius: 8px; box-shadow: 0 2px 12px rgba(0,0,0,.35); pointer-events: none; }
      </style><div class="layer"><div class="box"></div><div class="size"></div>
        <div class="hint">Drag to screenshot an area for the agent · Esc to stop</div></div>`;
      const layer = shadow.querySelector('.layer');
      const box = shadow.querySelector('.box');
      const size = shadow.querySelector('.size');
      const hint = shadow.querySelector('.hint');
      (document.documentElement || document.body).appendChild(host);

      let start = null;
      let rect = null;

      function update(e) {
        const x = Math.max(0, Math.min(start.x, e.clientX));
        const y = Math.max(0, Math.min(start.y, e.clientY));
        const w = Math.min(innerWidth, Math.max(start.x, e.clientX)) - x;
        const h = Math.min(innerHeight, Math.max(start.y, e.clientY)) - y;
        rect = { x, y, w, h };
        Object.assign(box.style, { display: 'block', left: x + 'px', top: y + 'px', width: w + 'px', height: h + 'px' });
        size.textContent = `${Math.round(w)}×${Math.round(h)}`;
        const top = y > 22 ? y - 22 : y + h + 4;
        Object.assign(size.style, { display: 'block', left: x + 'px', top: top + 'px' });
      }

      const stop = (e) => { e.preventDefault(); e.stopPropagation(); e.stopImmediatePropagation(); };
      const onDown = (e) => {
        if (e.button !== 0) return;
        stop(e);
        start = { x: e.clientX, y: e.clientY };
        layer.classList.add('dragging');
        hint.style.display = 'none';
        update(e);
      };
      const onMove = (e) => { if (start) { stop(e); update(e); } };
      const onUp = (e) => {
        if (!start || e.button !== 0) return;
        stop(e);
        update(e);
        start = null;
        if (!rect || rect.w < 4 || rect.h < 4) {
          // A click, not a drag: start over.
          box.style.display = 'none'; size.style.display = 'none';
          layer.classList.remove('dragging'); hint.style.display = '';
          return;
        }
        const vv = window.visualViewport;
        const left = vv ? vv.pageLeft : scrollX;
        const top = vv ? vv.pageTop : scrollY;
        finish({ type: 'area', url: location.href, rect: [rect.x + left, rect.y + top, rect.w, rect.h] });
      };
      const onKey = (e) => { if (e.key === 'Escape') { stop(e); finish({ type: 'cancel' }); } };
      const swallow = (e) => stop(e);

      const opts = { capture: true };
      layer.addEventListener('pointerdown', onDown, opts);
      addEventListener('pointermove', onMove, opts);
      addEventListener('pointerup', onUp, opts);
      layer.addEventListener('click', swallow, opts);
      addEventListener('keydown', onKey, opts);

      function finish(message, quiet) {
        removeEventListener('pointermove', onMove, opts);
        removeEventListener('pointerup', onUp, opts);
        removeEventListener('keydown', onKey, opts);
        host.remove();
        if (window.__kintermArea === api) delete window.__kintermArea;
        if (quiet) return;
        // Let the page draw without the box before the screenshot.
        requestAnimationFrame(() => requestAnimationFrame(() => send(message)));
      }

      const api = { cancel: (quiet) => finish({ type: 'cancel' }, quiet) };
      window.__kintermArea = api;
    })();
    """#
}
