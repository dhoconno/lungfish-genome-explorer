import CryptoKit
import Foundation
import Observation
import LungfishCore
import LungfishIO
import LungfishWorkflow

public struct ManualHaplotypeReplacementResult: Equatable, Sendable {
    public let didChange: Bool
    public let sample: String
    public let operationID: String?
    public let timestamp: String?
    public let added: [ManualHaplotypeAssignment]
    public let updated: [ManualHaplotypeAssignment]
    public let removed: [ManualHaplotypeAssignment]

    public init(
        didChange: Bool,
        sample: String,
        operationID: String?,
        timestamp: String?,
        added: [ManualHaplotypeAssignment],
        updated: [ManualHaplotypeAssignment],
        removed: [ManualHaplotypeAssignment]
    ) {
        self.didChange = didChange
        self.sample = sample
        self.operationID = operationID
        self.timestamp = timestamp
        self.added = added
        self.updated = updated
        self.removed = removed
    }
}
