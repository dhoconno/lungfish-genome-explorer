import CryptoKit
import Darwin
import Foundation
import LungfishIO

public enum PrimalScheme3TerminalGapPolicy: String, Codable, CaseIterable, Sendable {
    case legacy
    case observedOnly = "observed-only"

    public var discoveryBackend: String {
        self == .legacy ? "rust-legacy" : "python-observed-only"
    }
}
