import CryptoKit
import Darwin
import Foundation
import LungfishCore

public struct ONTMHCCandidateGenBankArtifactURLs: Codable, Equatable, Sendable {
    public static let empty = ONTMHCCandidateGenBankArtifactURLs(
        candidateAlleles: nil,
        unnameableClusters: nil,
        candidateFASTA: nil,
        unnameableFASTA: nil,
        candidateEMBL: nil,
        unnameableEMBL: nil
    )

    public let candidateAlleles: URL?
    public let unnameableClusters: URL?
    public let candidateFASTA: URL?
    public let unnameableFASTA: URL?
    public let candidateEMBL: URL?
    public let unnameableEMBL: URL?

    public init(
        candidateAlleles: URL?,
        unnameableClusters: URL?,
        candidateFASTA: URL? = nil,
        unnameableFASTA: URL? = nil,
        candidateEMBL: URL? = nil,
        unnameableEMBL: URL? = nil
    ) {
        self.candidateAlleles = candidateAlleles?.standardizedFileURL
        self.unnameableClusters = unnameableClusters?.standardizedFileURL
        self.candidateFASTA = candidateFASTA?.standardizedFileURL
        self.unnameableFASTA = unnameableFASTA?.standardizedFileURL
        self.candidateEMBL = candidateEMBL?.standardizedFileURL
        self.unnameableEMBL = unnameableEMBL?.standardizedFileURL
    }
}
