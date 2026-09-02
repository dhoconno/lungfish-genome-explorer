import Foundation
import LungfishIO

/// Builds the analysis bundle the sidebar and viewport consume.
///
/// The raw nf-core output is preserved rather than moved, so provenance stays
/// verifiable against what the pipeline actually wrote.
public enum ViralReconResultIngest {
    public struct Ingested: Sendable, Equatable {
        public let bundleDirectory: URL
        public let referenceBundleURL: URL
        public let inventory: ViralReconResultInventory

        public init(bundleDirectory: URL, referenceBundleURL: URL, inventory: ViralReconResultInventory) {
            self.bundleDirectory = bundleDirectory
            self.referenceBundleURL = referenceBundleURL
            self.inventory = inventory
        }
    }

    public enum IngestError: Error, LocalizedError, Equatable {
        case referenceBundleMissing

        public var errorDescription: String? {
            switch self {
            case .referenceBundleMissing:
                return "The Viral Recon reference bundle is missing."
            }
        }
    }

    public static func ingest(
        resultsDirectory: URL,
        sampleName: String,
        referenceBundleURL: URL,
        into bundleDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> Ingested {
        guard fileManager.fileExists(atPath: referenceBundleURL.path) else {
            throw IngestError.referenceBundleMissing
        }

        try fileManager.createDirectory(at: bundleDirectory, withIntermediateDirectories: true)

        let destinationReference = bundleDirectory
            .appendingPathComponent(referenceBundleURL.lastPathComponent, isDirectory: true)
        if !fileManager.fileExists(atPath: destinationReference.path) {
            try fileManager.copyItem(at: referenceBundleURL, to: destinationReference)
        }

        let metadata: [String: Any] = [
            "tool": "viralrecon",
            "isBatch": false,
            "created": ISO8601DateFormatter().string(from: Date()),
        ]
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            .write(to: bundleDirectory.appendingPathComponent("analysis-metadata.json"))

        let inventory = ViralReconResultInventory.discover(in: resultsDirectory,
                                                          sampleName: sampleName)
        return Ingested(bundleDirectory: bundleDirectory,
                        referenceBundleURL: destinationReference,
                        inventory: inventory)
    }

    /// Ingests a finished run into the project's `Analyses/` directory.
    ///
    /// This is the only entry point the launch path should use. The bundle has
    /// to land under `Analyses/` in the shape `SidebarProjectScanner` already
    /// understands, otherwise the run is invisible however complete it is;
    /// writing it anywhere else (for example inside the `.lungfishrun` bundle)
    /// produces a directory nothing ever scans.
    ///
    /// A single-sample run becomes one analysis directory. A multi-sample run
    /// becomes one batch directory with a per-sample subdirectory, which is the
    /// contract the sidebar's generic batch node already renders.
    public static func ingestRun(
        resultsDirectory: URL,
        sampleNames: [String],
        referenceBundleURL: URL,
        projectURL: URL,
        fileManager: FileManager = .default
    ) throws -> [Ingested] {
        guard sampleNames.count != 1 else {
            guard fileManager.fileExists(atPath: referenceBundleURL.path) else {
                throw IngestError.referenceBundleMissing
            }
            let directory = try AnalysesFolder.createAnalysisDirectory(
                tool: "viralrecon",
                in: projectURL,
                isBatch: false
            )
            return [try ingest(
                resultsDirectory: resultsDirectory,
                sampleName: sampleNames[0],
                referenceBundleURL: referenceBundleURL,
                into: directory,
                fileManager: fileManager
            )]
        }

        return try ingestBatch(
            resultsDirectory: resultsDirectory,
            sampleNames: sampleNames,
            referenceBundleURL: referenceBundleURL,
            projectURL: projectURL,
            fileManager: fileManager
        )
    }

    /// Ingests every sample of a multi-sample run into one batch directory.
    ///
    /// Samples get one bundle each, on the contract other batch tools already
    /// use, so the sidebar renders a batch node without a new node type and the
    /// layered viewport behaves the same whether one sample ran or twenty.
    ///
    /// The reference is acquired once for the batch: every sample in a Viral
    /// Recon run aligns to the same hard-coded SARS-CoV-2 genome.
    public static func ingestBatch(
        resultsDirectory: URL,
        sampleNames: [String],
        referenceBundleURL: URL,
        projectURL: URL,
        fileManager: FileManager = .default
    ) throws -> [Ingested] {
        guard fileManager.fileExists(atPath: referenceBundleURL.path) else {
            throw IngestError.referenceBundleMissing
        }

        let batchDirectory = try AnalysesFolder.createAnalysisDirectory(
            tool: "viralrecon",
            in: projectURL,
            isBatch: true
        )

        return try sampleNames.map { sampleName in
            try ingest(
                resultsDirectory: resultsDirectory,
                sampleName: sampleName,
                referenceBundleURL: referenceBundleURL,
                into: batchDirectory.appendingPathComponent(
                    TaxTriageSerialBatchRunner.sanitizedDirectoryName(for: sampleName),
                    isDirectory: true
                ),
                fileManager: fileManager
            )
        }
    }
}
