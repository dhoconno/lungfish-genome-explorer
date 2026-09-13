import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Exports a bundle capture, or replays a durable capture, through the common
/// one-way genotype Excel service. It never copies or reads an XLSX workbook
/// from the source bundle.
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
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("--output must not be empty.")
        }
        guard (bundle != nil) != (snapshot != nil) else { throw ValidationError("Choose exactly one of --bundle or --snapshot.") }
        if let bundle,
           bundle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("--bundle must not be empty.")
        }
        if let snapshot,
           snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("--snapshot must not be empty.")
        }
        if snapshot != nil {
            guard provenanceRequest != nil, python != nil else { throw ValidationError("--snapshot requires --provenance-request and --python.") }
        } else if provenanceRequest != nil || python != nil {
            throw ValidationError("--provenance-request and --python require --snapshot.")
        }
    }

    func run() async throws {
        try await run(managedPythonResolver: {
            try await CondaManager.shared.toolPath(name: "python", environment: "openpyxl")
        })
    }

    func run(
        managedPythonResolver: @escaping @Sendable () async throws -> URL
    ) async throws {
        if let snapshot {
            try await replaySnapshot(at: snapshot)
            return
        }
        guard let bundle else { throw ValidationError("--bundle is required.") }
        let bundleURL = URL(fileURLWithPath: bundle, isDirectory: true).standardizedFileURL
        let outputURL = URL(fileURLWithPath: output).standardizedFileURL
        var argv = [CLICommandIdentity.executableName, "genotype", "export-xlsx",
                    "--bundle", bundleURL.path, "--output", outputURL.path]
        if force { argv.append("--force") }
        let outcome = try await GenotypeExcelCLIExportSupport.export(
            .init(
                bundleURL: bundleURL,
                outputURL: outputURL,
                annotationURL: nil,
                projectionURL: nil,
                samples: [],
                activeHaplotypeDefinitionID: nil,
                filter: .unfiltered,
                workflowName: "genotype.export.xlsx",
                argv: GenotypeExcelCLIExportSupport.invocation(fallback: argv),
                options: [
                    "bundle": bundleURL.path,
                    "output": outputURL.path,
                    "force": String(force),
                    "filter": "unfiltered",
                    "annotations": "bundle annotations.json when present",
                    "filteredEvidenceRowPolicy": GenotypeExcelSnapshotBuilder.filteredEvidenceRowPolicy,
                ],
                defaults: [
                    "force": "false",
                    "filter": "unfiltered",
                    "annotations": "bundle annotations.json when present",
                ],
                runtimeContext: [
                    "candidatePercentBasis": "positive supporting samples / full logical sample roster",
                    "knownPercentBasis": ONTGenotypeSupportDenominator.viewedLocus.rawValue,
                ],
                replacingExisting: force
            ),
            managedPythonResolver: managedPythonResolver
        )
        let summary: [String: Any] = [
            "bundle": bundleURL.path,
            "output": outcome.result.outputURL.path,
            "receipt": outcome.result.receiptURL.path,
            "snapshot": outcome.result.snapshotURL.path,
            "replay": outcome.result.replayScriptURL.path,
            "sampleColumns": outcome.visibleSamples,
            "hasHaplotypeContent": outcome.hasHaplotypeContent,
        ]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]))
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
