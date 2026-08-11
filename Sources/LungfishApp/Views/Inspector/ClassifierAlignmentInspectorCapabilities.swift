// ClassifierAlignmentInspectorCapabilities.swift - Explicit Inspector contract for detached classifier evidence
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit

/// The Inspector contract for classifier BAM evidence.  This deliberately names
/// final evidence paths and never carries a `ReferenceBundle` or `MappingResult`.
struct ClassifierAlignmentInspectorCapabilities: Equatable {
    enum ReferenceValidation: Equatable {
        case absent
        case unavailable(String)
        case structural
        case md5

        var isValidated: Bool {
            switch self {
            case .structural, .md5: true
            case .absent, .unavailable: false
            }
        }

        var label: String {
            switch self {
            case .absent: "No reference provided"
            case .unavailable(let reason): reason
            case .structural: "Structurally validated reference"
            case .md5: "BAM M5 validated reference"
            }
        }
    }

    struct ReadGroup: Equatable, Identifiable {
        let id: String
        let sample: String?

        init(id: String, sample: String?) {
            self.id = id
            self.sample = sample
        }
    }

    struct Track: Equatable {
        let id: String
        let name: String
    }

    enum Control: CaseIterable, Hashable {
        case evidenceInventory, navigation, readRendering, minMAPQ, duplicates
        case secondary, supplementary, readGroups, coverage, selectedReadDetails
        case sourceProvenance, referenceMismatch, consensus
        case annotationAppearance, convertMappedReads, variantVCF, cohort
        case markDuplicates, createDeduplicatedBundle, primerTrim, variantCalling
        case createFilteredAlignment, mappingExports
    }

    enum Availability: Equatable {
        case available
        case disabled(String)
        case hidden(String)
    }

    let workflow: String
    let result: String
    let sample: String
    let contig: String
    let bamPath: String
    let indexPath: String
    let referenceValidation: ReferenceValidation
    let readGroups: [ReadGroup]
    let selectedTrack: Track
    let coveragePolicy: String
    /// Mirrors the provider's visible lifecycle state in the evidence inventory.
    let status: ClassifierAlignmentViewerStatus
    let referencePath: String?
    let bamSnapshot: ClassifierAlignmentEvidenceFileSnapshot?
    let indexSnapshot: ClassifierAlignmentEvidenceFileSnapshot?
    let referenceSnapshot: ClassifierAlignmentEvidenceFileSnapshot?
    let provenanceID: String?

    let defaultExcludeFlags: UInt16 = 0xD04

    static func detachedEvidence(
        workflow: String,
        result: String,
        sample: String,
        contig: String,
        bamPath: String,
        indexPath: String,
        referenceValidation: ReferenceValidation,
        readGroups: [ReadGroup],
        status: ClassifierAlignmentViewerStatus = .idle,
        referencePath: String? = nil,
        bamSnapshot: ClassifierAlignmentEvidenceFileSnapshot? = nil,
        indexSnapshot: ClassifierAlignmentEvidenceFileSnapshot? = nil,
        referenceSnapshot: ClassifierAlignmentEvidenceFileSnapshot? = nil,
        provenanceID: String? = nil
    ) -> Self {
        .init(
            workflow: workflow,
            result: result,
            sample: sample,
            contig: contig,
            bamPath: bamPath,
            indexPath: indexPath,
            referenceValidation: referenceValidation,
            readGroups: readGroups,
            selectedTrack: .init(id: "classifier:\(sample)", name: sample),
            coveragePolicy: "Coverage uses MAPQ and read-inclusion filters; it is unavailable while read-group filtering is active.",
            status: status, referencePath: referencePath, bamSnapshot: bamSnapshot,
            indexSnapshot: indexSnapshot, referenceSnapshot: referenceSnapshot, provenanceID: provenanceID
        )
    }

    var showsReadGroupControls: Bool { readGroups.count > 1 }

    var referenceMismatchExplanation: String? {
        guard case let .disabled(reason) = availability(of: .referenceMismatch) else { return nil }
        return reason
    }

    var inventoryRows: [String] {
        ["Workflow: \(workflow)", "Result: \(result)", "Sample: \(sample) • Contig: \(contig)", "BAM: \(bamPath)", "Index: \(indexPath)", "Reference: \(referencePath ?? referenceValidation.label)", "Status: \(status.message)", provenanceID.map { "Provenance: \($0)" }, snapshotRow("BAM snapshot", bamSnapshot), snapshotRow("Index snapshot", indexSnapshot), snapshotRow("Reference snapshot", referenceSnapshot), coveragePolicy].compactMap { $0 }
    }

    private func snapshotRow(_ label: String, _ snapshot: ClassifierAlignmentEvidenceFileSnapshot?) -> String? { snapshot.map { "\(label): \($0.size) bytes • \($0.sha256)" } }

    var unavailableReasons: [String] {
        Control.allCases.compactMap { control in
            switch availability(of: control) {
            case .available: nil
            case .disabled(let reason), .hidden(let reason): reason
            }
        }
    }

    func availability(of control: Control) -> Availability {
        // A request remains inspectable while it is validating or stale, but it
        // must not leave a live read-control surface attached to absent evidence.
        switch status {
        case .loading, .unavailable, .stale:
            switch control {
            case .evidenceInventory, .sourceProvenance:
                break
            default:
                return .disabled(status.message)
            }
        case .idle, .available:
            break
        }
        switch control {
        case .evidenceInventory, .navigation, .readRendering, .minMAPQ, .duplicates,
             .secondary, .supplementary, .coverage, .selectedReadDetails, .sourceProvenance:
            return .available
        case .readGroups:
            return showsReadGroupControls ? .available : .hidden("The BAM has fewer than two read groups.")
        case .referenceMismatch, .consensus:
            return referenceValidation.isValidated ? .available : .disabled("A validated reference sequence is required.")
        case .annotationAppearance:
            return .hidden("Classifier evidence has no annotation track.")
        case .convertMappedReads:
            return .disabled("Classifier evidence has no annotation mutation target.")
        case .variantVCF, .cohort, .variantCalling:
            return .disabled("Classifier evidence has no variant or cohort output target.")
        case .markDuplicates, .createDeduplicatedBundle:
            return .disabled("Classifier evidence is read-only; duplicate workflows are unavailable.")
        case .primerTrim:
            return .disabled("Classifier evidence is read-only; primer trimming is unavailable.")
        case .createFilteredAlignment:
            return .disabled("Classifier evidence is read-only; creating derived alignment outputs is unavailable.")
        case .mappingExports:
            return .disabled("Classifier evidence is not a mapping-result export target.")
        }
    }
}
