import CryptoKit
import Foundation
import LungfishCore
import LungfishIO

enum FullLengthONTMHCWorkbookCellValue: Codable, Equatable, Sendable {
    case text(String)
    case integer(Int)
    case decimal(Double)
    case blank
}
