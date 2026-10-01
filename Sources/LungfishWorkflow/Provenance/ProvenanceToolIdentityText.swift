// ProvenanceToolIdentityText.swift - A tool's version as a reader should see it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Records carry the version in several shapes: a bare `1.24`, a managed
// tool's `1.24 (managed conda environment bcftools; executable bcftools;
// package bioconda::bcftools=1.24=h6bd33b9_2)`, the app's own `Lungfish
// 2026.9.72 (dev)` or the older `Lungfish dev (0)`, and `lungfish-cli
// 2026.9.52`, which repeats the tool's name inside its version. Every
// export reads the version through this type, so a reader never sees
// `vLungfish dev (0)` or `vlungfish-cli 2026.9.52`, and the package pin a
// managed tool recorded becomes a conda environment the export can declare.

import Foundation

/// The managed conda environment a step ran in, as recorded in its version.
public struct ProvenanceManagedEnvironment: Sendable, Equatable, Hashable {
    /// The environment name (`bcftools`, `htslib`).
    public let name: String
    /// The executable inside it, when recorded.
    public let executable: String?
    /// The exact package pin (`bioconda::bcftools=1.24=h6bd33b9_2`), when recorded.
    public let packageSpec: String?

    public init(name: String, executable: String? = nil, packageSpec: String? = nil) {
        self.name = name
        self.executable = executable
        self.packageSpec = packageSpec
    }

    /// The path of the environment file an export writes for this
    /// environment, relative to the export folder.
    public var environmentFileName: String {
        "envs/\(WorkflowExportGraph.sanitize(name)).yaml"
    }

    /// The conda environment file: exact pin when recorded, the environment
    /// name as a package otherwise.
    public var environmentFileContents: String {
        var s = "# Written by Lungfish from the recorded package pin.\n"
        s += "name: lge-\(WorkflowExportGraph.sanitize(name))\n"
        s += "channels:\n  - conda-forge\n  - bioconda\ndependencies:\n"
        s += "  - \(packageSpec ?? name)\n"
        return s
    }

    /// The `micromamba create` line that recreates this environment.
    public var micromambaCreateCommand: String {
        "micromamba create -y -n lge-\(WorkflowExportGraph.sanitize(name)) -c conda-forge -c bioconda \(packageSpec ?? name)"
    }
}

/// A tool name and version split into the parts an export prints.
public struct ProvenanceToolIdentityText: Sendable, Equatable {
    public let toolName: String
    /// The version alone (`1.24`, `2026.9.52`, `dev (0)`, `unknown`).
    public let version: String
    /// The managed environment, when the version recorded one.
    public let environment: ProvenanceManagedEnvironment?
    /// A runtime note that is not a managed environment (`bundled executable ...`).
    public let runtimeNote: String?

    /// `v1.24` when the version starts with a digit, the version otherwise.
    public var displayVersion: String {
        guard let first = version.first, first.isNumber else { return version }
        return "v" + version
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
        if version.isEmpty { version = "unknown" }

        return ProvenanceToolIdentityText(
            toolName: name.isEmpty ? "unknown" : name,
            version: version,
            environment: environment,
            runtimeNote: runtimeNote
        )
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
