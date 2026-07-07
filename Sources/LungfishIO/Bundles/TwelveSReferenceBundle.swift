import Foundation
import LungfishCore

public typealias TwelveSReferenceBundleSourceFile = ReferenceBundleSourceFile

public struct TwelveSReferenceBundleMetrics: Codable, Equatable, Sendable {
    public let referenceCount: Int
    public let metadataRowCount: Int
    public let taxidCount: Int
    public let taxonGroupCount: Int
    public let taxonomyCount: Int
    public let alternateMatchCount: Int

    public init(
        referenceCount: Int,
        metadataRowCount: Int,
        taxidCount: Int,
        taxonGroupCount: Int,
        taxonomyCount: Int,
        alternateMatchCount: Int
    ) {
        self.referenceCount = referenceCount
        self.metadataRowCount = metadataRowCount
        self.taxidCount = taxidCount
        self.taxonGroupCount = taxonGroupCount
        self.taxonomyCount = taxonomyCount
        self.alternateMatchCount = alternateMatchCount
    }
}

public struct TwelveSReferenceBundleManifest: ReferenceBundleManifesting {
    public static let manifestFilename = "12s-reference.json"
    public static let kindIdentifier = "12s-reference"

    /// Retained for source compatibility with existing call sites.
    public static let filename = manifestFilename

    public let schemaVersion: Int
    public let kind: String
    public let name: String
    public let referenceFastaPath: String
    public let targetMetadataPath: String
    public let sourceFiles: [TwelveSReferenceBundleSourceFile]
    public let metrics: TwelveSReferenceBundleMetrics
    public let provenancePath: String
    public let createdAt: String

    public init(
        schemaVersion: Int = 1,
        kind: String = TwelveSReferenceBundleManifest.kindIdentifier,
        name: String,
        referenceFastaPath: String,
        targetMetadataPath: String,
        sourceFiles: [TwelveSReferenceBundleSourceFile] = [],
        metrics: TwelveSReferenceBundleMetrics,
        provenancePath: String,
        createdAt: String
    ) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.name = name
        self.referenceFastaPath = referenceFastaPath
        self.targetMetadataPath = targetMetadataPath
        self.sourceFiles = sourceFiles
        self.metrics = metrics
        self.provenancePath = provenancePath
        self.createdAt = createdAt
    }
}

public enum TwelveSReferenceBundle {
    public static let directoryExtension = "lungfish12sref"
    public static let manifestFilename = TwelveSReferenceBundleManifest.manifestFilename
    private static let supportedSchemaVersion = 1

    public static func manifestURL(in bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent(manifestFilename).standardizedFileURL
    }

    /// Consume-side check: requires both the extension and a manifest on disk.
    public static func isBundleURL(_ url: URL) -> Bool {
        ReferenceBundleEnvelope.isBundleURL(
            url,
            directoryExtension: directoryExtension,
            manifestFilename: manifestFilename
        )
    }

    /// Produce-side check: extension only, for validating an output path before
    /// its manifest exists.
    public static func hasBundleExtension(_ url: URL) -> Bool {
        ReferenceBundleEnvelope.hasBundleExtension(url, directoryExtension: directoryExtension)
    }

    public static func loadManifest(from bundleURL: URL) throws -> TwelveSReferenceBundleManifest {
        let data = try Data(contentsOf: manifestURL(in: bundleURL))
        return try JSONDecoder().decode(TwelveSReferenceBundleManifest.self, from: data)
    }

    public static func writeManifest(
        _ manifest: TwelveSReferenceBundleManifest,
        to bundleURL: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL(in: bundleURL), options: .atomic)
    }

    /// Confirms the bundle manifest references files that exist on disk and carries
    /// the expected schema version and kind.
    public static func validate(at bundleURL: URL) throws {
        let manifest = try loadManifest(from: bundleURL)
        guard manifest.schemaVersion == supportedSchemaVersion else {
            throw ReferenceBundleValidationError(
                kind: .schemaMismatch(
                    expected: supportedSchemaVersion,
                    found: manifest.schemaVersion
                )
            )
        }
        guard manifest.kind == TwelveSReferenceBundleManifest.kindIdentifier else {
            throw ReferenceBundleValidationError(
                kind: .kindMismatch(
                    expected: TwelveSReferenceBundleManifest.kindIdentifier,
                    found: manifest.kind
                )
            )
        }
        let referenceURL = try validatedBundleMemberURL(
            manifest.referenceFastaPath,
            in: bundleURL,
            field: "referenceFastaPath"
        )
        guard FileManager.default.fileExists(atPath: referenceURL.path) else {
            throw ReferenceBundleValidationError(kind: .missingFile(referenceURL.path))
        }
        let metadataURL = try validatedBundleMemberURL(
            manifest.targetMetadataPath,
            in: bundleURL,
            field: "targetMetadataPath"
        )
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            throw ReferenceBundleValidationError(kind: .missingFile(metadataURL.path))
        }
        let provenanceURL = try validatedBundleMemberURL(
            manifest.provenancePath,
            in: bundleURL,
            field: "provenancePath",
            allowReservedControlPath: true
        )
        guard FileManager.default.fileExists(atPath: provenanceURL.path) else {
            throw ReferenceBundleValidationError(kind: .missingFile(provenanceURL.path))
        }
    }

    public static func referenceFASTAURL(in bundleURL: URL) -> URL? {
        guard let manifest = try? loadManifest(from: bundleURL),
              isSupported(manifest),
              let url = try? validatedBundleMemberURL(
                manifest.referenceFastaPath,
                in: bundleURL,
                field: "referenceFastaPath"
              ) else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public static func targetMetadataURL(in bundleURL: URL) -> URL? {
        guard let manifest = try? loadManifest(from: bundleURL),
              isSupported(manifest),
              let url = try? validatedBundleMemberURL(
                manifest.targetMetadataPath,
                in: bundleURL,
                field: "targetMetadataPath"
              ) else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public static func provenanceURL(in bundleURL: URL) -> URL? {
        guard let manifest = try? loadManifest(from: bundleURL),
              isSupported(manifest),
              let url = try? validatedBundleMemberURL(
                manifest.provenancePath,
                in: bundleURL,
                field: "provenancePath",
                allowReservedControlPath: true
              ) else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func validatedBundleMemberURL(
        _ relativePath: String,
        in bundleURL: URL,
        field: String,
        allowReservedControlPath: Bool = false
    ) throws -> URL {
        do {
            return try BundleManifest.validatedBundleMemberURL(
                for: relativePath,
                in: bundleURL,
                field: field,
                allowReservedControlPath: allowReservedControlPath
            )
        } catch {
            throw ReferenceBundleValidationError(kind: .missingFile(relativePath))
        }
    }

    private static func isSupported(_ manifest: TwelveSReferenceBundleManifest) -> Bool {
        manifest.schemaVersion == supportedSchemaVersion
            && manifest.kind == TwelveSReferenceBundleManifest.kindIdentifier
    }
}
