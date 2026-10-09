import Foundation
import LungfishCore
import LungfishIO
import LungfishKit

public enum GenotypeMatrixStyleField: Equatable {
    case fillColor(AnnotationColor?)
    case textColor(AnnotationColor?)
    case borderColor(AnnotationColor?)
    case isBold(Bool)
    case isItalic(Bool)
    case clear
}
