// CLIInvocation.swift — Argv as the source of truth for execution, display, and provenance.
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// A concrete `lungfish-cli` command line, built once by a typed request
/// builder and then used for three purposes that used to drift independently
/// (ARC-03, ARC-09, SIMP-01, WFL-11, FEA-12, REC-03):
///
/// 1. **Execution** — `arguments` is handed to `CLISubprocessTransport` (or,
///    for a still-in-process feature, parsed and asserted against the real
///    `LungfishCLI` parser in a round-trip test) verbatim.
/// 2. **Display** — `displayString` is what the Operations panel shows as
///    "Copy CLI Command" and what a failure report includes.
/// 3. **Provenance** — the same `arguments` are recorded as the run's
///    `argv`, so what is written to disk is what actually ran, not a
///    separately hand-built description of it.
///
/// Before this type, the Kraken2 GUI replay built `--db <path>` (the CLI
/// resolves `--db` as a registry *name*) and omitted `--preset`; the FASTQ
/// derivative operations built three independent encodings of the same
/// request, one of which (`seqkit grep`) was not even the command that ran.
/// A `CLIInvocation` cannot express that kind of drift, because there is only
/// one value.
public struct CLIInvocation: Sendable, Equatable {
    /// Full argv, starting with the first subcommand path component (e.g.
    /// `["classify", "--db", "Viral", ...]`), never including the
    /// `lungfish`/`lungfish-cli` executable name itself — that is prepended
    /// only by `displayString` and by whichever transport launches the
    /// process, matching `OperationCenter.buildCLICommand`'s existing
    /// convention.
    public let arguments: [String]

    public init(arguments: [String]) {
        self.arguments = arguments
    }

    /// A copy-pasteable, shell-quoted command line: `lungfish <arguments>`.
    /// Uses the same quoting rule as `OperationCenter.buildCLICommand` so a
    /// migrated call site's displayed command is byte-for-byte what that
    /// helper would have produced by hand.
    public var displayString: String {
        (["lungfish"] + arguments)
            .map(shellEscape)
            .joined(separator: " ")
    }

    /// The argv to record in a provenance envelope's `argv`/`command` field.
    /// Identical to `arguments` — provenance records exactly what
    /// `executedArguments` (below) sends to the CLI, never a separate
    /// description of it.
    public var provenanceArguments: [String] {
        arguments
    }

    /// The argv actually handed to the subprocess transport. Identical to
    /// `arguments`; named separately so call sites can express "the argv I
    /// executed equals the argv I recorded" as `invocation.executedArguments
    /// == invocation.provenanceArguments` without the tautology being
    /// invisible in a diff.
    public var executedArguments: [String] {
        arguments
    }
}
