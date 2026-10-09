import Foundation
import LungfishKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import UniformTypeIdentifiers

/// The one container format of the GUI genotype export. CSV and TSV belong to
/// `lungfish-cli genotype export`, which has owned them since 24fe49f05.
enum GenotypeViewportExportFormat: String, Sendable {
    case excel

    var fileExtension: String { "xlsx" }

    var contentType: UTType { UTType(filenameExtension: "xlsx") ?? .data }
}

struct GenotypeViewportExportResult: Equatable {
    let outputURL: URL
    let provenanceURL: URL
}

/// Publishes the frozen scientific XLSX capture through the shared export owner.
struct GenotypeViewportExportService {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// XLSX has one publication owner: the shared scientific export service.
    /// Its receipt and replay directory witness the retained native capture.
    func exportExcel(
        snapshot: GenotypeViewportExportSnapshot,
        to outputURL: URL,
        pythonExecutableURL: URL? = nil,
        replacingExisting: Bool = true
    ) async throws -> GenotypeViewportExportResult {
        guard let data = snapshot.excelSnapshotData else {
            throw GenotypeExcelSnapshotBuilder.CaptureError.incoherent("Excel requires a frozen native scientific capture")
        }
        let capture = try JSONDecoder().decode(GenotypeWorkbookPresentation.Snapshot.self, from: data)
        let python: URL
        if let pythonExecutableURL { python = pythonExecutableURL }
        else { python = try await CondaManager.shared.toolPath(name: "python", environment: "openpyxl") }
        guard let replayExecutable = LungfishCLIRunner.findCLI() else {
            throw LungfishCLIRunner.RunError.cliNotFound
        }
        let output = outputURL.standardizedFileURL
        let options = snapshot.filters.merging([
            "sourceBundle": snapshot.bundleURL.path,
            "analysis": snapshot.analysisName,
            "lens": snapshot.lens,
            "output": output.path,
            "captureAuthority": "retained native result, annotations, analysis, definition and viewport projections",
            "filteredEvidenceRowPolicy": GenotypeExcelSnapshotBuilder.filteredEvidenceRowPolicy,
            "replacingExisting": String(replacingExisting),
        ]) { _, resolved in resolved }
        let result = try await GenotypeExcelExportService(pythonExecutableURL: python, replayExecutableURL: replayExecutable).export(
            snapshot: capture, outputURL: output,
            provenance: .init(workflowName: "genotype.export.excel", toolVersion: LungfishAppVersion.short,
                argv: ["Lungfish", "genotype.export.excel", "--captured-at", capture.generatedAt, "--output", output.path],
                options: options, defaults: ["worksheets": "all and current filtered view", "format": "xlsx"],
                runtimeContext: ["entryPoint": "Inspector Export to Excel", "condaEnvironment": "openpyxl", "python": python.path]),
            replacingExisting: replacingExisting)
        // The shared owner has committed both files. Do not layer a GUI
        // restore over its receipt or overwrite a concurrent publication.
        guard fileManager.fileExists(atPath: result.outputURL.path),
              fileManager.fileExists(atPath: result.receiptURL.path) else {
            throw GenotypeViewportExportError.missingProvenance(result.receiptURL.path)
        }
        return .init(outputURL: result.outputURL, provenanceURL: result.receiptURL)
    }
}

/// Maps a rendered ``GenotypeViewportExportSnapshot`` into the
/// ``GenotypeViewProjection`` the Excel capture embeds as its
/// `all-projection.json` and `filtered-projection.json` inputs.
///
/// Guarantees the invariants the Excel builder relies on: every row's `cells`
/// (and `cellColorsHex`, when present) has exactly one entry per visible
/// sample column, and every color is a normalized `#RRGGBB` string. The
/// builder refuses a ragged row, so rows are padded here instead.
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
                let fill: AnnotationColor?
                if let rendered = row.renderedCellStyles?[sample] { fill = rendered.fillColor }
                else { fill = (row.cellStyles[sample] ?? row.rowStyle).fillColor }
                if let hex = normalizedHex(fill) {
                    cellColors.append(hex)
                    hasAnyCellColor = true
                } else {
                    cellColors.append(nil)
                }
            }
            return GenotypeViewProjectionRow(
                label: row.displayName,
                rawGenotype: row.genotype,
                locus: row.locus,
                stableClusterID: row.stableClusterID,
                cells: cells,
                cellColorsHex: hasAnyCellColor ? cellColors : nil,
                rowColorHex: row.renderedRowStyle.map { normalizedHex($0.fillColor) } ?? normalizedHex(row.rowStyle.fillColor),
                rowStyle: row.renderedRowStyle.map(presentationStyle),
                cellStyles: row.renderedCellStyles.map { styles in columns.map { styles[$0].map(presentationStyle) } },
                matrixColumnValues: row.matrixColumnValues
            )
        }
        return GenotypeViewProjection(
            lens: snapshot.lens,
            sampleColumns: columns,
            rows: rows,
            cellColorMode: snapshot.filters["cellColorMode"],
            genotypeLocusDisplayOrder: snapshot.filters["genotypeLocusDisplayOrder"].flatMap {
                $0.isEmpty ? nil : $0.split(separator: ",").map(String.init)
            },
            genotypeNumericPrefixOrder: snapshot.filters["genotypeNumericPrefixOrder"].flatMap { Bool($0) },
            diagnosticAllelesOnly: snapshot.filters["diagnosticAllelesOnly"].flatMap { Bool($0) },
            includeTotalReads: snapshot.filters["includeTotalReads"].flatMap { Bool($0) },
            matrixColumns: snapshot.matrixColumns,
            haplotypeCalls: snapshot.haplotypeCalls,
            haplotypeLocusScope: snapshot.haplotypeLocusScope,
            sourceRevision: snapshot.sourceRevision,
            filterContext: snapshot.filters,
            presentationColors: snapshot.presentationColors
        )
    }

    private static func presentationStyle(_ style: GenotypeMatrixRenderedStyle) -> GenotypeWorkbookPresentation.Style {
        .init(fillHex: normalizedHex(style.fillColor), textHex: normalizedHex(style.textColor), borderHex: normalizedHex(style.borderColor), isBold: style.isBold, isItalic: style.isItalic)
    }

    /// Spreadsheet backgrounds are white. Composite translucent screen colors
    /// onto white deliberately instead of silently dropping their alpha.
    /// ``AnnotationColor/hexString`` already renders this shape; this guards
    /// against any future drift so the workbook writer never falls back.
    static func normalizedHex(_ color: AnnotationColor?) -> String? {
        guard let color else { return nil }
        let alpha = min(1, max(0, color.alpha))
        let r = Int(((color.red * alpha + 1 - alpha) * 255).rounded())
        let g = Int(((color.green * alpha + 1 - alpha) * 255).rounded())
        let b = Int(((color.blue * alpha + 1 - alpha) * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

enum GenotypeViewportExportError: Error, LocalizedError, Equatable {
    case missingProvenance(String)

    var errorDescription: String? {
        switch self {
        case .missingProvenance(let path):
            return "The genotype export did not create required provenance at \(path)."
        }
    }
}
