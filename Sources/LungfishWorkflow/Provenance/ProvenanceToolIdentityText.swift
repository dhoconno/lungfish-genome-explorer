// ProvenanceToolIdentityText.swift - A tool's version as a reader should see it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Records carry the version in several shapes: a bare `1.24`, a managed
// tool's `1.24 (managed conda environment bcftools; executable bcftools;
// package bioconda::bcftools=1.24=h6bd33b9_2)`, the app's own `Lungfish
// 2026.9.72 (dev)` or the older `Lungfish dev (0)`, and `lungfish-cli
// 2026.9.52`, which repeats the tool's name inside its version. Every
// export and the Inspector read the version through this type, so a reader
// never sees `vLungfish dev (0)`, `dev (0)` or `vlungfish-cli 2026.9.52`: a
// version a development build stamped reads as `(development build)`, and
// the package pin a managed tool recorded becomes a conda environment the
// export can declare.

import Foundation
import LungfishIO

/// The managed conda environment a step ran in, as recorded in its version.
public struct ProvenanceManagedEnvironment: Sendable, Equatable, Hashable {
    /// The environment name (`bcftools`, `htslib`).
    public let name: String
    /// The executable inside it, when recorded.
    public let executable: String?
    /// The exact package pin (`bioconda::bcftools=1.24=h6bd33b9_2`), when recorded.
    public let packageSpec: String?
    /// 1 for the first package an export installs in an environment of this name. A run whose steps used
    /// two packages in one environment keeps both, and the later one is variant 2 and up, exported as its
    /// own conda environment so that neither spec is dropped.
    public let variant: Int

    public init(name: String, executable: String? = nil, packageSpec: String? = nil, variant: Int = 1) {
        self.name = name
        self.executable = executable
        self.packageSpec = packageSpec
        self.variant = variant
    }

    /// What an export calls this environment, the sanitized name and then `_2` and up for a later variant.
    public var exportName: String {
        let stem = WorkflowExportGraph.sanitize(name)
        return variant > 1 ? "\(stem)_\(variant)" : stem
    }

    /// The path of the environment file an export writes for this
    /// environment, relative to the export folder.
    public var environmentFileName: String {
        "envs/\(exportName).yaml"
    }

    /// What an export installs: the recorded pin, else the package the managed
    /// lock installs in this environment (`whatshap` for `phasing`), and the
    /// environment name only for an environment the lock does not hold.
    private var installedPackage: String {
        packageSpec ?? ProvenanceExportPlan.lockPackageName(forEnvironment: name) ?? name
    }

    /// The conda environment file: the pin when there is one, the package
    /// the lock installs otherwise.
    public var environmentFileContents: String {
        var s = "# Written by Lungfish from the recorded package pin.\n"
        s += "name: lge-\(exportName)\n"
        s += "channels:\n  - conda-forge\n  - bioconda\ndependencies:\n"
        s += "  - \(installedPackage)\n"
        return s
    }

    /// The `micromamba create` line that recreates this environment.
    public var micromambaCreateCommand: String {
        "micromamba create -y -n lge-\(exportName) -c conda-forge -c bioconda \(installedPackage)"
    }
}

// MARK: - The runtime text a managed tool's record carries

extension ManagedToolLock {
    /// The conda package spec this lock installs for `entry`, such as `bioconda::ivar=1.4.4=hda5e58c_0`.
    ///
    /// `ManagedToolLockEntry` is a read-only view that carries no spec, so the spec is read from the lock
    /// list the entry came from. A pack tool resolves here as well as a tool of the required pack. A tool
    /// that a Python runtime or a source build installs has no spec of its own, because the lock's spec
    /// names the interpreter or the conda fallback, so this returns nil for it.
    func packageSpec(of entry: ManagedToolLockEntry) -> String? {
        guard entry.pythonRuntime == nil, entry.sourceBuild == nil else { return nil }
        switch entry.source {
        case .tool:
            return tools.first { $0.id == entry.id.rawValue }?.packageSpec
        case .packTool(let packID):
            return packTools.first { $0.packID == packID && $0.toolID == entry.id.rawValue }?.packageSpec
        }
    }
}

