// ProvenanceExportPinAssessment.swift - Which steps an export can pin to the lock
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// An executable export (shell, Python, Nextflow, Snakemake) promises that
// someone else can rebuild the environments a run used. `ProvenanceExportPlan`
// writes each environment as a package spec: the recorded `package` field when
// the version text holds one, otherwise `bioconda::<package>=<version>` built
// from the environment name or the lock, or the bare package when the version
// is not a number. Nothing checks that spec against the managed tool lock.
//
// This assessment reads a record and says, for every step, whether the spec
// today's export would write is the lock's pin, and if not why not. It is pure
// and changes no exporter, writer or record. Phase 2.6 decides what to refuse.

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

    public static func assess(_ envelope: ProvenanceEnvelope, lock: ManagedToolLock = .bundled) -> ProvenanceExportPinAssessment {
        assess(steps: envelope.steps, lock: lock)
    }

    public static func assess(steps: [ProvenanceStep], lock: ManagedToolLock = .bundled) -> ProvenanceExportPinAssessment {
        ProvenanceExportPinAssessment(steps: steps.enumerated().map { offset, step in
            assess(step, number: offset + 1, lock: lock)
        })
    }

    // MARK: - One step

    private static func assess(_ step: ProvenanceStep, number: Int, lock: ManagedToolLock) -> StepAssessment {
        let identity = ProvenanceToolIdentityText.parse(toolName: step.toolName, toolVersion: step.toolVersion)
        var evidence = ToolVersionEvidence.classify(recorded: step.toolVersion)
        let candidate = managedEnvironment(of: step, identity: identity)
        if candidate != nil, !evidence.isUnknown, isAppVersionLabel(step.toolVersion, identity: identity) {
            evidence = .unknown(.recordedAppVersion(evidence.recordedString))
        }
        func result(
            _ status: Status, environment: String? = nil, entry: ManagedToolLockEntry? = nil,
            exported: String? = nil, locked: String? = nil, hazards: [Hazard] = []
        ) -> StepAssessment {
            StepAssessment(
                number: number, toolName: step.toolName, recordedVersion: step.toolVersion, evidence: evidence,
                environment: environment, lockEntryID: entry?.id, exportedSpec: exported, lockSpec: locked,
                status: status, hazards: hazards
            )
        }

        guard let managed = candidate else { return result(.noEnvironmentRecorded) }
        // The spec the export writes today, through the export plan's own function.
        let exported = ProvenanceExportPlan.pinned(managed, version: identity.version).packageSpec
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
        if let environment = identity.environment { return environment }
        var argv = step.durableReplayArgv ?? step.argv
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
