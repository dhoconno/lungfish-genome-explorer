// ProvenanceExportPinAssessment.swift - Which steps an export can pin to the lock
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// An executable export (shell, Python, Nextflow, Snakemake) promises that
// someone else can rebuild the environments a run used. `ProvenanceExportPlan`
// writes each environment as a package spec, the lock's spec with its build at
// the recorded version and the recorded version alone otherwise.
//
// `assess(_:lock:)` reads the steps one record holds and says, for each step
// that names a managed environment, whether the spec `ProvenanceExportPlan.pinned`
// writes for it is the lock's pin, and if not why not. It does not expand a
// provenance chain, synthesize the one step `legacyWorkflowRun` builds for a
// record with no steps, or give each package of an environment its own
// variant as the plan does, so it characterizes records and does not
// reproduce `exportBundle`.
//
// `ProvenanceExportPinGate` is the refusal of plan decision S7. It assesses the
// plan `exportBundle` renders, through `assess(plan:lock:)`, so it sees what a
// script would run. Both computations are pure and change no exporter, writer
// or record.

import Foundation
import LungfishIO

public struct ProvenanceExportPinAssessment: Sendable, Hashable {
    /// Why a conda spec cannot express a locked tool.
    public enum RuntimeKind: String, Sendable, Hashable {
        /// A pack-built Python runtime such as primalscheme3.
        case pythonRuntime
        /// A source build such as bracken.
        case sourceBuild
    }

    /// The pin status of one step, in the order the assessment decides it.
    public enum Status: Sendable, Hashable {
        /// The export writes exactly the lock's spec for the environment.
        case pinnedToLock
        /// The recorded version is not the lock's pin.
        case versionDiffersFromLock(recorded: String, locked: String)
        /// The step recorded no usable version.
        case versionUnknown(ToolVersionEvidence.Reason)
        /// The environment the export derives is not an environment of the lock.
        case environmentNotInLock(String)
        /// The version matches the lock, but the spec the export would write is
        /// not the lock's spec (no build, another channel, a bare or wrong package).
        case packageSpecUnavailable
        /// The step recorded a full conda spec that is not the lock's spec.
        case recordedSpecDiffersFromLock
        /// The lock installs this environment by a Python runtime or a source
        /// build, which a conda spec cannot express.
        case unpinnableRuntime(RuntimeKind)
        /// The export derives no managed environment from this step (an app
        /// action, the app's own command line, a tool run outside a managed
        /// environment, or a record that kept the environment only in its
        /// runtime identity).
        case noEnvironmentRecorded

        /// A short stable name for tables and tests.
        public var code: String {
            switch self {
            case .pinnedToLock: return "pinnedToLock"
            case .versionDiffersFromLock: return "versionDiffersFromLock"
            case .versionUnknown: return "versionUnknown"
            case .environmentNotInLock: return "environmentNotInLock"
            case .packageSpecUnavailable: return "packageSpecUnavailable"
            case .recordedSpecDiffersFromLock: return "recordedSpecDiffersFromLock"
            case .unpinnableRuntime(let kind): return "unpinnableRuntime.\(kind.rawValue)"
            case .noEnvironmentRecorded: return "noEnvironmentRecorded"
            }
        }

        /// True when the export would declare a managed environment that is not
        /// pinned to the lock.
        public var isUnpinned: Bool {
            switch self {
            case .pinnedToLock, .noEnvironmentRecorded: return false
            default: return true
            }
        }
    }

    /// A way today's export spec differs from the lock's spec.
    public enum Hazard: String, Sendable, Hashable, CaseIterable {
        /// The export writes a package name with no version.
        case bareName
        /// The export writes the environment name as the package, and the lock's
        /// package has another name (`phasing` for `whatshap`, `gatk-core` for `gatk4`).
        case environmentNameAsPackage
        /// The export writes a channel other than the lock's (`bioconda::` for a
        /// conda-forge package such as pigz, mafft or openpyxl).
        case wrongChannel
        /// The export writes a version with no build, and the lock pins a build.
        case missingBuild
        /// The version text recorded a package that is not a conda spec
        /// (`ivar`, `ncbi-blast`, the native tool's source package).
        case recordedPackageNotCondaSpec
    }

