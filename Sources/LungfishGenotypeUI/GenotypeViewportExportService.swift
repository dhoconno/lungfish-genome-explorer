import Foundation
import LungfishKit
import LungfishCore
import LungfishIO
import LungfishTwelveSUI
import LungfishWorkflow
import UniformTypeIdentifiers

/// Container format for a genotype viewport export, mirroring the CLI's
/// `genotype export --export-format` values.
enum GenotypeViewportExportFormat: String, CaseIterable, Identifiable, Sendable {
    case csv
    case tsv
    case excel

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .csv: return "CSV"
        case .tsv: return "TSV"
        case .excel: return "Excel"
        }
    }

    var fileExtension: String {
        switch self {
        case .csv: return "csv"
        case .tsv: return "tsv"
        case .excel: return "xlsx"
        }
    }

    /// Value passed to `genotype export --export-format`.
    var cliValue: String {
        switch self {
        case .csv: return "csv"
        case .tsv: return "tsv"
        case .excel: return "xlsx"
        }
    }

    var contentType: UTType {
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

struct GenotypeViewportExportResult: Equatable {
    let outputURL: URL
    let provenanceURL: URL
}

/// Seam over the `lungfish-cli` subprocess so tests can record the argv and the
/// view-projection JSON the GUI hands the CLI without launching a process.
protocol GenotypeViewportExportRunning {
    func run(arguments: [String]) throws -> LungfishCLIRunner.Output
}

struct DefaultGenotypeViewportExportRunner: GenotypeViewportExportRunning {
    func run(arguments: [String]) throws -> LungfishCLIRunner.Output {
        try LungfishCLIRunner.run(arguments: arguments)
    }
}

/// Exports the rendered genotype matrix view by shelling out to
/// `lungfish-cli genotype export --view-projection <json>`.
///
/// The viewport's colored matrix is serialized into a ``GenotypeViewProjection``
/// (the contract `LungfishIO` defines and the CLI deserializes), written to a
/// temporary JSON file, and handed to the canonical CLI exporter. This export
/// deliberately reuses CLI-authored provenance (`toolName == "lungfish-cli"`)
/// because the output must be replayable from the recorded argv.
/// Mirrors ``TwelveSAmpliconResultExportService``.
struct GenotypeViewportExportService {
    private let runner: GenotypeViewportExportRunning
    private let fileManager: FileManager

    init(
        runner: GenotypeViewportExportRunning = DefaultGenotypeViewportExportRunner(),
        fileManager: FileManager = .default
    ) {
        self.runner = runner
        self.fileManager = fileManager
    }

    func export(
        snapshot: GenotypeViewportExportSnapshot,
        format: GenotypeViewportExportFormat,
        to outputURL: URL
    ) throws -> GenotypeViewportExportResult {
        try fileManager.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let standardizedOutputURL = outputURL.standardizedFileURL
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: standardizedOutputURL)

        // Serialize exactly what the viewport rendered, then hand the JSON to
        // the CLI. The temp file is removed regardless of outcome.
        let projection = GenotypeViewProjectionSerializer.makeProjection(from: snapshot)
        let projectionURL = fileManager.temporaryDirectory
            .appendingPathComponent("genotype-view-projection-\(UUID().uuidString).json")
        let projectionData = try JSONEncoder().encode(projection)
        try projectionData.write(to: projectionURL)
        defer { try? fileManager.removeItem(at: projectionURL) }

        var arguments = [
            "genotype", "export",
            "--bundle", snapshot.bundleURL.path,
            "--export-format", format.cliValue,
            "--output", standardizedOutputURL.path,
            "--lens", snapshot.lens,
            "--view-projection", projectionURL.path,
        ]
        for sample in snapshot.sampleNames {
            arguments += ["--sample", sample]
        }
        if let minReads = minimumReads(from: snapshot.filters) {
            arguments += ["--min-reads", String(minReads)]
        }
        if let filterText = filterText(from: snapshot.filters) {
            arguments += ["--filter", filterText]
        }
        if let definitionID = snapshot.filters["activeHaplotypeDefinitionSetID"],
           !definitionID.isEmpty {
            arguments += ["--active-haplotype-definition", definitionID]
        }
        if let annotationSidecarURL = snapshot.annotationSidecarURL {
            arguments += ["--annotations", annotationSidecarURL.path]
        }
        arguments.append("--force")

        do {
            _ = try runner.run(arguments: arguments)
            guard fileManager.fileExists(atPath: standardizedOutputURL.path) else {
                throw GenotypeViewportExportError.missingOutput(standardizedOutputURL.path)
            }
            guard fileManager.fileExists(atPath: provenanceURL.path) else {
                throw GenotypeViewportExportError.missingProvenance(provenanceURL.path)
            }
            try verifyProvenance(
                provenanceURL: provenanceURL,
                outputURL: standardizedOutputURL,
                expectedInputURLs: snapshot.annotationSidecarURL.map { [$0] } ?? []
            )
            return GenotypeViewportExportResult(
                outputURL: standardizedOutputURL,
                provenanceURL: provenanceURL
            )
        } catch {
            try? fileManager.removeItem(at: standardizedOutputURL)
            try? fileManager.removeItem(at: provenanceURL)
            throw error
        }
    }

    private func verifyProvenance(
        provenanceURL: URL,
        outputURL: URL,
        expectedInputURLs: [URL] = []
    ) throws {
        guard let envelope = try ProvenanceEnvelopeReader.load(fromSidecar: provenanceURL),
              envelope.toolName == "lungfish-cli",
              envelope.workflowName == "lungfish genotype export",
              envelope.exitStatus == 0,
              !envelope.argv.isEmpty else {
            throw GenotypeViewportExportError.invalidProvenance(provenanceURL.path)
        }
        let outputPath = outputURL.standardizedFileURL.path
        let outputPaths = Set(
            (envelope.outputs + envelope.steps.flatMap(\.outputs))
                .map { URL(fileURLWithPath: $0.path).standardizedFileURL.path }
        )
        guard outputPaths.contains(outputPath) else {
            throw GenotypeViewportExportError.invalidProvenance(provenanceURL.path)
        }
        guard expectedInputURLs.isEmpty else {
            let inputPaths = Set(
                (envelope.files + envelope.steps.flatMap(\.inputs))
                    .map { URL(fileURLWithPath: $0.path).standardizedFileURL.path }
            )
            for expectedInputURL in expectedInputURLs {
                guard inputPaths.contains(expectedInputURL.standardizedFileURL.path) else {
                    throw GenotypeViewportExportError.invalidProvenance(provenanceURL.path)
                }
            }
            return
        }
    }

    /// The genotype viewport filters by support *percent*, not an absolute
    /// unique-read floor, so `--min-reads` is only emitted when the snapshot
    /// carries an explicit integer read count.
    private func minimumReads(from filters: [String: String]) -> Int? {
        for key in ["minimumSupportReads", "minimumReads", "minReads"] {
            if let raw = filters[key], let value = Int(raw), value > 0 {
                return value
            }
        }
        return nil
    }

    /// The free-text filter the analyst typed, recorded in provenance.
    private func filterText(from filters: [String: String]) -> String? {
        for key in ["searchText", "quickFilter", "quickFilterSearchText"] {
            if let raw = filters[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !raw.isEmpty {
                return raw
            }
        }
        return nil
    }
}

/// Maps a rendered ``GenotypeViewportExportSnapshot`` into the
/// ``GenotypeViewProjection`` contract the CLI consumes.
///
/// Guarantees the producer-side invariants the CLI relies on:
/// every row's `cells` (and `cellColorsHex`, when present) has exactly one
/// entry per visible sample column, and every color is a normalized `#RRGGBB`
/// string. Ragged rows would be silently truncated by the CLI's projection
/// filter, so they are padded here instead.
enum GenotypeViewProjectionSerializer {
    static func makeProjection(
        from snapshot: GenotypeViewportExportSnapshot
    ) -> GenotypeViewProjection {
        let columns = snapshot.sampleNames
        let rows = snapshot.rows.map { row -> GenotypeViewProjectionRow in
            var cells: [String] = []
            var cellColors: [String?] = []
            var hasAnyCellColor = false
            cells.reserveCapacity(columns.count)
            cellColors.reserveCapacity(columns.count)
            for sample in columns {
                if let reads = row.sampleReads[sample] {
                    cells.append(String(reads))
                } else {
                    cells.append("")
                }
                let style = row.cellStyles[sample] ?? row.rowStyle
                if let hex = normalizedHex(style.fillColor) {
                    cellColors.append(hex)
                    hasAnyCellColor = true
                } else {
                    cellColors.append(nil)
                }
            }
            return GenotypeViewProjectionRow(
                label: row.genotype,
                locus: row.locus,
                cells: cells,
                cellColorsHex: hasAnyCellColor ? cellColors : nil,
                rowColorHex: normalizedHex(row.rowStyle.fillColor)
            )
        }
        return GenotypeViewProjection(
            lens: snapshot.lens,
            sampleColumns: columns,
            rows: rows,
            cellColorMode: snapshot.filters["cellColorMode"]
        )
    }

    /// Returns a `#RRGGBB` string (exactly 6 hex chars) or `nil`.
    /// ``AnnotationColor/hexString`` already renders this shape; this guards
    /// against any future drift so the CLI writer never falls back.
    static func normalizedHex(_ color: AnnotationColor?) -> String? {
        guard let color else { return nil }
        let r = Int((color.red * 255).rounded())
        let g = Int((color.green * 255).rounded())
        let b = Int((color.blue * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

enum GenotypeViewportExportError: Error, LocalizedError, Equatable {
    case missingOutput(String)
    case missingProvenance(String)
    case invalidProvenance(String)

    var errorDescription: String? {
        switch self {
        case .missingOutput(let path):
            return "The genotype export did not create the expected output file at \(path)."
        case .missingProvenance(let path):
            return "The genotype export did not create required provenance at \(path)."
        case .invalidProvenance(let path):
            return "The genotype export provenance is missing required lungfish-cli execution metadata at \(path)."
        }
    }
}
