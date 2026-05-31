import Foundation

public typealias MHCAmpliconReferenceBundleSourceFile = ReferenceBundleSourceFile

public struct MHCAmpliconReferenceBundleMetrics: Codable, Equatable, Sendable {
    public let referenceCount: Int
    public let haplotypeDefinitionCount: Int

    public init(referenceCount: Int, haplotypeDefinitionCount: Int) {
        self.referenceCount = referenceCount
        self.haplotypeDefinitionCount = haplotypeDefinitionCount
    }
}

public struct MHCAmpliconReferenceBundleManifest: ReferenceBundleManifesting {
    public static let manifestFilename = "mhc-reference.json"
    public static let kindIdentifier = "mhc-reference"

    public let schemaVersion: Int
    public let kind: String
    public let name: String
    public let referenceFastaPath: String
    public let haplotypeDefinitionPaths: [String]
    public let defaultHaplotypeDefinitionID: String?
    public let sourceFiles: [MHCAmpliconReferenceBundleSourceFile]
    public let metrics: MHCAmpliconReferenceBundleMetrics
    public let provenancePath: String?
    public let createdAt: String

    public init(
        schemaVersion: Int = 1,
        kind: String = MHCAmpliconReferenceBundleManifest.kindIdentifier,
        name: String,
        referenceFastaPath: String,
        haplotypeDefinitionPaths: [String],
        defaultHaplotypeDefinitionID: String?,
        sourceFiles: [MHCAmpliconReferenceBundleSourceFile] = [],
        metrics: MHCAmpliconReferenceBundleMetrics,
        provenancePath: String? = nil,
        createdAt: String
    ) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.name = name
        self.referenceFastaPath = referenceFastaPath
        self.haplotypeDefinitionPaths = haplotypeDefinitionPaths
        self.defaultHaplotypeDefinitionID = defaultHaplotypeDefinitionID
        self.sourceFiles = sourceFiles
        self.metrics = metrics
        self.provenancePath = provenancePath
        self.createdAt = createdAt
    }
}

public enum MHCAmpliconReferenceBundle {
    public static let directoryExtension = "lungfishmhcref"
    public static let manifestFilename = MHCAmpliconReferenceBundleManifest.manifestFilename

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

    public static func manifestURL(in bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent(manifestFilename)
    }

    public static func loadManifest(from bundleURL: URL) throws -> MHCAmpliconReferenceBundleManifest {
        let data = try Data(contentsOf: manifestURL(in: bundleURL))
        return try JSONDecoder().decode(MHCAmpliconReferenceBundleManifest.self, from: data)
    }

    public static func writeManifest(
        _ manifest: MHCAmpliconReferenceBundleManifest,
        to bundleURL: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL(in: bundleURL), options: .atomic)
    }

    /// Confirms the bundle manifest references files that exist on disk and carries
    /// the expected schema version and kind.
    public static func validate(at bundleURL: URL) throws {
        let manifest = try loadManifest(from: bundleURL)
        guard manifest.kind == MHCAmpliconReferenceBundleManifest.kindIdentifier else {
            throw ReferenceBundleValidationError(
                kind: .kindMismatch(
                    expected: MHCAmpliconReferenceBundleManifest.kindIdentifier,
                    found: manifest.kind
                )
            )
        }
        let referencePath = bundleURL.appendingPathComponent(manifest.referenceFastaPath).path
        guard FileManager.default.fileExists(atPath: referencePath) else {
            throw ReferenceBundleValidationError(kind: .missingFile(referencePath))
        }
        for relativePath in manifest.haplotypeDefinitionPaths {
            let definitionPath = bundleURL.appendingPathComponent(relativePath).path
            guard FileManager.default.fileExists(atPath: definitionPath) else {
                throw ReferenceBundleValidationError(kind: .missingFile(definitionPath))
            }
        }
    }

    public static func referenceFASTAURL(in bundleURL: URL) -> URL? {
        guard let manifest = try? loadManifest(from: bundleURL) else { return nil }
        return bundleURL.appendingPathComponent(manifest.referenceFastaPath).standardizedFileURL
    }

    public static func haplotypeDefinitionURLs(in bundleURL: URL) -> [URL] {
        guard let manifest = try? loadManifest(from: bundleURL) else { return [] }
        return manifest.haplotypeDefinitionPaths
            .map { bundleURL.appendingPathComponent($0).standardizedFileURL }
    }

    public static func haplotypeDefinitions(in bundleURL: URL) throws -> [GenotypeHaplotypeDefinitionSet] {
        try haplotypeDefinitionURLs(in: bundleURL).map { url in
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(GenotypeHaplotypeDefinitionSet.self, from: data)
        }
    }

    public static func defaultHaplotypeDefinition(in bundleURL: URL) throws -> GenotypeHaplotypeDefinitionSet? {
        let manifest = try loadManifest(from: bundleURL)
        let definitions = try haplotypeDefinitions(in: bundleURL)
        guard let defaultID = manifest.defaultHaplotypeDefinitionID else {
            return definitions.first
        }
        return definitions.first { $0.id == defaultID }
    }

    public static func haplotypeDefinition(
        id: String,
        assayID: String? = nil,
        speciesCode: String? = nil,
        in bundleURL: URL
    ) throws -> GenotypeHaplotypeDefinitionSet? {
        try haplotypeDefinitions(in: bundleURL).first { definition in
            definition.id == id
                && (assayID == nil || definition.assayID == assayID)
                && (speciesCode == nil || definition.speciesCode.caseInsensitiveCompare(speciesCode ?? "") == .orderedSame)
        }
    }

    public static func provenanceURL(in bundleURL: URL) -> URL? {
        let url = bundleURL.appendingPathComponent(".lungfish-provenance.json")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
