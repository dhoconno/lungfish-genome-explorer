import Foundation
import LungfishCore
import LungfishIO

public struct ONTGenotypingReportRow: Sendable, Codable, Equatable {
    public let inputBundleName: String
    public let genotype: String
    public let filteredIndelOnlyMappedReads: Int
    public let totalReads: Int
}
