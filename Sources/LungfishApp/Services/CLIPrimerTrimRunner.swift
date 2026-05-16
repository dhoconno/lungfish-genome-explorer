// CLIPrimerTrimRunner.swift - Actor that spawns lungfish-cli bam primer-trim and parses its event stream
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import os.log

private let primerTrimRunnerLogger = Logger(
    subsystem: LogSubsystem.app,
    category: "CLIPrimerTrimRunner"
)

enum CLIPrimerTrimEvent: Sendable, Equatable {
    case runStart(message: String)
    case preflightStart(message: String)
    case preflightComplete(message: String)
    case stageStart(message: String)
    case stageProgress(progress: Double, message: String)
    case stageComplete(message: String)
    case attachStart(message: String)
    case attachComplete(
        trackID: String?,
        trackName: String?,
        bamPath: String?,
        baiPath: String?,
        provenanceSidecarPath: String?
    )
    case runComplete(
        trackID: String,
        trackName: String,
        bamPath: String,
        baiPath: String,
        provenanceSidecarPath: String
    )
    case runFailed(message: String)
}

enum CLIPrimerTrimRunnerError: Error, LocalizedError, Equatable {
    case cliBinaryNotFound
    case processLaunchFailed(String)
    case processExited(status: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .cliBinaryNotFound:
            return "lungfish-cli binary not found"
        case .processLaunchFailed(let detail):
            return "Failed to launch lungfish-cli: \(detail)"
        case .processExited(let status, let stderr):
            guard !stderr.isEmpty else {
                return "lungfish-cli exited with status \(status)"
            }
            return "lungfish-cli exited with status \(status): \(stderr)"
        }
    }
}

private final class CLIPrimerTrimStreamState: @unchecked Sendable {
    private struct Buffers {
        var stdoutBuffer = Data()
        var stderrBuffer = Data()

        mutating func drainStdoutLines() -> [String] {
            var lines: [String] = []
            while let newlineRange = stdoutBuffer.range(of: Data("\n".utf8)) {
                let lineData = stdoutBuffer.subdata(
                    in: stdoutBuffer.startIndex..<newlineRange.lowerBound
                )
                stdoutBuffer.removeSubrange(
                    stdoutBuffer.startIndex..<newlineRange.upperBound
                )
                if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                    lines.append(line)
                }
            }
            return lines
        }