    public struct StepAssessment: Sendable, Hashable {
        /// The 1-based position of the step in the record.
        public let number: Int
        public let toolName: String
        /// The step's `toolVersion` as recorded.
        public let recordedVersion: String
        public let evidence: ToolVersionEvidence
        /// The environment the export derives from the version text or the executable path.
        public let environment: String?
        /// The lock entry installed in that environment.
        public let lockEntryID: ManagedToolID?
        /// The spec today's export would write for the environment.
        public let exportedSpec: String?
        /// The lock's spec for the environment.
        public let lockSpec: String?
        public let status: Status
        /// Every difference between the exported spec and the lock's spec, in declaration order.
        public let hazards: [Hazard]
    }

    public let steps: [StepAssessment]

    /// The steps whose declared environment is not pinned to the lock.
    public var unpinnedSteps: [StepAssessment] { steps.filter(\.status.isUnpinned) }

    /// The count of steps per status code.
    public var countsByStatusCode: [String: Int] {
        steps.reduce(into: [:]) { $0[$1.status.code, default: 0] += 1 }
    }

    /// Assesses the steps the envelope records, with no chain expansion and no synthesized step.
    ///
    /// - Parameter lock: The lock the steps are compared with. The exported spec always comes
    ///   from `ProvenanceExportPlan.pinned`, which reads the bundled lock.
    public static func assess(_ envelope: ProvenanceEnvelope, lock: ManagedToolLock = .bundled) -> ProvenanceExportPinAssessment {
        assess(steps: envelope.steps, lock: lock)
    }

    /// Assesses the given steps one by one.
    ///
    /// - Parameter lock: The lock the steps are compared with. The exported spec always comes
    ///   from `ProvenanceExportPlan.pinned`, which reads the bundled lock.
    public static func assess(steps: [ProvenanceStep], lock: ManagedToolLock = .bundled) -> ProvenanceExportPinAssessment {
        ProvenanceExportPinAssessment(steps: steps.enumerated().map { offset, step in
            assess(step, number: offset + 1, lock: lock)
        })
    }

    /// Assesses the steps a script export runs, from the plan it renders.
    ///
    /// Every replayable step of the plan is one assessment, numbered as the script numbers it, so
    /// the chain expansion and the step synthesized for a stepless record are already in it. A tool
    /// step is assessed with the spec its environment variant writes, and any other step reads as
    /// `noEnvironmentRecorded`, because the script declares no environment for it.
    static func assess(plan: ProvenanceExportPlan, lock: ManagedToolLock = .bundled) -> ProvenanceExportPinAssessment {
        ProvenanceExportPinAssessment(steps: plan.replayableSteps.map { step in
            let managed = step.kind == .tool ? step.identity.environment : nil
            return assess(
                number: step.number, toolName: step.toolName,
                recordedVersion: step.sourceSteps.first?.toolVersion ?? step.identity.version, identity: step.identity,
                managed: managed, exported: managed == nil ? nil : step.environment?.packageSpec, lock: lock
            )
        })
    }

    // MARK: - One step

    private static func assess(_ step: ProvenanceStep, number: Int, lock: ManagedToolLock) -> StepAssessment {
        let identity = ProvenanceToolIdentityText.parse(toolName: step.toolName, toolVersion: step.toolVersion)
        let managed = managedEnvironment(of: step, identity: identity)
        // The spec the export writes today, through the export plan's own function.
        let exported = managed.flatMap { ProvenanceExportPlan.pinned($0, version: identity.version).packageSpec }
        return assess(
            number: number, toolName: step.toolName, recordedVersion: step.toolVersion, identity: identity,
            managed: managed, exported: exported, lock: lock
        )
    }

