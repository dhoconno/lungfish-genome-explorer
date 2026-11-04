// TaxTriageControlMatch.swift - Which samples of a TaxTriage result belong to its negative controls
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The negative controls of a TaxTriage run, matched to the samples that the run's database holds.
///
/// LGE keeps the name a person typed for a sample, such as `NTC 1`. The pipeline's samplesheet check renames it
/// (see ``TaxTriageSample/pipelineName(of:)``), so the reports and the database name the control `NTC_1`, and it
/// numbers two samples of one samplesheet that end with the same name `_T1`, `_T2`. Comparing the typed name
/// with the database loses the control's flag (lane TTBUILDDB, BIO ruling 2 of TTIMPORT). This type reads every
/// control through the pipeline's rule, so the exports and the viewer flag the same samples.
///
/// It also tells a control that never ran from a control that ran and found nothing, since a batch records a
/// failed sample beside its marks and a failed control has no rows (BIO backlog row on a failed control).
public struct TaxTriageControlMatch: Sendable, Equatable {

    /// A negative control as the run lists it.
    public struct Control: Sendable, Equatable {

        /// What the result says about the control.
        public enum State: Sendable, Equatable {
            /// The database holds samples that belong to the control.
            case found
            /// The control ran and the database holds no sample for it, and every sample the database holds
            /// belongs to a sample the run lists. The control found nothing, which is the usual clean control.
            case noOrganisms
            /// The run lists the control as a failed sample, so it never ran. A control that has no sample in the
            /// database and that a task Nextflow ignored names is the same, since the task's results are missing
            /// (lane TTCONTROLS).
            case failed
            /// The control ran and the database holds no sample for it, but the database holds samples that no
            /// sample of the run accounts for. The control's organisms may sit under one of them, so its
            /// absence cannot be read as a clean control.
            case notFound
        }

        /// The name as typed, which the run's sidecar keeps.
        public let sampleId: String
        /// The name the pipeline's rule gives it, which the reports and the database use.
        public let resultsName: String
        /// What the result says about the control.
        public let state: State
        /// The samples of the database that belong to the control, in order.
        public let databaseSampleIds: [String]

        /// True when the pipeline renamed the control.
        public var isRenamed: Bool { sampleId != resultsName }
    }

    /// The controls the run lists, in order of their typed names.
    public let controls: [Control]
    /// The samples of the database that belong to a control. A sample that belongs to a control and to a sample
    /// that is not one counts as a control.
    public let controlSampleIds: Set<String>
    /// The samples of the database that no sample of the run accounts for, in order.
    public let unlistedSampleIds: [String]
    /// Words for a person, one for each set of samples that the pipeline's rule gives one name when that set
    /// holds a control and a sample that is not one and the database holds the name.
    public let notes: [String]

    /// The controls that never ran.
    public var failedControls: [Control] { controls.filter { $0.state == .failed } }
    /// The controls that ran and that the result does not show, while the database holds samples the run does not list.
    public var notFoundControls: [Control] { controls.filter { $0.state == .notFound } }
    /// True when a control never ran or cannot be found, so a `No` for contamination risk would not be known.
    public var hasUncheckedControl: Bool { controls.contains { $0.state == .failed || $0.state == .notFound } }

    /// Every control as the results name it, for a viewer that shows its Risk column whenever the run lists a control:
    /// the database samples that belong to a control, and the results name of each control that has none.
    public var controlNames: Set<String> {
        controlSampleIds.union(controls.map(\.resultsName).filter { !$0.isEmpty })
    }

    /// What a person reads when a control never ran or cannot be found, and what to do. Nil when every control ran.
    /// The batch report and the viewer's notice say these words, so screen and file agree (lane TTCONTROLS).
    public var uncheckedWords: String? {
        guard hasUncheckedControl else { return nil }
        let partly = controls.contains { $0.state == .found || $0.state == .noOrganisms }
        var sentences = [partly ? "Contamination risk is only partly checked." : "Contamination risk is not checked."]
        let failed = failedControls.map(\.sampleId)
        if !failed.isEmpty {
            let one = failed.count == 1
            sentences.append(one
                ? "The negative control \(failed[0]) failed, so Lungfish has no result for it."
                : "The negative controls \(Self.listing(failed)) failed, so Lungfish has no result for them.")
            sentences.append("Run \(one ? "it" : "them") again, or check \(one ? "it" : "them") another way, before you rely on these results.")
        }
        let missing = notFoundControls
        if !missing.isEmpty {
            let names = missing.map { $0.isRenamed ? "\($0.sampleId) (named \($0.resultsName) in the results)" : $0.sampleId }
            sentences.append(
                "The results hold no organisms for the negative control\(missing.count == 1 ? "" : "s") "
                    + "\(Self.listing(names)), but they hold samples that the run does not list "
                    + "(\(unlistedSampleIds.joined(separator: ", "))), so Lungfish cannot tell whether "
                    + "\(missing.count == 1 ? "its" : "their") organisms are among them."
            )
            sentences.append("Look in the control's own results before you rely on these results.")
        }
        return sentences.joined(separator: " ")
    }

