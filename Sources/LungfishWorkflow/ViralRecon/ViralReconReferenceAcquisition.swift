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

        public var errorDescription: String? {
            switch self {
            case .downloadProducedNoBundle(let accession):
                return "Downloading \(accession) did not produce a reference bundle."
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
        return .downloaded(bundleURL)
    }
}
