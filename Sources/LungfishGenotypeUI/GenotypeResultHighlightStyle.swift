import Foundation
import LungfishCore
import LungfishIO
import LungfishKit

public struct GenotypeResultHighlightStyle: Equatable, Hashable, Sendable {
    public var fillColor: AnnotationColor?
    public var borderColor: AnnotationColor?

    public static let `default` = GenotypeResultHighlightStyle()

    public init(fillColor: AnnotationColor? = nil, borderColor: AnnotationColor? = nil) {
        self.fillColor = fillColor
        self.borderColor = borderColor
    }

    public var isDefault: Bool {
        fillColor == nil && borderColor == nil
    }

    public func color(for channel: GenotypeResultHighlightChannel) -> AnnotationColor? {
        switch channel {
        case .fill:
            return fillColor
        case .border:
            return borderColor
        }
    }

    public mutating func setColor(_ color: AnnotationColor?, for channel: GenotypeResultHighlightChannel) {
        switch channel {
        case .fill:
            fillColor = color
        case .border:
            borderColor = color
        }
    }
}