    /// The status of one step that recorded `candidate` as its managed environment, when the export
    /// writes `exported` as that environment's package spec.
    fileprivate static func assess(
        number: Int, toolName: String, recordedVersion: String, identity: ProvenanceToolIdentityText,
        managed candidate: ProvenanceManagedEnvironment?, exported: String?, lock: ManagedToolLock
    ) -> StepAssessment {
        var evidence = ToolVersionEvidence.classify(recorded: recordedVersion)
        if candidate != nil, !evidence.isUnknown, isAppVersionLabel(recordedVersion, identity: identity) {
            evidence = .unknown(.recordedAppVersion(evidence.recordedString))
        }
        func result(
            _ status: Status, environment: String? = nil, entry: ManagedToolLockEntry? = nil,
            exported: String? = nil, locked: String? = nil, hazards: [Hazard] = []
        ) -> StepAssessment {
            StepAssessment(
                number: number, toolName: toolName, recordedVersion: recordedVersion, evidence: evidence,
                environment: environment, lockEntryID: entry?.id, exportedSpec: exported, lockSpec: locked,
                status: status, hazards: hazards
            )
        }

        guard let managed = candidate else { return result(.noEnvironmentRecorded) }
        guard let entry = lock.entry(environment: managed.name) else {
            let hazards = hazards(exported: exported, locked: nil, recorded: managed.packageSpec, environment: managed.name)
            return result(.environmentNotInLock(managed.name), environment: managed.name, exported: exported, hazards: hazards)
        }
        let locked = lock.packageSpec(forEnvironment: managed.name)
        let hazards = hazards(exported: exported, locked: locked, recorded: managed.packageSpec, environment: managed.name)
        func finish(_ status: Status) -> StepAssessment {
            result(status, environment: managed.name, entry: entry, exported: exported, locked: locked, hazards: hazards)
        }

        if entry.pythonRuntime != nil { return finish(.unpinnableRuntime(.pythonRuntime)) }
        if entry.sourceBuild != nil { return finish(.unpinnableRuntime(.sourceBuild)) }
        if case .unknown(let reason) = evidence { return finish(.versionUnknown(reason)) }
        if let lockedVersion = entry.version ?? locked.flatMap({ CondaSpec(spec: $0)?.version }),
           lockedVersion != identity.version {
            return finish(.versionDiffersFromLock(recorded: identity.version, locked: lockedVersion))
        }
        if exported == locked { return finish(.pinnedToLock) }
        if managed.packageSpec != nil, hazards.contains(.recordedPackageNotCondaSpec) == false {
            return finish(.recordedSpecDiffersFromLock)
        }
        return finish(.packageSpecUnavailable)
    }

    /// The environment `ProvenanceExportPlan` derives for a step: the one in the
    /// version text, else the one `micromamba run -n X` names, else the one in
    /// an executable path `.../envs/X/bin/tool`.
    private static func managedEnvironment(
        of step: ProvenanceStep, identity: ProvenanceToolIdentityText
    ) -> ProvenanceManagedEnvironment? {
        managedEnvironment(argv: step.durableReplayArgv ?? step.argv, identity: identity)
    }

    /// The environment of a tool piped after the first, found as the plan finds a step's: as above, or
    /// the runtime identity's `condaEnvironment` when its executable is that environment's copy of the
    /// tool's own program, as `ClassificationPipeline` records kraken2 and Bracken.
    fileprivate static func managedEnvironment(
        of step: StepExecution, identity: ProvenanceToolIdentityText
    ) -> ProvenanceManagedEnvironment? {
        let argv = step.durableReplayArgv ?? step.command
        if let environment = managedEnvironment(argv: argv, identity: identity) { return environment }
        guard let runtime = step.runtimeIdentity, let name = runtime.condaEnvironment,
              let program = argv.first.map({ URL(fileURLWithPath: $0).lastPathComponent }),
              runtime.executablePath?.hasSuffix("/envs/\(name)/bin/\(program)") == true else { return nil }
        return ProvenanceManagedEnvironment(name: name, executable: program, packageSpec: nil)
    }

