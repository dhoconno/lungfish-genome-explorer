import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Exports the genotype bundle's matrix + annotation sidecar as a
/// standalone auditor-grade XLSX.
///
/// The workbook is intentionally lightweight (no embedded charts or
/// volatile formulas) so analysts can share a single self-describing
/// file. Sheets:
///
///   1. `Matrix` — sample × locus haplotype calls (H1/H2) colored using
///      the canonical Budde 2010 palette (M1-M7), matching what the
///      in-app inspector renders. ERR cells use the Lungfish danger
///      color. Empty/absent cells receive no fill.
///   2. `Legend` — palette swatches with display names so a reader who
///      has never opened the Lungfish app can decode the colors.
///   3. `Overrides` — the analyst-applied call overrides, if any.
///   4. `Audit Log` — the audit trail recorded in `annotations.json`.
///
/// This is provenance-`inspectOnly` (`cli.genotype` policy) — it never
/// modifies the bundle or its sidecar. The workbook itself is produced by
/// the shared ``GenotypeXlsxWorkbookWriter`` (also used by the unified
/// `genotype export` subcommand).
struct GenotypeExportXlsxSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export-xlsx",
        abstract: "Export the genotype bundle's matrix and analyst annotations as an XLSX file."
    )

    @Option(name: [.long, .customShort("b")], help: "Path to the .lungfishgenotype bundle.")
    var bundle: String?

    @Option(name: .long, help: "Durable scientific Excel snapshot JSON to replay through the shared export service.")
    var snapshot: String?

    @Option(name: .long, help: "Original captured provenance request JSON (required with --snapshot).")
    var provenanceRequest: String?

    @Option(name: .long, help: "Managed openpyxl Python executable (required with --snapshot).")
    var python: String?

    @Flag(name: .long, help: "Replace an existing snapshot export report and its receipt.")
    var force = false

    @Option(name: [.long, .customShort("o")], help: "Output XLSX path.")
    var output: String

    func validate() throws {
        guard (bundle != nil) != (snapshot != nil) else { throw ValidationError("Choose exactly one of --bundle or --snapshot.") }
        if snapshot != nil {
            guard provenanceRequest != nil, python != nil else { throw ValidationError("--snapshot requires --provenance-request and --python.") }
        } else if provenanceRequest != nil || python != nil || force {
            throw ValidationError("--provenance-request, --python and --force require --snapshot.")
        }
    }

    func run() async throws {
        if let snapshot {
            try await replaySnapshot(at: snapshot)
            return
        }
        guard let bundle else { throw ValidationError("--bundle is required.") }
        let startedAt = Date()
        let bundleURL = URL(fileURLWithPath: bundle)
        let sidecarURL = ONTGenotypeResultBundleData.annotationSidecarURL(forBundleAt: bundleURL)
        let sidecar = try ONTGenotypeResultBundleData
            .loadAnnotationSidecarIfPresent(forBundleAt: bundleURL)

        // Load the matrix when the bundle is complete; gracefully emit an
        // empty matrix when only the annotation sidecar is present (the
        // original CLI behavior). This keeps the command useful for
        // sharing the override log of a bundle without artifacts.
        let matrix: GenotypeXlsxWorkbookWriter.Matrix
        let loadedResult = try? ONTGenotypeResultBundle.loadResult(from: bundleURL)
        if let result = loadedResult {
            matrix = GenotypeXlsxWorkbookWriter.MatrixBuilder.build(from: result, sidecar: sidecar)
        } else {
            matrix = GenotypeXlsxWorkbookWriter.Matrix(loci: [], rows: [])
        }

        let overrides = sidecar.callOverrides.map { o in
            GenotypeXlsxWorkbookWriter.OverrideRow(
                sample: o.sample, locus: o.locus, slot: o.slot.rawValue,
                originalCall: o.originalCall, overrideCall: o.overrideCall,
                reason: o.reasonTag.rawValue, rationale: o.rationale,
                author: o.author, timestamp: o.timestamp
            )
        }
        let audit = sidecar.auditLog.map { e in
            GenotypeXlsxWorkbookWriter.AuditRow(
                action: e.action, sample: e.sample,
                locus: e.locus ?? "", slot: e.slot?.rawValue ?? "",
                before: e.before ?? "", after: e.after ?? "",
                author: e.author, timestamp: e.timestamp
            )
        }

        let outputURL = URL(fileURLWithPath: output)
        try GenotypeXlsxWorkbookWriter().writeMatrix(
            to: outputURL,
            matrix: matrix,
            overrides: overrides,
            audit: audit,
            annotations: sidecar
        )
        let annotationInputURLs = FileManager.default.fileExists(atPath: sidecarURL.path)
            ? [sidecarURL.standardizedFileURL]
            : []
        var optionPaths: [String: URL] = [
            "bundle": bundleURL,
            "output": outputURL,
        ]
        if let annotationInputURL = annotationInputURLs.first {
            optionPaths["annotations"] = annotationInputURL
        }
        let haplotypeDefinitionInputURLs = loadedResult.flatMap {
            GenotypeActiveHaplotypeAnalysisResolver.activeDefinitionFileURL(
                for: $0,
                bundleURL: bundleURL,
                sidecar: sidecar
            )
        }.map { [$0] } ?? []
        try await GenotypeExportProvenanceSupport.record(
            workflowName: "genotype.export.xlsx",
            toolName: "lungfish genotype export-xlsx",
            command: [
                CLICommandIdentity.executableName, "genotype", "export-xlsx",
                "--bundle", bundleURL.path,
                "--output", outputURL.path,
            ],
            bundleURL: bundleURL,
            outputURLs: [outputURL],
            outputDirectory: outputURL.deletingLastPathComponent(),
            optionPaths: optionPaths,
            additionalInputURLs: annotationInputURLs + haplotypeDefinitionInputURLs,
            startedAt: startedAt
        )

        let summary: [String: Any] = [
            "bundle": bundleURL.path,
            "output": outputURL.path,
            "sampleCount": matrix.sampleRowCount,
            "locusCount": matrix.loci.count,
            "overrideCount": overrides.count,
            "auditEntryCount": audit.count
        ]
        let summaryData = try JSONSerialization.data(
            withJSONObject: summary,
            options: [.prettyPrinted, .sortedKeys]
        )
        FileHandle.standardOutput.write(summaryData)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private func replaySnapshot(at path: String) async throws {
        guard let provenanceRequest, let python else { throw ValidationError("Snapshot replay requires its provenance request and Python executable.") }
        let snapshotURL = URL(fileURLWithPath: path).standardizedFileURL
        let requestURL = URL(fileURLWithPath: provenanceRequest).standardizedFileURL
        let outputURL = URL(fileURLWithPath: output).standardizedFileURL
        let pythonURL = URL(fileURLWithPath: python).standardizedFileURL
        let snapshotData = try Data(contentsOf: snapshotURL), requestData = try Data(contentsOf: requestURL)
        let decoded = try JSONDecoder().decode(GenotypeWorkbookPresentation.Snapshot.self, from: snapshotData)
        let original = try JSONDecoder().decode(GenotypeExcelExportService.ProvenanceRequest.self, from: requestData)
        let argv = CommandLine.arguments
        let request = GenotypeExcelExportService.ProvenanceRequest(workflowName: "genotype.export.excel.replay",
            toolVersion: LungfishAppVersion.short, argv: argv,
            options: ["snapshot": snapshotURL.path, "provenanceRequest": requestURL.path, "output": outputURL.path,
                "python": pythonURL.path, "force": String(force)], defaults: ["force": "false"],
            runtimeContext: ["originalWorkflowName": original.workflowName, "captureMode": "durable-scientific-snapshot"],
            inputs: [.init(path: snapshotURL.path, data: snapshotData), .init(path: requestURL.path, data: requestData)])
        let service = GenotypeExcelExportService(pythonExecutableURL: pythonURL, replayExecutableURL: Bundle.main.executableURL)
        let result = try await service.export(snapshot: decoded, outputURL: outputURL, provenance: request, replacingExisting: force)
        let summary = ["output": result.outputURL.path, "receipt": result.receiptURL.path, "snapshot": result.snapshotURL.path]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
