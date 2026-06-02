import Foundation

public enum ResultBundleSampleMetadataResolver {
    public static func knownSampleIDs(in bundleURL: URL) throws -> Set<String> {
        let fm = FileManager.default

        if isTwelveSAmpliconResultBundle(bundleURL) {
            let sampleIDs = try TwelveSAmpliconResultBundle.sampleIDs(in: bundleURL)
            if !sampleIDs.isEmpty {
                return sampleIDs
            }
        }

        let naoMgsDB = bundleURL.appendingPathComponent("hits.sqlite")
        if fm.fileExists(atPath: naoMgsDB.path) {
            let db = try NaoMgsDatabase(at: naoMgsDB)
            return Set(try db.fetchSamples().map(\.sample))
        }

        let kraken2DB = bundleURL.appendingPathComponent("kraken2.sqlite")
        if fm.fileExists(atPath: kraken2DB.path) {
            let db = try Kraken2Database(at: kraken2DB)
            return Set(try db.fetchSamples().map(\.sample))
        }

        let esvirituDB = bundleURL.appendingPathComponent("esviritu.sqlite")
        if fm.fileExists(atPath: esvirituDB.path) {
            let db = try EsVirituDatabase(at: esvirituDB)
            return Set(try db.fetchSamples().map(\.sample))
        }

        let taxTriageDB = bundleURL.appendingPathComponent("taxtriage.sqlite")
        if fm.fileExists(atPath: taxTriageDB.path) {
            let db = try TaxTriageDatabase(at: taxTriageDB)
            return Set(try db.fetchSamples().map(\.sample))
        }

        return fallbackSampleSubdirectories(in: bundleURL)
    }

    public static func sampleMetadataContextFiles(in bundleURL: URL) -> [URL] {
        var candidates = [
            bundleURL.appendingPathComponent(TwelveSAmpliconResultBundleManifest.filename),
            bundleURL.appendingPathComponent("samples.tsv"),
            bundleURL.appendingPathComponent("genotype-result.json"),
            bundleURL.appendingPathComponent("manifest.json"),
            bundleURL.appendingPathComponent("hits.sqlite"),
            bundleURL.appendingPathComponent("kraken2.sqlite"),
            bundleURL.appendingPathComponent("esviritu.sqlite"),
            bundleURL.appendingPathComponent("taxtriage.sqlite"),
        ]

        if let manifest = try? TwelveSAmpliconResultBundle.loadManifest(from: bundleURL) {
            candidates.append(TwelveSAmpliconResultBundle.resolvedURL(for: manifest.sampleTablePath, in: bundleURL))
        }

        return existingUniqueFiles(candidates)
    }

    private static func isTwelveSAmpliconResultBundle(_ bundleURL: URL) -> Bool {
        TwelveSAmpliconResultBundle.isBundleURL(bundleURL)
            || FileManager.default.fileExists(
                atPath: bundleURL.appendingPathComponent(TwelveSAmpliconResultBundleManifest.filename).path
            )
    }

    private static func fallbackSampleSubdirectories(in bundleURL: URL) -> Set<String> {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(
            at: bundleURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        let excluded = Set([
            "metadata",
            "references",
            "bams",
            "genome",
            "indexes",
            "tmp",
        ])
        let subdirs = contents.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                && !url.lastPathComponent.hasPrefix(".")
                && !excluded.contains(url.lastPathComponent)
        }
        return Set(subdirs.map(\.lastPathComponent))
    }

    private static func existingUniqueFiles(_ candidates: [URL]) -> [URL] {
        var seen = Set<String>()
        var files: [URL] = []
        for candidate in candidates {
            let standardized = candidate.standardizedFileURL
            guard FileManager.default.fileExists(atPath: standardized.path) else { continue }
            guard seen.insert(standardized.path).inserted else { continue }
            files.append(standardized)
        }
        return files
    }
}