extension ProvenanceManagedEnvironment {
    /// The text a record keeps in parentheses after a managed tool's version, as the pipelines write it:
    /// `managed conda environment samtools; executable samtools; package bioconda::samtools=1.24=h36b3a25_1`.
    /// The package part is left out when there is none.
    static func recordedRuntime(environment: String, executableName: String, packageSpec: String?) -> String {
        var text = "managed conda environment \(environment); executable \(executableName)"
        if let packageSpec { text += "; package \(packageSpec)" }
        return text
    }

    /// The runtime text of a native tool. The package is the lock's spec for the tool's `ManagedToolID`,
    /// found with `entry(id:)` so a pack tool such as iVar, whatshap or minimap2 resolves, and the tool's
    /// source package when the lock has no such entry.
    static func recordedRuntime(for tool: NativeTool, lock: ManagedToolLock = .bundled) -> String {
        switch tool.location {
        case .managed(let environment, let executableName):
            let spec = lock.entry(id: tool.managedToolID).flatMap { lock.packageSpec(of: $0) }
            return recordedRuntime(environment: environment, executableName: executableName, packageSpec: spec ?? tool.sourcePackage)
        case .bundled(let relativePath):
            return "bundled executable \(relativePath)"
        }
    }

    /// The runtime text of a tool run through `micromamba run -n <environment>`, which names an environment
    /// and an executable and no `NativeTool`. The package is the spec of the lock entry installed in that
    /// environment, found with `entry(environment:)`, and is left out for an environment the lock does not hold.
    static func recordedRuntime(environment: String, executableName: String, lock: ManagedToolLock = .bundled) -> String {
        let spec = lock.entry(environment: environment).flatMap { lock.packageSpec(of: $0) }
        return recordedRuntime(environment: environment, executableName: executableName, packageSpec: spec)
    }
}

/// A tool name and version split into the parts an export prints.
public struct ProvenanceToolIdentityText: Sendable, Equatable {
    /// The version text of a build with no release number.
    public static let developmentBuildLabel = "development build"

    public let toolName: String
    /// The version alone (`1.24`, `2026.9.52`, `development build`, `unknown`).
    public let version: String
    /// The managed environment, when the version recorded one.
    public let environment: ProvenanceManagedEnvironment?
    /// A runtime note that is not a managed environment (`bundled executable ...`).
    public let runtimeNote: String?
    /// True when a development build of Lungfish recorded the version
    /// (`Lungfish dev (0)`, `Lungfish 2026.9.72 (dev)`, `dev`).
    public let isDevelopmentBuild: Bool

    public init(
        toolName: String,
        version: String,
        environment: ProvenanceManagedEnvironment?,
        runtimeNote: String?,
        isDevelopmentBuild: Bool = false
    ) {
        self.toolName = toolName
        self.version = version
        self.environment = environment
        self.runtimeNote = runtimeNote
        self.isDevelopmentBuild = isDevelopmentBuild
    }

    /// `v1.24` when the version starts with a digit, `(development build)`
    /// or `v2026.9.72 (development build)` for a development build, the
    /// version otherwise.
    public var displayVersion: String {
        if isDevelopmentBuild {
            guard version != Self.developmentBuildLabel else { return "(\(Self.developmentBuildLabel))" }
            return "v\(version) (\(Self.developmentBuildLabel))"
        }
        guard let first = version.first, first.isNumber else { return version }
        return "v" + version
    }

    /// An app version as a header or summary prints it: `Lungfish 2026.9.72
    /// (1)` and `lungfish-cli 2026.9.52` as recorded, `Lungfish (development
    /// build)` or `Lungfish 2026.9.72 (development build)` for a development
    /// build, which never prints as `dev (0)`.
    public static func appVersionLabel(_ recorded: String) -> String {
        let trimmed = recorded.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = parse(toolName: "Lungfish", toolVersion: trimmed)
        guard identity.isDevelopmentBuild else { return trimmed }
        guard identity.version != developmentBuildLabel else { return "Lungfish (\(developmentBuildLabel))" }
        return "Lungfish \(identity.version) (\(developmentBuildLabel))"
    }

