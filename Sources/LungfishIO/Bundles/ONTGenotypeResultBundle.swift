import Foundation

public struct ONTGenotypeResultBundleManifest: Codable, Equatable, Sendable {
    public static let filename = "genotype-result.json"

    public let schemaVersion: Int
    public let kind: String
    public let outputName: String
    public let analysisName: String
    public let primaryWorkbookPath: String
    public let longSummaryCSVPath: String
    public let sampleSummaryCSVPath: String
    public let statsJSONPath: String
    public let provenancePath: String
    public let createdAt: String?

    public init(
        schemaVersion: Int = 1,
        kind: String = "ont-barcode-genotype",
        outputName: String,
        analysisName: String,
        primaryWorkbookPath: String,
        longSummaryCSVPath: String,
        sampleSummaryCSVPath: String,
        statsJSONPath: String,
        provenancePath: String,
        createdAt: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.outputName = outputName
        self.analysisName = analysisName
        self.primaryWorkbookPath = primaryWorkbookPath
        self.longSummaryCSVPath = longSummaryCSVPath
        self.sampleSummaryCSVPath = sampleSummaryCSVPath
        self.statsJSONPath = statsJSONPath
        self.provenancePath = provenancePath
        self.createdAt = createdAt
    }
}

public enum ONTGenotypeResultBundle {
    public static let directoryExtension = "lungfishgenotype"

    public static func isBundleURL(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == directoryExtension
    }

    public static func manifestURL(in bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent(ONTGenotypeResultBundleManifest.filename)
    }

    public static func loadManifest(from bundleURL: URL) throws -> ONTGenotypeResultBundleManifest {
        let data = try Data(contentsOf: manifestURL(in: bundleURL))
        return try JSONDecoder().decode(ONTGenotypeResultBundleManifest.self, from: data)
    }

    public static func writeManifest(
        _ manifest: ONTGenotypeResultBundleManifest,
        to bundleURL: URL
    ) throws {
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL(in: bundleURL), options: .atomic)
    }

    public static func primaryWorkbookURL(for bundleURL: URL) throws -> URL {
        let manifest = try loadManifest(from: bundleURL)
        return bundleURL
            .appendingPathComponent(manifest.primaryWorkbookPath)
            .standardizedFileURL
    }
}