    private static func managedEnvironment(
        argv recorded: [String], identity: ProvenanceToolIdentityText
    ) -> ProvenanceManagedEnvironment? {
        if let environment = identity.environment { return environment }
        var argv = recorded
        if argv.count >= 5, argv[0] == "micromamba", argv[1] == "run", argv[2] == "-n" {
            let name = argv[3]
            argv.removeFirst(4)
            return ProvenanceManagedEnvironment(name: name, executable: argv.first, packageSpec: nil)
        }
        guard let executable = argv.first, executable.hasPrefix("/") || executable.hasPrefix("<") else { return nil }
        let components = executable.split(separator: "/").map(String.init)
        guard let bin = components.lastIndex(of: "bin"), bin >= 2, components[bin - 2] == "envs" else { return nil }
        return ProvenanceManagedEnvironment(name: components[bin - 1], executable: components.last, packageSpec: nil)
    }

    /// True for the app's own version label (`Lungfish 2026.10.10 (dev)`,
    /// `lungfish-cli 2026.10.10`, `dev (0)`), which is no version of an external tool.
    private static func isAppVersionLabel(_ recorded: String, identity: ProvenanceToolIdentityText) -> Bool {
        let lowered = recorded.lowercased()
        return identity.isDevelopmentBuild || lowered.hasPrefix("lungfish ") || lowered.hasPrefix("lungfish-cli ")
    }

    private static func hazards(exported: String?, locked: String?, recorded: String?, environment: String) -> [Hazard] {
        guard let exported else { return [.bareName] }
        var found: [Hazard] = []
        let exportedSpec = CondaSpec(spec: exported)
        if exportedSpec == nil { found.append(.bareName) }
        if let recorded, CondaSpec(spec: recorded) == nil { found.append(.recordedPackageNotCondaSpec) }
        guard let locked, let lockedSpec = CondaSpec(spec: locked) else { return order(found) }
        let exportedName = exportedSpec?.name ?? exported
        if recorded == nil, exportedName == environment, lockedSpec.name != environment {
            found.append(.environmentNameAsPackage)
        }
        if let channel = exportedSpec?.channel, let lockedChannel = lockedSpec.channel, channel != lockedChannel {
            found.append(.wrongChannel)
        }
        if let exportedSpec, exportedSpec.build == nil, lockedSpec.build != nil { found.append(.missingBuild) }
        return order(found)
    }

    private static func order(_ found: [Hazard]) -> [Hazard] {
        Hazard.allCases.filter(found.contains)
    }
}

// MARK: - The script export gate

/// What a script export checks before it writes anything (plan decisions S7, S20 and V6).
///
/// `ProvenanceExporter.pinGate(for:shape:format:sourceSidecarURL:sourceRootURL:)` builds it from the
/// plan `exportBundle` renders. Only shell, Python, Nextflow and Snakemake exports are gated. A record
/// that decoded as the Older record format is never exported as a script. A script with a step whose
/// recorded version has no lock entry of that version, records no version, or needs a source build or
/// a Python runtime is written only with `--allow-unpinned` in the CLI or Export Anyway… in the app.
/// The lock entry is the one of the recorded version, never the current pin of another version
/// (bioinformatics correction 4).
public struct ProvenanceExportPinGate: Sendable, Hashable {
    /// Why the export cannot pin one step's environment.
    public enum Reason: Sendable, Hashable {
        /// The record holds no version for the step, or holds `unknown`, an error line or LGE's own version.
        case versionNotRecorded(ToolVersionEvidence.Reason)
        /// The lock holds no entry of the recorded version. `locked` is the version it pins, if any.
        case versionNotInLock(recorded: String, locked: String?)
        /// The lock holds no entry for the step's environment.
        case environmentNotInLock(String)
        /// The lock builds the tool from source, as it does Bracken (S20), or in a Python runtime.
        case unpinnableRuntime(ProvenanceExportPinAssessment.RuntimeKind)
        /// The spec the export writes does not pin the recorded version.
        case specDoesNotPinVersion(spec: String?, version: String)
        /// A tool piped after the first ran in this environment, which the script does not write.
        case environmentNotWritten(String)

