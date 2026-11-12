import AppKit
import Darwin

/// A Unix socket `kinterm-browser` (the CLI, and the MCP server agents use)
/// talks to: one JSON request per connection, one JSON reply. The socket is
/// readable only by you. It waits without using any CPU, and loads nothing
/// of the browser until a request needs a browser.
///
/// Requests: `{"cmd": "status" | "open" | "start" | "close" | "reload" |
/// "back" | "forward" | "devtools" | "window", "url": "…"}`, and `{"cmd": "agent",
/// "active": true | false}` around an agent's tool calls, which shows its
/// cursor on the page.
///
/// Each may say which terminal it's from, `"surface": "<KINTERM_SURFACE_ID>"`:
/// then it acts on that terminal's tab's browser and no other, so an agent
/// in one tab never gets another tab's page. Without it (a shell outside
/// KinTerm, an agent that doesn't pass its environment on), the tab you're
/// looking at. `open`/`start` reply with the page's DevTools target id
/// (`"target"`), which the MCP server limits the agent to.
final class BrowserControlServer {
    static let shared = BrowserControlServer()

    private var listener: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.kinterm.browser-control")

    /// Where the socket is. Terminals get it as KINTERM_SOCKET and
    /// KINTERM_BROWSER_SOCKET.
    static var socketPath: String {
        let preferred = BrowserEngine.profileURL.deletingLastPathComponent().appendingPathComponent("browser.sock").path
        // Unix socket paths are limited to 104 bytes.
        if preferred.utf8.count < 100 { return preferred }
        return (NSTemporaryDirectory() as NSString).appendingPathComponent("kinterm-browser.sock")
    }

    func start() {
        guard listener < 0 else { return }
        let path = Self.socketPath
        setenv("KINTERM_BROWSER_SOCKET", path, 1)
        // The same, under a name agent configs never set: tools prefer it,
        // so an agent always reaches the KinTerm it runs in, even when its
        // MCP config names another (a release build's, from setup).
        setenv("KINTERM_SOCKET", path, 1)

        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8.prefix(buffer.count - 1))
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard bound, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            close(fd)
            return
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listener = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.accept() }
        source.resume()
        self.source = source

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in unlink(path) }
    }

    private func accept() {
        while true {
            let client = Darwin.accept(listener, nil, nil)
            guard client >= 0 else { return }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            queue.async { self.serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        // Blocking from here: the listener is non-blocking, its clients
        // aren't.
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 65536, !data.contains(UInt8(ascii: "\n")) {
            let count = read(client, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }

        let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        DispatchQueue.main.async {
            let reply = Self.handle(request)
            self.queue.async {
                var out = (try? JSONSerialization.data(withJSONObject: reply, options: [.withoutEscapingSlashes])) ?? Data()
                out.append(UInt8(ascii: "\n"))
                out.withUnsafeBytes { _ = write(client, $0.baseAddress, $0.count) }
                close(client)
            }
        }
    }

    // MARK: Requests

    @MainActor
    private static func handle(_ request: [String: Any]) -> [String: Any] {
        let center = BrowserCenter.shared
        let url = (request["url"] as? String).flatMap(BrowserPage.normalize)
        var reply: [String: Any] = [
            "installed": BrowserEngine.isInstalled,
            "port": Int(BrowserEngine.debugPort),
        ]

        // The caller's tab: the terminal it runs in, else the one in front.
        let surfaceID = request["surface"] as? String
        let fromSurface = surfaceID.flatMap { center.controller(forSurface: $0) }
        if surfaceID != nil, fromSurface == nil, request["cmd"] as? String != "status" {
            reply["ok"] = false
            reply["error"] = "The terminal this came from is closed."
            return reply
        }
        let tab = fromSurface ?? center.frontController

        func page(opening: Bool) -> BrowserPage? {
            guard let controller = tab else { return nil }
            if let page = center.page(for: controller) {
                if let url { page.load(url) }
                return page
            }
            // Without a terminal to go by, a browser in its own window will do.
            if fromSurface == nil, let page = center.windowedPage {
                if let url { page.load(url) }
                return page
            }
            // Agents open the browser without taking the keyboard from you.
            return opening ? center.show(for: controller, url: url, focus: false) : nil
        }

        func fail(_ message: String) -> [String: Any] {
            reply["ok"] = false
            reply["error"] = message
            return reply
        }

        let command = request["cmd"] as? String ?? "status"
        switch command {
        case "status":
            reply["running"] = BrowserEngine.isRunning
            reply["pages"] = center.allPages.map { ["url": $0.url, "title": $0.title] }

        case "open", "start":
            guard BrowserEngine.isInstalled else { return fail(BrowserEngine.Failure.notInstalled.localizedDescription) }
            if case .failure(let failure) = BrowserEngine.start() { return fail(failure.localizedDescription) }
            guard let page = page(opening: true) else { return fail("Open a KinTerm window first.") }
            reply["url"] = page.url
            // Null while the page is still opening; ask again.
            reply["target"] = page.targetID ?? NSNull()

        case "close":
            guard let controller = tab else { return fail("No KinTerm window is open.") }
            if let window = controller.gridWindow ?? controller.window, center.gridPage(for: window) != nil {
                center.closeGridTile(in: window)
            } else {
                center.hidePanel(for: controller)
            }

        case "agent":
            let active = request["active"] as? Bool ?? false
            // Only the agent's own page shows it working.
            if let target = request["target"] as? String,
               let page = center.allPages.first(where: { $0.targetID == target }) {
                page.agentActivity(active)
            } else if let controller = tab, let page = center.page(for: controller) {
                page.agentActivity(active)
            }

        case "window":
            guard let page = page(opening: false) else { return fail("No browser is open. Run: kinterm-browser open") }
            if center.isWindowed(page) { center.putBack(page) } else { center.popOut(page) }
            reply["url"] = page.url

        case "reload", "back", "forward", "devtools":
            guard let page = page(opening: false) else { return fail("No browser is open. Run: kinterm-browser open") }
            switch command {
            case "reload": page.run(.reload)
            case "back": page.run(.back)
            case "forward": page.run(.forward)
            default: page.showDevTools(docked: true)
            }
            reply["url"] = page.url

        default:
            return fail("Unknown command \(command).")
        }

        reply["ok"] = true
        return reply
    }
}
