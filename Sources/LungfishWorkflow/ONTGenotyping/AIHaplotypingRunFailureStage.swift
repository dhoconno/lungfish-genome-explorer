import Foundation
import LungfishCore
import LungfishIO

public enum AIHaplotypingRunFailureStage: String, Codable, Equatable, Sendable {
    case evidence
    case prompt
    case provider
    case decoding
    case runMetadata
    case validation
}
