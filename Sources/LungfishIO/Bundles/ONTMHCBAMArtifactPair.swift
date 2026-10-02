import Foundation

public struct ONTMHCBAMArtifactPair: Codable, Equatable, Sendable {
    public let bam: ONTMHCArtifactReference
    public let bai: ONTMHCArtifactReference

    public init(bam: ONTMHCArtifactReference, bai: ONTMHCArtifactReference) {
        self.bam = bam
        self.bai = bai
    }

    private enum CodingKeys: String, CodingKey {
        case bam
        case bai
    }
}
