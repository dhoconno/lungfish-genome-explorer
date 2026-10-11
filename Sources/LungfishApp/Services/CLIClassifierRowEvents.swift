// CLIClassifierRowEvents.swift - The row lines of a classifier run through lungfish-cli, by today's rules
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishWorkflow

/// The classifier a run through `lungfish-cli` runs.
enum CLIClassifierTool: String, Sendable, Equatable, CaseIterable {
    case kraken2
    case esViritu

    /// The detail today's row shows while the viewer database is built. The command's finalize
    /// writes the same words as a progress line when it starts the build.
    var databaseBuildDetail: String {
        switch self {
        case .kraken2: return "Building Kraken2 database\u{2026}"
        case .esViritu: return "Building EsViritu database\u{2026}"
        }
    }

    /// The info line today's row logs when the viewer database build starts.
    func databaseBuildLogLine(completedSamples: Int, isBatch: Bool) -> String {
        let file = self == .kraken2 ? "kraken2.sqlite" : "esviritu.sqlite"
        return isBatch ? "Building \(file) from \(completedSamples) sample(s)" : "Building \(file) from single-sample result"
    }
}

/// Turns the events of one classifier run through `lungfish-cli` into the lines today's row shows
/// (Phase 2.7 lane A10, UX differences D5 to D8, D11, D14 and D17).
///
/// The command runs under the analysis run executor, whose stream `AnalysisRunEvents` documents.
/// The executor starts each unit with a progress line `Running <label> (<i> of <n>).`, or
/// `Running <label>.` for a run of one unit, reports a unit's progress as `(index + fraction) /
/// count`, and reports the finalize at the end of the range. A failed unit of a batch is the
/// warning `<label> failed: <reason>` and a degraded one `<label>: <reason>`.
///
/// - Every progress line moves the bar, which never moves back, sets the detail, is logged at
///   info and shows in the viewer's overlay. In a batch the line reads `Sample i/N (id): <line>`
///   with today's sample ids. The lines after the last unit's line at the end of the range, or
///   after its failure, are the finalize's and carry no sample. The executor's own unit lines
///   are not shown, as today's row has none.
/// - The finalize's database line `Building <tool> database…` sets today's detail and logs today's
///   `Building <tool>.sqlite from …` line.
/// - A row reads Completed with Warnings in today's cases only (2.6 S16). The one warning line of
///   the command that today's row also logs is the database build failure. Every other warning
///   reads as info, and a failed batch unit reads as today's error line `Sample i/N (id): <reason>`.
/// - The EsViritu log tail of a single run goes to the row's error detail and not to the log.
/// - The early `output` line names the result folder, which the row tracks for Results and
///   Reveal Output Files.
struct CLIClassifierRowEvents: Sendable {
    /// What one event does to the row.
    struct Effects: Equatable, Sendable {
        /// Events for `OperationCenterCLIBridge`, which moves the bar, sets the detail and logs.
        var bridged: [CLIEvent] = []
        /// The line the viewer's progress overlay shows.
        var overlay: String?
        /// The result folder the row tracks for Results and Reveal Output Files.
        var trackedFolder: URL?
    }

    /// The heading of the EsViritu log tail, as today's row writes it in the error detail.
    static let esVirituLogTailHeading = "EsViritu log (last lines):\n"

    let tool: CLIClassifierTool
    /// Today's sample ids in plan order. More than one makes a batch.
    let sampleIDs: [String]

    /// The result folder the early `output` line named.
    private(set) var analysisFolder: URL?
    /// The reason of each unit that failed, in the order the command reported them.
    private(set) var failedUnitReasons: [String] = []
    /// The build error of today's database warning line, when the command wrote one.
    private(set) var databaseError: String?
    /// The EsViritu log tail of a single run, with its heading, for the row's error detail.
    private(set) var esVirituLogTail: String?

    private var bar = 0.0
    private var sawProgress = false
    private var finalizing = false
    private var unitIndex: Int?
    private var unitCount: Int
    private var unitLabels: [Int: String] = [:]

    init(tool: CLIClassifierTool, sampleIDs: [String]) {
        self.tool = tool
        self.sampleIDs = sampleIDs
        self.unitCount = max(sampleIDs.count, 1)
    }

    var isBatch: Bool {
        sampleIDs.count > 1
    }

    /// Whether every unit of a batch failed, as today's row reads a batch with no result.
    var everyUnitFailed: Bool {
        isBatch && !failedUnitReasons.isEmpty && failedUnitReasons.count >= unitCount
    }

    mutating func effects(of event: CLIEvent) -> Effects {
        switch event {
        case .start, .complete, .failed:
            // The begin text stays the first detail, and the runner reads the end of the run
            // from the transport.
            return Effects()
        case let .output(path, role):
            guard role == CLIEventArtifact.Role.analysisDirectory, analysisFolder == nil, !path.isEmpty else {
                return Effects()
            }
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            analysisFolder = folder
            return Effects(trackedFolder: folder)
        case let .progress(fraction, message):
            return progressEffects(fraction: fraction, message: message)
        case let .log(level, message):
            return logEffects(level: level, message: message)
        }
    }

    // MARK: - Progress

