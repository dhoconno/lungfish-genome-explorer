import Foundation

public enum HaplotypeSlot: String, CaseIterable, Codable, Sendable {
    case h1
    case h2

    public var displayName: String {
        switch self {
        case .h1: return "H1"
        case .h2: return "H2"
        }
    }
}
