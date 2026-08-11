// ClassifierAlignmentEvidence.swift — Detached classifier alignment evidence contracts
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation

/// The classifier workflows that use the shared detached alignment viewer.
///
/// NAO-MGS intentionally remains on its existing compact BAM viewer.
public enum ClassifierAlignmentWorkflowKind: String, CaseIterable, Sendable {
    case esViritu
    case taxTriage
    case nvd
}

/// Stable identity and final storage location of a classifier result.
public struct ClassifierAlignmentResultIdentity: Equatable, Sendable {
    public let stableID: String
    public let finalResultURL: URL
    public let provenanceID: String

    public init(stableID: String, finalResultURL: URL, provenanceID: String) {
        self.stableID = stableID
        self.finalResultURL = finalResultURL
        self.provenanceID = provenanceID
    }
}

/// An explicit BAM index belonging to classifier evidence.
public struct ClassifierAlignmentIndex: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case bai
        case csi
    }

    public let url: URL
    public let kind: Kind

    public init(url: URL, kind: Kind) {
        self.url = url
        self.kind = kind
    }
}

/// The persisted sample selected for classifier alignment evidence.
public struct ClassifierAlignmentSample: Equatable, Sendable {
    public let canonicalID: String

    public init(canonicalID: String) {
        self.canonicalID = canonicalID
    }
}

/// A contig selected from the final BAM's sequence dictionary.
public struct ClassifierAlignmentContig: Equatable, Sendable {
    public let name: String
    public let expectedLength: Int

    public init(name: String, expectedLength: Int) {
        self.name = name
        self.expectedLength = expectedLength
    }
}

/// A FASTA record that may be validated for reference-aware evidence rendering.
public struct ClassifierAlignmentReferenceCandidate: Equatable, Sendable {
    public let fastaURL: URL
    public let recordName: String
    public let expectedLength: Int
    public let expectedMD5: String?

    public init(
        fastaURL: URL,
        recordName: String,
        expectedLength: Int,
        expectedMD5: String? = nil
    ) {
        self.fastaURL = fastaURL
        self.recordName = recordName
        self.expectedLength = expectedLength
        self.expectedMD5 = expectedMD5
    }
}

/// Labels supplied by the classifier instead of derived from temporary paths.
public struct ClassifierAlignmentEvidencePresentation: Equatable, Sendable {
    public let workflowLabel: String
    public let resultLabel: String
    public let sampleLabel: String
    public let contigLabel: String

    public init(workflowLabel: String, resultLabel: String, sampleLabel: String, contigLabel: String) {
        self.workflowLabel = workflowLabel
        self.resultLabel = resultLabel
        self.sampleLabel = sampleLabel
        self.contigLabel = contigLabel
    }
}

/// Immutable input for showing final classifier alignment evidence.
///
/// This type deliberately carries final stored paths and explicit identity; it
/// never represents a synthetic reference-bundle wrapper or a staging payload.
public struct ClassifierAlignmentEvidenceRequest: Equatable, Sendable {
    public let workflow: ClassifierAlignmentWorkflowKind
    public let resultIdentity: ClassifierAlignmentResultIdentity
    public let bamURL: URL
    public let index: ClassifierAlignmentIndex
    public let sample: ClassifierAlignmentSample
    public let contig: ClassifierAlignmentContig
    public let referenceCandidate: ClassifierAlignmentReferenceCandidate?
    public let presentation: ClassifierAlignmentEvidencePresentation

    public init(
        workflow: ClassifierAlignmentWorkflowKind,
        resultIdentity: ClassifierAlignmentResultIdentity,
        bamURL: URL,
        index: ClassifierAlignmentIndex,
        sample: ClassifierAlignmentSample,
        contig: ClassifierAlignmentContig,
        referenceCandidate: ClassifierAlignmentReferenceCandidate?,
        presentation: ClassifierAlignmentEvidencePresentation
    ) {
        self.workflow = workflow
        self.resultIdentity = resultIdentity
        self.bamURL = bamURL
        self.index = index
        self.sample = sample
        self.contig = contig
        self.referenceCandidate = referenceCandidate
        self.presentation = presentation
    }
}

/// AppKit-safe seam used by classifier leaf modules to embed the full viewer.
///
/// The composition root supplies the implementation, so this interface never
/// imports `LungfishApp` or exposes its view-controller types.
@MainActor
public protocol ClassifierAlignmentViewerProviding: AnyObject {
    var viewController: NSViewController { get }

    func display(_ request: ClassifierAlignmentEvidenceRequest)
    func clear()
}
