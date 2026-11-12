import AppKit
import Darwin

// KinTerm's browser is Chromium (CEF), in a module built by
// macos/Browser/build.sh and copied into Contents/Frameworks. KinTerm never
// links it: the module is loaded with dlopen the first time a browser is
// opened, so until then it costs nothing. Without the module (a build that
// skipped build.sh) the browser says how to get it. See
// scope/designs/09-browser.md.

/// Loads the browser module and starts Chromium, once.
enum BrowserEngine {
    typealias EventFn = @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?, Int32, Int32) -> Void

    // The module's C API, see macos/Browser/src/kinterm_browser.mm.
    private typealias InitializeFn = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>, Int32) -> Int32
    private typealias CreateFn = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<CChar>, EventFn, UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    private typealias ExecuteFn = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<CChar>) -> Void
    private typealias NavigateFn = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<CChar>) -> Void
    private typealias HandleIntFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
    private typealias HandleFn = @convention(c) (UnsafeMutableRawPointer) -> Void
    private typealias VoidFn = @convention(c) () -> Void

    private struct API {
        let initialize: InitializeFn
        let create: CreateFn
        let navigate: NavigateFn
        let command: HandleIntFn
        let setFocus: HandleIntFn
        let showDevTools: HandleFn
        let execute: ExecuteFn
        let closeDevTools: HandleFn
        let close: HandleFn
        let shutdown: VoidFn
    }

    enum Command: Int32 { case back = 0, forward, reload, stop, hardReload }

    enum Failure: LocalizedError {
        case notInstalled
        case loadFailed(String)
        case startFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return BrowserEngine.isSupported
                    ? "This build of KinTerm doesn't include the browser. Run macos/Browser/build.sh, then build KinTerm again."
                    : "KinTerm's browser runs on Mac computers with Apple silicon."
            case .loadFailed(let reason):
                return "The browser couldn't be loaded: \(reason)"
            case .startFailed(let code):
                return code == 2
                    ? "The browser couldn't start. Another copy of KinTerm may be using its profile."
                    : "The browser couldn't start (error \(code))."
            }
        }
    }

    private static var frameworks: URL? { Bundle.main.privateFrameworksURL }

    private static var moduleURL: URL? { frameworks?.appendingPathComponent("KinTermBrowser.dylib") }

    /// Chromium is only built for Apple silicon; a universal KinTerm on an
    /// Intel Mac has the module but can't load it.
    static var isSupported: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    /// Whether this build includes the browser, for this Mac.
    static var isInstalled: Bool {
        guard isSupported, let path = moduleURL?.path else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    /// Whether Chromium is running.
    private(set) static var isRunning = false

    private static var api: API?
    private static var failure: Failure?

    /// Where KinTerm's browser keeps cookies and storage. Its own, not a
    /// browser you use day to day, and one per KinTerm (release and debug
    /// builds can't share one).
    static var profileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.kinterm.app")
            .appendingPathComponent("Browser")
    }

    /// The Chrome DevTools Protocol port on 127.0.0.1, for agents (MCP)
    /// and DevTools clients. Picked once, when first asked for, and used
    /// when Chromium starts.
    static let debugPort: Int32 = freeLocalPort() ?? 9333

    /// Load the module and start Chromium, if that hasn't happened yet.
    /// Takes a moment the first time.
    @discardableResult
    static func start() -> Result<Void, Failure> {
        if isRunning { return .success(()) }
        if let failure { return .failure(failure) }
        guard isInstalled, let frameworks, let moduleURL else { return .failure(.notInstalled) }

        guard let handle = dlopen(moduleURL.path, RTLD_NOW | RTLD_LOCAL) else {
            let reason = dlerror().map { String(cString: $0) } ?? "unknown error"
            failure = .loadFailed(reason)
            return .failure(.loadFailed(reason))
        }
        func symbol<T>(_ name: String, _: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let initialize = symbol("kt_browser_initialize", InitializeFn.self),
              let create = symbol("kt_browser_create", CreateFn.self),
              let navigate = symbol("kt_browser_navigate", NavigateFn.self),
              let command = symbol("kt_browser_command", HandleIntFn.self),
              let setFocus = symbol("kt_browser_set_focus", HandleIntFn.self),
              let showDevTools = symbol("kt_browser_show_devtools", HandleFn.self),
              let execute = symbol("kt_browser_execute_js", ExecuteFn.self),
              let closeDevTools = symbol("kt_browser_close_devtools", HandleFn.self),
              let close = symbol("kt_browser_close", HandleFn.self),
              let shutdown = symbol("kt_browser_shutdown", VoidFn.self) else {
            failure = .loadFailed("the module is from another version of KinTerm")
            return .failure(failure!)
        }

        let framework = frameworks.appendingPathComponent("Chromium Embedded Framework.framework").path
        let helper = frameworks.appendingPathComponent("KinTerm Helper.app/Contents/MacOS/KinTerm Helper").path
        try? FileManager.default.createDirectory(at: profileURL, withIntermediateDirectories: true)

        let code = initialize(framework, helper, profileURL.path, debugPort)
        guard code == 0 else {
            failure = .startFailed(code)
            return .failure(.startFailed(code))
        }

        api = API(
            initialize: initialize, create: create, navigate: navigate, command: command,
            setFocus: setFocus, showDevTools: showDevTools, execute: execute, closeDevTools: closeDevTools,
            close: close, shutdown: shutdown)
        isRunning = true

        // Chromium's processes end with KinTerm.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            api?.shutdown()
            api = nil
            isRunning = false
        }
        return .success(())
    }

    // MARK: Browsers

    static func create(in view: NSView, url: String, events: EventFn, context: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
        api?.create(Unmanaged.passUnretained(view).toOpaque(), url, events, context)
    }

    static func navigate(_ handle: UnsafeMutableRawPointer, to url: String) {
        api?.navigate(handle, url)
    }

    static func run(_ command: Command, on handle: UnsafeMutableRawPointer) {
        api?.command(handle, command.rawValue)
    }

    static func setFocus(_ handle: UnsafeMutableRawPointer, _ focus: Bool) {
        api?.setFocus(handle, focus ? 1 : 0)
    }

    /// The page's DevTools in a window of their own.
    static func showDevToolsWindow(_ handle: UnsafeMutableRawPointer) {
        api?.showDevTools(handle)
    }

    /// Run JavaScript in the page's main frame.
    static func execute(_ handle: UnsafeMutableRawPointer, _ code: String) {
        api?.execute(handle, code)
    }

    static func closeDevTools(_ handle: UnsafeMutableRawPointer) {
        api?.closeDevTools(handle)
    }

    static func close(_ handle: UnsafeMutableRawPointer) {
        api?.close(handle)
    }

    // MARK: Helpers

    /// A TCP port on 127.0.0.1 nothing is listening on right now.
    private static func freeLocalPort() -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0
            }
        }
        guard bound else { return nil }
        return Int32(UInt16(bigEndian: addr.sin_port))
    }
}