        /// A short stable name for tables and tests.
        public var code: String {
            switch self {
            case .versionNotRecorded: return "versionNotRecorded"
            case .versionNotInLock: return "versionNotInLock"
            case .environmentNotInLock: return "environmentNotInLock"
            case .unpinnableRuntime(let kind): return "unpinnableRuntime.\(kind.rawValue)"
            case .specDoesNotPinVersion: return "specDoesNotPinVersion"
            case .environmentNotWritten: return "environmentNotWritten"
            }
        }

        /// The reason in plain words, one sentence about the step's tool.
        ///
        /// Every spelling that means no version reads as not recorded, because the reader turns an
        /// empty or missing version into `unknown`, so the record cannot tell them apart.
        public var sentence: String {
            switch self {
            case .versionNotRecorded(.recordedProbeError):
                return "Its recorded version is an error message from the version check."
            case .versionNotRecorded(.recordedAppVersion(let label)):
                return "The record holds LGE's own version (\(label)) instead of the tool's."
            case .versionNotRecorded:
                return "Its version was not recorded."
            case .versionNotInLock(let recorded, let locked?):
                return "Version \(recorded) ran, but LGE installs version \(locked)."
            case .versionNotInLock(let recorded, nil):
                return "Version \(recorded) ran, and LGE installs no exact version of this tool."
            case .environmentNotInLock(let name):
                return "LGE does not manage its conda environment \(name)."
            case .unpinnableRuntime(.sourceBuild):
                return "LGE builds this tool from source code, which no conda package reproduces."
            case .unpinnableRuntime(.pythonRuntime):
                return "LGE installs this tool in its own Python setup, which no conda package reproduces."
            case .specDoesNotPinVersion(_, let version):
                return "The export names no exact package for version \(version)."
            case .environmentNotWritten(let name):
                return "The script writes no environment for this tool, which ran in \(name)."
            }
        }
    }

    /// One step of the script whose environment the export cannot pin.
    public struct UnpinnedStep: Sendable, Hashable {
        /// The step numbers the script prints, more than one for steps joined by a pipe.
        public let numbers: [Int]
        public let toolName: String
        /// The step's `toolVersion` as recorded.
        public let recordedVersion: String
        /// The environment the step runs in, as the export names it (`lge-samtools_2`), and empty when
        /// the script writes none for the step.
        public let environmentName: String
        public let reason: Reason

        /// `Step 3`, or `Steps 3 and 4` for steps joined by a pipe.
        public var stepLabel: String {
            numbers.count == 1 ? "Step \(numbers[0])" : "Steps " + numbers.map(String.init).joined(separator: " and ")
        }

        /// The version the step recorded, parsed from `recordedVersion` (`3.1`).
        public var version: String {
            ProvenanceToolIdentityText.parse(toolName: toolName, toolVersion: recordedVersion).version
        }

        /// The step, its tool and the version that ran, its environment and the reason, as the CLI, the
        /// script header and the export record name it. The version is left out when none was recorded.
        public var summary: String {
            var tool = toolName
            if case .versionNotRecorded = reason {} else { tool += " \(version)" }
            let place = environmentName.isEmpty ? "" : " in \(environmentName)"
            return "\(stepLabel), \(tool)\(place). \(reason.sentence)"
        }
    }