    private mutating func progressEffects(fraction: Double, message: String) -> Effects {
        let firstLine = !sawProgress
        sawProgress = true
        if let start = Self.unitStart(message), start.count > 1 {
            unitIndex = start.index
            unitCount = start.count
            unitLabels[start.index] = start.label
            return Effects()
        }
        if firstLine, fraction == 0, let label = Self.singleUnitLabel(message) {
            unitIndex = 0
            unitCount = 1
            unitLabels[0] = label
            return Effects()
        }
        bar = max(bar, min(max(fraction, 0), 1))
        if message == tool.databaseBuildDetail {
            finalizing = true
            let completed = max(0, unitCount - failedUnitReasons.count)
            return Effects(bridged: [
                .progress(fraction: bar, message: message),
                .log(level: .info, message: tool.databaseBuildLogLine(completedSamples: completed, isBatch: isBatch)),
            ])
        }
        let text = prefixed(message)
        // The last unit's line at the end of the range is its last, so the lines after it are
        // the finalize's.
        if fraction >= 1, isLastUnit {
            finalizing = true
        }
        return Effects(bridged: [.progress(fraction: bar, message: text), .log(level: .info, message: text)], overlay: text)
    }

    private var isLastUnit: Bool {
        isBatch && (unitIndex ?? -1) >= unitCount - 1
    }

    // MARK: - Logs

    private mutating func logEffects(level: CLIEventLogLevel, message: String) -> Effects {
        switch level {
        case .warning:
            if let failure = unitLine(message, separator: " failed: ") {
                failedUnitReasons.append(failure.text)
                if failure.index >= unitCount - 1 {
                    finalizing = true
                }
                return Self.logging(.error, "\(prefix(failure.index)): \(failure.text)")
            }
            if let error = Self.databaseBuildError(in: message) {
                databaseError = error
                return Self.logging(.warning, message)
            }
            if let degraded = unitLine(message, separator: ": ") {
                return Self.logging(.info, "\(prefix(degraded.index)): \(degraded.text)")
            }
            return Self.logging(.info, prefixed(message))
        case .error:
            if !isBatch, message.hasPrefix(Self.esVirituLogTailHeading) {
                esVirituLogTail = message
                return Effects()
            }
            return Self.logging(.error, prefixed(message))
        case .info, .debug:
            return Self.logging(level, prefixed(message))
        }
    }

    private static func logging(_ level: CLIEventLogLevel, _ message: String) -> Effects {
        Effects(bridged: [.log(level: level, message: message)])
    }

    // MARK: - Units

    /// A batch line that starts with a unit's label, such as `<label> failed: <reason>`, with the
    /// unit's index and the text after the separator. The current unit's label is tried first.
    private func unitLine(_ message: String, separator: String) -> (index: Int, text: String)? {
        guard isBatch else { return nil }
        let candidates = unitLabels.sorted { lhs, rhs in
            (lhs.key == unitIndex ? -1 : lhs.key) < (rhs.key == unitIndex ? -1 : rhs.key)
        }
        for (index, label) in candidates where message.hasPrefix(label + separator) {
            return (index, String(message.dropFirst(label.count + separator.count)))
        }
        return nil
    }

    private func prefixed(_ message: String) -> String {
        guard isBatch, !finalizing, let unitIndex else { return message }
        return "\(prefix(unitIndex)): \(message)"
    }

    /// Today's prefix of a batch line, `Sample 2/5 (air-B)`, with today's sample id when the
    /// command's unit has one and the command's label otherwise.
    private func prefix(_ index: Int) -> String {
        let sampleID = sampleIDs.indices.contains(index) ? sampleIDs[index] : (unitLabels[index] ?? "sample_\(index + 1)")
        return AppDelegate.classificationBatchSamplePrefix(index: index, sampleCount: unitCount, sampleID: sampleID)
    }

    /// The executor's line at the start of a unit of a batch, `Running <label> (<i> of <n>).`.
    static func unitStart(_ message: String) -> (index: Int, count: Int, label: String)? {
        guard message.hasPrefix("Running "), message.hasSuffix(").") else { return nil }
        let body = message.dropFirst("Running ".count).dropLast(2)
        guard let open = body.range(of: " (", options: .backwards) else { return nil }
        let label = String(body[..<open.lowerBound])
        let counts = body[open.upperBound...].components(separatedBy: " of ")
        guard !label.isEmpty, counts.count == 2,
              let position = Int(counts[0]), let count = Int(counts[1]),
              position >= 1, position <= count else { return nil }
        return (position - 1, count, label)
    }

    /// The label of the executor's line at the start of a run of one unit, `Running <label>.`.
    static func singleUnitLabel(_ message: String) -> String? {
        guard message.hasPrefix("Running "), message.hasSuffix("."), !message.hasSuffix("..."),
              !message.hasSuffix(")."), message.count > "Running .".count else { return nil }
        return String(message.dropFirst("Running ".count).dropLast())
    }

    /// The build error of today's database warning line,
    /// `AppDelegate.classificationDatabaseBuildWarning(_:)`, or nil for any other line.
    static func databaseBuildError(in message: String) -> String? {
        let parts = AppDelegate.classificationDatabaseBuildWarning("\u{0}").components(separatedBy: "\u{0}")
        guard parts.count == 2, message.hasPrefix(parts[0]), message.hasSuffix(parts[1]),
              message.count > parts[0].count + parts[1].count else { return nil }
        return String(message.dropFirst(parts[0].count).dropLast(parts[1].count))
    }
}
