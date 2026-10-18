import Foundation
import LungfishCore
import LungfishOperations
import LungfishWorkflow

enum AnnotationTableExportService {
    static func export(
        snapshot: AnnotationTableExportSnapshot,
        format: ScientificTableFormat,
        outputURL: URL,
        runClock: ProvenanceRunClock = ProvenanceRunClock(),
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

            let sourcePaths = snapshot.sourceURLs.map(ParameterValue.file)
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
                outputFormat: AnnotationTableExportSnapshot.provenanceFormat(format),
                argv: argv,
                explicitOptions: [
                    "sourcePaths": .array(sourcePaths),
                    "outputPath": .file(outputURL),
                    "outputFormat": .string(format.rawValue),
                    "scope": .string(snapshot.scope.rawValue),
                    "tab": .string(snapshot.tab),
                ],
                defaults: AnnotationTableExportSnapshot.recordDefaults,
                resolved: snapshot.recordResolved(writerReport: writerReport),
                runClock: runClock
            ), preserveOriginalSources: true)
        } catch {
            retained.discardAfterFailure(error)
            throw error
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
