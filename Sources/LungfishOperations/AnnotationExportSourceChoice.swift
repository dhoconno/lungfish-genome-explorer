import Foundation
import LungfishCore

/// Immutable presentation choice; the export service owns writing and provenance.
package struct AnnotationExportSourceChoice {
    package let source: AnnotationExportService.Source
    package let annotations: [SequenceAnnotation]?

    package init(source: AnnotationExportService.Source, annotations: [SequenceAnnotation]?) {
        self.source = source
        self.annotations = annotations
    }

    package var displayTitle: String {
        guard !source.urls.isEmpty else { return source.name }
        return source.name + " — " + source.urls.map(\.path).joined(separator: ", ")
    }
}
