import Foundation

struct GeneiousDecodedSequenceSet: Sendable, Equatable {
    let documentRelativePath: String
    let documentName: String
    let records: [GeneiousDecodedSequenceRecord]
    let decodedSidecarPaths: Set<String>
    let annotationSidecarPaths: Set<String>
    let hasInlineAnnotations: Bool
    let warnings: [String]
}
