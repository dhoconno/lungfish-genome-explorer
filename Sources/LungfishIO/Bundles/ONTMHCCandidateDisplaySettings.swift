import Foundation
import LungfishCore

public struct ONTMHCCandidateDisplaySettings: Codable, Equatable, Sendable {
    public var showKnown: Bool
    public var showSharedCandidates: Bool
    public var showSingletonCandidates: Bool
    public var tints: [ONTMHCCandidateTintCategory: AnnotationColor]

    public static let defaultTints: [ONTMHCCandidateTintCategory: AnnotationColor] = [
        .sharedNovel: AnnotationColor(hex: "#F5D78E")!,
        .singletonNovel: AnnotationColor(hex: "#F5B97A")!,
        .sharedExtension: AnnotationColor(hex: "#A8D8D0")!,
        .singletonExtension: AnnotationColor(hex: "#AFCBF2")!,
    ]

    public static let `default` = ONTMHCCandidateDisplaySettings(
        showKnown: true,
        showSharedCandidates: true,
        showSingletonCandidates: true,
        tints: defaultTints
    )

    public init(
        showKnown: Bool = true,
        showSharedCandidates: Bool = true,
        showSingletonCandidates: Bool = true,
        tints: [ONTMHCCandidateTintCategory: AnnotationColor] = Self.defaultTints
    ) {
        self.showKnown = showKnown
        self.showSharedCandidates = showSharedCandidates
        self.showSingletonCandidates = showSingletonCandidates
        self.tints = Self.normalizedTints(tints)
    }

    private enum CodingKeys: String, CodingKey {
        case showKnown
        case showSharedCandidates
        case showSingletonCandidates
        case tints
    }

    private struct TintCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showKnown = try container.decodeIfPresent(Bool.self, forKey: .showKnown) ?? true
        showSharedCandidates = try container.decodeIfPresent(Bool.self, forKey: .showSharedCandidates) ?? true
        showSingletonCandidates = try container.decodeIfPresent(Bool.self, forKey: .showSingletonCandidates) ?? true

        var decodedTints: [ONTMHCCandidateTintCategory: AnnotationColor] = [:]
        if container.contains(.tints),
           let tintContainer = try? container.nestedContainer(keyedBy: TintCodingKey.self, forKey: .tints) {
            for key in tintContainer.allKeys {
                guard let category = ONTMHCCandidateTintCategory(rawValue: key.stringValue) else {
                    continue
                }
                if let color = try? tintContainer.decode(AnnotationColor.self, forKey: key) {
                    decodedTints[category] = color
                } else if let hex = try? tintContainer.decode(String.self, forKey: key),
                          let color = AnnotationColor(hex: hex) {
                    decodedTints[category] = color
                }
            }
        }
        tints = Self.normalizedTints(decodedTints)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(showKnown, forKey: .showKnown)
        try container.encode(showSharedCandidates, forKey: .showSharedCandidates)
        try container.encode(showSingletonCandidates, forKey: .showSingletonCandidates)
        var tintContainer = container.nestedContainer(keyedBy: TintCodingKey.self, forKey: .tints)
        for category in ONTMHCCandidateTintCategory.allCases {
            let key = TintCodingKey(stringValue: category.rawValue)!
            try tintContainer.encode(tints[category] ?? Self.defaultTints[category]!, forKey: key)
        }
    }

    private static func normalizedTints(
        _ tints: [ONTMHCCandidateTintCategory: AnnotationColor]
    ) -> [ONTMHCCandidateTintCategory: AnnotationColor] {
        var normalized = defaultTints
        for category in ONTMHCCandidateTintCategory.allCases {
            if let tint = tints[category] {
                normalized[category] = AnnotationColor(
                    red: tint.red,
                    green: tint.green,
                    blue: tint.blue,
                    alpha: tint.alpha
                )
            }
        }
        return normalized
    }
}
