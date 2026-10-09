import Foundation
import LungfishCore
import LungfishIO
import LungfishKit

struct GenotypeMatrixRenderedStyle: Equatable {
    var fillColor: AnnotationColor?
    var textColor: AnnotationColor?
    var borderColor: AnnotationColor?
    var isBold: Bool = false
    var isItalic: Bool = false

    static let `default` = GenotypeMatrixRenderedStyle()

    var isDefault: Bool {
        fillColor == nil && textColor == nil && borderColor == nil && !isBold && !isItalic
    }
}
