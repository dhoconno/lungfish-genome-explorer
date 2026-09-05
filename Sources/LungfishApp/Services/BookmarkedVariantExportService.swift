import Foundation
import LungfishWorkflow

enum BookmarkedVariantExportService {
    struct Row: Codable, Sendable {
        let trackID: String
        let rowID: Int64?
        let name: String
        let type: String
        let chromosome: String
        let start: Int
        let ref: String?
        let alt: String?
        let quality: Double?
        let filter: String?
    }

    struct Request: Sendable {
        let sourceURLs: [URL]
        let rows: [Row]
        let outputURL: URL
    }

    private struct Selection: Encodable {
        let replayScope = RetainedSelectionExportSnapshot.replayScope
        let sourceDatabaseURLs: [URL]
        let selectedRows: [Row]
    }

    static func export(_ request: Request) throws {
        let startedAt = Date()
        var lines = [["ID", "Type", "Chrom", "Pos", "Ref", "Alt", "Quality", "Filter"].joined(separator: "\t")]
        for row in request.rows {
            let quality = row.quality.map { $0 < 0 ? "." : String(format: "%.1f", $0) } ?? "."
            lines.append([row.name, row.type, row.chromosome, "\(row.start + 1)",
                row.ref ?? ".", row.alt ?? ".", quality, row.filter ?? "."].joined(separator: "\t"))
        }
        var argv = ["Lungfish Genome Explorer", "export-bookmarked-variants"]
        for sourceURL in request.sourceURLs { argv += ["--variant-database", sourceURL.path] }
        argv += ["--output", request.outputURL.path]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let snapshot = try RetainedSelectionExportSnapshot(outputURL: request.outputURL,
            selectionMetadata: encoder.encode(Selection(sourceDatabaseURLs: request.sourceURLs, selectedRows: request.rows)))
        do {
            try (lines.joined(separator: "\n") + "\n").write(to: snapshot.payloadURL, atomically: true, encoding: .utf8)
            try snapshot.publish(.init(
                workflowName: "lungfish app bookmarked variant export", sourceURLs: request.sourceURLs,
                outputURL: request.outputURL, outputFormat: .text, argv: argv,
                explicitOptions: ["sourceVariantDatabasePaths": .array(request.sourceURLs.map { .file($0) }),
                    "outputPath": .file(request.outputURL)],
                defaults: ["outputFormat": .string("tsv")],
                resolved: ["variantCount": .integer(request.rows.count)], startedAt: startedAt
            ))
        } catch {
            snapshot.discardAfterFailure(error)
            throw error
        }
    }
}
