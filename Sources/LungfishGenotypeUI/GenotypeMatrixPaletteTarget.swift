import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
import LungfishKit

public enum GenotypeMatrixPaletteTarget: String, CaseIterable, Identifiable {
    case fill
    case text
    case border

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fill: return "Fill"
        case .text: return "Text"
        case .border: return "Border"
        }
    }
}
