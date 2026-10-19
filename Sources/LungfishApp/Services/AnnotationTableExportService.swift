import Foundation

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
