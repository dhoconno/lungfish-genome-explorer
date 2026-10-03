import CryptoKit
import Foundation
import LungfishCore
import LungfishIO

enum FullLengthONTMHCTranslationStatus: String, Codable, Equatable, Sendable {
    case fullLength = "full-length"
    case pseudogene
    case incompleteUnresolved = "incomplete/unresolved"
}
