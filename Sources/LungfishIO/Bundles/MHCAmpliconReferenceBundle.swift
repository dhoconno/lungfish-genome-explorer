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

public struct MHCReferenceBundleWarning: Codable, Equatable, Sendable {
    public let category: String
    public let message: String
    public let recordIdentifier: String?
    public let featureType: String?
    public let sourceLocation: String?

    public init(
        category: String,
        message: String,
        recordIdentifier: String? = nil,
        featureType: String? = nil,
        sourceLocation: String? = nil
    ) {
        self.category = category
        self.message = message
        self.recordIdentifier = recordIdentifier
        self.featureType = featureType
        self.sourceLocation = sourceLocation
    }
}

public struct MHCAmpliconReferenceBundleManifest: ReferenceBundleManifesting {
    public static let manifestFilename = "mhc-reference.json"
    public static let kindIdentifier = "mhc-reference"

    public let schemaVersion: Int
    public let kind: String
    public let name: String
    public let referenceFastaPath: String
    /// Embedded standard `.lungfishref` bundle. Present and required in schema v2.
    public let referenceBundlePath: String?
    public let haplotypeDefinitionPaths: [String]
    public let defaultHaplotypeDefinitionID: String?
    public let sourceFiles: [MHCAmpliconReferenceBundleSourceFile]
    public let metrics: MHCAmpliconReferenceBundleMetrics
    public let provenancePath: String?
    /// Recoverable source-import problems retained for display in the app.
    public let warnings: [MHCReferenceBundleWarning]
    public let createdAt: String

    public init(
        schemaVersion: Int = 1,
        kind: String = MHCAmpliconReferenceBundleManifest.kindIdentifier,
        name: String,
        referenceFastaPath: String,
        referenceBundlePath: String? = nil,
        haplotypeDefinitionPaths: [String],
        defaultHaplotypeDefinitionID: String?,
        sourceFiles: [MHCAmpliconReferenceBundleSourceFile] = [],
        metrics: MHCAmpliconReferenceBundleMetrics,
        provenancePath: String? = nil,
        warnings: [MHCReferenceBundleWarning] = [],
        createdAt: String
    ) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.name = name
        self.referenceFastaPath = referenceFastaPath
        self.referenceBundlePath = referenceBundlePath
        self.haplotypeDefinitionPaths = haplotypeDefinitionPaths
        self.defaultHaplotypeDefinitionID = defaultHaplotypeDefinitionID
        self.sourceFiles = sourceFiles
        self.metrics = metrics
        self.provenancePath = provenancePath
        self.warnings = warnings
        self.createdAt = createdAt
    }

    /// Source- and binary-compatible initializer retained for schema-v1 clients.
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
        self.init(
            schemaVersion: schemaVersion,
            kind: kind,
            name: name,
            referenceFastaPath: referenceFastaPath,
            referenceBundlePath: nil,
            haplotypeDefinitionPaths: haplotypeDefinitionPaths,
            defaultHaplotypeDefinitionID: defaultHaplotypeDefinitionID,
            sourceFiles: sourceFiles,
            metrics: metrics,
            provenancePath: provenancePath,
            warnings: [],
            createdAt: createdAt
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, kind, name, referenceFastaPath, referenceBundlePath
        case haplotypeDefinitionPaths, defaultHaplotypeDefinitionID, sourceFiles
        case metrics, provenancePath, warnings, createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        kind = try container.decode(String.self, forKey: .kind)
        name = try container.decode(String.self, forKey: .name)
        referenceFastaPath = try container.decode(String.self, forKey: .referenceFastaPath)
        referenceBundlePath = try container.decodeIfPresent(String.self, forKey: .referenceBundlePath)
        haplotypeDefinitionPaths = try container.decode([String].self, forKey: .haplotypeDefinitionPaths)
        defaultHaplotypeDefinitionID = try container.decodeIfPresent(String.self, forKey: .defaultHaplotypeDefinitionID)
        sourceFiles = try container.decodeIfPresent(
            [MHCAmpliconReferenceBundleSourceFile].self,
            forKey: .sourceFiles
        ) ?? []
        metrics = try container.decode(MHCAmpliconReferenceBundleMetrics.self, forKey: .metrics)
        provenancePath = try container.decodeIfPresent(String.self, forKey: .provenancePath)
        warnings = try container.decodeIfPresent([MHCReferenceBundleWarning].self, forKey: .warnings) ?? []
        createdAt = try container.decode(String.self, forKey: .createdAt)
    }
}

