import Foundation
import LungfishWorkflow
import os

enum ReferenceBundleImportHelperLauncher {
    private enum LauncherError: Error, LocalizedError {
        case helperExecutableNotFound
        case helperLaunchFailed(String)
        case helperFailed(String)
        case helperProtocolError(String)

        var errorDescription: String? {
            switch self {
            case .helperExecutableNotFound:
                return "Could not locate application executable for reference import helper"
            case .helperLaunchFailed(let message):
                return "Failed to launch reference import helper: \(message)"
            case .helperFailed(let message):
                return "Reference import helper failed: \(message)"
            case .helperProtocolError(let message):
                return "Reference import helper protocol error: \(message)"
            }
        }
    }

    private struct HelperEvent: Decodable {
        let event: String
        let progress: Double?
        let message: String?
        let bundlePath: String?
        let bundleName: String?
        let error: String?
    }

    private struct HelperParseState: Sendable {
        var stdoutBuffer = Data()
        var helperError: String?
        var bundlePath: String?
        var bundleName: String?
    }

    static func importAsReferenceBundleViaAppHelper(
        sourceURL: URL,
        outputDirectory: URL,
        preferredBundleName: String? = nil,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> ReferenceBundleImportResult {
        guard let helperExecutableURL = Bundle.main.executableURL else {
            throw LauncherError.helperExecutableNotFound
        }

        return try await Task.detached(priority: .userInitiated) {
            try runReferenceImportViaHelper(
                sourceURL: sourceURL,
                outputDirectory: outputDirectory,
                helperExecutableURL: helperExecutableURL,
                preferredBundleName: preferredBundleName,
                progressHandler: progressHandler
            )
        }.value
    }

    private static func runReferenceImportViaHelper(
        sourceURL: URL,
        outputDirectory: URL,
        helperExecutableURL: URL,
        preferredBundleName: String?,
        progressHandler: (@Sendable (Double, String) -> Void)?
    ) throws -> ReferenceBundleImportResult {
        guard !helperExecutableURL.path.isEmpty else {
            throw LauncherError.helperExecutableNotFound
        }

        let process = Process()
        process.executableURL = helperExecutableURL

        var arguments = [
            "--reference-import-helper",
            "--input-file", sourceURL.path,
            "--output-dir", outputDirectory.path,
        ]
        if let preferredBundleName,
           !preferredBundleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments.append(contentsOf: ["--name", preferredBundleName])
        }
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let parseState = OSAllocatedUnfairLock(initialState: HelperParseState())
        let stderrState = OSAllocatedUnfairLock(initialState: Data())

        let handleEventLine: @Sendable (Data) -> Void = { line in
            guard !line.isEmpty else { return }

            guard let event = try? JSONDecoder().decode(HelperEvent.self, from: line) else {
                if let text = String(data: line, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty {
                    parseState.withLock { state in
                        if state.helperError == nil {
                            state.helperError = text
                        }
                    }
                }
                return
            }

            switch event.event {
            case "progress", "started":
                if let progress = event.progress {
                    progressHandler?(max(0.0, min(1.0, progress)), event.message ?? "Importing reference...")
                }
            case "done":
                parseState.withLock { state in
                    state.bundlePath = event.bundlePath
                    state.bundleName = event.bundleName
                }
            case "error":
                parseState.withLock { state in
                    state.helperError = event.error ?? event.message ?? "Reference import helper failed"
                }
            default:
                break
            }
        }

        let consumeStdoutData: @Sendable (Data) -> Void = { data in
            guard !data.isEmpty else { return }
            let lines = parseState.withLock { state -> [Data] in
                var parsed: [Data] = []
                state.stdoutBuffer.append(data)
                while let newlineIndex = state.stdoutBuffer.firstIndex(of: 0x0A) {
                    let line = Data(state.stdoutBuffer.prefix(upTo: newlineIndex))
                    state.stdoutBuffer.removeSubrange(...newlineIndex)
                    parsed.append(line)
                }
                return parsed
            }
            for line in lines {
                handleEventLine(line)
            }
        }

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        stdoutHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            consumeStdoutData(data)
        }
        stderrHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stderrState.withLock { $0.append(data) }
        }

        do {
            try process.run()
        } catch {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            throw LauncherError.helperLaunchFailed(error.localizedDescription)
        }

        process.waitUntilExit()

        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
        consumeStdoutData(stdoutHandle.readDataToEndOfFile())

        if let trailing = parseState.withLock({ state -> Data? in
            guard !state.stdoutBuffer.isEmpty else { return nil }
            defer { state.stdoutBuffer.removeAll(keepingCapacity: false) }
            return state.stdoutBuffer
        }) {
            handleEventLine(trailing)
        }

        if process.terminationStatus != 0 {
            let helperError = parseState.withLock { $0.helperError }
            let stderrMessage = stderrState.withLock { data -> String in
                String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            let fallback = "Helper exited with status \(process.terminationStatus)"
            let message = helperError ?? (stderrMessage.isEmpty ? fallback : stderrMessage)
            throw LauncherError.helperFailed(message)
        }

        let parsed = parseState.withLock { state -> (String?, String?) in
            (state.bundlePath, state.bundleName)
        }

        guard let bundlePath = parsed.0,
              !bundlePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LauncherError.helperProtocolError("Missing bundle path in helper response")
        }

        let bundleURL = URL(fileURLWithPath: bundlePath)
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw LauncherError.helperProtocolError(
                "Helper reported bundle path that does not exist: \(bundlePath)"
            )
        }

        let inferredName = parsed.1 ?? bundleURL.deletingPathExtension().lastPathComponent
        return ReferenceBundleImportResult(bundleURL: bundleURL, bundleName: inferredName)
    }
}
