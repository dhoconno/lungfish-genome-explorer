import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Value-captured export inputs shared by document and sidebar entry points.
enum AnnotationExportService {
    struct Source: Codable, Sendable {
        enum Kind: String, Codable, Sendable { case openDocument, sidebarBundle }
        let kind: Kind
        let urls: [URL]
        let name: String
    }

    struct Request: Sendable {
        let source: Source
        let annotations: [SequenceAnnotation]
        let outputURL: URL
    }

    private struct Selection: Encodable {
        let replayScope = RetainedSelectionExportSnapshot.replayScope
        let source: Source
        let annotations: [SequenceAnnotation]
    }

    static func export(_ request: Request) async throws {
        let startedAt = Date()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let snapshot = try RetainedSelectionExportSnapshot(outputURL: request.outputURL,
            selectionMetadata: encoder.encode(Selection(source: request.source, annotations: request.annotations)))
        do {
            try await GFF3Writer.write(request.annotations, to: snapshot.payloadURL, source: "Lungfish")
            var argv = ["Lungfish.app", "export-gff3", "--source-kind", request.source.kind.rawValue]
            for url in request.source.urls { argv += ["--source", url.path] }
            argv += ["--output", request.outputURL.path]
            try snapshot.publish(.init(
                workflowName: "lungfish app annotation export", sourceURLs: request.source.urls,
                outputURL: request.outputURL, outputFormat: .gff3, argv: argv,
                explicitOptions: ["sourceKind": .string(request.source.kind.rawValue),
                    "sourceName": .string(request.source.name),
                    "sourcePaths": .array(request.source.urls.map { .file($0) }),
                    "outputPath": .file(request.outputURL)],
                defaults: ["outputFormat": .string("gff3"), "featureSource": .string("Lungfish")],
                resolved: ["annotationCount": .integer(request.annotations.count)], startedAt: startedAt))
        } catch {
            snapshot.discardAfterFailure(error)
            throw error
        }
    }
}