    public let format: ProvenanceExportFormat
    /// The shape the reader decoded the record in.
    public let shape: ProvenanceEnvelopeReader.RecordShape
    /// The script's steps, each with its pin status. Empty for a format the gate does not check.
    public let assessment: ProvenanceExportPinAssessment
    /// The steps whose environments the export cannot pin, in script order.
    public let unpinnedSteps: [UnpinnedStep]
    /// The sidecar of a record the chain reads in the Older record format, when the exported record
    /// itself is not in that format. The script would replay that record's steps.
    public let olderRecordFormatUpstream: URL?

    /// True for the four formats that run tools.
    public var isGated: Bool { format.isPinGated }

    /// True when the format runs tools and the record, or a record its chain reads, decoded as the
    /// Older record format. No override lets this export through (V6).
    public var refusesOlderRecordFormat: Bool {
        isGated && (Self.isOlderRecordFormat(shape) || olderRecordFormatUpstream != nil)
    }

    /// True when the script would run a step the lock does not pin, which needs the override (S7).
    public var requiresOverride: Bool {
        isGated && !refusesOlderRecordFormat && !unpinnedSteps.isEmpty
    }

    /// Whether the export may be written, given whether the person chose to override the pins.
    public func permitsExport(allowUnpinned: Bool) -> Bool {
        !refusesOlderRecordFormat && (!requiresOverride || allowUnpinned)
    }

    /// The lines of a refusal, the reason first, then each unpinned step and the way past it. Empty
    /// when nothing is refused.
    public var refusalLines: [String] {
        if refusesOlderRecordFormat, let upstream = olderRecordFormatUpstream {
            return [
                "This record builds on \(upstream.path), which is in the Older record format. LGE fills in facts "
                    + "such records leave out, so it never exports a \(format.sentenceName) that replays one, with or "
                    + "without \(ProvenanceExporter.allowUnpinnedFlag).",
                "Export it with --format methods or --format json instead.",
            ]
        }
        if refusesOlderRecordFormat {
            return [
                "This record is in the Older record format. LGE fills in facts such records leave out, so it never "
                    + "exports one as a \(format.sentenceName), with or without \(ProvenanceExporter.allowUnpinnedFlag).",
                "Export it with --format methods or --format json instead.",
            ]
        }
        guard requiresOverride else { return [] }
        let count = unpinnedSteps.count == 1 ? "1 step" : "\(unpinnedSteps.count) steps"
        return ["LGE did not write the \(format.sentenceName), because it cannot pin the tool version of \(count)."]
            + unpinnedSteps.map(\.summary)
            + [
                "Pass \(ProvenanceExporter.allowUnpinnedFlag) to write it anyway. "
                    + "The \(format.sentenceName) and its export record then name each of these steps.",
            ]
    }

    // MARK: - Building the gate

    /// Only the bare run and the primitive shapes are the Older record format, never an envelope and
    /// never a typed record such as `mapping-provenance.json`.
    static func isOlderRecordFormat(_ shape: ProvenanceEnvelopeReader.RecordShape) -> Bool {
        switch shape {
        case .workflowRun, .primitive: return true
        case .envelope, .typedRecord: return false
        }
    }

    /// The gate for a format the pin check does not cover, which never refuses.
    static func ungated(_ format: ProvenanceExportFormat, shape: ProvenanceEnvelopeReader.RecordShape) -> ProvenanceExportPinGate {
        ProvenanceExportPinGate(
            format: format, shape: shape, assessment: ProvenanceExportPinAssessment(steps: []), unpinnedSteps: [],
            olderRecordFormatUpstream: nil
        )
    }

    /// Whether a sidecar the chain merged reads as the Older record format. A typed mapping record
    /// counts as typed, because only the finder converts it.
    static func isOlderRecordFormat(sidecar url: URL) -> Bool {
        guard !MappingProvenance.isRecordFilename(url.lastPathComponent),
              let reading = (try? ProvenanceEnvelopeReader.read(fromSidecar: url)) ?? nil else { return false }
        return isOlderRecordFormat(reading.shape)
    }

