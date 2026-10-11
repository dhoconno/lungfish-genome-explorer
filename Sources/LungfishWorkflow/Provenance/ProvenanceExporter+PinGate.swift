// ProvenanceExporter+PinGate.swift - The pin gate a script export asks before it writes anything
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Plan decision S7. A shell, Python, Nextflow or Snakemake export promises that
// someone else can rebuild the environments the run used. `pinGate` assesses the
// script `exportBundle` would write, from the same expanded chain, synthesized
// step and plan, and the CLI and both GUI paths ask it before they write. The
// gate never runs inside `exportBundle`, which writes whatever it is asked to.

import Foundation
import LungfishCore

extension ProvenanceExportFormat {
    /// True for the four formats that run tools, the only ones the pin gate checks.
    public var isPinGated: Bool {
        switch self {
        case .shell, .python, .nextflow, .snakemake: return true
        case .methods, .json: return false
        }
    }

    /// What a sentence calls an export of this format (`shell script`, `Nextflow pipeline`).
    public var sentenceName: String {
        switch self {
        case .shell: return "shell script"
        case .python: return "Python script"
        case .nextflow: return "Nextflow pipeline"
        case .snakemake: return "Snakemake workflow"
        case .methods: return "methods section"
        case .json: return "provenance JSON"
        }
    }
}

extension ProvenanceExporter {
    /// The CLI flag that writes a script past the pin gate, as the export record keeps it.
    public static let allowUnpinnedFlag = "--allow-unpinned"

    /// What exporting `envelope` as `format` must check before anything is written.
    ///
    /// The gate reads the plan `exportBundle` renders for the same arguments, so it sees the
    /// expanded chain of upstream records, the step synthesized for a stepless record and the spec
    /// each environment variant writes. `shape` comes from the reading that found the record,
    /// `ProvenanceRecorder.findProvenanceReading(for:)` or `ProvenanceEnvelopeReader.read(fromSidecar:)`.
    /// A format the gate does not check gets a gate that never refuses.
    public func pinGate(
        for envelope: ProvenanceEnvelope,
        shape: ProvenanceEnvelopeReader.RecordShape,
        format: ProvenanceExportFormat,
        sourceSidecarURL: URL?,
        sourceRootURL: URL? = nil
    ) -> ProvenanceExportPinGate {
        guard format.isPinGated else { return .ungated(format, shape: shape) }
        let source = scriptSource(envelope, sourceSidecarURL: sourceSidecarURL, sourceRootURL: sourceRootURL)
        let (assessment, unpinned) = ProvenanceExportPinGate.unpinnedSteps(in: exportPlan(source.run))
        return ProvenanceExportPinGate(format: format, shape: shape, assessment: assessment, unpinnedSteps: unpinned)
    }

    /// What a script export renders: the record with every record that fed it merged in, upstream
    /// first, and the run made from that, which holds one synthesized step for a record with none.
    func scriptSource(
        _ envelope: ProvenanceEnvelope,
        sourceSidecarURL: URL?,
        sourceRootURL: URL?
    ) -> (expansion: ProvenanceChainExpansion, run: WorkflowRun) {
        let expansion = expandProvenanceChain(
            startingWith: envelope,
            sourceSidecarURL: sourceSidecarURL,
            sourceRootURL: sourceRootURL
        )
        return (expansion, expansion.envelope.legacyWorkflowRun(preferCanonicalSteps: true))
    }
}
