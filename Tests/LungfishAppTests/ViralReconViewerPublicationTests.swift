import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishWorkflow

/// Verifies that a finished Viral Recon run is registered into the reference
/// bundle manifest the viewport binds to.
///
/// The viewport does not open loose BAM files. It reads a `.lungfishref`
/// manifest, so an unregistered alignment is invisible no matter how healthy the
/// BAM is. These tests assert the registration actually lands in the manifest.
final class ViralReconViewerPublicationTests: XCTestCase {
    private var root: URL!
    private var results: URL!
    private var referenceBundle: URL!

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var fixtures: URL { repositoryRoot().appendingPathComponent("Tests/Fixtures/sarscov2") }

    override func setUpWithError() throws {
        let fileManager = FileManager.default
        root = fileManager.temporaryDirectory
            .appendingPathComponent("vr-publish-\(UUID().uuidString)", isDirectory: true)
        results = root.appendingPathComponent("results", isDirectory: true)
        referenceBundle = root.appendingPathComponent("MT192765.1.lungfishref", isDirectory: true)

        // A reference bundle shaped the way the viewport expects.
        let genomeDirectory = referenceBundle.appendingPathComponent("genome", isDirectory: true)
        try fileManager.createDirectory(at: genomeDirectory, withIntermediateDirectories: true)
        try fileManager.copyItem(
            at: fixtures.appendingPathComponent("genome.fasta"),
            to: genomeDirectory.appendingPathComponent("sequence.fa"))
        try fileManager.copyItem(
            at: fixtures.appendingPathComponent("genome.fasta.fai"),
            to: genomeDirectory.appendingPathComponent("sequence.fa.fai"))

        let manifest = BundleManifest(
            name: "MT192765.1",
            identifier: "org.ncbi.genbank.mt192765",
            description: nil,
            source: SourceInfo(
                organism: "Severe acute respiratory syndrome coronavirus 2",
                assembly: "MT192765.1",
                assemblyAccession: "MT192765.1",
                database: "NCBI"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: 29_829,
                chromosomes: [
                    ChromosomeInfo(
                        name: "MT192765.1",
                        length: 29_829,
                        offset: 120,
                        lineBases: 80,
                        lineWidth: 81,
                        aliases: [])
                ]))
        try manifest.save(to: referenceBundle)

        // An nf-core results tree carrying the real fixture outputs.
        try stage(fixture: "test.paired_end.sorted.bam", at: "variants/bowtie2/S1.sorted.bam")
        try stage(fixture: "test.paired_end.sorted.bam.bai", at: "variants/bowtie2/S1.sorted.bam.bai")
        try stage(fixture: "test.vcf.gz", at: "variants/ivar/S1.vcf.gz")
        try stage(fixture: "test.vcf.gz.tbi", at: "variants/ivar/S1.vcf.gz.tbi")
    }

    private func stage(fixture: String, at relative: String) throws {
        let destination = results.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent(fixture), to: destination)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func ingest() throws -> ViralReconResultIngest.Ingested {
        try ViralReconResultIngest.ingest(
            resultsDirectory: results,
            sampleName: "S1",
            referenceBundleURL: referenceBundle,
            into: root.appendingPathComponent("Analyses/viralrecon", isDirectory: true))
    }

    func testPublishRegistersTheAlignmentInTheManifest() async throws {
        let published = try await ViralReconViewerPublication.publish(ingested: try ingest())

        let manifest = try BundleManifest.load(from: published)
        XCTAssertEqual(manifest.alignments.count, 1)
        XCTAssertTrue(
            manifest.alignments[0].sourcePath.hasSuffix(".bam"),
            "expected a BAM source path, got \(manifest.alignments[0].sourcePath)")
        XCTAssertFalse(manifest.alignments[0].indexPath.isEmpty)
    }

    func testPublishRegistersTheVariantTrackInTheManifest() async throws {
        let published = try await ViralReconViewerPublication.publish(ingested: try ingest())

        let manifest = try BundleManifest.load(from: published)
        XCTAssertEqual(manifest.variants.count, 1)
        XCTAssertTrue(
            manifest.variants[0].path.hasSuffix(".vcf.gz"),
            "expected a bgzipped VCF path, got \(manifest.variants[0].path)")
    }

    func testPublishedPayloadsExistInsideTheBundle() async throws {
        let published = try await ViralReconViewerPublication.publish(ingested: try ingest())

        let manifest = try BundleManifest.load(from: published)
        let fileManager = FileManager.default
        for relative in [manifest.alignments[0].sourcePath,
                         manifest.alignments[0].indexPath,
                         manifest.variants[0].path] {
            XCTAssertTrue(
                fileManager.fileExists(atPath: published.appendingPathComponent(relative).path),
                "manifest references a payload that is not in the bundle: \(relative)")
        }
    }

    func testMissingAlignmentPublishesVariantsWithoutFailing() async throws {
        try FileManager.default.removeItem(
            at: results.appendingPathComponent("variants/bowtie2/S1.sorted.bam"))

        let published = try await ViralReconViewerPublication.publish(ingested: try ingest())

        let manifest = try BundleManifest.load(from: published)
        XCTAssertTrue(manifest.alignments.isEmpty)
        XCTAssertEqual(manifest.variants.count, 1, "a missing BAM must not lose the variants")
    }
}