    /// The assessment of every replayable step of `plan`, and the tools among them the export cannot pin.
    ///
    /// A pipe is one script step, and the script writes the environment of its first tool only. Each
    /// tool piped after the first is assessed too, and one that ran in another environment is unpinned
    /// under the step's numbers. Writing each piped tool's environment is 2.7 work.
    static func unpinnedSteps(
        in plan: ProvenanceExportPlan, lock: ManagedToolLock = .bundled
    ) -> (assessment: ProvenanceExportPinAssessment, unpinned: [UnpinnedStep]) {
        let assessment = ProvenanceExportPinAssessment.assess(plan: plan, lock: lock)
        let unpinned = zip(plan.replayableSteps, assessment.steps).flatMap { step, assessed -> [UnpinnedStep] in
            let written = step.environment
            let writtenName = written.map { "lge-\($0.exportName)" } ?? ""
            var found: [UnpinnedStep] = []
            if written != nil, let reason = reason(for: assessed, version: step.identity.version, lock: lock) {
                found.append(UnpinnedStep(
                    numbers: step.numbers, toolName: step.sourceSteps.first?.toolName ?? step.toolName,
                    recordedVersion: assessed.recordedVersion, environmentName: writtenName, reason: reason
                ))
            }
            guard step.kind == .tool else { return found }
            for piped in step.sourceSteps.dropFirst() {
                let identity = ProvenanceToolIdentityText.parse(toolName: piped.toolName, toolVersion: piped.toolVersion)
                guard let managed = ProvenanceExportPinAssessment.managedEnvironment(of: piped, identity: identity) else {
                    continue
                }
                let reason: Reason?
                if let written, written.name == managed.name {
                    let tool = ProvenanceExportPinAssessment.assess(
                        number: step.number, toolName: piped.toolName, recordedVersion: piped.toolVersion,
                        identity: identity, managed: managed, exported: written.packageSpec, lock: lock
                    )
                    reason = Self.reason(for: tool, version: identity.version, lock: lock)
                } else {
                    reason = .environmentNotWritten(managed.name)
                }
                guard let reason else { continue }
                found.append(UnpinnedStep(
                    numbers: step.numbers, toolName: piped.toolName, recordedVersion: piped.toolVersion,
                    environmentName: writtenName, reason: reason
                ))
            }
            return found
        }
        return (assessment, unpinned)
    }

    /// Why the export cannot pin a tool recorded at `version`, or nil when it can or the script
    /// declares no environment for it.
    ///
    /// A spec that differs from the lock's only in its channel or build is pinned when the recorded
    /// version is the lock entry's version, because that spec is what ran. The written spec must
    /// still pin the recorded version, so no environment installs another one.
    private static func reason(
        for assessed: ProvenanceExportPinAssessment.StepAssessment,
        version: String,
        lock: ManagedToolLock
    ) -> Reason? {
        switch assessed.status {
        case .noEnvironmentRecorded:
            return nil
        case .versionUnknown(let reason):
            return .versionNotRecorded(reason)
        case .versionDiffersFromLock(let recorded, let locked):
            return .versionNotInLock(recorded: recorded, locked: locked)
        case .environmentNotInLock(let name):
            return .environmentNotInLock(name)
        case .unpinnableRuntime(let kind):
            return .unpinnableRuntime(kind)
        case .pinnedToLock, .packageSpecUnavailable, .recordedSpecDiffersFromLock:
            let entry = assessed.environment.flatMap { lock.entry(environment: $0) }
            let locked = entry?.version ?? assessed.lockSpec.flatMap { CondaSpec(spec: $0)?.version }
            guard locked == version else { return .versionNotInLock(recorded: version, locked: locked) }
            guard let spec = assessed.exportedSpec, CondaSpec(spec: spec)?.version == version else {
                return .specDoesNotPinVersion(spec: assessed.exportedSpec, version: version)
            }
            return nil
        }
    }
}
