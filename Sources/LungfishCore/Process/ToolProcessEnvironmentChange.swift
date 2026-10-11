// ToolProcessEnvironmentChange.swift - What an adapter changed in a child's environment, for provenance
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// What an adapter changed in a child's environment, as the provenance
/// observer carries it (`docs/contracts/RECORDING-PROVENANCE.md`, "The
/// ToolProcess observer hook").
///
/// ``ToolProcessSpec/environment`` stays the child's whole environment, and
/// this value never changes what the child gets. It describes the change
/// alone and never holds the inherited environment. It names every variable
/// the adapter set or removed, and it keeps a value only for a name on
/// ``valueRecordedNames``, the variables LGE's own adapters set, after
/// ``PortablePath`` sanitizing. The list names each variable, because a rule
/// on name patterns fails open when a secret sits in a value such as a proxy
/// address or a `DATABASE_URL`.
///
/// `PATH` never keeps a value. ``pathPrefix`` holds the entries the adapter
/// put before the base PATH instead, so the user's PATH never reaches a
/// record. `HOME`, `TMPDIR`, `MAFFT_TMPDIR` and `XDG_CACHE_HOME` keep their
/// names only, because their values name the account's home or scratch
/// folder and say nothing about the result (Phase 2.7 decision P10).
public struct ToolProcessEnvironmentChange: Sendable, Equatable {
    /// What the child's environment starts from before the adapter's change.
    public enum Base: String, Sendable, Equatable {
        /// The environment of the process that runs LGE, as
        /// ``ToolProcessSpec/inheritedEnvironment(overriding:)`` builds it.
        case inherited
        /// An empty environment, so the adapter set every variable the child has.
        case hermetic
    }

    /// One variable the adapter set.
    public struct Variable: Sendable, Equatable {
        /// The variable's name.
        public let name: String
        /// The sanitized value when ``name`` is on ``ToolProcessEnvironmentChange/valueRecordedNames``,
        /// and nil otherwise.
        public let value: String?

        public init(name: String, value: String?) {
            self.name = name
            self.value = value
        }
    }

    /// What the environment starts from.
    public let base: Base
    /// Every variable the adapter set, sorted by name.
    public let set: [Variable]
    /// The names the adapter removed from an inherited base, sorted. Empty
    /// for a hermetic base, which inherits nothing to remove.
    public let unset: [String]
    /// The PATH entries the adapter put before the base PATH, sanitized, in
    /// order. For a hermetic base this is the whole PATH the adapter set,
    /// which names no folder of the user's.
    public let pathPrefix: [String]

    /// Builds the change from what the adapter set, keeping a value only for
    /// a name on ``valueRecordedNames`` and sanitizing each kept value and
    /// each ``pathPrefix`` entry with `context`.
    ///
    /// - Parameters:
    ///   - base: What the environment starts from.
    ///   - set: Every variable the adapter set, with the value it set,
    ///     including `PATH` when the adapter set it.
    ///   - unset: The names the adapter removed from an inherited base.
    ///   - pathPrefix: The PATH entries the adapter put before the base PATH,
    ///     or the whole PATH it set for a hermetic base.
    ///   - context: The sanitizing context. Give it the managed tool and
    ///     storage roots, so an entry under them reads `<tool-root>` or
    ///     `<storage-root>` rather than `<external>`, and the project when
    ///     the run writes into one.
    public init(
        base: Base,
        set: [String: String] = [:],
        unset: [String] = [],
        pathPrefix: [String] = [],
        sanitizing context: PortablePath.Context
    ) {
        self.base = base
        self.set = set.sorted { $0.key < $1.key }.map { name, value in
            Variable(
                name: name,
                value: Self.recordsValue(of: name) ? PortablePath.sanitize(value: value, context: context) : nil
            )
        }
        self.unset = Array(Set(unset)).sorted()
        self.pathPrefix = pathPrefix.map { PortablePath.sanitize(path: $0, context: context) }
    }

    /// The names whose value a record keeps, the variables LGE's adapters and
    /// engine launches set for their tools. Any other name keeps its name only.
    public static let valueRecordedNames: Set<String> = [
        // Micromamba (CondaManager, ManagedMappingPipeline, WorkflowEngineLaunch, TaxTriage).
        "MAMBA_ROOT_PREFIX", "MAMBA_NO_BANNER",
        // Java for BBTools and the engines.
        "JAVA_HOME", "BBMAP_JAVA", "_JAVA_OPTIONS",
        // Nextflow.
        "NXF_ANSI_LOG", "NXF_HOME", "NXF_SYNTAX_PARSER",
        // The Python environments of primer design.
        "CONDA_PREFIX", "PYTHONNOUSERSITE", "PYTHONDONTWRITEBYTECODE", "PYTHONPATH", "PYTHONHOME", "MPLBACKEND",
        // MAFFT and the managed tool installer.
        "MAFFT_BINARIES", "DYLD_LIBRARY_PATH",
        // Terminal output of primalscheme3.
        "COLUMNS", "TERM", "NO_COLOR",
        // The managed roots a launched lungfish-cli reads.
        "LUNGFISH_STORAGE_ROOT", "LUNGFISH_CONDA_ROOT",
    ]

    /// Names that adapters set and whose value a record never keeps. `PATH`
    /// is recorded through ``pathPrefix``, and the other four name the
    /// account's home or scratch folder (P10). Every name off
    /// ``valueRecordedNames`` keeps its name only, and this list states the
    /// deliberate cases.
    public static let nameOnlyNames: Set<String> = ["PATH", "HOME", "TMPDIR", "MAFFT_TMPDIR", "XDG_CACHE_HOME"]

    /// True when a record keeps the value of variable `name`.
    public static func recordsValue(of name: String) -> Bool {
        valueRecordedNames.contains(name)
    }
}
