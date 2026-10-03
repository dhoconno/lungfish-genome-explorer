import Foundation
import LungfishCore
import LungfishIO

public struct ONTGenotypingGenotypeCount: Sendable, Codable, Equatable {
    public let genotype: String
    public let filteredIndelOnlyMappedReads: Int

    public init(genotype: String, filteredIndelOnlyMappedReads: Int) {
        self.genotype = genotype
        self.filteredIndelOnlyMappedReads = filteredIndelOnlyMappedReads
    }
}
