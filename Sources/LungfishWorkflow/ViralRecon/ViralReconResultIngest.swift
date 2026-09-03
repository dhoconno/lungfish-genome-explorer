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
        /// A run with no samples at all. Refused rather than ingested as an
        /// empty batch: an empty batch directory litters `Analyses/` and
        /// reports success for a run that produced nothing to view.
        case noSamples

        public var errorDescription: String? {
            switch self {
            case .referenceBundleMissing:
                return "The Viral Recon reference bundle is missing."
            case .noSamples:
                return "The Viral Recon run listed no samples, so there are no "
                    + "results to add to the project."
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
        let copied = try copyOutputsByRole(inventory,
                                           into: bundleDirectory,
                                           fileManager: fileManager)
        try writeResultSidecar(
            inventory: inventory,
            copied: copied,
            referenceBundleURL: destinationReference,
            resultsDirectory: resultsDirectory,
            into: bundleDirectory
        )
        return Ingested(bundleDirectory: bundleDirectory,
                        referenceBundleURL: destinationReference,
                        inventory: inventory)
    }

    /// The paths, relative to the bundle, of the outputs copied by role.
    private struct CopiedOutputs {
        var consensus: String?
        var lineage: [String] = []
        var reports: [String] = []
    }

    /// Copies the sample's outputs into `consensus/`, `lineage/` and `reports/`.
    ///
    /// The bundle is self-contained on purpose: the raw nf-core tree stays put
    /// as provenance, but a bundle that only points into it stops working the
    /// moment that tree is moved or cleaned up. The role directories are always
    /// created, even when empty, so the bundle has one predictable shape and a
    /// reader can tell "the step produced nothing" from "the bundle is
    /// truncated".
    private static func copyOutputsByRole(
        _ inventory: ViralReconResultInventory,
        into bundleDirectory: URL,
        fileManager: FileManager
    ) throws -> CopiedOutputs {
        var copied = CopiedOutputs()

        for role in ["consensus", "lineage", "reports"] {
            try fileManager.createDirectory(
                at: bundleDirectory.appendingPathComponent(role, isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        // Two distinct outputs can share a filename: mosdepth writes the
        // per-amplicon and whole-genome coverage tables under sibling
        // directories, both named `<sample>.mosdepth.coverage.tsv`. Keying the
        // destination on the last path component alone dropped the second and
        // reported the first's path for it, silently losing the amplicon
        // dropout view. A colliding name is therefore qualified by the source
        // directory rather than skipped.
        var usedRelativePaths: Set<String> = []
        func copy(_ source: URL, role: String) throws -> String? {
            guard fileManager.fileExists(atPath: source.path) else { return nil }
            var name = source.lastPathComponent
            var relative = "\(role)/\(name)"
            if usedRelativePaths.contains(relative) {
                let qualifier = source.deletingLastPathComponent().lastPathComponent
                name = "\(qualifier)-\(name)"
                relative = "\(role)/\(name)"
            }
            let destination = bundleDirectory.appendingPathComponent(relative)
            guard !fileManager.fileExists(atPath: destination.path) else {
                usedRelativePaths.insert(relative)
                return relative
            }
            try fileManager.copyItem(at: source, to: destination)
            usedRelativePaths.insert(relative)
            return relative
        }

        if let consensus = inventory.consensusFASTA {
            copied.consensus = try copy(consensus, role: "consensus")
        }
        for lineage in inventory.lineageFiles {
            if let relative = try copy(lineage, role: "lineage") {
                copied.lineage.append(relative)
            }
        }
        for report in inventory.reportFiles {
            if let relative = try copy(report, role: "reports") {
                copied.reports.append(relative)
            }
        }
        return copied
    }

    /// Writes `viralrecon-result.json`, the summary sidecar analogous to
    /// `mapping-result.json`.
    ///
    /// Paths are recorded relative to the bundle so the bundle stays valid when
    /// the project is moved; the raw results directory is recorded absolutely
    /// because it deliberately lives outside the bundle.
    private static func writeResultSidecar(
        inventory: ViralReconResultInventory,
        copied: CopiedOutputs,
        referenceBundleURL: URL,
        resultsDirectory: URL,
        into bundleDirectory: URL
    ) throws {
        var json: [String: Any] = [
            "schemaVersion": 1,
            "tool": "viralrecon",
            "sampleName": inventory.sampleName,
            "referenceBundlePath": referenceBundleURL.lastPathComponent,
            "rawResultsPath": resultsDirectory.path,
            "lineagePaths": copied.lineage,
            "reportPaths": copied.reports,
        ]
        if let consensus = copied.consensus {
            json["consensusPath"] = consensus
        }
        if let bam = inventory.sortedBAM {
            json["alignmentPath"] = bam.path
        }
        if let vcf = inventory.variantVCF {
            json["variantsPath"] = vcf.path
        }

        let data = try JSONSerialization.data(withJSONObject: json,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: bundleDirectory.appendingPathComponent("viralrecon-result.json"),
                       options: .atomic)
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
        // Checked before the batch path, which would otherwise create an empty
        // batch directory for a run that has nothing to ingest.
        guard !sampleNames.isEmpty else {
            throw IngestError.noSamples
        }

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
        guard !sampleNames.isEmpty else {
            throw IngestError.noSamples
        }
        guard fileManager.fileExists(atPath: referenceBundleURL.path) else {
            throw IngestError.referenceBundleMissing
        }

        let batchDirectory = try AnalysesFolder.createAnalysisDirectory(
            tool: "viralrecon",
            in: projectURL,
            isBatch: true
        )

        // Deduped, not merely sanitized: "S 1" and "S_1" both sanitize to
        // "S_1", and the second sample would then write into the first
        // sample's directory, where copy() returns early because the
        // destination exists. Sample 2 would silently inherit sample 1's
        // consensus and reports, attributing one sample's result to another.
        var usedNames: Set<String> = []
        return try sampleNames.map { sampleName in
            let directoryName = TaxTriageSerialBatchRunner.uniqueDirectoryName(
                for: sampleName,
                usedNames: &usedNames
            )
            return try ingest(
                resultsDirectory: resultsDirectory,
                sampleName: sampleName,
                referenceBundleURL: referenceBundleURL,
                into: batchDirectory.appendingPathComponent(directoryName, isDirectory: true),
                fileManager: fileManager
            )
        }
    }
}
