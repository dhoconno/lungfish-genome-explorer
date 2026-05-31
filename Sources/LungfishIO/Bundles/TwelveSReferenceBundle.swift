import Foundation

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

    public static func referenceFASTAURL(in bundleURL: URL) -> URL? {
        guard let manifest = try? loadManifest(from: bundleURL) else { return nil }
        let url = bundleURL.appendingPathComponent(manifest.referenceFastaPath).standardizedFileURL
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public static func targetMetadataURL(in bundleURL: URL) -> URL? {
        guard let manifest = try? loadManifest(from: bundleURL) else { return nil }
        let url = bundleURL.appendingPathComponent(manifest.targetMetadataPath).standardizedFileURL
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public static func provenanceURL(in bundleURL: URL) -> URL? {
        guard let manifest = try? loadManifest(from: bundleURL) else { return nil }
        let url = bundleURL.appendingPathComponent(manifest.provenancePath).standardizedFileURL
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
