// AppDelegate+ImportCenterOperationBegin.swift - Operations panel registration for Import Center and export launches
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishKit
import LungfishWorkflow

/// The begin helpers for the Import Center and sequence export launches
/// (finding R4). They live here, not beside their launch sites, so the
/// baselined AppDelegate+ImportCenter.swift does not grow
/// (scripts/ratchets/file-size.sh). Each helper registers its row through
/// `OperationReporting` and calls `launch` only when the row started, so a
/// test can check the row, its lock and its command without touching
/// `OperationCenter.shared`.
extension AppDelegate {
    // MARK: - Reference, application export and native bundle imports

    /// Registers the Reference Import row, which turns a standalone FASTA,
    /// GenBank or EMBL file into a `.lungfishref` bundle, and calls `launch`
    /// with the operation ID only when the row started. The row locks no
    /// bundle, as before.
    ///
    /// The row records `lungfish-cli import fasta <source> --output-dir
    /// <project>`, with `--name` added when the run has a preferred bundle
    /// name. `--output-dir` names the project, because the command appends the
    /// Reference Sequences folder itself, which is where the run writes. The
    /// run can also carry durable provenance input files, which no command
    /// option reproduces.
    @discardableResult
    static func beginReferenceImportOperation(
        sourceURL: URL,
        projectURL: URL,
        preferredBundleName: String?,
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        var arguments = ["fasta", sourceURL.path, "--output-dir", projectURL.path]
        if let name = preferredBundleName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            arguments += ["--name", name]
        }
        let result = reporter.begin(
            title: "Reference Import",
            detail: "Importing \(sourceURL.lastPathComponent)...",
            operationType: .bundleBuild,
            cliCommand: OperationCenter.buildCLICommand(subcommand: "import", args: arguments),
            routeContext: routeContext
        )
        switch result {
        case .started(let operationID):
            launch(operationID)
        case .refused:
            break // The panel already shows the refused row. Nothing was launched.
        }
        return result
    }

    /// Registers the Geneious Import row and calls `launch` with the operation
    /// ID only when the row started. `arguments` is the argv the runner
    /// executes (`CLIApplicationExportImportRunner.buildGeneiousArguments`),
    /// so the row records the `lungfish-cli import geneious` command the run
    /// is. The row locks no bundle and registers `onCancel` when it starts.
    @discardableResult
    static func beginGeneiousImportOperation(
        sourceURL: URL,
        arguments: [String],
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        onCancel: @escaping @Sendable () -> Void,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: "Geneious Import",
            detail: "Importing \(sourceURL.lastPathComponent)...",
            operationType: .applicationExportImport,
            cliCommand: OperationCenter.buildCLICommand(
                subcommand: "import",
                args: Array(arguments.dropFirst())
            ),
            routeContext: routeContext,
            onCancel: onCancel
        )
        switch result {
        case .started(let operationID):
            launch(operationID)
        case .refused:
            break // The panel already shows the refused row. Nothing was launched.
        }
        return result
    }

    /// Registers the application export import row (CLC Workbench, Benchling
    /// and the other kinds) and calls `launch` with the operation ID only when
    /// the row started. `arguments` is the argv the runner executes
    /// (`CLIApplicationExportImportRunner.buildApplicationExportArguments`),
    /// so the row records the `lungfish-cli import application-export`
    /// command the run is. The row locks no bundle and registers `onCancel`
    /// when it starts.
    @discardableResult
    static func beginApplicationExportImportOperation(
        kind: ApplicationExportKind,
        sourceURL: URL,
        arguments: [String],
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        onCancel: @escaping @Sendable () -> Void,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: "\(kind.displayName) Import",
            detail: "Importing \(sourceURL.lastPathComponent)...",
            operationType: .applicationExportImport,
            cliCommand: OperationCenter.buildCLICommand(
                subcommand: "import",
                args: Array(arguments.dropFirst())
            ),
            routeContext: routeContext,
            onCancel: onCancel
        )
        switch result {
        case .started(let operationID):
            launch(operationID)
        case .refused:
            break // The panel already shows the refused row. Nothing was launched.
        }
        return result
    }

    /// Registers the MSA or tree import row and calls `launch` with the
    /// operation ID only when the row started. `arguments` is the argv the
    /// runner executes (`CLINativeBundleImportRunner.buildArguments`), so the
    /// row records the `lungfish-cli import msa` or `import tree` command the
    /// run is. The row locks no bundle and registers `onCancel` when it starts.
    @discardableResult
    static func beginNativeBundleImportOperation(
        kind: CLINativeBundleImportRunner.BundleKind,
        sourceURL: URL,
        arguments: [String],
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        onCancel: @escaping @Sendable () -> Void,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let operationType: OperationType = kind == .msa
            ? .multipleSequenceAlignmentImport
            : .phylogeneticTreeImport
        let result = reporter.begin(
            title: kind.operationTitle,
            detail: "Importing \(sourceURL.lastPathComponent)...",
            operationType: operationType,
            cliCommand: OperationCenter.buildCLICommand(
                subcommand: "import",
                args: Array(arguments.dropFirst())
            ),
            routeContext: routeContext,
            onCancel: onCancel
        )
        switch result {
        case .started(let operationID):
            launch(operationID)
        case .refused:
            break // The panel already shows the refused row. Nothing was launched.
        }
        return result
    }

    // MARK: - Classifier result imports

    /// Registers the classifier result import row (Kraken2, EsViritu,
    /// TaxTriage and NAO-MGS) and calls `launch` with the operation ID only
    /// when the row started. The row locks no bundle and carries the
    /// Classification type, which replaces the Download label it showed
    /// while the call passed no type.
    ///
    /// The recorded command comes from
    /// `MetagenomicsImportHelper.canonicalProvenanceCommand`, the argv the
    /// import helper writes into the result's provenance, so the row and the
    /// provenance replay command agree. NAO-MGS records `--no-fetch-references`
    /// only when references are not fetched, because the command-line option
    /// is a flag that defaults to fetching.
    @discardableResult
    static func beginClassifierResultImportOperation(
        kind: MetagenomicsImportKind,
        operationTitle: String,
        inputURL: URL,
        outputDirectory: URL,
        preferredName: String?,
        naoMgsOptions: MetagenomicsImportHelperClient.NaoMgsOptions?,
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let trimmedName = preferredName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let argv = MetagenomicsImportHelper.canonicalProvenanceCommand(
            kind: kind,
            inputURL: inputURL,
            outputDirectory: outputDirectory,
            secondaryInputURL: nil,
            preferredName: trimmedName?.isEmpty == true ? nil : trimmedName,
            fetchReferences: naoMgsOptions?.fetchReferences ?? true
        )
        let result = reporter.begin(
            title: operationTitle,
            detail: "Importing \(inputURL.lastPathComponent)...",
            operationType: .classification,
            cliCommand: OperationCenter.buildCLICommand(
                subcommand: "import",
                args: Array(argv.dropFirst(2))
            ),
            routeContext: routeContext
        )
        switch result {
        case .started(let operationID):
            launch(operationID)
        case .refused:
            break // The panel already shows the refused row. Nothing was launched.
        }
        return result
    }

    // MARK: - Alignment and variant imports into a bundle

    /// Registers the VCF import row and calls `launch` with the operation ID
    /// only when the row started. The row locks `bundleURL` and registers
    /// `onCancel` when it starts.
    ///
    /// The run launches this app executable in `--vcf-import-helper` mode,
    /// which is not a `lungfish-cli` flag. The row records the runnable
    /// equivalent, `lungfish-cli import vcf`, as `VCFImportCLICommand` builds
    /// it, with `--replace` when the user confirmed a replacement. It attaches
    /// through the same `VCFBundleVariantImport` core as the run.
    @discardableResult
    static func beginVCFImportOperation(
        vcfURL: URL,
        bundleURL: URL,
        importProfile: VCFImportProfile,
        replaceTrackID: String?,
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        onCancel: @escaping @Sendable () -> Void,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: "Importing \(vcfURL.lastPathComponent)",
            detail: "Importing VCF variants (\(Self.importProfileLabel(importProfile)))...",
            operationType: .vcfImport,
            targetBundleURL: bundleURL,
            cliCommand: VCFImportCLICommand.build(
                vcfURL: vcfURL,
                bundleURL: bundleURL,
                importProfile: importProfile,
                replaceTrackID: replaceTrackID
            ),
            routeContext: routeContext,
            onCancel: onCancel
        )
        switch result {
        case .started(let operationID):
            launch(operationID)
        case .refused:
            break // The panel already shows the refused row. Nothing was launched.
        }
        return result
    }

    /// Registers the BAM import row and calls `launch` with the operation ID
    /// only when the row started. The row locks `bundleURL` and registers
    /// `onCancel` when it starts.
    ///
    /// The run launches this app executable in `--bam-import-helper` mode,
    /// which is not a `lungfish-cli` flag. The row records the runnable
    /// equivalent, `lungfish-cli import bam`, as `BAMImportCLICommand` builds
    /// it. It attaches through the same primitive as the run.
    @discardableResult
    static func beginBAMImportOperation(
        bamURL: URL,
        bundleURL: URL,
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        onCancel: @escaping @Sendable () -> Void,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: "Importing \(bamURL.lastPathComponent)",
            detail: "Importing alignments...",
            operationType: .bamImport,
            targetBundleURL: bundleURL,
            cliCommand: BAMImportCLICommand.build(bamURL: bamURL, bundleURL: bundleURL),
            routeContext: routeContext,
            onCancel: onCancel
        )
        switch result {
        case .started(let operationID):
            launch(operationID)
        case .refused:
            break // The panel already shows the refused row. Nothing was launched.
        }
        return result
    }

    // MARK: - Sequence exports

    /// Registers the sequence export row for one chosen output file and calls
    /// `launch` with the operation ID only when the row started. The row
    /// locks no bundle.
    ///
    /// The row records `lungfish-cli convert` through
    /// `sequenceExportCLICommand`, which adds `--include-annotations` for a
    /// GenBank export because the run writes the source's annotations.
    ///
    /// CLI parity gap. That command exists only for a single file input
    /// without compression. `inputURL` is nil when the export has several
    /// sources or its source is a captured document snapshot rather than a
    /// file, and the command is nil whenever compression is chosen, because
    /// `convert` writes no compressed output. The row then records no command
    /// until a command covers those exports.
    @discardableResult
    static func beginSequenceExportOperation(
        outputURL: URL,
        inputURL: URL?,
        format: SequenceExportFormat,
        compression: SequenceExportCompression,
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: "Exporting \(outputURL.lastPathComponent)",
            detail: "Preparing sequence export...",
            operationType: .export,
            cliCommand: Self.sequenceExportCLICommand(
                inputURL: inputURL,
                outputURL: outputURL,
                format: format,
                compression: compression
            ),
            routeContext: routeContext
        )
        switch result {
        case .started(let operationID):
            launch(operationID)
        case .refused:
            break // The panel already shows the refused row. Nothing was launched.
        }
        return result
    }

    /// Registers the batch sequence export row, one output file per selected
    /// reference bundle, and calls `launch` with the operation ID only when
    /// the row started. The row locks no bundle.
    ///
    /// CLI parity gap. One `lungfish-cli convert` command exports one bundle,
    /// and no command covers the batch. The row records the first command
    /// followed by a `#` note that counts the rest, and records no command
    /// when compression is chosen. Pasted into a terminal, the row exports
    /// the first file only.
    @discardableResult
    static func beginBatchSequenceExportOperation(
        bundleURLs: [URL],
        outputFolder: URL,
        format: SequenceExportFormat,
        compression: SequenceExportCompression,
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let cliCommands = Self.batchSequenceExportCLICommands(
            for: bundleURLs,
            outputFolder: outputFolder,
            format: format,
            compression: compression
        )
        let result = reporter.begin(
            title: "Exporting \(bundleURLs.count) sequence files",
            detail: "Preparing batch export...",
            operationType: .export,
            cliCommand: cliCommands.first.map { firstCommand in
                guard cliCommands.count > 1 else { return firstCommand }
                return "\(firstCommand)\n# ... \(cliCommands.count - 1) more export command(s)"
            },
            routeContext: routeContext
        )
        switch result {
        case .started(let operationID):
            launch(operationID)
        case .refused:
            break // The panel already shows the refused row. Nothing was launched.
        }
        return result
    }
}
