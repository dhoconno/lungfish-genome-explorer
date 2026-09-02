import Foundation
import LungfishKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import UniformTypeIdentifiers

/// Container format for a genotype viewport export, mirroring the CLI's
/// `genotype export --export-format` values.
enum GenotypeViewportExportFormat: String, CaseIterable, Identifiable, Sendable {
    case csv
    case tsv
    case excel
    /// Samples-across / alleles-down pivot, in the collaborator template
    /// layout. Unlike the other formats this routes to
    /// `genotype export-pivot-xlsx` and carries the viewport's Min Reads and
    /// Min Percent thresholds, so the exported pivot already has background
    /// suppressed rather than needing it stripped by hand in Excel.
    case pivotExcel

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .csv: return "CSV"
        case .tsv: return "TSV"
        case .excel: return "Excel"
        case .pivotExcel: return "Excel (pivot)"
        }
    }

    var fileExtension: String {
        switch self {
        case .csv: return "csv"
        case .tsv: return "tsv"
        case .excel, .pivotExcel: return "xlsx"
        }
    }

    /// Value passed to `genotype export --export-format`.
    ///
    /// `pivotExcel` uses its own subcommand, so it has no `--export-format`
    /// value of its own; it reports `xlsx` for provenance readability.
    var cliValue: String {
        switch self {
        case .csv: return "csv"
        case .tsv: return "tsv"
        case .excel, .pivotExcel: return "xlsx"
        }
    }

    /// Whether the format is produced by `genotype export-pivot-xlsx` rather
    /// than the projection-driven `genotype export`.
    var usesPivotSubcommand: Bool { self == .pivotExcel }

    /// `workflowName` recorded in the export's provenance envelope.
    var provenanceWorkflowName: String {
        usesPivotSubcommand ? "genotype.export.pivot-xlsx" : "lungfish genotype export"
    }

    /// `toolName` recorded in the export's provenance envelope.
    var provenanceToolName: String {
        usesPivotSubcommand
            ? "lungfish genotype export-pivot-xlsx"
            : CLICommandIdentity.executableName
    }

    var contentType: UTType {
        switch self {
        case .csv:
            return .commaSeparatedText
        case .tsv:
            return UTType(filenameExtension: "tsv") ?? .plainText
        case .excel, .pivotExcel:
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
/// durable sidecar beside the export, and handed to the canonical CLI exporter.
/// This export deliberately reuses CLI-authored provenance (`toolName ==
/// "lungfish-cli"`) because the output must be replayable from the recorded
/// argv.
/// Uses the same CLI-backed export pattern as the 12S amplicon export path.
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

        // Serialize exactly what the viewport rendered, then keep the JSON
        // beside the export so the provenance argv can be replayed later.
        let projection = GenotypeViewProjectionSerializer.makeProjection(from: snapshot)
        let projectionURL = standardizedOutputURL.appendingPathExtension("view-projection.json")
        let projectionData = try JSONEncoder().encode(projection)

        var arguments: [String]
        if format.usesPivotSubcommand {
            // The pivot builder reads the bundle directly rather than the
            // rendered projection, so the viewport's thresholds are passed
            // explicitly and applied while the workbook is built.
            arguments = [
                "genotype", "export-pivot-xlsx",
                "--bundle", snapshot.bundleURL.path,
                "--output", standardizedOutputURL.path,
            ]
            if let minReads = minimumReads(from: snapshot.filters) {
                arguments += ["--min-reads", String(minReads)]
            }
            if let minPercent = minimumPercent(from: snapshot.filters) {
                arguments += ["--min-percent", String(minPercent)]
            }
        } else {
            arguments = [
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
        }

        let rollbackSnapshot = try GenotypeViewportExportRollbackSnapshot(
            urls: [standardizedOutputURL, provenanceURL, projectionURL],
            fileManager: fileManager
        )
        do {
            try projectionData.write(to: projectionURL, options: .atomic)
            _ = try runner.run(arguments: arguments)
            guard fileManager.fileExists(atPath: standardizedOutputURL.path) else {
                throw GenotypeViewportExportError.missingOutput(standardizedOutputURL.path)
            }
            guard fileManager.fileExists(atPath: provenanceURL.path) else {
                throw GenotypeViewportExportError.missingProvenance(provenanceURL.path)
            }
            // The pivot subcommand builds from the bundle, not the rendered
            // projection, so only the projection-driven export attests it.
            let expectedInputURLs = format.usesPivotSubcommand
                ? []
                : [projectionURL] + (snapshot.annotationSidecarURL.map { [$0] } ?? [])
            try verifyProvenance(
                provenanceURL: provenanceURL,
                outputURL: standardizedOutputURL,
                expectedWorkflowName: format.provenanceWorkflowName,
                expectedToolName: format.provenanceToolName,
                expectedInputURLs: expectedInputURLs
            )
            rollbackSnapshot.discard()
            return GenotypeViewportExportResult(
                outputURL: standardizedOutputURL,
                provenanceURL: provenanceURL
            )
        } catch {
            do {
                try rollbackSnapshot.restore()
            } catch let rollbackError {
                throw GenotypeViewportExportError.rollbackFailed(
                    original: String(describing: error),
                    rollback: String(describing: rollbackError)
                )
            }
            throw error
        }
    }

    private func verifyProvenance(
        provenanceURL: URL,
        outputURL: URL,
        expectedWorkflowName: String = "lungfish genotype export",
        expectedToolName: String = CLICommandIdentity.executableName,
        expectedInputURLs: [URL] = []
    ) throws {
        guard let envelope = try ProvenanceEnvelopeReader.load(fromSidecar: provenanceURL),
              envelope.toolName == expectedToolName,
              envelope.workflowName == expectedWorkflowName,
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
                guard fileManager.fileExists(atPath: expectedInputURL.path),
                      inputPaths.contains(expectedInputURL.standardizedFileURL.path) else {
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
        for key in ["matrixMinimumReads", "minimumSupportReads", "minimumReads", "minReads"] {
            if let raw = filters[key], let value = Int(raw), value > 0 {
                return value
            }
        }
        return nil
    }

    /// The viewport's Min Percent control, when the analyst set one.
    private func minimumPercent(from filters: [String: String]) -> Double? {
        // `matrixMinimumPercent` is the comparison matrix's own Min Percent
        // control and takes precedence over the row-level support percent.
        for key in ["matrixMinimumPercent", "minimumSupportPercent", "minimumPercent", "minPercent"] {
            if let raw = filters[key], let value = Double(raw), value > 0 {
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
                stableClusterID: row.stableClusterID,
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

/// Keeps a byte-for-byte rollback copy of every durable file in a viewport
/// export generation. The CLI is allowed to atomically replace individual
/// files; if the runner or the cross-file provenance verification fails, this
/// restores the prior output/provenance/projection trio instead of deleting it.
private final class GenotypeViewportExportRollbackSnapshot {
    private struct Entry {
        let destinationURL: URL
        let backupURL: URL?
    }

    private let fileManager: FileManager
    private let backupDirectoryURL: URL
    private var entries: [Entry] = []
    private var isFinished = false

    init(urls: [URL], fileManager: FileManager) throws {
        self.fileManager = fileManager
        backupDirectoryURL = urls[0].deletingLastPathComponent().appendingPathComponent(
            ".lungfish-genotype-export-rollback-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(
                at: backupDirectoryURL,
                withIntermediateDirectories: false
            )
            for (index, url) in urls.enumerated() {
                let backupURL: URL?
                if fileManager.fileExists(atPath: url.path) {
                    let candidate = backupDirectoryURL.appendingPathComponent(String(index))
                    try fileManager.copyItem(at: url, to: candidate)
                    backupURL = candidate
                } else {
                    backupURL = nil
                }
                entries.append(Entry(destinationURL: url, backupURL: backupURL))
            }
        } catch {
            try? fileManager.removeItem(at: backupDirectoryURL)
            throw error
        }
    }

    func restore() throws {
        guard !isFinished else { return }
        var failures: [String] = []
        for entry in entries {
            do {
                if let backupURL = entry.backupURL {
                    if fileManager.fileExists(atPath: entry.destinationURL.path) {
                        _ = try fileManager.replaceItemAt(
                            entry.destinationURL,
                            withItemAt: backupURL
                        )
                    } else {
                        try fileManager.moveItem(
                            at: backupURL,
                            to: entry.destinationURL
                        )
                    }
                } else if fileManager.fileExists(atPath: entry.destinationURL.path) {
                    try fileManager.removeItem(at: entry.destinationURL)
                }
            } catch {
                failures.append("\(entry.destinationURL.path): \(error)")
            }
        }
        isFinished = true
        try? fileManager.removeItem(at: backupDirectoryURL)
        if !failures.isEmpty {
            throw NSError(
                domain: "GenotypeViewportExportRollbackSnapshot",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Failed to restore viewport export generation: \(failures.joined(separator: "; "))"
                ]
            )
        }
    }

    func discard() {
        guard !isFinished else { return }
        isFinished = true
        try? fileManager.removeItem(at: backupDirectoryURL)
    }

    deinit {
        discard()
    }
}

enum GenotypeViewportExportError: Error, LocalizedError, Equatable {
    case missingOutput(String)
    case missingProvenance(String)
    case invalidProvenance(String)
    case rollbackFailed(original: String, rollback: String)

    var errorDescription: String? {
        switch self {
        case .missingOutput(let path):
            return "The genotype export did not create the expected output file at \(path)."
        case .missingProvenance(let path):
            return "The genotype export did not create required provenance at \(path)."
        case .invalidProvenance(let path):
            return "The genotype export provenance is missing required lungfish-cli execution metadata at \(path)."
        case .rollbackFailed(let original, let rollback):
            return "The genotype export failed (\(original)) and its prior files could not be restored (\(rollback))."
        }
    }
}
