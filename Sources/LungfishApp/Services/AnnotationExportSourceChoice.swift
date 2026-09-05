import Foundation
import LungfishCore

/// Immutable presentation choice; the export service owns writing and provenance.
struct AnnotationExportSourceChoice {
    let source: AnnotationExportService.Source
    let annotations: [SequenceAnnotation]?

    var displayTitle: String {
        guard !source.urls.isEmpty else { return source.name }
        return source.name + " — " + source.urls.map(\.path).joined(separator: ", ")
    }
}
