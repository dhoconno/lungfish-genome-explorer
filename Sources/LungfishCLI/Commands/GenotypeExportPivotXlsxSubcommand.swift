import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Exports the bundle as the reviewed one-way genotype Excel snapshot.
struct GenotypeExportPivotXlsxSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export-pivot-xlsx",
        abstract: "Export a one-way genotype XLSX report with All and Filtered matrices."
    )

    enum PercentBasis: String, CaseIterable, ExpressibleByArgument, Sendable {
        case viewedLocus = "viewed-locus"
        case sampleRetained = "sample-retained"

        var denominator: ONTGenotypeSupportDenominator {
            switch self {
            case .viewedLocus: return .viewedLocus
            case .sampleRetained: return .sampleRetained
            }
        }
    }

    @Option(name: [.long, .customShort("b")], help: "Path to the .lungfishgenotype bundle.")
    var bundle: String

    @Option(name: [.long, .customShort("o")], help: "Output XLSX path.")
    var output: String

    @Option(name: .long, help: "Minimum displayed unique-read support in the Filtered matrix; 0 disables the filter.")
    var minReads: Int = 0

    @Option(name: .long, help: "Minimum displayed support percent in the Filtered matrix; 0 disables the filter.")
    var minPercent: Double = 0

    @Option(name: .long, help: "Known-call denominator for --min-percent: viewed-locus or sample-retained.")
    var percentBasis: PercentBasis = .sampleRetained

    @Option(name: .long, help: "Captured genotype viewport defining the Filtered matrix's visible rows and samples.")
    var viewProjection: String?

    @Option(name: .long, help: "Genotype annotation sidecar; defaults to bundle annotations.json when present.")
    var annotations: String?

    @Flag(name: .long, help: "Overwrite an existing report and receipt.")
    var force = false

    func validate() throws {
        guard !bundle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("--bundle must not be empty.")
        }
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("--output must not be empty.")
        }
        guard minReads >= 0 else {
            throw ValidationError("--min-reads must not be negative.")
        }
        guard minPercent >= 0, minPercent <= 100 else {
            throw ValidationError("--min-percent must be between 0 and 100.")
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
        let bundleURL = URL(fileURLWithPath: bundle, isDirectory: true).standardizedFileURL
        let outputURL = URL(fileURLWithPath: output).standardizedFileURL
        let projectionURL = viewProjection.map { URL(fileURLWithPath: $0).standardizedFileURL }
        let annotationURL = annotations.map { URL(fileURLWithPath: $0).standardizedFileURL }
        let filter = GenotypeMatrixBaseProjection.Filter(
            matrixMinimumReads: minReads,
            matrixMinimumPercent: minPercent,
            matrixDenominator: percentBasis.denominator
        )
        var argv = [CLICommandIdentity.executableName, "genotype", "export-pivot-xlsx",
                    "--bundle", bundleURL.path, "--output", outputURL.path]
        if minReads != 0 { argv += ["--min-reads", String(minReads)] }
        if minPercent != 0 {
            argv += ["--min-percent", String(minPercent), "--percent-basis", percentBasis.rawValue]
        }
        if let projectionURL { argv += ["--view-projection", projectionURL.path] }
        if let annotationURL { argv += ["--annotations", annotationURL.path] }
        if force { argv.append("--force") }

        let outcome = try await GenotypeExcelCLIExportSupport.export(
            .init(
                bundleURL: bundleURL,
                outputURL: outputURL,
                annotationURL: annotationURL,
                projectionURL: projectionURL,
                samples: [],
                activeHaplotypeDefinitionID: nil,
                filter: filter,
                workflowName: "genotype.export.pivot-xlsx",
                argv: GenotypeExcelCLIExportSupport.invocation(fallback: argv),
                options: [
                    "bundle": bundleURL.path,
                    "output": outputURL.path,
                    "minReads": String(minReads),
                    "minPercent": String(minPercent),
                    "percentBasis": percentBasis.rawValue,
                    "viewProjection": projectionURL?.path ?? "none",
                    "annotations": annotationURL?.path ?? "bundle annotations.json when present",
                    "force": String(force),
                    "filteredEvidenceRowPolicy": GenotypeExcelSnapshotBuilder.filteredEvidenceRowPolicy,
                ],
                defaults: [
                    "minReads": "0",
                    "minPercent": "0",
                    "percentBasis": PercentBasis.sampleRetained.rawValue,
                    "viewProjection": "none",
                    "annotations": "bundle annotations.json when present",
                    "force": "false",
                ],
                runtimeContext: [
                    "candidatePercentBasis": "positive supporting samples / full logical sample roster",
                    "knownPercentBasis": percentBasis.denominator.rawValue,
                ],
                replacingExisting: force
            ),
            managedPythonResolver: managedPythonResolver
        )
        emitSummary(outcome)
    }

    private func emitSummary(_ outcome: GenotypeExcelCLIExportSupport.Outcome) {
        let object: [String: Any] = [
            "bundle": bundle,
            "output": outcome.result.outputURL.path,
            "receipt": outcome.result.receiptURL.path,
            "snapshot": outcome.result.snapshotURL.path,
            "replay": outcome.result.replayScriptURL.path,
            "sampleColumns": outcome.visibleSamples,
            "hasHaplotypeContent": outcome.hasHaplotypeContent,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
