import LungfishCore

/// Native style layering shared by the matrix and static report capture.
public enum GenotypeMatrixStyleResolver {
    public static func resolve(_ layers: [GenotypeAnnotationSidecar.MatrixStyle?],
        initial: GenotypeWorkbookPresentation.Style = .init()) -> GenotypeWorkbookPresentation.Style {
        var fill = initial.fillHex, text = initial.textHex, border = initial.borderHex
        var bold = initial.isBold, italic = initial.isItalic
        for case let style? in layers {
            if let color = style.fillColor.flatMap(AnnotationColor.init(hex:)) { fill = color.hexString }
            if let color = style.textColor.flatMap(AnnotationColor.init(hex:)) { text = color.hexString }
            if let color = style.borderColor.flatMap(AnnotationColor.init(hex:)) { border = color.hexString }
            bold = style.boldOverride ?? (bold || style.isBold)
            italic = style.italicOverride ?? (italic || style.isItalic)
        }
        return .init(fillHex: fill, textHex: text, borderHex: border, isBold: bold, isItalic: italic)
    }
}
