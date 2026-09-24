// CLIVariantCallingRunner.swift — Runs `lungfish-cli variants call` through CLISubprocessTransport.
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishKit
import LungfishWorkflow

/// Result of a successful `lungfish-cli variants call` run, decoded from the
/// shared `CLIEvent` schema instead of the private `runStart`/`stageProgress`/
/// `runComplete`/… JSON shape this runner used to hand-parse (ARC-02,
/// SIMP-04). `VariantsCommand` folds its rich completion fields
/// (`variantTrackID`, `vcfPath`, `tbiPath`, `databasePath`) into
/// `CLIEvent.complete`'s `outputs` (`[databasePath, vcfPath, tbiPath]`) and a
/// `"trackID=… trackName=…"` message; this type parses them back out.
struct CLIVariantCallingResult: Sendable, Equatable {
    let trackID: String?
    let trackName: String?
    let databasePath: String?
    let vcfPath: String?
    let tbiPath: String?
}

enum CLIVariantCallingRunnerError: Error, LocalizedError, Equatable {
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
            return "lungfish-cli finished without reporting variant-calling completion."
        }
    }
}

actor CLIVariantCallingRunner {
    private let transport: CLISubprocessTransport
    private var cancellationRequested = false

    init(cliURLOverride: URL? = nil) {
        self.transport = CLISubprocessTransport(cliURLOverride: cliURLOverride)
    }

    /// Retained for source compatibility with call sites that supply a custom
    /// binary lookup rather than a fixed override URL.
    init(cliBinaryPathProvider: @escaping @Sendable () -> URL?) {
        self.transport = CLISubprocessTransport(cliURLOverride: cliBinaryPathProvider())
    }

    static func buildCLIArguments(request: BundleVariantCallingRequest) -> [String] {
        var arguments = [
            "variants",
            "call",
            "--bundle", request.bundleURL.path,
            "--alignment-track", request.alignmentTrackID,
            "--caller", request.caller.rawValue,
            "--name", request.outputTrackName,
            "--format", "json",
            "--threads", String(max(1, request.threads)),
            "--no-progress",
        ]

        if let minimumAlleleFrequency = request.minimumAlleleFrequency {
            arguments += ["--min-af", String(minimumAlleleFrequency)]
        }

        if let minimumDepth = request.minimumDepth {
            arguments += ["--min-depth", String(minimumDepth)]
        }

        if request.ivarPrimerTrimConfirmed {
            arguments.append("--ivar-primer-trimmed")
        }

        if request.caller == .ivar {
            arguments += ["--ivar-consensus-af", String(request.ivarConsensusAF)]
            arguments += ["--ivar-merge-af-threshold", String(request.ivarMergeAFThreshold)]
            arguments += ["--ivar-bad-quality-threshold", String(request.ivarBadQualityThreshold)]
            if !request.ivarIgnoreStrandBias {
                arguments.append("--ivar-no-ignore-strand-bias")
            }
        }

        let medakaModel = request.medakaModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !medakaModel.isEmpty {
            arguments += ["--medaka-model", medakaModel]
        }

        if !request.advancedArguments.isEmpty {
            arguments += ["--extra-args", AdvancedCommandLineOptions.join(request.advancedArguments)]
        }

        return arguments
    }

    /// Runs `arguments`, invoking `onEvent` for every progress/log line and
    /// returning the parsed completion fields on success.
    func run(
        arguments: [String],
        onEvent: @escaping @Sendable (CLIEvent) -> Void = { _ in }
    ) async throws -> CLIVariantCallingResult {
        do {
            let result = try await transport.run(
                arguments: arguments,
                isCancelled: { [cancellationRequested] in cancellationRequested },
                onEvent: onEvent
            )
            return Self.parseCompletion(outputs: result.outputs, message: result.message)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CLISubprocessTransport.RunError {
            switch error {
            case .nonZeroExit(let status, let stderr):
                throw CLIVariantCallingRunnerError.processExited(status: status, stderr: stderr)
            case .launchFailed(let message):
                throw CLIVariantCallingRunnerError.processLaunchFailed(message)
            case .cliNotFound:
                throw CLIVariantCallingRunnerError.cliBinaryNotFound
            case .missingCompletion:
                throw CLIVariantCallingRunnerError.missingCompletion
            case .failedEvent(let message, _):
                throw CLIVariantCallingRunnerError.runFailed(message: message)
            }
        }
    }

    func cancel() {
        cancellationRequested = true
        transport.cancel()
    }

    /// Parses the `"trackID=… trackName=…"` message and `[databasePath,
    /// vcfPath, tbiPath]` outputs `VariantsCommand` encodes into
    /// `CLIEvent.complete` for a successful run.
    private static func parseCompletion(outputs: [String], message: String?) -> CLIVariantCallingResult {
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
        return CLIVariantCallingResult(
            trackID: trackID,
            trackName: trackName,
            databasePath: outputs.indices.contains(0) ? outputs[0] : nil,
            vcfPath: outputs.indices.contains(1) ? outputs[1] : nil,
            tbiPath: outputs.indices.contains(2) ? outputs[2] : nil
        )
    }

    /// Splits `"trackID=a trackName=Sample 1 • LoFreq"` back into
    /// `["trackID=a", "trackName=Sample 1 • LoFreq"]`: `trackName`'s value can
    /// itself contain spaces, so this only splits at the boundary before a
    /// recognized key, not on every space.
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
