import Foundation
import LungfishCore
import LungfishIO
import LungfishKit

public struct GenotypeResultHighlightTarget: Equatable, Hashable {
    public let genotype: String
    public let locus: String
    public let sample: String?
    public let stableClusterID: String?

    public init(
        genotype: String,
        locus: String,
        sample: String? = nil,
        stableClusterID: String? = nil
    ) {
        self.genotype = genotype
        self.locus = locus
        self.sample = sample
        self.stableClusterID = stableClusterID
    }

    public var displayScope: String {
        sample == nil ? "Genotype Row" : "Sample Cell"
    }
}
