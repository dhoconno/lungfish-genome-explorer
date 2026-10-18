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

extension BookmarkedVariantExport {
    /// One bookmarked variant as the export writes it, from a database's `bookmarkedVariants()`.
    package struct Row: Sendable, Equatable {
        let name: String
        let type: String
        let chromosome: String
        let start: Int
        let ref: String?
        let alt: String?
        let quality: Double?
        let filter: String?

        package init(
            name: String,
            type: String,
            chromosome: String,
            start: Int,
            ref: String?,
            alt: String?,
            quality: Double?,
            filter: String?
        ) {
            self.name = name
            self.type = type
            self.chromosome = chromosome
            self.start = start
            self.ref = ref
            self.alt = alt
            self.quality = quality
            self.filter = filter
        }
    }

    /// The eight-column TSV of the rows in their order. `Pos` is the stored 0-based start plus one, a negative or
    /// missing quality prints `.` and so does a missing ref, alt or filter.
    package static func tsv(rows: [Row]) -> String {
        var lines = [["ID", "Type", "Chrom", "Pos", "Ref", "Alt", "Quality", "Filter"].joined(separator: "\t")]
        for row in rows {
            let quality = row.quality.map { $0 < 0 ? "." : String(format: "%.1f", $0) } ?? "."
            lines.append([row.name, row.type, row.chromosome, "\(row.start + 1)",
                row.ref ?? ".", row.alt ?? ".", quality, row.filter ?? "."].joined(separator: "\t"))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
