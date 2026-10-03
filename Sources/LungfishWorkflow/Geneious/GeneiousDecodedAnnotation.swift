import Foundation

struct GeneiousDecodedAnnotation: Sendable, Equatable {
    let type: String
    let description: String
    let intervals: [GeneiousDecodedAnnotationInterval]
    let qualifiers: [GeneiousDecodedAnnotationQualifier]
}
