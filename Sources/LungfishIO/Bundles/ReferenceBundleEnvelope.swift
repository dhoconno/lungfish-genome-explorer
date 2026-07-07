import Foundation

/// Shared manifest convention for Lungfish reference bundles.
///
/// Every reference bundle (`.lungfishref`, `.lungfishmhcref`, `.lungfish12sref`)
/// stores a JSON manifest carrying a `schemaVersion` and a `kind` discriminator so
/// readers can confirm both the layout version and the bundle type before loading.
public protocol ReferenceBundleManifesting: Codable, Equatable, Sendable {
    /// Filename of the manifest within the bundle directory.
    static var manifestFilename: String { get }
    /// Canonical `kind` value for this manifest type.
    static var kindIdentifier: String { get }
    /// Layout version of the manifest as decoded.
    var schemaVersion: Int { get }
    /// `kind` discriminator as decoded.
    var kind: String { get }
    /// Files copied into the bundle, in manifest declaration order.
    var sourceFiles: [ReferenceBundleSourceFile] { get }
}

/// A file copied into a reference bundle, recorded in its manifest.
public struct ReferenceBundleSourceFile: Codable, Equatable, Sendable {
    public let path: String
    public let role: String
    public let originalPath: String?

    public init(path: String, role: String, originalPath: String? = nil) {
        self.path = path
        self.role = role
        self.originalPath = originalPath
    }
}

/// Helpers that enforce a single `isBundleURL` contract across bundle types.
public enum ReferenceBundleEnvelope {
    /// True when `url` has the bundle's directory extension AND contains its manifest.
    ///
    /// Use this on the consume side, when inspecting a bundle the user selected or
    /// opened, so a bare directory with the right name is not mistaken for a bundle.
    public static func isBundleURL(
        _ url: URL,
        directoryExtension: String,
        manifestFilename: String
    ) -> Bool {
        url.pathExtension.lowercased() == directoryExtension
            && FileManager.default.fileExists(
                atPath: url.appendingPathComponent(manifestFilename).path
            )
    }

    /// True when `url` has the bundle's directory extension, regardless of manifest.
    ///
    /// Use this on the produce side, when validating an output path before the
    /// manifest has been written.
    public static func hasBundleExtension(
        _ url: URL,
        directoryExtension: String
    ) -> Bool {
        url.pathExtension.lowercased() == directoryExtension
    }
}

/// Actionable validation failure for a reference bundle.
public struct ReferenceBundleValidationError: Error, LocalizedError, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case missingFile(String)
        case schemaMismatch(expected: Int, found: Int)
        case kindMismatch(expected: String, found: String)
    }

    public let kind: Kind

    public init(kind: Kind) {
        self.kind = kind
    }

    public var errorDescription: String? {
        switch kind {
        case let .missingFile(path):
            return "Reference bundle is missing a required file at \(path)."
        case let .schemaMismatch(expected, found):
            return "Reference bundle schema version \(found) is not supported. Expected version \(expected)."
        case let .kindMismatch(expected, found):
            return "Reference bundle kind \"\(found)\" does not match the expected kind \"\(expected)\"."
        }
    }
}
