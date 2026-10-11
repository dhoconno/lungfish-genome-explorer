// FASTQImportEventStream.swift - The version 2 events of `import fastq`, made from the batch importer's log events
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// Turns the log events of a batch import into the version 2 events that `lungfish-cli import fastq
/// --format json` prints, which replaced its private stream S1 in Phase 2.7 (lane Q4,
/// `docs/formats/cli-events.md`).
///
/// Each event keeps the text and the level the app's import runner gave the S1 event it replaces, so
/// the Operations row reads as before. A sample's start and each step's start are `progress` events.
/// Their fraction is one fraction for the whole import that only moves forward, `(index + share) /
/// count` for sample `index` of `count`, where a step's share is the part of the sample that the runner
/// filled before, 0.8 times the step's number over the step count. A notice and a skipped sample are
/// `log` events at level `warning`, a failed sample is one at `error`, and every other line is at
/// `info`. A finished sample adds its bundle to ``bundles``, which the `complete` line names.
public struct FASTQImportEventStream: Sendable {
    /// The part of a sample's share of the bar that its steps fill.
    public static let stepShareOfSample = 0.8

    /// The bundles the import published, as absolute paths, in the order the samples finished.
    public private(set) var bundles: [String] = []
    /// Each failed sample as `<sample>: <error>`, in the order they failed.
    public private(set) var failures: [String] = []

    private let importsFolder: URL
    private var sampleIndex = 0
    private var sampleCount = 1

    /// - Parameter projectDirectory: The project the import writes into, whose `Imports` folder holds
    ///   each bundle.
    public init(projectDirectory: URL) {
        importsFolder = projectDirectory.appendingPathComponent("Imports")
    }

    /// The line the Operations row logs for a notice, from the CLI or from the Import FASTQ sheet.
    public static func noticeLine(sample: String, message: String) -> String {
        "\(sample) — \(message)"
    }

    /// The events that one log event of the importer becomes, in order. Some become none.
    public mutating func events(for event: ImportLogEvent) -> [CLIEvent] {
        switch event {
        case let .importStart(count, _):
            sampleCount = max(count, 1)
            return []
        case let .platformResolved(sample, _, _, _, _, _, message):
            return [.log(level: .info, message: "\(sample): \(message)")]
        case let .sampleStart(sample, index, total, _, _, _):
            sampleIndex = index
            sampleCount = max(total, 1)
            return [.progress(fraction: fraction(stepShare: 0), message: "Importing \(sample) (\(index + 1)/\(sampleCount))")]
        case let .stepStart(sample, step, stepIndex, totalSteps):
            let share = Self.stepShareOfSample * Double(stepIndex) / Double(max(1, totalSteps))
            return [
                .progress(fraction: fraction(stepShare: share), message: "\(sample): \(step)"),
                .log(level: .info, message: "\(sample) — step \(stepIndex)/\(totalSteps): \(step)"),
            ]
        case let .stepComplete(sample, step, durationSeconds):
            return [.log(level: .info, message: "\(sample) — \(step) completed (\(String(format: "%.1f", durationSeconds))s)")]
        case let .notice(sample, message):
            return [.log(level: .warning, message: Self.noticeLine(sample: sample, message: message))]
        case let .recipeReadDelta(sample, label, inputReads, outputReads, _, _):
            let summary = RecipeAppliedInfo.ReadDeltaSummary(inputReads: inputReads, outputReads: outputReads)
            return [.log(level: .info, message: "\(sample) — \(RecipeAppliedInfo.readDeltaLogLine(label, summary))")]
        case let .sampleComplete(sample, bundle, _, _, _):
            bundles.append(importsFolder.appendingPathComponent(bundle).path)
            return [.log(level: .info, message: "\(sample) — bundle created")]
        case let .sampleSkip(sample, reason):
            return [.log(level: .warning, message: "\(sample) skipped: \(reason)")]
        case let .sampleFailed(sample, error):
            failures.append("\(sample): \(error)")
            return [.log(level: .error, message: "\(sample) failed: \(error)")]
        case let .importComplete(completed, skipped, failed, totalDurationSeconds):
            let duration = String(format: "%.1f", totalDurationSeconds)
            return [.log(level: .info, message: "Import complete — \(completed) done, \(skipped) skipped, \(failed) failed (\(duration)s)")]
        }
    }

    /// One artifact for each bundle in ``bundles``, typed by the FASTQ bundle kind, with the role
    /// `bundle` and the bundle's own record when the import wrote one.
    public func bundleArtifacts() -> [CLIEventArtifact] {
        bundles.map { path in
            let record = URL(fileURLWithPath: path).appendingPathComponent(BundleKindDescriptor.SidecarNaming.rootRecordFileName)
            return CLIEventArtifact(
                kind: BundleKindID.fastq.rawValue,
                path: path,
                role: CLIEventArtifact.Role.bundle,
                provenancePath: FileManager.default.fileExists(atPath: record.path) ? record.path : nil
            )
        }
    }

    private func fraction(stepShare: Double) -> Double {
        (Double(sampleIndex) + stepShare) / Double(sampleCount)
    }
}

extension CLIEventArtifact.Role {
    /// A bundle that an import made, such as a `.lungfishfastq` bundle of `import fastq`.
    public static let bundle = "bundle"
}
