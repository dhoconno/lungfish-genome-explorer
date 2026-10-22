import Foundation
import XCTest
@testable import LungfishExecutor
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Starts the built `lungfish-executor` as a child of the test process and reads what it left.
///
/// Every test that needs the subreaper, the blocked signal mask or the sweep runs the binary, never the code in process,
/// because only the binary's `main` blocks the signals and calls the setter (tally-r2 K3-1). The binary sits next to the
/// test bundle on macOS. The Linux tier names it with `LUNGFISH_EXECUTOR_BINARY`.
enum ExecutorTestSupport {
    private final class Marker {}

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func executorBinary() throws -> String {
        let manager = FileManager.default
        if let path = ProcessInfo.processInfo.environment["LUNGFISH_EXECUTOR_BINARY"], manager.isExecutableFile(atPath: path) {
            return path
        }
        var starts = [URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()]
        #if os(macOS)
        starts.insert(Bundle(for: Marker.self).bundleURL.deletingLastPathComponent(), at: 0)
        #endif
        for start in starts {
            var folder = start
            for _ in 0..<4 {
                let candidate = folder.appendingPathComponent("lungfish-executor").path
                if manager.isExecutableFile(atPath: candidate) {
                    return candidate
                }
                folder = folder.deletingLastPathComponent()
            }
        }
        throw Failure(description: "lungfish-executor was not built next to the tests. Build it, or set LUNGFISH_EXECUTOR_BINARY")
    }

    /// A new empty folder for one test, with no space in its path.
    static func scratchFolder() throws -> String {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("executor-k3-\(UUID().uuidString.prefix(8))").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Starts `program` with the launcher, stdout and stderr in files of `folder`, and returns its PID.
    static func spawn(_ program: String, _ arguments: [String], folder: String, name: String = "child") throws -> pid_t {
        let stdin = try ExecutorSpawn.openNullForReading()
        let stdout = try ExecutorSpawn.openForWriting("\(folder)/\(name).out")
        let stderr = try ExecutorSpawn.openForWriting("\(folder)/\(name).err")
        defer {
            close(stdin)
            close(stdout)
            close(stderr)
        }
        return try ExecutorSpawn.spawn(
            executable: program, arguments: arguments, environment: ["PATH": "/usr/bin:/bin"],
            stdin: stdin, stdout: stdout, stderr: stderr
        )
    }

    /// Starts `lungfish-executor step` with its record, stdout and stderr in `folder`, the environment `EXE`, `DIR` and
    /// `PATH`, and the tool `program`. Returns the executor's PID.
    static func startStep(
        folder: String,
        options: [String] = [],
        environment: [String: String] = [:],
        _ program: [String]
    ) throws -> pid_t {
        let binary = try executorBinary()
        var arguments = ["step", "--record", "\(folder)/record.json", "--stdout", "\(folder)/tool.out",
                         "--stderr", "\(folder)/tool.err"] + options
        let base = ["EXE": binary, "DIR": folder, "PATH": "/usr/bin:/bin"]
        for (name, value) in base.merging(environment, uniquingKeysWith: { $1 }).sorted(by: { $0.key < $1.key }) {
            arguments += ["--env", "\(name)=\(value)"]
        }
        return try spawn(binary, arguments + ["--"] + program, folder: folder, name: "executor")
    }

    /// Waits up to `timeout` seconds for `pid` to exit and reaps it, or kills it and returns nil.
    static func waitForExit(_ pid: pid_t, timeout: Double) -> ChildExit? {
        let end = Date().addingTimeInterval(timeout)
        while true {
            var status: Int32 = 0
            var usage = rusage()
            let reaped = wait4(pid, &status, WNOHANG, &usage)
            if reaped == pid {
                return ChildExit(termination: ExecutorSpawn.decode(status: status),
                                 peakResidentBytes: ExecutorSpawn.peakResidentBytes(usage))
            }
            if reaped == -1 && errno != EINTR {
                return nil
            }
            if Date() >= end {
                kill(pid, SIGKILL)
                _ = ExecutorSpawn.reap(pid)
                return nil
            }
            usleep(20_000)
        }
    }

    /// Runs a step to its end and returns the executor's exit and record.
    static func runStep(
        folder: String,
        options: [String] = [],
        environment: [String: String] = [:],
        timeout: Double = 60,
        _ program: [String]
    ) throws -> (exit: ChildExit, record: StepRecord) {
        let pid = try startStep(folder: folder, options: options, environment: environment, program)
        guard let exit = waitForExit(pid, timeout: timeout) else {
            throw Failure(description: "the executor did not end within \(timeout) s")
        }
        return (exit, try record(in: folder))
    }

    static func record(in folder: String) throws -> StepRecord {
        let data = try Data(contentsOf: URL(fileURLWithPath: "\(folder)/record.json"))
        return try JSONDecoder().decode(StepRecord.self, from: data)
    }

    static func text(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    /// Polls until `condition` holds or `timeout` seconds pass.
    @discardableResult
    static func waitUntil(timeout: Double, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= end { return false }
            usleep(20_000)
        }
        return true
    }

    /// The PID a script wrote to `<folder>/<name>`, once the file exists.
    static func pid(in folder: String, _ name: String, timeout: Double = 10) throws -> pid_t {
        let path = "\(folder)/\(name)"
        waitUntil(timeout: timeout) { FileManager.default.fileExists(atPath: path) }
        guard let pid = pid_t(text(path).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw Failure(description: "no PID in \(path)")
        }
        return pid
    }

    /// True once no process `pid` exists, neither running nor a zombie.
    static func isGone(_ pid: pid_t, timeout: Double = 3) -> Bool {
        waitUntil(timeout: timeout) {
            #if os(Linux)
            return !FileManager.default.fileExists(atPath: "/proc/\(pid)")
            #else
            return kill(pid, 0) == -1 && errno == ESRCH
            #endif
        }
    }

    /// The parent of `pid` as the process table reads it.
    static func parent(of pid: pid_t) -> pid_t? {
        ProcessTable.snapshot().first { $0.pid == pid }?.parent
    }
}
