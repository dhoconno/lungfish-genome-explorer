import Foundation

/// Factory helpers for authoring ephemeral on-disk fixtures used by IO-layer tests.
///
/// Each factory method creates a unique temporary directory under
/// `FileManager.default.temporaryDirectory` and returns the root URL. Callers are
/// responsible for cleanup if they care; the OS will eventually reap the directory.
enum TestWorkspace {
    /// Creates an empty `.lungfishprimers` directory (no manifest, no BED, no PROVENANCE).
    static func makeEmptyBundle(name: String) throws -> URL {
        let url = try makeUniqueDirectory().appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Creates a `.lungfishprimers` bundle that has only a valid manifest.json
    /// (no primers.bed, no PROVENANCE.md).
    static func makeBundleWithOnlyManifest() throws -> URL {
        let url = try makeEmptyBundle(name: "only-manifest.lungfishprimers")
        let manifestURL = url.appendingPathComponent("manifest.json")
        try validManifestJSON().write(to: manifestURL, options: .atomic)
        return url
    }

    /// Creates a `.lungfishprimers` bundle with a malformed manifest.json
    /// plus the other required files, so the loader gets past file-existence checks
    /// and fails inside manifest decoding.
    static func makeBundleWithMalformedManifest() throws -> URL {
        let url = try makeEmptyBundle(name: "malformed-manifest.lungfishprimers")
        let manifestURL = url.appendingPathComponent("manifest.json")
        try Data("{ not valid json".utf8).write(to: manifestURL, options: .atomic)

        let bedURL = url.appendingPathComponent("primers.bed")
        try Data("ref\t0\t10\tname\t60\t+\n".utf8).write(to: bedURL, options: .atomic)

        let provenanceURL = url.appendingPathComponent("PROVENANCE.md")
        try Data("# PROVENANCE\n".utf8).write(to: provenanceURL, options: .atomic)

        return url
    }

    // MARK: - Internals

    private static func makeUniqueDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LungfishIOTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func validManifestJSON() -> Data {
        let json = """
        {
          "schema_version": 1,
          "name": "tmp-bundle",
          "display_name": "Temp Bundle",
          "reference_accessions": [
            { "accession": "MN908947.3", "canonical": true }
          ],
          "primer_count": 0,
          "amplicon_count": 0
        }
        """
        return Data(json.utf8)
    }
}
