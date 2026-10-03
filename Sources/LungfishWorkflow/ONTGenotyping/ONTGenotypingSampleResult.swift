import Foundation
import LungfishCore
import LungfishIO

public struct ONTGenotypingSampleResult: Sendable, Codable, Equatable {
    public let inputFASTQURL: URL
    public let sampleName: String
    public let mappingResult: MappingResult
    public let filteredMappingResult: MappingResult
    public let filterResult: ONTGenotypingFilterResult
    public let reportRows: [ONTGenotypingReportRow]
}
