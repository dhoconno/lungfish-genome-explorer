import Foundation
import LungfishCore
import LungfishIO
import LungfishKit

public struct GenotypeResultHighlightRequest: Equatable {
    public let target: GenotypeResultHighlightTarget
    public let scope: GenotypeResultHighlightScope
    public let channel: GenotypeResultHighlightChannel
    public let color: AnnotationColor?

    public init(
        target: GenotypeResultHighlightTarget,
        scope: GenotypeResultHighlightScope,
        channel: GenotypeResultHighlightChannel = .fill,
        color: AnnotationColor?
    ) {
        self.target = target
        self.scope = scope
        self.channel = channel
        self.color = color
    }
}
