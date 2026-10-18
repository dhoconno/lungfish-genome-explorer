import Foundation
import LungfishCore
import LungfishWorkflow

package enum BookmarkedVariantExportService {
    package typealias Row = BookmarkedVariantExport.Row

    package struct Request: Sendable {
        let sourceURLs: [URL]
        let rows: [Row]
        let outputURL: URL

        package init(sourceURLs: [URL], rows: [Row], outputURL: URL) {
            self.sourceURLs = sourceURLs
            self.rows = rows
            self.outputURL = outputURL
        }
    }

    /// Writes the TSV and its record in one transaction. The record names the variant databases the rows were read
    /// from, each with its digest, and no copy of its own payload (lane 12.39, the side A fix that the settled
    /// answers of 12.31 call for, BIO rulings on 12.31 G3 and M4).
    package static func export(_ request: Request) throws {
        let runClock = ProvenanceRunClock()
        let content = BookmarkedVariantExport.tsv(rows: request.rows)
        var argv = ["Lungfish Genome Explorer", "export-bookmarked-variants"]
        for sourceURL in request.sourceURLs { argv += ["--variant-database", sourceURL.path] }
        argv += ["--output", request.outputURL.path]
        try ScientificFileExportProvenance.writeAtomically(.init(
            workflowName: "lungfish app bookmarked variant export", sourceURLs: request.sourceURLs,
            outputURL: request.outputURL, outputFormat: .text, argv: argv,
            explicitOptions: ["sourceVariantDatabasePaths": .array(request.sourceURLs.map { .file($0) }),
                "outputPath": .file(request.outputURL)],
            defaults: ["outputFormat": .string("tsv")],
            resolved: ["variantCount": .integer(request.rows.count)], runClock: runClock
        )) { stagedURL in
            try content.write(to: stagedURL, atomically: true, encoding: .utf8)
        }
    }
}
