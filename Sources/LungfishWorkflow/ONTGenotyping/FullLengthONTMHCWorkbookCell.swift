import CryptoKit
import Foundation
import LungfishCore
import LungfishIO

struct FullLengthONTMHCWorkbookCell: Codable, Equatable, Sendable {
    let value: FullLengthONTMHCWorkbookCellValue
    let tint: FullLengthONTMHCWorkbookTintCategory?

    init(_ text: String, tint: FullLengthONTMHCWorkbookTintCategory? = nil) {
        value = .text(text)
        self.tint = tint
    }

    init(_ integer: Int) {
        value = .integer(integer)
        tint = nil
    }

    init(_ decimal: Double) {
        value = .decimal(decimal)
        tint = nil
    }

    static let blank = FullLengthONTMHCWorkbookCell(value: .blank, tint: nil)

    private init(value: FullLengthONTMHCWorkbookCellValue, tint: FullLengthONTMHCWorkbookTintCategory?) {
        self.value = value
        self.tint = tint
    }
}