        mutating func drainRemainingStdoutLine() -> [String] {
            guard !stdoutBuffer.isEmpty else { return [] }
            let lineData = stdoutBuffer
            stdoutBuffer.removeAll(keepingCapacity: false)
            guard let line = String(data: lineData, encoding: .utf8), !line.isEmpty else {
                return []
            }
            return [line]
        }
    }

    private let lock = OSAllocatedUnfairLock(initialState: Buffers())

    func appendStderr(_ chunk: Data) {
        lock.withLock { buffers in
            buffers.stderrBuffer.append(chunk)
        }
    }

    func appendStdout(_ chunk: Data) -> [String] {
        lock.withLock { buffers in
            buffers.stdoutBuffer.append(chunk)
            return buffers.drainStdoutLines()
        }
    }

    func finishStdout() -> [String] {
        lock.withLock { buffers in
            buffers.drainRemainingStdoutLine()
        }
    }

    func stderrText() -> String {
        lock.withLock { buffers in
            String(data: buffers.stderrBuffer, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }
}

private final class CLIPrimerTrimStreamCompletion: @unchecked Sendable {
    private enum Stream {
        case stdout
        case stderr
    }

    private struct State {
        var stdoutClosed = false
        var stderrClosed = false
        var resumed = false
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    func markStdoutClosed(_ continuation: CheckedContinuation<Void, Never>) {
        mark(.stdout, continuation)
    }

    func markStderrClosed(_ continuation: CheckedContinuation<Void, Never>) {
        mark(.stderr, continuation)
    }

    private func mark(
        _ stream: Stream,
        _ continuation: CheckedContinuation<Void, Never>
    ) {
        let shouldResume = lock.withLock { state in
            switch stream {
            case .stdout:
                state.stdoutClosed = true
            case .stderr:
                state.stderrClosed = true
            }
            guard state.stdoutClosed && state.stderrClosed && !state.resumed else {
                return false
            }
            state.resumed = true
            return true
        }
        if shouldResume {
            continuation.resume()
        }
    }
}

actor CLIPrimerTrimRunner {
    private var process: Process?

    static func cliBinaryPath() -> URL? {
        CLIImportRunner.cliBinaryPath()
    }

    static func buildCLIArguments(
        bundleURL: URL,
        alignmentTrackID: String,
        schemeURL: URL,
        outputTrackName: String,
        targetReferenceName: String? = nil,
        ivarMinQuality: Int = 20,
        ivarMinLength: Int = 30,
        ivarSlidingWindow: Int = 4,
        ivarPrimerOffset: Int = 0
    ) -> [String] {
        var arguments: [String] = [
            "bam",
            "primer-trim",
            "--bundle", bundleURL.path,
            "--alignment-track", alignmentTrackID,
            "--scheme", schemeURL.path,
            "--name", outputTrackName,
            "--format", "json",
            "--no-progress"
        ]
        if let targetReferenceName, !targetReferenceName.isEmpty {
            arguments += ["--target-reference", targetReferenceName]
        }
        if ivarMinQuality != 20 {
            arguments += ["--ivar-min-quality", String(ivarMinQuality)]
        }
        if ivarMinLength != 30 {
            arguments += ["--ivar-min-length", String(ivarMinLength)]
        }
        if ivarSlidingWindow != 4 {
            arguments += ["--ivar-sliding-window", String(ivarSlidingWindow)]
        }
        if ivarPrimerOffset != 0 {
            arguments += ["--ivar-primer-offset", String(ivarPrimerOffset)]
        }
        return arguments
    }

    static func parseEvent(from line: String) throws -> CLIPrimerTrimEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else { return nil }

        guard let data = trimmed.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = dict["event"] as? String else {
            return nil
        }

        let message = dict["message"] as? String ?? ""
        let progress = dict["progress"] as? Double
        let outputTrackID = dict["outputAlignmentTrackID"] as? String
        let outputTrackName = dict["outputAlignmentTrackName"] as? String
        let bamPath = dict["bamPath"] as? String
        let baiPath = dict["baiPath"] as? String
        let provenanceSidecarPath = dict["provenanceSidecarPath"] as? String

        switch event {
        case "runStart":
            return .runStart(message: message)
        case "preflightStart":
            return .preflightStart(message: message)
        case "preflightComplete":
            return .preflightComplete(message: message)
        case "stageStart":
            return .stageStart(message: message)
        case "stageProgress":
            return .stageProgress(progress: progress ?? 0, message: message)
        case "stageComplete":
            return .stageComplete(message: message)
        case "attachStart":
            return .attachStart(message: message)
        case "attachComplete":
            return .attachComplete(
                trackID: outputTrackID,
                trackName: outputTrackName,
                bamPath: bamPath,
                baiPath: baiPath,
                provenanceSidecarPath: provenanceSidecarPath
            )
        case "runComplete":
            guard let outputTrackID,
                  let outputTrackName,
                  let bamPath,
                  let baiPath,
                  let provenanceSidecarPath else { return nil }
            return .runComplete(
                trackID: outputTrackID,
                trackName: outputTrackName,
                bamPath: bamPath,
                baiPath: baiPath,
                provenanceSidecarPath: provenanceSidecarPath
            )
        case "runFailed":
            return .runFailed(message: message)
        default:
            primerTrimRunnerLogger.debug("Unknown CLI primer-trim event type: \(event)")
            return nil
        }
    }

    private static func emitEvents(
        from lines: [String],
        onEvent: @escaping @Sendable (CLIPrimerTrimEvent) -> Void
    ) {
        for line in lines {
            do {
                if let event = try parseEvent(from: line) {
                    onEvent(event)
                }
            } catch {
                primerTrimRunnerLogger.warning(
                    "Failed to parse primer-trim CLI event: \(error.localizedDescription)"
                )
            }
        }
    }

    func run(
        arguments: [String],
        onEvent: @escaping @Sendable (CLIPrimerTrimEvent) -> Void
    ) async throws {
        guard let binaryURL = Self.cliBinaryPath() else {
            throw CLIPrimerTrimRunnerError.cliBinaryNotFound
        }

        let process = Process()
        process.executableURL = binaryURL
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        self.process = process

        do {
            try process.run()
        } catch {
            self.process = nil
            throw CLIPrimerTrimRunnerError.processLaunchFailed(error.localizedDescription)
        }

        let state = CLIPrimerTrimStreamState()

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let completion = CLIPrimerTrimStreamCompletion()

            stderrHandle.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else {
                    stderrHandle.readabilityHandler = nil
                    completion.markStderrClosed(continuation)
                    return
                }
                state.appendStderr(chunk)
            }

            stdoutHandle.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else {
                    Self.emitEvents(from: state.finishStdout(), onEvent: onEvent)
                    stdoutHandle.readabilityHandler = nil
                    completion.markStdoutClosed(continuation)
                    return
                }

                Self.emitEvents(from: state.appendStdout(chunk), onEvent: onEvent)
            }
        }

        process.waitUntilExit()
        stderrHandle.readabilityHandler = nil
        self.process = nil

        if Task.isCancelled {
            throw CancellationError()
        }

        let status = process.terminationStatus
        guard status == 0 else {
            throw CLIPrimerTrimRunnerError.processExited(status: status, stderr: state.stderrText())
        }
    }

    func cancel() {
        guard let process, process.isRunning else { return }
        process.terminate()
    }
}
