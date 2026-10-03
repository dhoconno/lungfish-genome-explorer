import Foundation
import Darwin
import LungfishCore
import LungfishIO

struct AmpliconWorkDirectoryDisposition: Codable, Sendable {
    let path: String
    let disposition: String
    let error: String?
}
