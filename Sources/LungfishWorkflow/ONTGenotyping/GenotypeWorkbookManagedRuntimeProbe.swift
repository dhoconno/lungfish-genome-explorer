import Darwin
import Foundation

public enum GenotypeWorkbookManagedRuntimeProbeError:
    Error,
    LocalizedError,
    Sendable
{
    case timedOut(TimeInterval)
    case failed(exitStatus: Int32, stderr: String)
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
        case .invalidResponse:
            return "Managed openpyxl runtime identity probe returned invalid JSON."
        }
    }
}

public enum GenotypeWorkbookManagedRuntimeProbe {
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
        let stdoutData = LockedProbeData()
        let stderrData = LockedProbeData()
        let drains = DispatchGroup()
        try process.run()
        drains.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutData.set(
                stdout.fileHandleForReading.readDataToEndOfFile()
            )
            drains.leave()
        }
        drains.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrData.set(
                stderr.fileHandleForReading.readDataToEndOfFile()
            )
            drains.leave()
        }

        let deadline = Date().addingTimeInterval(max(0.1, timeout))
        var cancellationRequested = false
        var timedOut = false
        while process.isRunning {
            if cancellationCheck() {
                cancellationRequested = true
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
        _ = drains.wait(timeout: .now() + 2)
        if cancellationRequested { throw CancellationError() }
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

private final class LockedProbeData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var value: Data { lock.withLock { storage } }

    func set(_ data: Data) {
        lock.withLock { storage = data }
    }
}
