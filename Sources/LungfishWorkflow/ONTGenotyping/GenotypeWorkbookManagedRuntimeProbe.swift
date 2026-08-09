import Darwin
import Foundation

public enum GenotypeWorkbookManagedRuntimeProbeError:
    Error,
    LocalizedError,
    Sendable
{
    case timedOut(TimeInterval)
    case failed(exitStatus: Int32, stderr: String)
    case outputLimitExceeded(
        stream: String,
        maximumBytes: Int,
        diagnostic: String
    )
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .timedOut(let seconds):
            return "Managed openpyxl runtime identity probe timed out after \(seconds) seconds."
        case .failed(let exitStatus, let stderr):
            let detail = stderr.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            return detail.isEmpty
                ? "Managed openpyxl runtime identity probe failed with exit code \(exitStatus)."
                : "Managed openpyxl runtime identity probe failed with exit code \(exitStatus): \(detail)"
        case .outputLimitExceeded(let stream, let maximumBytes, _):
            return "Managed openpyxl runtime identity probe exceeded the \(maximumBytes)-byte \(stream) limit."
        case .invalidResponse:
            return "Managed openpyxl runtime identity probe returned invalid JSON."
        }
    }
}

public enum GenotypeWorkbookManagedRuntimeProbe {
    private static let stdoutLimit = 16_384
    private static let stderrLimit = 65_536

    /// Async wrapper around `probe(pythonExecutableURL:timeout:cancellationCheck:)`
    /// that runs the underlying synchronous busy-poll on a detached background task
    /// (R3-R3ML-17). `probe` itself is fully synchronous and spins in a `usleep`
    /// polling loop for up to `timeout` seconds (15s default) -- calling it directly
    /// from the main actor or any async context would freeze that thread/task for the
    /// duration. This is the entry point any GUI call path should use; CLI callers
    /// that are already comfortable blocking their own dedicated thread may continue
    /// to call `probe` directly.
    public static func probeAsync(
        pythonExecutableURL: URL,
        timeout: TimeInterval = 15,
        cancellationCheck:
            @escaping @Sendable () -> Bool = {
                withUnsafeCurrentTask { $0?.isCancelled ?? false }
            }
    ) async throws -> [String: String] {
        try await Task.detached(priority: .utility) {
            try probe(
                pythonExecutableURL: pythonExecutableURL,
                timeout: timeout,
                cancellationCheck: cancellationCheck
            )
        }.value
    }

