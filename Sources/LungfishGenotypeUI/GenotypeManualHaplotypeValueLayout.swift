import AppKit
import LungfishCore
import LungfishIO

struct GenotypeManualHaplotypeValueLayout: Equatable {
    static let textAlignment: NSTextAlignment = .center

    let value: String
    let rowRect: NSRect
    let textRect: NSRect
    let alignment: NSTextAlignment

    static func drawingAttributes(
        font: NSFont
    ) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = textAlignment
        paragraph.lineBreakMode = .byTruncatingTail
        return [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
    }
}
