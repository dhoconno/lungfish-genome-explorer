import Foundation

public struct ONTMHCEvidenceLocator: Codable, Equatable, Sendable {
    public let bamPath: String
    public let queryName: String
    public let referenceName: String
    public let readGroupID: String?
    public let referenceStart: Int
    public let cigar: String

    public init(
        bamPath: String,
        queryName: String,
        referenceName: String,
        readGroupID: String?,
        referenceStart: Int,
        cigar: String
    ) {
        self.bamPath = bamPath
        self.queryName = queryName
        self.referenceName = referenceName
        self.readGroupID = readGroupID
        self.referenceStart = referenceStart
        self.cigar = cigar
    }

    private enum CodingKeys: String, CodingKey {
        case bamPath = "bam_path"
        case queryName = "query_name"
        case referenceName = "reference_name"
        case readGroupID = "read_group_id"
        case referenceStart = "reference_start"
        case cigar
    }
}
