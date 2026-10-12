// ClassifierCLIGUIParityReplayTests+Rows.swift - What the Operations rows of sides A and C show, and how they compare
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Panel decisions T2 and E15. Side C, the GUI route through `lungfish-cli`, must show the row
// side A, today's route, shows. A row is compared field by field: title, first detail, final
// state, completion detail, error message and alert, then its log lines with their levels, the
// details it showed while it ran and the lines of the viewer's progress overlay. Texts are
// compared with each side's root, run ids, timestamps and measured times masked, and with the
// candidate's analysis folder named as the reference's.

import AppKit
import Combine
import Foundation
import XCTest
@testable import LungfishApp
import LungfishKit
@testable import LungfishWorkflow

/// A viewer that keeps every line its progress overlay showed.
final class OverlayRecordingViewer: ViewerViewController {
    private(set) var overlayLines: [String] = []

    override func showProgress(_ message: String) {
        overlayLines.append(message)
        super.showProgress(message)
    }
}

/// Every detail each new row of `OperationCenter.shared` showed, in order, while it records.
@MainActor
final class RowDetailRecorder {
    private(set) var details: [UUID: [String]] = [:]
    private var subscription: AnyCancellable?

    /// Records the rows whose ids are not in `existing`.
    init(ignoring existing: Set<UUID>) {
        subscription = OperationCenter.shared.$items.sink { [weak self] items in
            MainActor.assumeIsolated {
                self?.record(items, ignoring: existing)
            }
        }
    }

    private func record(_ items: [OperationCenter.Item], ignoring existing: Set<UUID>) {
        for item in items where !existing.contains(item.id) && details[item.id]?.last != item.detail {
            details[item.id, default: []].append(item.detail)
        }
    }

    func stop() {
        subscription?.cancel()
        subscription = nil
    }
}

extension ClassifierParityComparison {
    /// How a side's run ended, in the words of a row: a row's own label, else `Completed` for
    /// exit 0, `Completed with Warnings` for exit 0 with a degraded Bracken profile (E4),
    /// `Cancelled` for exit 125 (E5) and `Failed` for any other end.
    static func outcome(of run: ClassifierParitySideRun) -> String {
        switch run.terminal {
        case .row(let label):
            return label
        case .exit(0):
            return hasDegradedProfile(run) ? "Completed with Warnings" : "Completed"
        case .exit(125):
            return "Cancelled"
        case .exit, .error:
            return "Failed"
        case .notRun:
            return "Not run"
        }
    }

    /// Whether a Kraken2 result of the run's analysis folder holds a degraded Bracken profile.
    private static func hasDegradedProfile(_ run: ClassifierParitySideRun) -> Bool {
        guard let analysis = run.analysisFolder else { return false }
        return relativeFiles(under: analysis)
            .filter { ($0 as NSString).lastPathComponent == "classification-result.json" }
            .contains { relative in
                let folder = analysis.appendingPathComponent(relative).deletingLastPathComponent()
                return (try? ClassificationResult.load(from: folder))?.profileOutcome.state == .degraded
            }
    }

    /// The candidate's analysis folder and the reference's, as `Analyses/<name>`, when the two runs
    /// named them differently. A run with `--project` names its folder by the second it started.
    static func folderRename(
        _ reference: ClassifierParitySideRun,
        _ candidate: ClassifierParitySideRun
    ) -> (from: String, to: String)? {
        guard let referenceName = reference.analysisPath.map({ ($0 as NSString).lastPathComponent }),
              let candidateName = candidate.analysisPath.map({ ($0 as NSString).lastPathComponent }),
              referenceName != candidateName else { return nil }
        return ("Analyses/\(candidateName)", "Analyses/\(referenceName)")
    }

    /// `value` with every string naming the candidate's analysis folder as the reference's.
    static func renaming(_ value: Value, _ rename: (from: String, to: String)?) -> Value {
        guard let rename else { return value }
        switch value {
        case .string(let text): return .string(text.replacingOccurrences(of: rename.from, with: rename.to))
        case .array(let items): return .array(items.map { renaming($0, rename) })
        case .object(let members): return .object(members.mapValues { renaming($0, rename) })
        default: return value
        }
    }
}

