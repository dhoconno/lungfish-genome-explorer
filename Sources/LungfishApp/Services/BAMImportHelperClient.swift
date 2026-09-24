// BAMImportHelperClient.swift - Launches helper-mode BAM import subprocesses
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os
import LungfishWorkflow

/// Errors thrown by ``BAMImportHelperClient``.
public enum BAMImportHelperClientError: Error, LocalizedError {
    case helperExecutableNotFound
    case helperLaunchFailed(String)
    case helperFailed(String)
    case helperProtocolError(String)

    public var errorDescription: String? {
        switch self {
        case .helperExecutableNotFound:
            return "Could not locate application executable for BAM import helper"
        case .helperLaunchFailed(let message):
            return "Failed to launch BAM import helper: \(message)"
        case .helperFailed(let message):
            return "BAM import helper failed: \(message)"
        case .helperProtocolError(let message):
            return "BAM import helper protocol error: \(message)"
        }
    }
}

/// Runs helper-mode BAM imports and parses structured progress events.
public enum BAMImportHelperClient {
    /// Final result returned after a successful helper run.
    public struct Result: Sendable {
        public let mappedReads: Int64
        public let unmappedReads: Int64
        public let sampleCount: Int
        public let indexWasCreated: Bool
        public let wasSorted: Bool
    }

    private struct Event: Decodable {
        let event: String
        let progress: Double?
        let message: String?
        let mappedReads: Int64?
        let unmappedReads: Int64?
        let sampleCount: Int?
        let indexWasCreated: Bool?
        let wasSorted: Bool?
        let error: String?
    }

    private struct ParseState: Sendable {
        var stdoutBuffer = Data()
        var helperError: String?
        var mappedReads: Int64?
        var unmappedReads: Int64?
        var sampleCount: Int?
        var indexWasCreated: Bool?
        var wasSorted: Bool?
    }

    /// Imports an alignment by launching the app executable in helper mode.
    public static func importViaCLI(
        bamURL: URL,
        bundleURL: URL,
        name: String? = nil,
        shouldCancel: (@Sendable () -> Bool)? = nil,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> Result {
        try await Task.detached(priority: .userInitiated) {
            try runHelper(
                bamURL: bamURL,
                bundleURL: bundleURL,
                name: name,
                shouldCancel: shouldCancel,
                progressHandler: progressHandler
            )
        }.value
    }

    private static func runHelper(
        bamURL: URL,
        bundleURL: URL,
        name: String?,
        shouldCancel: (@Sendable () -> Bool)?,
        progressHandler: (@Sendable (Double, String) -> Void)?
    ) throws -> Result {
        guard let executablePath = CommandLine.arguments.first, !executablePath.isEmpty else {
            throw BAMImportHelperClientError.helperExecutableNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)

        var args = [
            "--bam-import-helper",
            "--bam-path", bamURL.path,
            "--bundle-path", bundleURL.path,
        ]
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args.append(contentsOf: ["--name", name])
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
                    progressHandler?(max(0.0, min(1.0, progress)), event.message ?? "Importing alignments...")
                }
            case "done":
                parseState.withLock { state in
                    state.mappedReads = event.mappedReads
                    state.unmappedReads = event.unmappedReads
                    state.sampleCount = event.sampleCount
                    state.indexWasCreated = event.indexWasCreated
                    state.wasSorted = event.wasSorted
                }
            case "error":
                parseState.withLock { state in
                    state.helperError = event.error ?? event.message ?? "BAM import helper failed"
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
            throw BAMImportHelperClientError.helperLaunchFailed(error.localizedDescription)
        }

        // PERF-13: terminate the whole process tree on cancel (not just the
        // helper root), and register with NativeProcessRegistry so app quit
        // also reaches it. The BAM import helper can spawn samtools children
        // that must not outlive a cancelled import.
        let requestedCancel = waitForHelperProcessExit(
            process,
            shouldCancel: { shouldCancel?() == true }
        )

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

        if requestedCancel || shouldCancel?() == true {
            throw CancellationError()
        }

        if process.terminationStatus != 0 {
            let helperError = parseState.withLock { $0.helperError }
            let stderrMessage = stderrState.withLock { data -> String in
                String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            let fallback = "Helper exited with status \(process.terminationStatus)"
            let message = helperError ?? (stderrMessage.isEmpty ? fallback : stderrMessage)
            throw BAMImportHelperClientError.helperFailed(message)
        }

        let parsed = parseState.withLock { state in
            (
                state.mappedReads,
                state.unmappedReads,
                state.sampleCount,
                state.indexWasCreated,
                state.wasSorted
            )
        }

        guard let mappedReads = parsed.0,
              let unmappedReads = parsed.1,
              let sampleCount = parsed.2,
              let indexWasCreated = parsed.3,
              let wasSorted = parsed.4 else {
            throw BAMImportHelperClientError.helperProtocolError(
                "Missing final result fields in BAM helper response"
            )
        }

        return Result(
            mappedReads: mappedReads,
            unmappedReads: unmappedReads,
            sampleCount: sampleCount,
            indexWasCreated: indexWasCreated,
            wasSorted: wasSorted
        )
    }
}
