import Foundation
import LungfishKit
import LungfishIO
import LungfishWorkflow
import UniformTypeIdentifiers

public enum TwelveSAmpliconResultExportFormat: String, CaseIterable, Identifiable, Sendable {
    case csv
    case tsv
    case excel

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .csv: return "CSV"
        case .tsv: return "TSV"
        case .excel: return "Excel"
        }
    }

    public var fileExtension: String {
        switch self {
        case .csv: return "csv"
        case .tsv: return "tsv"
        case .excel: return "xlsx"
        }
    }

    public var cliValue: String {
        switch self {
        case .csv: return "csv"
        case .tsv: return "tsv"
        case .excel: return "xlsx"
        }
    }

    public var contentType: UTType {
        switch self {
        case .csv:
            return .commaSeparatedText
        case .tsv:
            return UTType(filenameExtension: "tsv") ?? .plainText
        case .excel:
            return UTType(filenameExtension: "xlsx") ?? .data
        }
    }
}

struct TwelveSAmpliconResultExportSnapshot: Equatable {
    let bundleURL: URL
    let analysisName: String
    let sampleNames: [String]
    let filters: TwelveSResultDisplayState
    let rows: [TwelveSScientificNameCountRow]
    let unresolvedRows: [TwelveSUnresolvedSequence]
}

struct TwelveSAmpliconResultExportResult: Equatable {
    let outputURL: URL
    let provenanceURL: URL
}

protocol TwelveSAmpliconResultExportRunning {
    func run(arguments: [String]) throws -> LungfishCLIRunner.Output
}

struct DefaultTwelveSAmpliconResultExportRunner: TwelveSAmpliconResultExportRunning {
    func run(arguments: [String]) throws -> LungfishCLIRunner.Output {
        try LungfishCLIRunner.run(arguments: arguments)
    }
}

struct TwelveSAmpliconResultExportService {
    private let runner: TwelveSAmpliconResultExportRunning
    private let fileManager: FileManager

    init(
        runner: TwelveSAmpliconResultExportRunning = DefaultTwelveSAmpliconResultExportRunner(),
        fileManager: FileManager = .default
    ) {
        self.runner = runner
        self.fileManager = fileManager
    }

    func export(
        snapshot: TwelveSAmpliconResultExportSnapshot,
        format: TwelveSAmpliconResultExportFormat,
        to outputURL: URL
    ) throws -> TwelveSAmpliconResultExportResult {
        try fileManager.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let standardizedOutputURL = outputURL.standardizedFileURL
        let provenanceURL = standardizedOutputURL.appendingPathExtension("lungfish-provenance.json")
        var arguments = [
            "fastq", "12s-export",
            "--bundle", snapshot.bundleURL.path,
            "--export-format", format.cliValue,
            "--output", standardizedOutputURL.path,
        ]
        if snapshot.filters.minimumExactReads > 0 {
            arguments += ["--min-exact-reads", String(snapshot.filters.minimumExactReads)]
        }
        let filterText = snapshot.filters.normalizedFilterText
        if !filterText.isEmpty {
            arguments += ["--filter", filterText]
        }
        for group in snapshot.filters.includedTaxonGroups.sorted() {
            arguments += ["--taxon-group", group]
        }
        for group in snapshot.filters.excludedTaxonGroups.sorted() {
            arguments += ["--exclude-taxon-group", group]
        }
        if snapshot.filters.excludeHuman {
            arguments.append("--exclude-human")
        }
        if snapshot.filters.requireAlternateMatches {
            arguments.append("--require-alternate-matches")
        }
        if snapshot.filters.minimumUnresolvedReads > 0 {
            arguments += ["--min-unresolved-reads", String(snapshot.filters.minimumUnresolvedReads)]
        }
        if snapshot.filters.chimeraFilter != .all {
            arguments += ["--chimera-status", snapshot.filters.chimeraFilter.rawValue]
        }
        arguments.append("--force")

        do {
            _ = try runner.run(arguments: arguments)
            guard fileManager.fileExists(atPath: standardizedOutputURL.path) else {
                throw TwelveSAmpliconResultExportError.missingOutput(standardizedOutputURL.path)
            }
            guard fileManager.fileExists(atPath: provenanceURL.path) else {
                throw TwelveSAmpliconResultExportError.missingProvenance(provenanceURL.path)
            }
            try verifyProvenance(
                provenanceURL: provenanceURL,
                outputURL: standardizedOutputURL
            )
            return TwelveSAmpliconResultExportResult(
                outputURL: standardizedOutputURL,
                provenanceURL: provenanceURL
            )
        } catch {
            try? fileManager.removeItem(at: standardizedOutputURL)
            try? fileManager.removeItem(at: provenanceURL)
            throw error
        }
    }

    private func verifyProvenance(provenanceURL: URL, outputURL: URL) throws {
        guard let envelope = try ProvenanceEnvelopeReader.load(fromSidecar: provenanceURL),
              envelope.toolName == "lungfish-cli",
              envelope.workflowName == "lungfish fastq 12s-export",
              envelope.exitStatus == 0,
              !envelope.argv.isEmpty else {
            throw TwelveSAmpliconResultExportError.invalidProvenance(provenanceURL.path)
        }
        let outputPath = outputURL.standardizedFileURL.path
        let outputPaths = Set(
            (envelope.outputs + envelope.steps.flatMap(\.outputs))
                .map { URL(fileURLWithPath: $0.path).standardizedFileURL.path }
        )
        guard outputPaths.contains(outputPath) else {
            throw TwelveSAmpliconResultExportError.invalidProvenance(provenanceURL.path)
        }
    }
}

enum TwelveSAmpliconResultExportError: Error, LocalizedError, Equatable {
    case missingOutput(String)
    case missingProvenance(String)
    case invalidProvenance(String)

    var errorDescription: String? {
        switch self {
        case .missingOutput(let path):
            return "The 12S export did not create the expected output file at \(path)."
        case .missingProvenance(let path):
            return "The 12S export did not create required provenance at \(path)."
        case .invalidProvenance(let path):
            return "The 12S export provenance is missing required CLI execution metadata at \(path)."
        }
    }
}