    /// Blocking; spins in a `usleep` polling loop (checking `cancellationCheck` and
    /// the process's live state every 20ms) for up to `timeout` seconds. Must be
    /// called off the main thread / from a background Task -- never directly from
    /// `@MainActor` or any other async context expected to stay responsive. Prefer
    /// `probeAsync`, which wraps this in a detached background task, unless the
    /// caller already owns a dedicated thread it is fine to block (e.g. a CLI
    /// subcommand's synchronous `run()`) (R3-R3ML-17).
    public static func probe(
        pythonExecutableURL: URL,
        timeout: TimeInterval = 15,
        cancellationCheck:
            @escaping @Sendable () -> Bool = {
                withUnsafeCurrentTask { $0?.isCancelled ?? false }
            }
    ) throws -> [String: String] {
        let executable = pythonExecutableURL.standardizedFileURL
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-c", script]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let stdoutData = CappedProbeStream(maximumBytes: stdoutLimit)
        let stderrData = CappedProbeStream(maximumBytes: stderrLimit)
        let drains = DispatchGroup()
        try process.run()
        let stdoutDescriptor = stdout.fileHandleForReading.fileDescriptor
        let stderrDescriptor = stderr.fileHandleForReading.fileDescriptor
        drains.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutData.drain(fileDescriptor: stdoutDescriptor)
            drains.leave()
        }
        drains.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrData.drain(fileDescriptor: stderrDescriptor)
            drains.leave()
        }

        let deadline = Date().addingTimeInterval(max(0.1, timeout))
        var cancellationRequested = false
        var timedOut = false
        var overflow: (stream: String, maximumBytes: Int)?
        while process.isRunning {
            if cancellationCheck() {
                cancellationRequested = true
                terminate(process)
                break
            }
            if stdoutData.didOverflow {
                overflow = ("stdout", stdoutLimit)
                terminate(process)
                break
            }
            if stderrData.didOverflow {
                overflow = ("stderr", stderrLimit)
                terminate(process)
                break
            }
            if Date() >= deadline {
                timedOut = true
                terminate(process)
                break
            }
            Darwin.usleep(20_000)
        }
        process.waitUntilExit()
        if drains.wait(timeout: .now() + 2) != .success {
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
            _ = drains.wait(timeout: .now() + 1)
        }
        if cancellationRequested { throw CancellationError() }
        if overflow == nil {
            if stdoutData.didOverflow {
                overflow = ("stdout", stdoutLimit)
            } else if stderrData.didOverflow {
                overflow = ("stderr", stderrLimit)
            }
        }
        if let overflow {
            let diagnosticBytes = stderrData.value.prefix(
                overflow.maximumBytes
            )
            throw GenotypeWorkbookManagedRuntimeProbeError
                .outputLimitExceeded(
                    stream: overflow.stream,
                    maximumBytes: overflow.maximumBytes,
                    diagnostic: String(
                        decoding: diagnosticBytes,
                        as: UTF8.self
                    )
                )
        }
        if timedOut {
            throw GenotypeWorkbookManagedRuntimeProbeError.timedOut(timeout)
        }
        let errorText = String(
            data: stderrData.value,
            encoding: .utf8
        ) ?? ""
        guard process.terminationStatus == 0 else {
            throw GenotypeWorkbookManagedRuntimeProbeError.failed(
                exitStatus: process.terminationStatus,
                stderr: errorText
            )
        }
        guard let object = try JSONSerialization.jsonObject(
            with: stdoutData.value
        ) as? [String: String],
              let pythonVersion = object["python_version"],
              !pythonVersion.isEmpty,
              let openpyxlVersion = object["openpyxl_version"],
              !openpyxlVersion.isEmpty else {
            throw GenotypeWorkbookManagedRuntimeProbeError.invalidResponse
        }
        return [
            "pythonExecutable": executable.path,
            "condaEnvironment": "openpyxl",
            "condaPrefix": executable.deletingLastPathComponent()
                .deletingLastPathComponent().path,
            "pythonVersion": pythonVersion,
            "openpyxlVersion": openpyxlVersion,
        ]
    }

    private static func terminate(_ process: Process) {
        process.terminate()
        let graceDeadline = Date().addingTimeInterval(0.25)
        while process.isRunning, Date() < graceDeadline {
            Darwin.usleep(10_000)
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }

    private static let script = """
        import json
        import platform
        import openpyxl
        print(json.dumps({
            "python_version": platform.python_version(),
            "openpyxl_version": openpyxl.__version__,
        }))
        """
}

private final class CappedProbeStream: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private var storage = Data()
    private var overflow = false

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
        storage.reserveCapacity(maximumBytes)
    }

    var value: Data { lock.withLock { storage } }
    var didOverflow: Bool { lock.withLock { overflow } }

    func drain(fileDescriptor: Int32) {
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(
                    fileDescriptor,
                    rawBuffer.baseAddress,
                    rawBuffer.count
                )
            }
            if count < 0 {
                if errno == EINTR { continue }
                return
            }
            if count == 0 { return }
            lock.withLock {
                let available = max(0, maximumBytes - storage.count)
                let retained = min(available, count)
                if retained > 0 {
                    storage.append(contentsOf: buffer[0..<retained])
                }
                if retained < count {
                    overflow = true
                }
            }
        }
    }
}
