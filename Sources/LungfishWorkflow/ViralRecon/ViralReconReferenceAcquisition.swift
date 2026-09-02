import Foundation

/// Obtains the canonical SARS-CoV-2 reference bundle for a Viral Recon run.
///
/// There are exactly two outcomes: the project already holds
/// `Downloads/MN908947.3.lungfishref`, or it is downloaded. No other bundle in
/// the project is inspected, matched or substituted.
public enum ViralReconReferenceAcquisition {
    public enum Outcome: Equatable, Sendable {
        case alreadyPresent(URL)
        case downloaded(URL)

        /// The bundle to hand to the pipeline, whichever way it was obtained.
        public var bundleURL: URL {
            switch self {
            case .alreadyPresent(let url), .downloaded(let url): return url
            }
        }
    }

    public enum AcquisitionError: Error, LocalizedError, Equatable {
        case downloadProducedNoBundle(String)
        case sequenceIdentifierMismatch(expected: String, found: String)

        public var errorDescription: String? {
            switch self {
            case .downloadProducedNoBundle(let accession):
                return "Downloading \(accession) did not produce a reference bundle."
            case .sequenceIdentifierMismatch(let expected, let found):
                return """
                    The downloaded reference is \(found), not \(expected). \
                    The primer scheme is written against \(expected), so trimming \
                    would match nothing. Remove the bundle and retry.
                    """
            }
        }
    }

    /// Downloads `accession` into `destinationDirectory`.
    public typealias Downloader = (_ accession: String, _ destinationDirectory: URL) throws -> Void

    public static func acquire(
        projectURL: URL,
        downloader: Downloader,
        fileManager: FileManager = .default
    ) throws -> Outcome {
        let bundleURL = ViralReconReferenceCatalog.bundleURL(inProject: projectURL)
        if fileManager.fileExists(atPath: bundleURL.path) {
            return .alreadyPresent(bundleURL)
        }

        let downloadsURL = bundleURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: downloadsURL, withIntermediateDirectories: true)
        try downloader(ViralReconReferenceCatalog.canonicalAccession, downloadsURL)

        guard fileManager.fileExists(atPath: bundleURL.path) else {
            throw AcquisitionError.downloadProducedNoBundle(
                ViralReconReferenceCatalog.canonicalAccession)
        }
        // A bundle named for the canonical accession can still hold a different
        // sequence: `fetch genome` resolves through the NCBI assembly database,
        // which returns the linked RefSeq record for a GenBank accession. The
        // name would pass an existence check while every primer BED line failed
        // to match, so the identifier is checked here rather than trusted.
        if let found = sequenceIdentifier(inBundleAt: bundleURL, fileManager: fileManager),
           found != ViralReconReferenceCatalog.canonicalAccession {
            throw AcquisitionError.sequenceIdentifierMismatch(
                expected: ViralReconReferenceCatalog.canonicalAccession, found: found)
        }
        return .downloaded(bundleURL)
    }

    /// The sequence name a bundle actually carries, read from the FASTA index.
    ///
    /// Returns nil when there is no index to read, leaving the bundle to the
    /// pipeline rather than refusing it on absent evidence.
    static func sequenceIdentifier(
        inBundleAt bundleURL: URL,
        fileManager: FileManager = .default
    ) -> String? {
        let genome = bundleURL.appendingPathComponent("genome", isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(atPath: genome.path) else {
            return nil
        }
        guard let index = entries.first(where: { $0.hasSuffix(".fai") }) else { return nil }
        guard let contents = try? String(contentsOf: genome.appendingPathComponent(index),
                                         encoding: .utf8) else { return nil }
        guard let first = contents.split(separator: "\n").first else { return nil }
        let name = first.split(separator: "\t").first.map(String.init)
        return name?.isEmpty == false ? name : nil
    }
}
