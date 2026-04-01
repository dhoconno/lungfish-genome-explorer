// MetagenomicsImportHelperClient.swift - Launches helper-mode metagenomics import subprocesses
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishWorkflow
import os.log

/// Errors thrown by ``MetagenomicsImportHelperClient``.
public enum MetagenomicsImportHelperClientError: Error, LocalizedError {
    case helperExecutableNotFound
    case helperLaunchFailed(String)
    case helperFailed(String, partialResultDirectory: URL?)
    case helperProtocolError(String)

    public var errorDescription: String? {
        switch self {
        case .helperExecutableNotFound:
            return "Could not locate application executable for metagenomics import helper"
        case .helperLaunchFailed(let message):
            return "Failed to launch metagenomics import helper: \(message)"
        case .helperFailed(let message, _):
            return "Metagenomics import helper failed: \(message)"
        case .helperProtocolError(let message):
            return "Metagenomics import helper protocol error: \(message)"
        }
    }

    /// The partial result directory that should be cleaned up, if any.
    var partialResultDirectory: URL? {
        if case .helperFailed(_, let dir) = self { return dir }
        return nil
    }
}

/// Runs helper-mode metagenomics imports and parses structured progress events.
public enum MetagenomicsImportHelperClient {
    /// Final result returned after a successful helper run.
    public struct Result: Sendable {
        public let resultDirectory: URL
        public let detail: String
    }

    /// NAO-MGS-specific import options forwarded to helper mode.
    public struct NaoMgsOptions: Sendable {
        public let sampleName: String?
        public let minIdentity: Double
        public let includeAlignment: Bool
        public let fetchReferences: Bool

        public init(
            sampleName: String? = nil,
            minIdentity: Double = 0,
            includeAlignment: Bool = true,
            fetchReferences: Bool = true
        ) {
            self.sampleName = sampleName
            self.minIdentity = minIdentity
            self.includeAlignment = includeAlignment
            self.fetchReferences = fetchReferences
        }
    }

    private struct Event: Decodable {
        let event: String
        let progress: Double?
        let message: String?
        let resultPath: String?
        let error: String?
    }

    private struct ParseState: Sendable {
        var stdoutBuffer = Data()
        var helperError: String?
        var resultPath: String?
        var finalMessage: String?
    }

    /// Imports classifier output by launching the app executable in helper mode.
    public static func importViaCLI(
        kind: MetagenomicsImportKind,
        inputURL: URL,
        outputDirectory: URL,
        secondaryInputURL: URL? = nil,
        preferredName: String? = nil,
        naoMgsOptions: NaoMgsOptions? = nil,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> Result {
        try await Task.detached(priority: .userInitiated) {
            try runHelper(
                kind: kind,
                inputURL: inputURL,
                outputDirectory: outputDirectory,
                secondaryInputURL: secondaryInputURL,
                preferredName: preferredName,
                naoMgsOptions: naoMgsOptions,
                progressHandler: progressHandler
            )
        }.value
    }

    private static func runHelper(
        kind: MetagenomicsImportKind,
        inputURL: URL,
        outputDirectory: URL,
        secondaryInputURL: URL?,
        preferredName: String?,
        naoMgsOptions: NaoMgsOptions?,
        progressHandler: (@Sendable (Double, String) -> Void)?
    ) throws -> Result {
        guard let executablePath = CommandLine.arguments.first, !executablePath.isEmpty else {
            throw MetagenomicsImportHelperClientError.helperExecutableNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)

        var args = [
            "--metagenomics-import-helper",
            "--kind", kind.rawValue,
            "--input-path", inputURL.path,
            "--output-dir", outputDirectory.path,
        ]
        if let secondaryInputURL {
            args.append(contentsOf: ["--secondary-input", secondaryInputURL.path])
        }
        if let preferredName,
           !preferredName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args.append(contentsOf: ["--name", preferredName])
        }
        if kind == .naomgs {
            let options = naoMgsOptions ?? NaoMgsOptions()
            if let sampleName = options.sampleName?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !sampleName.isEmpty {
                args.append(contentsOf: ["--sample-name", sampleName])
            }
            let normalizedIdentity = max(0, min(100, options.minIdentity))
            args.append(contentsOf: ["--min-identity", String(normalizedIdentity)])
            args.append(contentsOf: ["--include-alignment", options.includeAlignment ? "true" : "false"])
            args.append(contentsOf: ["--fetch-references", options.fetchReferences ? "true" : "false"])
        }
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let parseState = OSAllocatedUnfairLock(initialState: ParseState())
        let stderrState = OSAllocatedUnfairLock(initialState: Data())

        let handleEventLine: @Sendable (Data) -> Void = { line in
            guard !line.isEmpty else { return }
            guard let event = try? JSONDecoder().decode(Event.self, from: line) else {
                if let text = String(data: line, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
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
            case "started", "progress":
                if let progress = event.progress {
                    progressHandler?(max(0.0, min(1.0, progress)), event.message ?? "Importing...")
                }
            case "done":
                parseState.withLock { state in
                    state.resultPath = event.resultPath
                    state.finalMessage = event.message
                }
            case "error":
                parseState.withLock { state in
                    state.helperError = event.error ?? event.message ?? "Import helper failed"
                    if let path = event.resultPath, !path.isEmpty {
                        state.resultPath = path
                    }
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
            throw MetagenomicsImportHelperClientError.helperLaunchFailed(error.localizedDescription)
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
            let (helperError, partialPath) = parseState.withLock { ($0.helperError, $0.resultPath) }
            let stderrMessage = stderrState.withLock { data -> String in
                String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            let fallback = "Helper exited with status \(process.terminationStatus)"
            let message = helperError ?? (stderrMessage.isEmpty ? fallback : stderrMessage)
            let partialDir = partialPath.map { URL(fileURLWithPath: $0) }
            throw MetagenomicsImportHelperClientError.helperFailed(message, partialResultDirectory: partialDir)
        }

        let parsed = parseState.withLock { state -> (String?, String?) in
            (state.resultPath, state.finalMessage)
        }
        guard let resultPath = parsed.0,
              !resultPath.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty else {
            throw MetagenomicsImportHelperClientError.helperProtocolError(
                "Missing result path in helper response"
            )
        }

        let resultDirectory = URL(fileURLWithPath: resultPath)
        guard FileManager.default.fileExists(atPath: resultDirectory.path) else {
            throw MetagenomicsImportHelperClientError.helperProtocolError(
                "Helper reported result path that does not exist: \(resultPath)"
            )
        }

        return Result(
            resultDirectory: resultDirectory,
            detail: parsed.1 ?? "Import complete"
        )
    }
}
