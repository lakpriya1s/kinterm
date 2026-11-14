import Darwin
import Foundation

/// Who is on the other end of KinTerm's control socket.
///
/// A request says which terminal it comes from (`"surface"`), but anything
/// can say anything. What a process can't fake is where it runs: every
/// program started in a KinTerm terminal, and everything those programs
/// start (an agent, its shell commands, its MCP servers), has that
/// terminal's pty as the controlling terminal of itself or of one of its
/// ancestors. So a request is believed when the process that sent it, or
/// one of its ancestors, runs on the pty of the terminal it names.
enum ControlPeer {
    /// The process that connected to a Unix socket.
    static func pid(of socket: Int32) -> pid_t? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(socket, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else { return nil }
        return pid
    }

    /// Whether the process, or one of its ancestors, runs on the terminal
    /// device `tty`. Nil when that can't be told: the process is gone.
    static func runs(_ pid: pid_t, on tty: dev_t) -> Bool? {
        var current = pid
        var seen = false
        // An agent's MCP server is a few processes below the shell; 32 is
        // far more than any real chain.
        for _ in 0..<32 {
            guard current > 1, let info = bsdInfo(current) else { break }
            seen = true
            if info.e_tdev == tty { return true }
            current = pid_t(info.pbi_ppid)
        }
        return seen ? false : nil
    }

    /// The terminal device of a pty path such as /dev/ttys003.
    static func device(ofTTY path: String) -> dev_t? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return info.st_rdev
    }

    private static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }
}

extension ControlPeer {
    /// Whether a request from `pid` really comes from `surface`'s terminal.
    /// Nil when it can't be told (no pid, or the terminal has no pty yet).
    @MainActor
    static func isFrom(_ pid: pid_t?, surface: Ghostty.SurfaceView) -> Bool? {
        guard let pid,
              let name = surface.surfaceModel?.ttyName,
              let tty = device(ofTTY: name.hasPrefix("/") ? name : "/dev/\(name)") else { return nil }
        return runs(pid, on: tty)
    }
}