    /// `bcftools v1.24`.
    public var displayLabel: String {
        "\(toolName) \(displayVersion)"
    }

    private static let appPrefixes = ["lungfish-cli ", "lungfish ", "lge "]

    public static func parse(toolName: String, toolVersion: String) -> ProvenanceToolIdentityText {
        var version = toolVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        var environment: ProvenanceManagedEnvironment?
        var runtimeNote: String?

        if let open = version.lastIndex(of: "("), version.hasSuffix(")") {
            let note = String(version[version.index(after: open) ..< version.index(before: version.endIndex)])
            if let managed = parseManagedEnvironment(note) {
                environment = managed
                version = String(version[..<open]).trimmingCharacters(in: .whitespaces)
            } else if note.contains("executable") || note.contains("environment") || note.contains("root ") {
                runtimeNote = note
                version = String(version[..<open]).trimmingCharacters(in: .whitespaces)
            }
        }

        // A version that names the tool again keeps only the version.
        var prefixes = appPrefixes
        let name = toolName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { prefixes.insert(name + " ", at: 0) }
        var stripped = true
        while stripped {
            stripped = false
            for prefix in prefixes
            where version.lowercased().hasPrefix(prefix.lowercased()) && version.count > prefix.count {
                version = String(version.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                stripped = true
            }
        }
        if version.isEmpty || looksLikeProbeError(version) { version = "unknown" }

        let development = developmentBuildVersion(version)
        return ProvenanceToolIdentityText(
            toolName: name.isEmpty ? "unknown" : name,
            version: development ?? version,
            environment: environment,
            runtimeNote: runtimeNote,
            isDevelopmentBuild: development != nil
        )
    }

    /// True when a recorded version is a tool's complaint about the version
    /// probe rather than a version (`FATAL(lofreq_main.c|main:336):
    /// Unrecognized command '--version'`), which older records stored.
    private static func looksLikeProbeError(_ version: String) -> Bool {
        let lowered = version.lowercased()
        return ["fatal", "unrecognized", "unrecognised", "unknown command", "unknown option", "usage:", "error:"]
            .contains { lowered.contains($0) }
    }

    /// The release number of a development build's version, the development
    /// label when it has none, or nil for a released version. Recognised
    /// shapes are `dev`, `dev (0)`, `dev (12)`, `2026.9.72 (dev)` and `vdev`.
    private static func developmentBuildVersion(_ version: String) -> String? {
        var value = version.trimmingCharacters(in: .whitespaces)
        if value.lowercased().hasPrefix("v"), value.dropFirst().lowercased().hasPrefix("dev") {
            value = String(value.dropFirst())
        }
        var release = value
        var build: String?
        if let open = value.lastIndex(of: "("), value.hasSuffix(")") {
            build = String(value[value.index(after: open) ..< value.index(before: value.endIndex)])
                .trimmingCharacters(in: .whitespaces)
            release = String(value[..<open]).trimmingCharacters(in: .whitespaces)
        }
        let releaseIsDev = release.lowercased() == "dev"
        let buildIsDev = build?.lowercased() == "dev"
        guard releaseIsDev || buildIsDev else { return nil }
        if releaseIsDev || release.isEmpty { return developmentBuildLabel }
        return release
    }

    private static func parseManagedEnvironment(_ note: String) -> ProvenanceManagedEnvironment? {
        let fields = note.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = fields.first, first.hasPrefix("managed conda environment ") else { return nil }
        let name = String(first.dropFirst("managed conda environment ".count)).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        var executable: String?
        var packageSpec: String?
        for field in fields.dropFirst() {
            if field.hasPrefix("executable ") {
                executable = String(field.dropFirst("executable ".count)).trimmingCharacters(in: .whitespaces)
            } else if field.hasPrefix("package ") {
                packageSpec = String(field.dropFirst("package ".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return ProvenanceManagedEnvironment(name: name, executable: executable, packageSpec: packageSpec)
    }
}
