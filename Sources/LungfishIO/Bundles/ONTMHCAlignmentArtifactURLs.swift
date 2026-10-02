import CryptoKit
import Darwin
import Foundation
import LungfishCore

public struct ONTMHCAlignmentArtifactURLs: Codable, Equatable, Sendable {
    public static let empty = ONTMHCAlignmentArtifactURLs(
        genotypingBAM: nil,
        genotypingBAI: nil,
        reciprocalBAM: nil,
        reciprocalBAI: nil
    )

    public let genotypingBAM: URL?
    public let genotypingBAI: URL?
    public let reciprocalBAM: URL?
    public let reciprocalBAI: URL?

    public init(
        genotypingBAM: URL?,
        genotypingBAI: URL?,
        reciprocalBAM: URL?,
        reciprocalBAI: URL?
    ) {
        self.genotypingBAM = genotypingBAM?.standardizedFileURL
        self.genotypingBAI = genotypingBAI?.standardizedFileURL
        self.reciprocalBAM = reciprocalBAM?.standardizedFileURL
        self.reciprocalBAI = reciprocalBAI?.standardizedFileURL
    }
}
