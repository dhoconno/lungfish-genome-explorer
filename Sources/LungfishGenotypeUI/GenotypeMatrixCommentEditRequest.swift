import Foundation
import LungfishCore
import LungfishIO
import LungfishKit

public struct GenotypeMatrixCommentEditRequest: Equatable, Sendable {
    public enum Intent: Equatable, Sendable {
        case upsert(body: String)
        case remove
        case replace(body: String)
    }

    public let targets: [GenotypeAnnotationSidecar.MatrixTarget]
    public let intent: Intent

    public init(
        targets: [GenotypeAnnotationSidecar.MatrixTarget],
        intent: Intent
    ) {
        self.targets = targets
        self.intent = intent
    }

    /// Compatibility initializer for pre-semantic call sites. It now means an
    /// exact target-keyed upsert, never an append.
    public init(
        targets: [GenotypeAnnotationSidecar.MatrixTarget],
        body: String
    ) {
        self.init(targets: targets, intent: .upsert(body: body))
    }

    public var body: String {
        switch intent {
        case let .upsert(body), let .replace(body):
            return body
        case .remove:
            return ""
        }
    }
}

@available(*, deprecated, renamed: "GenotypeMatrixCommentEditRequest")
public typealias GenotypeMatrixCommentRequest = GenotypeMatrixCommentEditRequest
