import Foundation

public struct HaplotypeColorToken: Equatable, Hashable, Codable, Sendable {
    public let canonicalIndex: Int
    public let displayName: String
    public let fillColor: AnnotationColor
    public let darkFillColor: AnnotationColor
    public let fontColor: AnnotationColor
    public let glyph: HaplotypeBlockGlyph

    public init(canonicalIndex: Int,
                displayName: String,
                fillColor: AnnotationColor,
                darkFillColor: AnnotationColor,
                fontColor: AnnotationColor,
                glyph: HaplotypeBlockGlyph) {
        self.canonicalIndex = canonicalIndex
        self.displayName = displayName
        self.fillColor = fillColor
        self.darkFillColor = darkFillColor
        self.fontColor = fontColor
        self.glyph = glyph
    }
}

public extension HaplotypeColorToken {
    static let canonicalPalette: [HaplotypeColorToken] = [
        HaplotypeColorToken(
            canonicalIndex: 0,
            displayName: "Absent",
            fillColor: AnnotationColor(red: 0.87, green: 0.87, blue: 0.87),
            darkFillColor: AnnotationColor(red: 0.27, green: 0.27, blue: 0.27),
            fontColor: AnnotationColor(red: 0.42, green: 0.42, blue: 0.42),
            glyph: .empty
        ),
        HaplotypeColorToken(
            canonicalIndex: 1,
            displayName: "M1",
            fillColor: AnnotationColor(hex: "#0C0000") ?? AnnotationColor(red: 0.05, green: 0, blue: 0),
            darkFillColor: AnnotationColor(hex: "#1A1A1A") ?? AnnotationColor(red: 0.1, green: 0.1, blue: 0.1),
            fontColor: AnnotationColor(hex: "#FFFFFF") ?? AnnotationColor(red: 1, green: 1, blue: 1),
            glyph: .filledCircle
        ),
        HaplotypeColorToken(
            canonicalIndex: 2,
            displayName: "M2",
            fillColor: AnnotationColor(hex: "#FF0000") ?? AnnotationColor(red: 1, green: 0, blue: 0),
            darkFillColor: AnnotationColor(hex: "#FF4444") ?? AnnotationColor(red: 1, green: 0.27, blue: 0.27),
            fontColor: AnnotationColor(hex: "#FFFFFF") ?? AnnotationColor(red: 1, green: 1, blue: 1),
            glyph: .filledSquare
        ),
        HaplotypeColorToken(
            canonicalIndex: 3,
            displayName: "M3",
            fillColor: AnnotationColor(hex: "#0000FF") ?? AnnotationColor(red: 0, green: 0, blue: 1),
            darkFillColor: AnnotationColor(hex: "#4488FF") ?? AnnotationColor(red: 0.27, green: 0.53, blue: 1),
            fontColor: AnnotationColor(hex: "#FFFFFF") ?? AnnotationColor(red: 1, green: 1, blue: 1),
            glyph: .filledTriangle
        ),
        HaplotypeColorToken(
            canonicalIndex: 4,
            displayName: "M4",
            fillColor: AnnotationColor(hex: "#008000") ?? AnnotationColor(red: 0, green: 0.5, blue: 0),
            darkFillColor: AnnotationColor(hex: "#22AA44") ?? AnnotationColor(red: 0.13, green: 0.67, blue: 0.27),
            fontColor: AnnotationColor(hex: "#FFFFFF") ?? AnnotationColor(red: 1, green: 1, blue: 1),
            glyph: .filledDiamond
        ),
        HaplotypeColorToken(
            canonicalIndex: 5,
            displayName: "M5",
            fillColor: AnnotationColor(hex: "#FFFF00") ?? AnnotationColor(red: 1, green: 1, blue: 0),
            darkFillColor: AnnotationColor(hex: "#DDDD00") ?? AnnotationColor(red: 0.87, green: 0.87, blue: 0),
            fontColor: AnnotationColor(hex: "#0C0000") ?? AnnotationColor(red: 0.05, green: 0, blue: 0),
            glyph: .hollowCircle
        ),
        HaplotypeColorToken(
            canonicalIndex: 6,
            displayName: "M6",
            fillColor: AnnotationColor(hex: "#808080") ?? AnnotationColor(red: 0.5, green: 0.5, blue: 0.5),
            darkFillColor: AnnotationColor(hex: "#999999") ?? AnnotationColor(red: 0.6, green: 0.6, blue: 0.6),
            fontColor: AnnotationColor(hex: "#FFFFFF") ?? AnnotationColor(red: 1, green: 1, blue: 1),
            glyph: .hollowSquare
        ),
        HaplotypeColorToken(
            canonicalIndex: 7,
            displayName: "M7",
            fillColor: AnnotationColor(hex: "#800080") ?? AnnotationColor(red: 0.5, green: 0, blue: 0.5),
            darkFillColor: AnnotationColor(hex: "#BB44BB") ?? AnnotationColor(red: 0.73, green: 0.27, blue: 0.73),
            fontColor: AnnotationColor(hex: "#FFFFFF") ?? AnnotationColor(red: 1, green: 1, blue: 1),
            glyph: .asterisk
        ),
    ]

    static let canonicalByName: [String: Int] = [
        "M1A": 1, "M2A": 2, "M3A": 3, "M4A": 4, "M5A": 5, "M6A": 6, "M7A": 7,
        "M1B": 1, "M2B": 2, "M3B": 3, "M4B": 4, "M5B": 5, "M6B": 6, "M7B": 7,
        "M1DR": 1, "M2DR": 2, "M3DR": 3, "M4DR": 4, "M5DR": 5, "M6DR": 6, "M7DR": 7,
        "M1DQ": 1, "M2DQ": 2, "M3DQ": 3, "M4DQ": 4, "M5DQ": 5, "M6DQ": 6, "M7DQ": 7,
        "M1DP": 1, "M2DP": 2, "M3DP": 3, "M4M7DP": 4, "M5M6DP": 5,
        "-": 0, "": 0, "A1_063": 1,
    ]

    static func assigned(forName name: String) -> HaplotypeColorToken {
        if let index = canonicalByName[name] {
            return canonicalPalette[index]
        }
        if name.hasPrefix("recM") {
            return canonicalPalette[1]
        }
        let bytes: [UInt8] = Array(name.utf8)
        var hash: UInt32 = 2166136261
        for byte in bytes {
            hash ^= UInt32(byte)
            hash &*= 16777619
        }
        let index = Int(hash % 7) + 1
        return canonicalPalette[index]
    }
}
