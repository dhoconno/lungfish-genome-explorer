// PrimerExportInvocations.swift - The argv of the primer order and primer selection exports
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// The `lungfish-cli primers analysis export-order` command of a primer order export (Phase 2.13 lane 13.43,
/// PRIMER-EXPORT-RUN, ARCH ruling on the export shape 1.1).
///
/// The Inspector's order export and the leaf share this builder, so the row the app records, the argv the leaf records
/// and the command a user pastes in Terminal are one command.
public enum PrimerOrderExport {
    /// The leaf's path under `lungfish-cli`.
    public static let commandPath = ["primers", "analysis", "export-order"]
}

/// The `lungfish-cli primers analysis export-selection` command of a primer FASTA bundle or a reference amplicon
/// export (Phase 2.13 lane 13.43, PRIMER-EXPORT-RUN, ARCH ruling on the export shape 1.1).
public enum PrimerSelectionExport {
    /// The leaf's path under `lungfish-cli`.
    public static let commandPath = ["primers", "analysis", "export-selection"]
}

extension PrimerOrderExport {
    /// The leaf's invocation for a captured selection and the order fields the user filled in, with absolute
    /// standardized paths. The begin helper passes its `arguments()` to the runner and to the row's command, and the leaf
    /// records its `canonicalArgv()`, so the row, the record and the command a user pastes in Terminal are one command.
    /// `--name` is always passed because the CLI's default name differs from the app's.
    public static func invocation(
        analysisURL: URL,
        selection: PrimerOrderSelection,
        metadata: PrimerOrderMetadata,
        outputURL: URL,
        emitsEvents: Bool = true
    ) -> ViewerExportInvocation {
        ViewerExportInvocation(
            commandPath: commandPath,
            input: analysisURL.standardizedFileURL.path,
            leafArguments: primerOrderExportScopeArguments(selection) + primerOrderMetadataArguments(metadata),
            output: outputURL.standardizedFileURL.path,
            emitsEvents: emitsEvents
        )
    }

    /// The `--scope` arguments for the captured selection, and for a PrimalScheme
    /// selection the view options of its view.
    private static func primerOrderExportScopeArguments(_ selection: PrimerOrderSelection) -> [String] {
        if selection.isPrimer3CandidateSelection {
            return ["--scope", "candidate-pairs"]
                + (selection.selectedAssayIDs ?? []).flatMap { ["--candidate-pair-id", $0] }
        }
        if selection.selectedAssayIDs != nil {
            return ["--scope", selection.includesAllReportedAssays == true ? "all-reported-assays" : "selected-assays"]
        }
        return ["--scope", "displayed"] + primerOrderViewArguments(selection.settings)
    }

    /// The view options of `export-order` that reproduce `settings`, none for the
    /// default view. They name every field of the settings that differs from the
    /// default, so the order records the same view as the app's.
    private static func primerOrderViewArguments(_ settings: PrimerAnalysisDisplaySettings) -> [String] {
        var args = settings.hiddenPrimerIDs.sorted().flatMap { ["--hide-primer", $0] }
        args += settings.hiddenPoolIDs.sorted().flatMap { ["--hide-pool", $0] }
        if !settings.showForward { args.append("--hide-forward") }
        if !settings.showReverse { args.append("--hide-reverse") }
        if !settings.showAmplicons { args.append("--hide-amplicons") }
        if !settings.showIdentityDots { args.append("--hide-identity-dots") }
        if !settings.showUnassessed { args.append("--hide-unassessed") }
        if settings.filterByCompatibility { args.append("--filter-compatibility") }
        if settings.minimumCompatibilityPercent != 0 {
            args += ["--min-compatibility", String(settings.minimumCompatibilityPercent)]
        }
        return args
    }

    /// `--name` and the order fields the user filled in. `--name` is always
    /// passed because the CLI's default name differs from the app's.
    private static func primerOrderMetadataArguments(_ metadata: PrimerOrderMetadata) -> [String] {
        var args = ["--name", metadata.name]
        let optionalFields = [
            ("--requested-by", metadata.requestedBy),
            ("--project", metadata.project),
            ("--order-reference", metadata.orderReference),
            ("--notes", metadata.notes),
        ]
        for (flag, value) in optionalFields where !value.isEmpty {
            args += [flag, value]
        }
        return args
    }
}

extension PrimerSelectionExport {
    /// The leaf's invocation for one saved selection, with absolute standardized paths. The begin helper passes its
    /// `arguments()` to the runner and to the row's command, and the leaf records its `canonicalArgv()`. The values the
    /// saved analysis supplies (the IDs and a native pool name) join their option with `=`, so the parser reads one that
    /// starts with a hyphen as a value.
    public static func invocation(
        analysisURL: URL,
        selection: PrimerAnalysisExportSelection,
        kind: PrimerAnalysisExportKind,
        outputURL: URL,
        emitsEvents: Bool = true
    ) -> ViewerExportInvocation {
        let selectionArguments: [String]
        switch selection {
        case .primer(let targetID, let primerID):
            selectionArguments = ["--target-id=\(targetID)", "--primer-id=\(primerID)"]
        case .amplicon(let targetID, let ampliconID):
            selectionArguments = ["--target-id=\(targetID)", "--amplicon-id=\(ampliconID)"]
        case .pool(let sourceResultID, let pool):
            selectionArguments = ["--source-result-id=\(sourceResultID)", "--pool", String(pool)]
        case .nativePool(let sourceResultID, let pool):
            selectionArguments = ["--source-result-id=\(sourceResultID)", "--native-pool=\(pool)"]
        }
        let kindName: String
        switch kind {
        case .primerFASTA: kindName = "primer-fasta"
        case .referenceAmplicon: kindName = "reference-amplicon"
        }
        return ViewerExportInvocation(
            commandPath: commandPath,
            input: analysisURL.standardizedFileURL.path,
            leafArguments: ["--kind", kindName] + selectionArguments,
            output: outputURL.standardizedFileURL.path,
            emitsEvents: emitsEvents
        )
    }
}
