import CryptoKit
import Darwin
import Foundation
import LungfishCore

public enum ONTGenotypeWorkbookRevisionRole: String, Codable, CaseIterable, Equatable, Sendable {
    case initialCurrentCopy = "initial-current-copy"
    case imported
    case restored
    case externalEditSnapshot = "external-edit-snapshot"
    case aiRefinement = "ai-refinement"
}
