// ProvenanceExporter+PinGate.swift - The pin gate a script export asks before it writes anything
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Plan decision S7. A shell, Python, Nextflow or Snakemake export promises that
// someone else can rebuild the environments the run used. `pinGate` assesses the
// script `exportBundle` would write, from the same expanded chain, synthesized
// step and plan, and the CLI and both GUI paths ask it before they write. The
// gate never runs inside `exportBundle`, which writes whatever it is asked to.
//
// When the person overrides the gate, `exportBundle(... allowUnpinned: true)`
// names each unpinned step in the script header, comments each such step, and
// keeps the override and the steps in the export's own record.

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

    /// The plan of `run` and the notes its script carries for the steps an override let through.
    func planAndPins(_ run: WorkflowRun, allowUnpinned: Bool) -> (ProvenanceExportPlan, ProvenanceExportPinNotes) {
        let plan = exportPlan(run)
        return (plan, ProvenanceExportPinNotes(plan: plan, allowUnpinned: allowUnpinned))
    }

    // MARK: - Header facts

    /// The app version that recorded the run, as a script header prints it.
    func recordedAppLabel(_ run: WorkflowRun) -> String {
        let label = ProvenanceToolIdentityText.appVersionLabel(run.appVersion)
        return label.isEmpty ? "LGE, version not recorded" : label
    }

    /// A recorded fact as a header prints it, with `not recorded` for one the record left empty.
    func recordedFact(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "not recorded" : value
    }

    /// The app and the operating system that ran the workflow, as the methods section names them.
    func methodsRuntimePhrase(_ run: WorkflowRun) -> String {
        let app = ProvenanceToolIdentityText.appVersionLabel(run.appVersion)
        let host = run.hostOS.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (app.isEmpty, host.isEmpty) {
        case (false, false): return "\(app) on \(host)"
        case (true, false): return "an LGE version that was not recorded on \(host)"
        case (false, true): return "\(app) on an operating system that was not recorded"
        case (true, true): return "an LGE version and an operating system that were not recorded"
        }
    }

    /// What the `=<build>` part of a spec means, for an export that writes a versioned spec.
    func buildNote(_ plan: ProvenanceExportPlan, prefix: String) -> String {
        guard plan.environments.contains(where: { $0.packageSpec.flatMap(CondaSpec.init(spec:))?.version != nil }) else {
            return ""
        }
        return "\(prefix)A spec without =<build> keeps the recorded version and leaves the build\n"
            + "\(prefix)to the solver. The lock's build strings name osx-arm64 builds, so on\n"
            + "\(prefix)another platform drop =<build> from a spec and keep its version.\n"
    }
}

/// What a script carries for the steps an override let through (plan decision S7). Nothing without
/// the override, so an export that needs none reads as it always did.
struct ProvenanceExportPinNotes {
    static let none = ProvenanceExportPinNotes(allowUnpinned: false, steps: [])

    /// Whether the person passed the override.
    let allowUnpinned: Bool
    /// The steps the override let through, in script order.
    let steps: [ProvenanceExportPinGate.UnpinnedStep]

    init(allowUnpinned: Bool, steps: [ProvenanceExportPinGate.UnpinnedStep]) {
        self.allowUnpinned = allowUnpinned
        self.steps = steps
    }

    /// The notes for the script `plan` renders.
    init(plan: ProvenanceExportPlan, allowUnpinned: Bool) {
        self.init(
            allowUnpinned: allowUnpinned,
            steps: allowUnpinned ? ProvenanceExportPinGate.unpinnedSteps(in: plan).unpinned : []
        )
    }

    /// The header block that names each unpinned step (bioinformatics non-negotiable 3).
    func header(prefix: String) -> String {
        guard !steps.isEmpty else { return "" }
        var s = "\(prefix)\n"
        s += "\(prefix)Exported with \(ProvenanceExporter.allowUnpinnedFlag). LGE cannot pin the tool version\n"
        s += "\(prefix)of these steps, so their environments may not hold the versions that ran:\n"
        for step in steps {
            s += "\(prefix)  \(step.summary)\n"
        }
        return s
    }

    /// The comment line on one step the override let through, and nothing for any other step.
    func stepNote(_ step: ProvenanceExportPlan.Step, prefix: String) -> String {
        guard let unpinned = steps.first(where: { $0.numbers == step.numbers }) else { return "" }
        return "\(prefix)Not pinned. \(unpinned.reason.sentence) Exported with \(ProvenanceExporter.allowUnpinnedFlag).\n"
    }

    /// The flag after a default argv, which the export builds when its caller passes none.
    func defaultArgvSuffix(provided argv: [String]) -> [String] {
        argv.isEmpty && allowUnpinned ? [ProvenanceExporter.allowUnpinnedFlag] : []
    }

    /// The explicit option the export record keeps for the override.
    var explicitOptions: [String: ParameterValue] {
        allowUnpinned ? ["allowUnpinned": .boolean(true)] : [:]
    }

    /// The resolved options of the export record, with the steps the override let through.
    func resolvedOptions(_ base: [String: ParameterValue]) -> [String: ParameterValue] {
        guard !steps.isEmpty else { return base }
        return base.merging(["unpinnedSteps": .array(steps.map { .string($0.summary) })]) { current, _ in current }
    }
}
