import Foundation
import XCTest
@testable import LungfishOperations
@testable import LungfishCore
@testable import LungfishWorkflow

/// A Nanopore run's variant track and alignment reach the reference bundle the viewport binds (VR-INVENTORY, BIO B1
/// and SF-1).
///
/// ARTIC publishes its primer-trimmed BAM as `artic_minion/<sample>.primertrimmed.rg.sorted.bam`, and viralrecon reads
/// its pass VCF only through `artic_minion/<sample>.pass.unique.vcf.gz`. The BAM is imported before the variants are
/// registered, so a BAM the import cannot take would hide the variant track too, and this runs both.
final class ViralReconNanoporePublicationTests: XCTestCase {
    private var root: URL!
    private var results: URL!
    private var referenceBundle: URL!

    private var fixtures: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/sarscov2")
    }

    override func setUpWithError() throws {
        let fileManager = FileManager.default
        root = fileManager.temporaryDirectory
            .appendingPathComponent("vr-nanopore-publish-\(UUID().uuidString)", isDirectory: true)
        results = root.appendingPathComponent("results", isDirectory: true)
        referenceBundle = root.appendingPathComponent("MT192765.1.lungfishref", isDirectory: true)

        let genomeDirectory = referenceBundle.appendingPathComponent("genome", isDirectory: true)
        try fileManager.createDirectory(at: genomeDirectory, withIntermediateDirectories: true)
        try fileManager.copyItem(
            at: fixtures.appendingPathComponent("genome.fasta"),
            to: genomeDirectory.appendingPathComponent("sequence.fa"))
        try fileManager.copyItem(
            at: fixtures.appendingPathComponent("genome.fasta.fai"),
            to: genomeDirectory.appendingPathComponent("sequence.fa.fai"))
        try BundleManifest(
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
                ])).save(to: referenceBundle)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func stage(fixture: String, at relative: String) throws {
        let destination = results.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent(fixture), to: destination)
    }

    func testANanoporeRunPublishesItsPrimerTrimmedAlignmentAndItsUniqueVariants() async throws {
        try stage(fixture: "test.paired_end.sorted.bam", at: "artic_minion/S1.primertrimmed.rg.sorted.bam")
        try stage(fixture: "test.paired_end.sorted.bam.bai", at: "artic_minion/S1.primertrimmed.rg.sorted.bam.bai")
        try stage(fixture: "test.vcf.gz", at: "artic_minion/S1.pass.unique.vcf.gz")
        try stage(fixture: "test.vcf.gz.tbi", at: "artic_minion/S1.pass.unique.vcf.gz.tbi")
        let ingested = try ViralReconResultIngest.ingest(
            resultsDirectory: results,
            sampleName: "S1",
            referenceBundleURL: referenceBundle,
            into: root.appendingPathComponent("Analyses/viralrecon", isDirectory: true),
            params: ["platform": "nanopore", "protocol": "amplicon"])

        let published = try await ViralReconViewerPublication.publish(ingested: ingested)

        let manifest = try BundleManifest.load(from: published)
        XCTAssertEqual(manifest.alignments.count, 1, "the primer-trimmed alignment is registered")
        XCTAssertEqual(manifest.variants.count, 1, "the unique VCF is registered")
        XCTAssertEqual(manifest.variants.first?.description, "ARTIC variants from Viral Recon")
        let fileManager = FileManager.default
        for relative in [manifest.alignments.first?.sourcePath, manifest.alignments.first?.indexPath,
                         manifest.variants.first?.path].compactMap({ $0 }) {
            XCTAssertTrue(fileManager.fileExists(atPath: published.appendingPathComponent(relative).path),
                          "manifest references a payload that is not in the bundle: \(relative)")
        }
    }
}
