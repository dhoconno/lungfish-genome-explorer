import Foundation

public enum HaplotypeBlockGlyph: String, CaseIterable, Codable, Sendable {
    case empty
    case filledCircle
    case filledSquare
    case filledTriangle
    case filledDiamond
    case hollowCircle
    case hollowSquare
    case asterisk

    public var symbol: String {
        switch self {
        case .empty:           return "·"
        case .filledCircle:    return "●"
        case .filledSquare:    return "■"
        case .filledTriangle:  return "▲"
        case .filledDiamond:   return "◆"
        case .hollowCircle:    return "○"
        case .hollowSquare:    return "□"
        case .asterisk:        return "✻"
        }
    }
}
