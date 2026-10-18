import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Value-captured export inputs shared by document and sidebar entry points.
package enum AnnotationExportService {
    package struct Source: Codable, Sendable {
        package enum Kind: String, Codable, Sendable { case openDocument, sidebarBundle }
        package let kind: Kind
        package let urls: [URL]
        package let name: String

        package init(kind: Kind, urls: [URL], name: String) {
            self.kind = kind
            self.urls = urls
            self.name = name
        }
    }

    package struct Request: Sendable {
        let source: Source
        let annotations: [SequenceAnnotation]
        let outputURL: URL

        package init(source: Source, annotations: [SequenceAnnotation], outputURL: URL) {
            self.source = source
            self.annotations = annotations
            self.outputURL = outputURL
        }
    }

    private struct Selection: Encodable {
        let replayScope = RetainedSelectionExportSnapshot.replayScope
        let source: Source
        let annotations: [SequenceAnnotation]
    }

    package static func export(_ request: Request) async throws {
        let runClock = ProvenanceRunClock()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let snapshot = try RetainedSelectionExportSnapshot(outputURL: request.outputURL,
            selectionMetadata: encoder.encode(Selection(source: request.source, annotations: request.annotations)))
        do {
            try await GFF3Writer.write(request.annotations, to: snapshot.payloadURL, source: "Lungfish")
            var argv = ["Lungfish.app", "export-gff3", "--source-kind", request.source.kind.rawValue]
            for url in request.source.urls { argv += ["--source", url.path] }
            argv += ["--output", request.outputURL.path]
            // A sidebar bundle's annotations were read from its manifest and annotation databases, so the record
            // names those files (settled answers of 12.31, G3 and M4). An open document is read from memory.
            let readURLs = request.source.kind == .sidebarBundle
                ? request.source.urls.flatMap { (try? AnnotationGFF3Export.bundleInputURLs(bundleURL: $0)) ?? [] }
                : []
            try snapshot.publish(.init(
                workflowName: "lungfish app annotation export", sourceURLs: readURLs,
                outputURL: request.outputURL, outputFormat: .gff3, argv: argv,
                explicitOptions: ["sourceKind": .string(request.source.kind.rawValue),
                    "sourceName": .string(request.source.name),
                    "sourcePaths": .array(request.source.urls.map { .file($0) }),
                    "outputPath": .file(request.outputURL)],
                defaults: ["outputFormat": .string("gff3"), "featureSource": .string("Lungfish")],
                resolved: ["annotationCount": .integer(request.annotations.count)], runClock: runClock),
                preserveOriginalSources: true)
        } catch {
            snapshot.discardAfterFailure(error)
            throw error
        }
    }
}
