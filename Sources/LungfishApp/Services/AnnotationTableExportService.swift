import Foundation
import LungfishWorkflow

enum AnnotationTableExportService {
    static func export(
        snapshot: AnnotationTableExportSnapshot,
        format: ScientificTableFormat,
        outputURL: URL,
        startedAt: Date = Date(),
        shouldCancel: @Sendable () -> Bool
    ) throws {
        if shouldCancel() { throw ScientificTableWriterError.cancelled }
        guard !snapshot.sourceURLs.isEmpty else {
            throw AnnotationTableExportServiceError.noScientificSources
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let retained = try RetainedSelectionExportSnapshot(
            outputURL: outputURL,
            selectionMetadata: encoder.encode(snapshot)
        )
        do {
            let writerReport = try ScientificTableWriter.writeWithReport(
                snapshot.table,
                format: format,
                to: retained.payloadURL,
                shouldCancel: shouldCancel
            )
            if shouldCancel() { throw ScientificTableWriterError.cancelled }

            let columnIDs = snapshot.table.columns.map { ParameterValue.string($0.id) }
            let columnTitles = snapshot.table.columns.map { ParameterValue.string($0.title) }
            let rowIdentities = snapshot.rowIdentities.map(ParameterValue.string)
            let sourcePaths = snapshot.sourceURLs.map(ParameterValue.file)
            let query = snapshot.queryDescription.keys.sorted().map { key in
                ParameterValue.string("\(key)=\(snapshot.queryDescription[key] ?? "")")
            }
            let coordinates = snapshot.coordinateConventions.keys.sorted().map { key in
                ParameterValue.string("\(key)=\(snapshot.coordinateConventions[key] ?? "")")
            }
            var argv = [
                "Lungfish.app", "export-annotation-table",
                "--tab", snapshot.tab,
                "--scope", snapshot.scope.rawValue,
                "--format", format.rawValue,
                "--output", outputURL.path,
            ]
            for sourceURL in snapshot.sourceURLs {
                argv.append(contentsOf: ["--source", sourceURL.path])
            }
            try retained.publish(.init(
                workflowName: "lungfish app annotation table export",
                sourceURLs: snapshot.sourceURLs,
                outputURL: outputURL,
                outputFormat: provenanceFormat(format),
                argv: argv,
                explicitOptions: [
                    "sourcePaths": .array(sourcePaths),
                    "outputPath": .file(outputURL),
                    "outputFormat": .string(format.rawValue),
                    "scope": .string(snapshot.scope.rawValue),
                    "tab": .string(snapshot.tab),
                ],
                defaults: [
                    "encoding": .string("UTF-8"),
                    "headerRow": .boolean(true),
                    "formulaTextPolicy": .string(ScientificTableWriter.formulaTextPolicy),
                    "numericPolicy": .string(ScientificTableWriter.numericPolicy),
                    "missingValuePolicy": .string(ScientificTableWriter.missingValuePolicy),
                ],
                resolved: [
                    "rowCount": .integer(snapshot.table.rows.count),
                    "columnCount": .integer(snapshot.table.columns.count),
                    "columnIDs": .array(columnIDs),
                    "columnTitles": .array(columnTitles),
                    "rowIdentities": .array(rowIdentities),
                    "query": .array(query),
                    "coordinateConventions": .array(coordinates),
                    "xlsxArchiveTool": .string(writerReport.archiveToolPath ?? "not applicable"),
                    "xlsxArchiveArgv": .array((writerReport.archiveArgv ?? []).map(ParameterValue.string)),
                    "xlsxArchiveToolVersion": .string(writerReport.archiveToolVersion ?? "not applicable"),
                ],
                startedAt: startedAt
            ), preserveOriginalSources: true)
        } catch {
            retained.discardAfterFailure(error)
            throw error
        }
    }

    private static func provenanceFormat(_ format: ScientificTableFormat) -> FileFormat {
        switch format {
        case .json: return .json
        case .csv, .tsv: return .text
        case .xlsx: return .unknown
        }
    }
}

enum AnnotationTableExportServiceError: LocalizedError {
    case noScientificSources
    case missingScientificSource(URL)

    var errorDescription: String? {
        switch self {
        case .noScientificSources:
            return "Cannot export this scientific table because no durable source files are available for provenance."
        case .missingScientificSource(let url):
            return "Cannot export this scientific table because a required provenance source is missing: \(url.path)"
        }
    }
}