    /// The words the viewer shows above its table, the notes on names that meet and then the unchecked words. Nil when
    /// there is nothing to say.
    public var noticeWords: String? {
        let parts = notes + [uncheckedWords].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Matches the controls of a run to the database.
    ///
    /// A sample `d` of the database belongs to a sample `s` of the run when `d` is `s.sampleId`, or the pipeline's
    /// name for it, or that name with `_T<k>` for a `k` from 1 to the number of samples that share the name.
    ///
    /// - Parameters:
    ///   - samples: The samples the run's sidecar lists, as typed.
    ///   - failedSampleIDs: The samples the sidecar lists as failed.
    ///   - ignoredFailures: The tasks Nextflow ignored an error in, which name their sample in the task label
    ///     (`MINIMAP2_ALIGN (NTC1)`). A control with no sample in the database that one of them names is a failed
    ///     control, since the pipeline goes on after an ignored error and ends with exit 0 and no rows for it. A task
    ///     that only draws quality plots costs the sample no result and is not counted.
    ///   - databaseSampleIds: The samples the result's database holds.
    public init(
        samples: [TaxTriageSample],
        failedSampleIDs: [String],
        ignoredFailures: [TaxTriageIgnoredFailure] = [],
        databaseSampleIds: [String]
    ) {
        let database = Array(Set(databaseSampleIds)).sorted()
        var sharing: [String: Int] = [:]
        for sample in samples {
            sharing[TaxTriageSample.pipelineName(of: sample.sampleId), default: 0] += 1
        }
        let unlisted = database.filter { name in
            !samples.contains { Self.belongs(name, to: $0.sampleId, sharing: sharing) }
        }
        let failed = Set(failedSampleIDs)
        // The parser cuts a task's tag at its first dot and the pipeline keeps dots in a name, so a control `NTC.1` is `NTC`
        // by `sampleID` and `NTC.1` by the whole tag, which `taskLabel` holds (lane TTCONTROLS, BIO review).
        let ignoredTags = ignoredFailures.filter { !$0.onlyAffectsQualityPlots }
        let ignored = Set(ignoredTags.compactMap(\.sampleID) + ignoredTags.map(\.taskLabel))

        var controls: [Control] = []
        var controlSampleIds: Set<String> = []
        for sample in samples where sample.isNegativeControl {
            let resultsName = TaxTriageSample.pipelineName(of: sample.sampleId)
            let owned = database.filter { Self.belongs($0, to: sample.sampleId, sharing: sharing) }
            let state: Control.State
            if failed.contains(sample.sampleId) || (!resultsName.isEmpty && failed.contains(resultsName)) {
                state = .failed
            } else if !owned.isEmpty {
                state = .found
            } else if ignored.contains(sample.sampleId) || (!resultsName.isEmpty && ignored.contains(resultsName)) {
                state = .failed
            } else {
                state = unlisted.isEmpty ? .noOrganisms : .notFound
            }
            controls.append(Control(
                sampleId: sample.sampleId,
                resultsName: resultsName,
                state: state,
                databaseSampleIds: owned
            ))
            controlSampleIds.formUnion(owned)
        }

        var notes: [String] = []
        let groups = Dictionary(grouping: samples, by: { TaxTriageSample.pipelineName(of: $0.sampleId) })
        for name in groups.keys.sorted() {
            guard let group = groups[name], !name.isEmpty, group.count > 1,
                  group.contains(where: \.isNegativeControl), group.contains(where: { !$0.isNegativeControl })
            else { continue }
            let held = database.filter { candidate in
                group.contains { Self.belongs(candidate, to: $0.sampleId, sharing: sharing) }
            }
            guard !held.isEmpty else { continue }
            let typed = group.map(\.sampleId).sorted()
            let meet = typed.count == 2
                ? "\(typed[0]) and \(typed[1]) are both"
                : "\(Self.listing(typed)) are all"
            notes.append(
                "\(meet) named \(name) in the results, so Lungfish cannot tell them apart and treats "
                    + "\(Self.listing(held)) as \(held.count == 1 ? "a negative control" : "negative controls"). "
                    + "Give each sample a name that stays different once spaces and symbols are removed, then run it again."
            )
        }
        // Names that meet with no control among them: a batch root keeps one folder's rows (lane TTCONTROLS, BIO review).
        for name in groups.keys.sorted() {
            guard let group = groups[name], !name.isEmpty, group.count > 1,
                  !(group.contains(where: \.isNegativeControl) && group.contains(where: { !$0.isNegativeControl }))
            else { continue }
            let held = database.filter { candidate in
                group.contains { Self.belongs(candidate, to: $0.sampleId, sharing: sharing) }
            }
            let expected = group.filter { !failed.contains($0.sampleId) && !failed.contains(name) }.count
            guard !held.isEmpty, held.count < expected else { continue }
            let typed = group.map(\.sampleId).sorted()
            let meet = typed.count == 2 ? "\(typed[0]) and \(typed[1]) are both" : "\(Self.listing(typed)) are all"
            let kept = held.count == 1 ? "one sample" : "\(held.count) of them"
            notes.append(
                "\(meet) named \(name) in the results, and the results hold only \(kept), so the rows of the others are not in this table. "
                    + "Give each sample a name that stays different once spaces and symbols are removed, then run it again."
            )
        }

        self.controls = controls.sorted { $0.sampleId < $1.sampleId }
        self.controlSampleIds = controlSampleIds
        self.unlistedSampleIds = unlisted
        self.notes = notes
    }

    /// True when the database sample `databaseName` belongs to the run's sample `sampleId`.
    private static func belongs(_ databaseName: String, to sampleId: String, sharing: [String: Int]) -> Bool {
        let resultsName = TaxTriageSample.pipelineName(of: sampleId)
        if databaseName == sampleId || (!resultsName.isEmpty && databaseName == resultsName) { return true }
        guard !resultsName.isEmpty, let count = sharing[resultsName], count > 1,
              databaseName.hasPrefix(resultsName + "_T")
        else { return false }
        let suffix = String(databaseName.dropFirst(resultsName.count + 2))
        guard let number = Int(suffix), String(number) == suffix else { return false }
        return (1...count).contains(number)
    }

    /// `names` as a list of words, `A`, `A and B` or `A, B and C`.
    static func listing(_ names: [String]) -> String {
        guard names.count > 1, let last = names.last else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }
}
