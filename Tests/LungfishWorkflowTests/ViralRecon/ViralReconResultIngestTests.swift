import LungfishIO
import XCTest
@testable import LungfishWorkflow

final class ViralReconResultIngestTests: XCTestCase {
    private var root: URL!
    private var results: URL!
    private var referenceBundle: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vr-ingest-\(UUID().uuidString)", isDirectory: true)
        results = root.appendingPathComponent("results", isDirectory: true)
        referenceBundle = root.appendingPathComponent("MN908947.3.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: referenceBundle, withIntermediateDirectories: true)
        try Data().write(to: referenceBundle.appendingPathComponent("manifest.json"))
        for relative in ["variants/bowtie2/S1.sorted.bam",
                         "variants/bowtie2/S1.sorted.bam.bai",
                         "variants/ivar/S1.vcf.gz",
                         "variants/ivar/consensus/bcftools/S1.consensus.fa"] {
            let url = results.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data().write(to: url)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCreatesBundleContainingReferenceAndPreservesRawOutput() throws {
        let destination = root.appendingPathComponent("Analyses/Viral Recon", isDirectory: true)

        let ingested = try ViralReconResultIngest.ingest(
            resultsDirectory: results,
            sampleName: "S1",
            referenceBundleURL: referenceBundle,
            into: destination)

        let fileManager = FileManager.default
        XCTAssertTrue(fileManager.fileExists(atPath: ingested.referenceBundleURL.path))
        XCTAssertEqual(ingested.referenceBundleURL.lastPathComponent, "MN908947.3.lungfishref")
        // Raw nf-core output is preserved, not moved.
        XCTAssertTrue(fileManager.fileExists(
            atPath: results.appendingPathComponent("variants/bowtie2/S1.sorted.bam").path))
    }

    func testWritesAnalysisMetadataIdentifyingTheTool() throws {
        let destination = root.appendingPathComponent("Analyses/Viral Recon", isDirectory: true)
        let ingested = try ViralReconResultIngest.ingest(
            resultsDirectory: results, sampleName: "S1",
            referenceBundleURL: referenceBundle, into: destination)

        let metadataURL = ingested.bundleDirectory.appendingPathComponent("analysis-metadata.json")
        let json = try JSONSerialization.jsonObject(
            with: Data(contentsOf: metadataURL)) as? [String: Any]
        XCTAssertEqual(json?["tool"] as? String, "viralrecon")
    }

    func testMissingReferenceBundleThrows() {
        let destination = root.appendingPathComponent("Analyses/Viral Recon", isDirectory: true)
        XCTAssertThrowsError(
            try ViralReconResultIngest.ingest(
                resultsDirectory: results, sampleName: "S1",
                referenceBundleURL: root.appendingPathComponent("absent.lungfishref"),
                into: destination)
        ) { error in
            XCTAssertEqual(error as? ViralReconResultIngest.IngestError, .referenceBundleMissing)
        }
    }

    func testBatchCreatesOneSanitizedSubdirectoryPerSample() throws {
        for sample in ["S1", "S 2"] {
            for relative in ["variants/bowtie2/\(sample).sorted.bam"] {
                let url = results.appendingPathComponent(relative)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try Data().write(to: url)
            }
        }
        let project = root.appendingPathComponent("P.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let ingested = try ViralReconResultIngest.ingestBatch(
            resultsDirectory: results,
            sampleNames: ["S1", "S 2"],
            referenceBundleURL: referenceBundle,
            projectURL: project)

        XCTAssertEqual(ingested.count, 2)
        let parents = Set(ingested.map { $0.bundleDirectory.deletingLastPathComponent().path })
        XCTAssertEqual(parents.count, 1, "all samples share one batch directory")
        for entry in ingested {
            XCTAssertFalse(entry.bundleDirectory.lastPathComponent.contains(" "),
                           "sample directory names are sanitized")
        }
    }

    // M-2: sanitization is lossy. "S 1" and "S_1" both collapse to "S_1", so
    // the second sample wrote into the first sample's directory, copy() bailed
    // out because the destination already existed, and sample 2 silently
    // inherited sample 1's consensus and reports. That is a wrong scientific
    // result attributed to the wrong sample, so the names must be deduped.
    func testCollidingSampleNamesGetDistinctDirectories() throws {
        for sample in ["S 1", "S_1"] {
            for relative in ["variants/bowtie2/\(sample).sorted.bam",
                             "variants/ivar/consensus/bcftools/\(sample).consensus.fa"] {
                let url = results.appendingPathComponent(relative)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try Data("\(sample) consensus".utf8).write(to: url)
            }
        }
        let project = root.appendingPathComponent("PCollide.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let ingested = try ViralReconResultIngest.ingestBatch(
            resultsDirectory: results,
            sampleNames: ["S 1", "S_1"],
            referenceBundleURL: referenceBundle,
            projectURL: project)

        XCTAssertEqual(ingested.count, 2)
        let directories = ingested.map { $0.bundleDirectory.path }
        XCTAssertEqual(
            Set(directories).count, 2,
            "two samples whose names sanitize to the same string must not share a directory"
        )

        // The decisive check: each sample's own consensus, not sample 1's twice.
        for (entry, expected) in zip(ingested, ["S 1", "S_1"]) {
            XCTAssertEqual(entry.inventory.sampleName, expected)
            let consensus = try XCTUnwrap(
                entry.inventory.consensusFASTA,
                "sample \(expected) must have its own consensus"
            )
            XCTAssertEqual(
                try String(contentsOf: consensus, encoding: .utf8),
                "\(expected) consensus",
                "sample \(expected) must not inherit another sample's consensus"
            )
        }
    }

    // M-3: `guard sampleNames.count != 1` sent count == 0 down the batch path,
    // which created an empty batch directory in Analyses/ and returned no
    // samples. Unreachable in production today, but a latent trap: it litters
    // the project and reports success for a run that ingested nothing.
    func testZeroSamplesIsRefusedAndLeavesNoEmptyBatchDirectory() throws {
        let project = root.appendingPathComponent("PEmpty.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try ViralReconResultIngest.ingestRun(
                resultsDirectory: results,
                sampleNames: [],
                referenceBundleURL: referenceBundle,
                projectURL: project)
        ) { error in
            XCTAssertEqual(error as? ViralReconResultIngest.IngestError, .noSamples)
        }

        let analyses = project.appendingPathComponent(AnalysesFolder.directoryName, isDirectory: true)
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            at: analyses, includingPropertiesForKeys: nil)) ?? []
        XCTAssertTrue(
            leftovers.isEmpty,
            "a refused run must not leave an empty batch directory behind. Got: "
                + "\(leftovers.map { $0.lastPathComponent })"
        )
    }

    // ingestBatch is public, so it is refused directly too, not only via
    // ingestRun's dispatch.
    func testIngestBatchAlsoRefusesZeroSamples() throws {
        let project = root.appendingPathComponent("PEmptyBatch.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try ViralReconResultIngest.ingestBatch(
                resultsDirectory: results,
                sampleNames: [],
                referenceBundleURL: referenceBundle,
                projectURL: project)
        ) { error in
            XCTAssertEqual(error as? ViralReconResultIngest.IngestError, .noSamples)
        }
    }

    func testBatchDirectoryIsMarkedAsABatch() throws {
        let project = root.appendingPathComponent("P2.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let ingested = try ViralReconResultIngest.ingestBatch(
            resultsDirectory: results,
            sampleNames: ["S1"],
            referenceBundleURL: referenceBundle,
            projectURL: project)

        let batchDirectory = try XCTUnwrap(ingested.first).bundleDirectory.deletingLastPathComponent()
        XCTAssertTrue(batchDirectory.lastPathComponent.contains("viralrecon-batch-"))
        let metadata = try JSONSerialization.jsonObject(
            with: Data(contentsOf: batchDirectory.appendingPathComponent("analysis-metadata.json"))
        ) as? [String: Any]
        XCTAssertEqual(metadata?["tool"] as? String, "viralrecon")
        XCTAssertEqual(metadata?["isBatch"] as? Bool, true)
    }

    func testEachBatchSampleFindsItsOwnOutputs() throws {
        let project = root.appendingPathComponent("P3.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let ingested = try ViralReconResultIngest.ingestBatch(
            resultsDirectory: results,
            sampleNames: ["S1"],
            referenceBundleURL: referenceBundle,
            projectURL: project)

        let entry = try XCTUnwrap(ingested.first)
        XCTAssertEqual(entry.inventory.sampleName, "S1")
        XCTAssertEqual(entry.inventory.sortedBAM?.lastPathComponent, "S1.sorted.bam")
    }
    // mosdepth writes per-amplicon and whole-genome coverage under sibling
    // directories using the SAME filename. Copying both into one flat reports/
    // directory by last path component silently dropped the second, so the
    // amplicon-dropout view could be lost while the sidecar still listed two
    // report paths.
    func testKeepsBothCoverageTablesWhenTheirFilenamesCollide() throws {
        for relative in ["variants/bowtie2/mosdepth/amplicon/S1.mosdepth.coverage.tsv",
                         "variants/bowtie2/mosdepth/genome/S1.mosdepth.coverage.tsv"] {
            let url = results.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            // Distinct contents so an overwrite is detectable, not just a name clash.
            try Data(relative.utf8).write(to: url)
        }
        let destination = root.appendingPathComponent("Analyses/Viral Recon", isDirectory: true)

        let ingested = try ViralReconResultIngest.ingest(
            resultsDirectory: results,
            sampleName: "S1",
            referenceBundleURL: referenceBundle,
            into: destination)

        let reports = ingested.bundleDirectory.appendingPathComponent("reports", isDirectory: true)
        let copied = try FileManager.default.contentsOfDirectory(atPath: reports.path)
            .filter { $0.contains("mosdepth") }
        XCTAssertEqual(copied.count, 2, "both coverage tables must survive, got \(copied)")

        let bodies = try Set(copied.map {
            String(decoding: try Data(contentsOf: reports.appendingPathComponent($0)), as: UTF8.self)
        })
        XCTAssertEqual(bodies.count, 2, "one coverage table overwrote the other")
    }
}
