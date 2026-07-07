import Foundation
import LungfishCore

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
    private static let supportedSchemaVersion = 1

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
        guard manifest.schemaVersion == supportedSchemaVersion else {
            throw ReferenceBundleValidationError(
                kind: .schemaMismatch(
                    expected: supportedSchemaVersion,
                    found: manifest.schemaVersion
                )
            )
        }
        guard manifest.kind == MHCAmpliconReferenceBundleManifest.kindIdentifier else {
            throw ReferenceBundleValidationError(
                kind: .kindMismatch(
                    expected: MHCAmpliconReferenceBundleManifest.kindIdentifier,
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
        for relativePath in manifest.haplotypeDefinitionPaths {
            let definitionURL = try validatedBundleMemberURL(
                relativePath,
                in: bundleURL,
                field: "haplotypeDefinitionPaths[]"
            )
            guard FileManager.default.fileExists(atPath: definitionURL.path) else {
                throw ReferenceBundleValidationError(kind: .missingFile(definitionURL.path))
            }
        }
        if let provenancePath = manifest.provenancePath {
            _ = try validatedBundleMemberURL(
                provenancePath,
                in: bundleURL,
                field: "provenancePath",
                allowReservedControlPath: true
            )
        }
    }

    public static func referenceFASTAURL(in bundleURL: URL) -> URL? {
        guard let manifest = try? loadManifest(from: bundleURL),
              isSupported(manifest) else { return nil }
        return try? validatedBundleMemberURL(
            manifest.referenceFastaPath,
            in: bundleURL,
            field: "referenceFastaPath"
        )
    }

    public static func haplotypeDefinitionURLs(in bundleURL: URL) -> [URL] {
        (try? validatedHaplotypeDefinitionURLs(in: bundleURL)) ?? []
    }

    public static func haplotypeDefinitions(in bundleURL: URL) throws -> [GenotypeHaplotypeDefinitionSet] {
        try validatedHaplotypeDefinitionURLs(in: bundleURL).map { url in
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

    private static func validatedHaplotypeDefinitionURLs(in bundleURL: URL) throws -> [URL] {
        let manifest = try loadManifest(from: bundleURL)
        guard isSupported(manifest) else {
            throw ReferenceBundleValidationError(
                kind: .schemaMismatch(
                    expected: supportedSchemaVersion,
                    found: manifest.schemaVersion
                )
            )
        }
        guard manifest.kind == MHCAmpliconReferenceBundleManifest.kindIdentifier else {
            throw ReferenceBundleValidationError(
                kind: .kindMismatch(
                    expected: MHCAmpliconReferenceBundleManifest.kindIdentifier,
                    found: manifest.kind
                )
            )
        }
        return try manifest.haplotypeDefinitionPaths.map {
            try validatedBundleMemberURL($0, in: bundleURL, field: "haplotypeDefinitionPaths[]")
        }
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

    private static func isSupported(_ manifest: MHCAmpliconReferenceBundleManifest) -> Bool {
        manifest.schemaVersion == supportedSchemaVersion
            && manifest.kind == MHCAmpliconReferenceBundleManifest.kindIdentifier
    }
}
