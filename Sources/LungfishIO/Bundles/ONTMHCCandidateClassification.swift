import Foundation

public enum ONTMHCCandidateClassification: String, Codable, Sendable {
    case novel
    case `extension`
    case partialExtension = "partial-extension"

    public var isExtensionLike: Bool {
        self == .extension || self == .partialExtension
    }
}
