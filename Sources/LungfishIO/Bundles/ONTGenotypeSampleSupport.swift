import CryptoKit
import Darwin
import Foundation
import LungfishCore

public struct ONTGenotypeSampleSupport: Codable, Equatable, Sendable {
    public let sample: String
    public let passedAlignments: Int
    public let passedUniqueReads: Int
    public let sampleUniqueRetainedReads: Int?

    public init(
        sample: String,
        passedAlignments: Int,
        passedUniqueReads: Int,
        sampleUniqueRetainedReads: Int? = nil
    ) {
        self.sample = sample
        self.passedAlignments = passedAlignments
        self.passedUniqueReads = passedUniqueReads
        self.sampleUniqueRetainedReads = sampleUniqueRetainedReads
    }
}
