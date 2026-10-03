@preconcurrency import Foundation

/// A checksum-pinned source payload installed into an otherwise managed conda
/// environment. This is deliberately a typed contract so status evaluation can
/// distinguish a valid managed source tool from an arbitrary executable.
public struct PackToolSourceOverlay: Sendable, Codable, Hashable {
    public enum Kind: String, Sendable, Codable, Hashable {
        case bracken
    }

    public let kind: Kind
    public let version: String
    public let sourceURL: URL
    public let sha256: String

    public init(kind: Kind, version: String, sourceURL: URL, sha256: String) {
        self.kind = kind
        self.version = version
        self.sourceURL = sourceURL
        self.sha256 = sha256.lowercased()
    }

    func validateRequestedIdentity() throws {
        guard !version.isEmpty, sourceURL.scheme == "https", sourceURL.host != nil,
              sha256.count == 64, sha256.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw CondaLockfileError.invalidSpecification("Source overlay requires an HTTPS archive URL, version, and SHA-256.")
        }
    }

}
