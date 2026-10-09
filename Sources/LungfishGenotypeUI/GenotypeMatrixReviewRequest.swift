import Foundation
import LungfishCore
import LungfishIO
import LungfishKit

public struct GenotypeMatrixReviewRequest: Equatable, Sendable {
    public enum Intent: Equatable, Sendable {
        case set(GenotypeAnnotationSidecar.MatrixReviewDisposition)
        case clear
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
}
