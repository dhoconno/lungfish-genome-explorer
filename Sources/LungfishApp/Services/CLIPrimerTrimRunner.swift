// CLIPrimerTrimRunner.swift - Actor that spawns lungfish-cli bam primer-trim and parses its event stream
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow

/// Result of a successful `lungfish-cli bam primer-trim` run, decoded from
/// the shared `CLIEvent` schema instead of the private `runStart`/
/// `stageProgress`/`runComplete`/… JSON shape this runner used to hand-parse
/// (ARC-02, SIMP-04). `BAMPrimerTrimSubcommand` folds its rich completion
/// fields (`outputAlignmentTrackID`/`Name`, `bamPath`, `baiPath`,
/// `provenanceSidecarPath`) into `CLIEvent.complete`'s `outputs`
/// (`[bamPath, baiPath, provenanceSidecarPath]`) and a
/// `"trackID=… trackName=…"` message; this type parses them back out.
struct CLIPrimerTrimResult: Sendable, Equatable {
    let trackID: String?
    let trackName: String?
    let bamPath: String?
    let baiPath: String?
    let provenanceSidecarPath: String?
}

enum CLIPrimerTrimRunnerError: Error, LocalizedError, Equatable {
    case cliBinaryNotFound
    case processLaunchFailed(String)
    case processExited(status: Int32, stderr: String)
    case runFailed(message: String)
    case missingCompletion

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
        case .runFailed(let message):
            return message
        case .missingCompletion:
            return "lungfish-cli finished without reporting primer-trim completion."
        }
    }
}

/// A plain struct, not an actor: `CLISubprocessTransport` is itself an actor
/// owning all the concurrency here, so a wrapping actor would only add a
/// second isolation domain with nothing to protect. That second domain was a
/// real bug on the sibling `CLIVariantCallingRunner` (caught by the P6-A/B
/// integration gate): an actor-isolated `cancel()` queues behind an in-flight
/// `run()` call on the same actor instance and never executes until `run()`
/// returns -- but `run()` awaits the subprocess exiting, which only
/// `cancel()` was supposed to trigger. This type's `cancel()` only ever
/// forwarded to `transport.cancel()` (already `nonisolated` and thread-safe),
/// so it never actually reproduced that deadlock, but keeping it as an actor
/// left the same trap for the next person who adds actor-isolated state here.
struct CLIPrimerTrimRunner {
    private let transport: CLISubprocessTransport

    init(cliURLOverride: URL? = nil) {
        self.transport = CLISubprocessTransport(cliURLOverride: cliURLOverride)
    }

    static func cliBinaryPath() -> URL? {
        CLIBinaryLocator.cliBinaryPath()
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

    func run(
        arguments: [String],
        onEvent: @escaping @Sendable (CLIEvent) -> Void = { _ in }
    ) async throws -> CLIPrimerTrimResult {
        do {
            let result = try await transport.run(
                arguments: arguments,
                isCancelled: { false },
                onEvent: onEvent
            )
            return Self.parseCompletion(outputs: result.outputs, message: result.message)
        } catch let error as CLISubprocessTransport.RunError {
            switch error {
            case .nonZeroExit(let status, let stderr):
                throw CLIPrimerTrimRunnerError.processExited(status: status, stderr: stderr)
            case .launchFailed(let message):
                throw CLIPrimerTrimRunnerError.processLaunchFailed(message)
            case .cliNotFound:
                throw CLIPrimerTrimRunnerError.cliBinaryNotFound
            case .missingCompletion:
                throw CLIPrimerTrimRunnerError.missingCompletion
            case .failedEvent(let message, _):
                throw CLIPrimerTrimRunnerError.runFailed(message: message)
            }
        }
    }

    func cancel() {
        transport.cancel()
    }

    /// Parses the `"trackID=… trackName=…"` message and `[bamPath, baiPath,
    /// provenanceSidecarPath]` outputs `BAMPrimerTrimSubcommand` encodes into
    /// `CLIEvent.complete` for a successful run.
    private static func parseCompletion(outputs: [String], message: String?) -> CLIPrimerTrimResult {
        var trackID: String?
        var trackName: String?
        if let message {
            for token in Self.tokenize(message) {
                let parts = token.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let value = String(parts[1])
                switch parts[0] {
                case "trackID": trackID = value.isEmpty ? nil : value
                case "trackName": trackName = value.isEmpty ? nil : value
                default: break
                }
            }
        }
        return CLIPrimerTrimResult(
            trackID: trackID,
            trackName: trackName,
            bamPath: outputs.indices.contains(0) ? outputs[0] : nil,
            baiPath: outputs.indices.contains(1) ? outputs[1] : nil,
            provenanceSidecarPath: outputs.indices.contains(2) ? outputs[2] : nil
        )
    }

    /// Splits `"trackID=a trackName=Sample 1 • Primer Trim"` back into
    /// `["trackID=a", "trackName=Sample 1 • Primer Trim"]`: `trackName`'s
    /// value can itself contain spaces, so this only splits at the boundary
    /// before a recognized key, not on every space.
    private static func tokenize(_ message: String) -> [String] {
        let keys = ["trackID=", "trackName="]
        var results: [String] = []
        var remaining = Substring(message)
        while let keyRange = keys.compactMap({ remaining.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) {
            let afterKey = remaining[keyRange.upperBound...]
            let nextKeyStart = keys.compactMap { afterKey.range(of: $0)?.lowerBound }.min()
            let valueEnd = nextKeyStart ?? afterKey.endIndex
            results.append(String(remaining[keyRange.lowerBound..<valueEnd]).trimmingCharacters(in: .whitespaces))
            remaining = remaining[valueEnd...]
        }
        return results
    }
}
