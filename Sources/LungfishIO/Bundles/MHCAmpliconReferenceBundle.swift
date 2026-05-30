import Foundation

public struct MHCAmpliconReferenceBundleSourceFile: Codable, Equatable, Sendable {
    public let path: String
    public let role: String
    public let originalPath: String?

    public init(path: String, role: String, originalPath: String? = nil) {
        self.path = path
        self.role = role
        self.originalPath = originalPath
    }
}

public struct MHCAmpliconReferenceBundleMetrics: Codable, Equatable, Sendable {
    public let referenceCount: Int
    public let haplotypeDefinitionCount: Int

    public init(referenceCount: Int, haplotypeDefinitionCount: Int) {
        self.referenceCount = referenceCount
        self.haplotypeDefinitionCount = haplotypeDefinitionCount
    }
}

public struct MHCAmpliconReferenceBundleManifest: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let name: String
    public let referenceFastaPath: String
    public let haplotypeDefinitionPaths: [String]
    public let defaultHaplotypeDefinitionID: String?
    public let sourceFiles: [MHCAmpliconReferenceBundleSourceFile]
    public let metrics: MHCAmpliconReferenceBundleMetrics
    public let provenancePath: String?
    public let createdAt: String

    public init(
        formatVersion: Int = 1,
        name: String,
        referenceFastaPath: String,
        haplotypeDefinitionPaths: [String],
        defaultHaplotypeDefinitionID: String?,
        sourceFiles: [MHCAmpliconReferenceBundleSourceFile] = [],
        metrics: MHCAmpliconReferenceBundleMetrics,
        provenancePath: String? = nil,
        createdAt: String
    ) {
        self.formatVersion = formatVersion
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
    public static let manifestFilename = "mhc-reference.json"

    public static func isBundleURL(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == directoryExtension
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
