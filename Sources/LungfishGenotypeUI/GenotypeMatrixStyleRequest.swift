import Foundation
import LungfishCore
import LungfishIO
import LungfishKit

public struct GenotypeMatrixStyleRequest: Equatable {
    public let targets: [GenotypeAnnotationSidecar.MatrixTarget]
    public let field: GenotypeMatrixStyleField
    public let minimumReads: Int?

    public init(
        targets: [GenotypeAnnotationSidecar.MatrixTarget],
        field: GenotypeMatrixStyleField,
        minimumReads: Int? = nil
    ) {
        self.targets = targets
        self.field = field
        self.minimumReads = minimumReads
    }
}
