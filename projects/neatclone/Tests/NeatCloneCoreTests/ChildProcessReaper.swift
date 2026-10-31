import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Owns cleanup for short-lived local test servers. `Process.waitUntilExit()`
/// has no timeout and can hang forever if a child inherits a blocked signal.
/// The PID is captured once, signals are sent only while waitpid confirms that
/// exact child is still alive, and every successful exit path reaps it.
final class ChildProcessReaper {
    private let process: Process
    let pid: pid_t
    private var reaped = false

    init(_ process: Process) throws {
        try process.run()
        self.process = process
        self.pid = process.processIdentifier
    }

    func waitUntilExit(timeout: TimeInterval) -> Bool {
        guard !reaped else { return true }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if reapIfExited() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return reapIfExited()
    }

    func terminate(gracePeriod: TimeInterval = 0.5, killPeriod: TimeInterval = 1.0) {
        guard !reaped else { return }
        guard !reapIfExited() else { return }

        // ESRCH is harmless; waitpid below remains the authority on whether
        // this exact child exited. Never signal a stale PID after it is reaped.
        _ = kill(pid, SIGTERM)
        if waitUntilExit(timeout: gracePeriod) { return }

        // Recheck/reap before escalation to avoid signaling a PID that has
        // exited between the timeout and SIGKILL (and could have been reused).
        guard !reapIfExited() else { return }
        _ = kill(pid, SIGKILL)
        if !waitUntilExit(timeout: killPeriod) {
            // Keep cleanup bounded even on a broken kernel/process wrapper.
            // SIGKILL has been sent; leave reaping to Process if waitpid cannot
            // observe the child, rather than blocking test teardown forever.
        }
    }

    private func reapIfExited() -> Bool {
        guard !reaped else { return true }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid || (result == -1 && errno == ECHILD) {
            reaped = true
            return true
        }
        return false
    }

    deinit { terminate() }
}

final class ChildProcessReaperTests: XCTestCase {
    func testIgnoredTerminationIsEscalatedAndChildIsReaped() throws {
        let executable = ["/usr/bin/python3", "/usr/local/bin/python3", "/opt/homebrew/bin/python3"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        guard let executable else { throw XCTSkip("Python 3 is required for the child-process fixture") }

        let child = Process()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = ["-c", "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)"]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        let reaper = try ChildProcessReaper(child)
        let started = ProcessInfo.processInfo.systemUptime
        Thread.sleep(forTimeInterval: 0.1)
        reaper.terminate(gracePeriod: 0.1, killPeriod: 1)

        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2)
        var status: Int32 = 0
        let result = waitpid(reaper.pid, &status, WNOHANG)
        let waitError = errno
        XCTAssertEqual(result, -1)
        XCTAssertEqual(waitError, ECHILD)
    }
}
