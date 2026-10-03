import Foundation

struct GeneiousDecodedSequenceRecord: Sendable, Equatable {
    let name: String
    let sequence: String
    let sidecarRelativePath: String
    let annotations: [GeneiousDecodedAnnotation]
}
