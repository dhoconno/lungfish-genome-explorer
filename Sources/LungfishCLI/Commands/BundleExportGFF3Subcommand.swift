// BundleExportGFF3Subcommand.swift - lungfish-cli bundle export-gff3
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Writes one source's annotations as GFF3 with its record beside it (Phase 2.12 lane 12.39, ARCH ruling on 12.39 R2).
///
/// Give a reference bundle, and the leaf reads its manifest and annotation databases and names those files as
/// inputs. Give `--selection`, and it reads the open document's annotations from the selection file the app wrote
/// and names that file only. The app's Export Annotations runs this leaf behind its Operations row.
struct BundleExportGFF3Subcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export-gff3",
        abstract: "Write one source's annotations as GFF3 with provenance"
    )

    @Argument(help: "The reference bundle whose annotations to write. Leave it out to pass --selection")
    var bundlePath: String?

    @Option(
        name: .customLong(ViewerExportOption.selection.rawValue),
        help: "The selection file the app wrote for an open document's annotations"
    )
    var selectionPath: String?

    @OptionGroup var output: ViewerExportOptions.Output
    @OptionGroup var globalOptions: GlobalOptions

    func validate() throws {
        if bundlePath != nil, selectionPath != nil {
            throw ValidationError("Give a bundle or --selection, not both.")
        }
        if bundlePath == nil, selectionPath == nil {
            throw ValidationError("Give a bundle or --selection.")
        }
    }

    /// The invocation this parse stands for, which the record's argv comes from.
    func invocation() -> AnnotationGFF3Export.Invocation {
        AnnotationGFF3Export.Invocation(
            bundle: bundlePath.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path },
            selection: selectionPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path },
            output: URL(fileURLWithPath: output.path).standardizedFileURL.path,
            force: output.force,
            emitsEvents: globalOptions.outputFormat == .json
        )
    }

    func run() async throws {
        let command = self
        try await ViewerExportLeaf.run(
            globalOptions: globalOptions,
            startMessage: "Exporting annotations as GFF3."
        ) { _ in
            try await command.export()
        }
    }

    /// The export, which refuses before it writes and writes payload and record in one transaction.
    func export() async throws -> ViewerExportLeafOutcome {
        let runClock = ProvenanceRunClock()
        let invocation = invocation()
        let outputURL = URL(fileURLWithPath: invocation.output)
        let source = try readSource(invocation, outputURL: outputURL)
        guard !source.annotations.isEmpty else {
            throw ViewerExportRefusal("\(source.name) has no annotations to export.")
        }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-export-gff3-\(UUID().uuidString).gff3")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try await GFF3Writer.write(source.annotations, to: scratch, source: AnnotationGFF3Export.featureSource)

        var explicitOptions: [String: ParameterValue] = ["outputPath": .file(outputURL)]
        if invocation.force {
            explicitOptions["force"] = .boolean(true)
        }
        try Task.checkCancellation()
        try ScientificFileExportProvenance.writeAtomically(.cliLeaf(
            workflowName: AnnotationGFF3Export.workflowName,
            sourceURLs: source.inputURLs,
            outputURL: outputURL,
            outputFormat: .gff3,
            argv: invocation.canonicalArgv(),
            explicitOptions: explicitOptions,
            defaults: ["outputFormat": .string("gff3"), "featureSource": .string(AnnotationGFF3Export.featureSource)],
            resolved: ["annotationCount": .integer(source.annotations.count)],
            runClock: runClock
        )) { stagedURL in
            try FileManager.default.copyItem(at: scratch, to: stagedURL)
            try ViewerExportLeaf.checkpointAfterStaging()
        }
        let noun = source.annotations.count == 1 ? "annotation" : "annotations"
        return ViewerExportLeafOutcome(
            outputURL: outputURL,
            message: "Exported \(source.annotations.count) \(noun) from \(source.name) to \(outputURL.lastPathComponent)"
        )
    }

    /// The annotations and the files read for them, after the output is checked against those files.
    private func readSource(
        _ invocation: AnnotationGFF3Export.Invocation,
        outputURL: URL
    ) throws -> (name: String, annotations: [SequenceAnnotation], inputURLs: [URL]) {
        if let bundle = invocation.bundle {
            let bundleURL = URL(fileURLWithPath: bundle, isDirectory: true)
            let inputURLs: [URL]
            do {
                inputURLs = try AnnotationGFF3Export.bundleInputURLs(bundleURL: bundleURL)
            } catch {
                throw ViewerExportRefusal(
                    "No bundle manifest can be read at \(bundleURL.appendingPathComponent("manifest.json").path). "
                        + "Pass a reference bundle (.lungfishref)."
                )
            }
            try ViewerExportLeaf.refuseUnsafeOutput(outputURL, inputs: inputURLs, force: invocation.force)
            let loaded = try AnnotationGFF3Export.loadBundleAnnotations(bundleURL: bundleURL)
            return (bundleURL.deletingPathExtension().lastPathComponent, loaded.annotations, loaded.inputURLs)
        }
        let selectionURL = URL(fileURLWithPath: invocation.selection ?? "")
        guard FileManager.default.fileExists(atPath: selectionURL.path) else {
            throw ViewerExportRefusal("No selection file at \(selectionURL.path). Pass the selection file the app wrote.")
        }
        try ViewerExportLeaf.refuseUnsafeOutput(outputURL, inputs: [selectionURL], force: invocation.force)
        let selection: ViewerExportSelection
        do {
            selection = try ViewerExportSelection.read(from: selectionURL)
        } catch {
            throw ViewerExportRefusal("The selection file at \(selectionURL.path) cannot be read. \(error.localizedDescription)")
        }
        guard let document = selection.documentAnnotations else {
            throw ViewerExportRefusal(
                "The selection file at \(selectionURL.path) holds no document annotations. Pass a bundle instead."
            )
        }
        return (document.sourceName, document.annotations, [selectionURL])
    }
}