public enum MHCAmpliconReferenceBundle {
    public static let directoryExtension = "lungfishmhcref"
    public static let manifestFilename = MHCAmpliconReferenceBundleManifest.manifestFilename
    private static let supportedSchemaVersions = 1...2
    private static let currentSchemaVersion = 2

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
        guard supportedSchemaVersions.contains(manifest.schemaVersion) else {
            throw ReferenceBundleValidationError(
                kind: .schemaMismatch(
                    expected: currentSchemaVersion,
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
        if manifest.schemaVersion >= 2 {
            guard let embeddedReferenceURL = try validatedEmbeddedReferenceBundleURL(
                manifest: manifest,
                in: bundleURL
            ) else {
                throw ReferenceBundleValidationError(kind: .missingFile("referenceBundlePath"))
            }
            try validateEmbeddedReferenceBundle(at: embeddedReferenceURL)
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

    public static func referenceBundleURL(in bundleURL: URL) -> URL? {
        guard let manifest = try? loadManifest(from: bundleURL),
              isSupported(manifest),
              let url = try? validatedEmbeddedReferenceBundleURL(manifest: manifest, in: bundleURL),
              FileManager.default.fileExists(atPath: url.appendingPathComponent(BundleManifest.filename).path)
        else { return nil }
        return url
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
                    expected: currentSchemaVersion,
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
        supportedSchemaVersions.contains(manifest.schemaVersion)
            && manifest.kind == MHCAmpliconReferenceBundleManifest.kindIdentifier
    }

    private static func validatedEmbeddedReferenceBundleURL(
        manifest: MHCAmpliconReferenceBundleManifest,
        in bundleURL: URL
    ) throws -> URL? {
        guard let relativePath = manifest.referenceBundlePath else { return nil }
        return try validatedBundleMemberURL(relativePath, in: bundleURL, field: "referenceBundlePath")
    }

    private static func validateEmbeddedReferenceBundle(at embeddedURL: URL) throws {
        guard embeddedURL.pathExtension.lowercased() == "lungfishref" else {
            throw ReferenceBundleValidationError(kind: .missingFile(embeddedURL.path))
        }
        let embeddedManifest: BundleManifest
        do {
            embeddedManifest = try BundleManifest.load(from: embeddedURL)
        } catch {
            throw ReferenceBundleValidationError(
                kind: .missingFile(embeddedURL.appendingPathComponent(BundleManifest.filename).path)
            )
        }
        guard embeddedManifest.validate().isEmpty, let genome = embeddedManifest.genome else {
            throw ReferenceBundleValidationError(kind: .missingFile(embeddedURL.path))
        }
        var requiredPaths = [genome.path, genome.indexPath]
        if let gzipIndexPath = genome.gzipIndexPath { requiredPaths.append(gzipIndexPath) }
        for annotation in embeddedManifest.annotations {
            requiredPaths.append(annotation.path)
            if let databasePath = annotation.databasePath { requiredPaths.append(databasePath) }
        }
        for path in requiredPaths {
            let url: URL
            do {
                url = try BundleManifest.validatedBundleMemberURL(for: path, in: embeddedURL, field: path)
            } catch {
                throw ReferenceBundleValidationError(kind: .missingFile(path))
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ReferenceBundleValidationError(kind: .missingFile(url.path))
            }
        }
    }
}
