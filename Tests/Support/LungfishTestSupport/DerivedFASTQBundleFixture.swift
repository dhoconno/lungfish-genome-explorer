import Foundation
import LungfishIO

/// A project with a root FASTQ bundle of three reads and a virtual oriented
/// bundle over it: read 1 forward, read 3 reverse-complemented, read 2 not
/// mapped. Like bundles the app writes, the oriented bundle's own
/// `preview.fastq` holds only its first read. A tool reading the resolver's
/// root file sees all three original reads, one reading the bundle's own FASTQ
/// sees only read 1, and a correct tool sees read1 and read3 (reverse
/// complemented). Orient materialization is pure Swift, so no tools are needed.
public struct DerivedFASTQBundleFixture: Sendable {
    public let projectURL: URL
    public let rootBundleURL: URL
    public let derivedBundleURL: URL

    public static let read1 = "@read1\nACGTACGTAC\n+\nIIIIIIIIII\n"
    public static let read2 = "@read2\nGGGGCCCCAA\n+\nIIIIIIIIII\n"
    public static let read3 = "@read3\nTTTTAAAACC\n+\nIIIIIIIIII\n"

    public static func make(in directory: URL) throws -> DerivedFASTQBundleFixture {
        let fm = FileManager.default
        let project = directory.appendingPathComponent("Project.lungfish", isDirectory: true)
        let imports = project.appendingPathComponent("Imports", isDirectory: true)
        let root = imports.appendingPathComponent("pooled.lungfishfastq", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try (read1 + read2 + read3).write(
            to: root.appendingPathComponent("pooled.fastq"), atomically: true, encoding: .utf8)

        let derived = imports.appendingPathComponent("pooled-oriented.lungfishfastq", isDirectory: true)
        try fm.createDirectory(at: derived, withIntermediateDirectories: true)
        try "read1\t+\nread3\t-\n".write(
            to: derived.appendingPathComponent("orient-map.tsv"), atomically: true, encoding: .utf8)
        try read1.write(to: derived.appendingPathComponent("preview.fastq"), atomically: true, encoding: .utf8)
        let operation = FASTQDerivativeOperation(kind: .orient)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "pooled-oriented",
                parentBundleRelativePath: "@/Imports/pooled.lungfishfastq",
                rootBundleRelativePath: "@/Imports/pooled.lungfishfastq",
                rootFASTQFilename: "pooled.fastq",
                payload: .orientMap(orientMapFilename: "orient-map.tsv", previewFilename: "preview.fastq"),
                lineage: [operation],
                operation: operation,
                cachedStatistics: .placeholder(readCount: 2, baseCount: 20),
                pairingMode: .singleEnd,
                sequenceFormat: .fastq
            ),
            in: derived
        )
        return DerivedFASTQBundleFixture(projectURL: project, rootBundleURL: root, derivedBundleURL: derived)
    }

    /// The reverse complement of read 3's sequence, as a correct tool sees it.
    public static let read3ReverseComplement = "GGTTTTAAAA"

    /// Read names in a FASTQ file, in order.
    public static func readNames(in fastqURL: URL) throws -> [String] {
        try String(contentsOf: fastqURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { index, line in index % 4 == 0 && line.hasPrefix("@") ? String(line.dropFirst()) : nil }
    }
}
