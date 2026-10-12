// ClassifierCLIGUIParityReplayTests+Rows.swift - What the Operations row of side C shows, and how a run's end reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Panel decisions T2 and E15. Side C, the GUI route through `lungfish-cli`, shows today's row.
// The recorders below keep the details the row showed while the run went on and the lines of the
// viewer's progress overlay, and `rowOutcomeViolations`
// (ClassifierCLIGUIParityReplayTests+FixedFacts.swift) holds the row to today's words. Until
// Phase 2.9 the row of side A, the in-process route, was compared with side C's field by field.
// That route and its comparison went with the route (E14, QA Q12).

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