enum ClassifierParityRowComparison {
    /// How the candidate's row differs from the reference's. Each field that differs is one
    /// difference, and so is each log line, detail and overlay line that only one side shows,
    /// once per time it shows. The log lines both sides show must come in the same order.
    static func differences(
        reference: ClassifierParitySideRun,
        candidate: ClassifierParitySideRun
    ) -> [ClassifierParityDifference] {
        guard let rowA = reference.row, let rowB = candidate.row else {
            return reference.row == nil && candidate.row == nil
                ? []
                : [ClassifierParityDifference(id: "row: only one side has a row", detail: "\(reference.terminal), \(candidate.terminal)")]
        }
        let mask = masking(reference, candidate)
        var found: [ClassifierParityDifference] = []
        let fields: [(String, String?, String?)] = [
            ("title", rowA.title, rowB.title),
            ("first detail", rowA.firstDetail, rowB.firstDetail),
            ("state", rowA.stateLabel, rowB.stateLabel),
            ("completion detail", rowA.completionDetail, rowB.completionDetail),
            ("error message", rowA.errorMessage, rowB.errorMessage),
            ("alert", rowA.alertText, rowB.alertText),
        ]
        for (name, valueA, valueB) in fields where valueA.map(mask) != valueB.map(mask) {
            found.append(ClassifierParityDifference(
                id: "row: \(name) differs",
                detail: "\(reference.side) \(valueA.map(mask) ?? "none"), \(candidate.side) \(valueB.map(mask) ?? "none")"
            ))
        }
        let logs = (rowA.logLines.map { mask($0.description) }, rowB.logLines.map { mask($0.description) })
        found += onlyOnOneSide("log line", logs.0, logs.1, reference.side, candidate.side)
        let commonA = common(logs.0, logs.1), commonB = common(logs.1, logs.0)
        if commonA != commonB {
            found.append(ClassifierParityDifference(
                id: "row: log lines both sides show come in another order",
                detail: zip(commonA, commonB).first { $0 != $1 }.map { "\(reference.side) \($0), \(candidate.side) \($1)" } ?? ""
            ))
        }
        found += onlyOnOneSide("detail", rowA.details.map(mask), rowB.details.map(mask), reference.side, candidate.side)
        found += onlyOnOneSide("overlay line", rowA.overlayLines.map(mask), rowB.overlayLines.map(mask), reference.side, candidate.side)
        return found
    }

    /// One difference per text that one list holds more often than the other.
    private static func onlyOnOneSide(
        _ kind: String,
        _ textsA: [String],
        _ textsB: [String],
        _ sideA: ClassifierParitySide,
        _ sideB: ClassifierParitySide
    ) -> [ClassifierParityDifference] {
        var found: [ClassifierParityDifference] = []
        for (texts, others, side) in [(textsA, textsB, sideA), (textsB, textsA, sideB)] {
            var left = Dictionary(others.map { ($0, 1) }, uniquingKeysWith: +)
            for text in texts {
                if let count = left[text], count > 0 {
                    left[text] = count - 1
                } else {
                    found.append(ClassifierParityDifference(id: "row: \(kind) only in \(side): \(text)", detail: ""))
                }
            }
        }
        return found
    }

    /// The texts of `texts` that `others` also holds, in the order of `texts`, each as often as
    /// both hold it.
    private static func common(_ texts: [String], _ others: [String]) -> [String] {
        var left = Dictionary(others.map { ($0, 1) }, uniquingKeysWith: +)
        return texts.filter { text in
            guard let count = left[text], count > 0 else { return false }
            left[text] = count - 1
            return true
        }
    }

    /// The text of a row with both side roots, the candidate's folder name and what changes from
    /// run to run masked, and a line break shown as `\n`, so a text is one stable id.
    static func masking(
        _ reference: ClassifierParitySideRun,
        _ candidate: ClassifierParitySideRun
    ) -> (String) -> String {
        let spellings = [reference.root, candidate.root]
            .flatMap(ClassifierParityComparison.rootSpellings)
            .sorted { $0.count > $1.count }
        let rename = ClassifierParityComparison.folderRename(reference, candidate)
        return { text in
            var masked = spellings.reduce(text) { $0.replacingOccurrences(of: $1, with: "<SIDE-ROOT>") }
            if let rename { masked = masked.replacingOccurrences(of: rename.from, with: rename.to) }
            return ClassifierParityComparison.maskedText(masked).replacingOccurrences(of: "\n", with: "\\n")
        }
    }
}
