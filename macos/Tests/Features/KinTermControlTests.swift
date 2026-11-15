//
//  KinTermControlTests.swift
//  GhosttyTests
//
//  Tests for the `kinterm-ctl` control commands: proving which terminal a
//  request comes from, and trimming terminal text.
//

import Darwin
import Foundation
import Testing
@testable import Ghostty

struct ControlPeerTests {
    /// A pty pair, the device of its terminal side, and a cleanup.
    private func pty() -> (dev_t, () -> Void)? {
        var primary: Int32 = 0
        var secondary: Int32 = 0
        guard openpty(&primary, &secondary, nil, nil, nil) == 0 else { return nil }
        var info = stat()
        guard fstat(secondary, &info) == 0 else { return nil }
        return (info.st_rdev, { close(primary); close(secondary) })
    }

    @Test func refusesATerminalTheProcessDoesntRunOn() throws {
        // A fresh pty no process has as its controlling terminal: this
        // process and its ancestors don't run on it.
        let (device, cleanup) = try #require(pty())
        defer { cleanup() }
        #expect(ControlPeer.runs(getpid(), on: device) == false)
    }

    @Test func acceptsTheTerminalTheProcessRunsOn() throws {
        // The test runner's own controlling terminal, when it has one.
        let fd = open("/dev/tty", O_RDONLY)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var info = stat()
        try #require(fstat(fd, &info) == 0)
        #expect(ControlPeer.runs(getpid(), on: info.st_rdev) == true)
    }

    @Test func cantTellForAProcessThatIsGone() {
        #expect(ControlPeer.runs(pid_t(Int32.max - 1), on: 0) == nil)
    }

    @Test func findsThePeerOfAUnixSocket() {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { return }
        defer { close(fds[0]); close(fds[1]) }
        #expect(ControlPeer.pid(of: fds[0]) == getpid())
    }
}

struct KinTermControlTailTests {
    @Test @MainActor func keepsTheLastLinesWithoutTrailingBlankRows() {
        let text = "one\ntwo\nthree\n\n   \n"
        #expect(KinTermControl.tail(text, lines: 2) == "two\nthree")
        #expect(KinTermControl.tail(text, lines: nil) == "one\ntwo\nthree")
    }

    @Test @MainActor func clampsTheLineCount() {
        #expect(KinTermControl.tail("a\nb", lines: 0) == "b")
        #expect(KinTermControl.tail("", lines: 5) == "")
    }
}
