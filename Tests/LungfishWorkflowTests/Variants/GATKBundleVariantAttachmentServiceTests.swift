import Foundation
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow
import XCTest

final class GATKBundleVariantAttachmentServiceTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GATKBundleVariantAttachmentServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testAttachesGATKOutputAsStandardVariantTrackWithFinalProvenance() async throws {
        let bundleURL = tempDir.appendingPathComponent("sample.lungfishref", isDirectory: true)
        let vcfURL = try makeBundleWithGATKOutput(at: bundleURL)
        let executionProvenanceURL = bundleURL
            .appendingPathComponent("variants/gatk", isDirectory: true)
            .appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        try Data("{}".utf8).write(to: executionProvenanceURL)

        let executionRequest = GATKPipelineExecutionRequest.haplotypeCaller(
            configuration: GATKHaplotypeCallerConfiguration(
                referenceFASTAURL: bundleURL.appendingPathComponent("genome/reference.fa"),
                inputBAMURL: bundleURL.appendingPathComponent("alignments/sample.bam"),
                outputVCFURL: vcfURL,
                emitReferenceConfidence: .none
            ),
            toolVersion: "4.5.0.0",
            runtimeIdentity: GATKRuntimeIdentity(condaEnvironment: "/opt/lungfish/envs/gatk-core")
        )

        let service = GATKBundleVariantAttachmentService()
        let result = try await service.attach(
            request: GATKBundleVariantAttachmentRequest(
                bundleURL: bundleURL,
                alignmentTrackID: "aln-1",
                outputTrackID: "gatk-track",
                outputTrackName: "Sample GATK",
                outputVCFURL: vcfURL,
                executionProvenanceURL: executionProvenanceURL,
                executionRequest: executionRequest,
                importProfile: .fast
            )
        )

        let manifest = try BundleManifest.load(from: bundleURL)
        let track = try XCTUnwrap(manifest.variants.first(where: { $0.id == "gatk-track" }))
        XCTAssertEqual(track.name, "Sample GATK")
        XCTAssertEqual(track.path, "variants/gatk/gatk-track.vcf")
        XCTAssertEqual(track.indexPath, "variants/gatk/gatk-track.vcf.idx")
        XCTAssertEqual(track.databasePath, "variants/gatk/gatk-track.db")
        XCTAssertEqual(track.source, "GATK HaplotypeCaller")
        XCTAssertEqual(track.version, "4.5.0.0")
        XCTAssertEqual(result.variantCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.databaseURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.provenanceURL.path))

        let database = try VariantDatabase(url: result.databaseURL)
        XCTAssertEqual(database.totalVariantCount(), 1)
        XCTAssertEqual(
            VariantDatabase.metadataValue(at: result.databaseURL, key: "call_semantics"),
            VCFImportSemantics.standard.rawValue
        )
        XCTAssertEqual(
            VariantDatabase.metadataValue(at: result.databaseURL, key: "source_execution_provenance"),
            executionProvenanceURL.path
        )

        let provenanceData = try Data(contentsOf: result.provenanceURL)
        let provenance = try JSONDecoder.workflowRunDecoder.decode(WorkflowRun.self, from: provenanceData)
        XCTAssertEqual(provenance.name, "GATK HaplotypeCaller bundle attachment")
        XCTAssertEqual(provenance.status, .completed)
        XCTAssertEqual(provenance.parameters["importSemantics"]?.stringValue, VCFImportSemantics.standard.rawValue)
        XCTAssertEqual(provenance.parameters["sourceExecutionProvenance"]?.stringValue, executionProvenanceURL.path)
        XCTAssertEqual(provenance.parameters["option.emitReferenceConfidence"]?.stringValue, "NONE")
        XCTAssertTrue(
            provenance.steps.flatMap(\.outputs).contains { $0.path == result.databaseURL.path }
        )
    }

    private func makeBundleWithGATKOutput(at bundleURL: URL) throws -> URL {
        let genomeDir = bundleURL.appendingPathComponent("genome", isDirectory: true)
        let alignmentsDir = bundleURL.appendingPathComponent("alignments", isDirectory: true)
        let variantsDir = bundleURL.appendingPathComponent("variants/gatk", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: alignmentsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: variantsDir, withIntermediateDirectories: true)

        try Data(">chr1\nACGTACGTACGT\n".utf8)
            .write(to: genomeDir.appendingPathComponent("reference.fa"))
        try Data("chr1\t12\t6\t12\t13\n".utf8)
            .write(to: genomeDir.appendingPathComponent("reference.fa.fai"))
        try Data().write(to: alignmentsDir.appendingPathComponent("sample.bam"))
        try Data().write(to: alignmentsDir.appendingPathComponent("sample.bam.bai"))

        let vcfURL = variantsDir.appendingPathComponent("gatk-track.vcf")
        try Data(
            """
            ##fileformat=VCFv4.2
            ##contig=<ID=chr1,length=12>
            #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tsample
            chr1\t4\t.\tT\tG\t60\tPASS\tDP=18\tGT:DP\t0/1:18
            """.utf8
        ).write(to: vcfURL)
        try Data().write(to: variantsDir.appendingPathComponent("gatk-track.vcf.idx"))

        let manifest = BundleManifest(
            name: "Sample",
            identifier: "sample-bundle",
            source: SourceInfo(organism: "Test organism", assembly: "test"),
            genome: GenomeInfo(
                path: "genome/reference.fa",
                indexPath: "genome/reference.fa.fai",
                totalLength: 12,
                chromosomes: [
                    ChromosomeInfo(
                        name: "chr1",
                        length: 12,
                        offset: 6,
                        lineBases: 12,
                        lineWidth: 13
                    )
                ]
            ),
            alignments: [
                AlignmentTrackInfo(
                    id: "aln-1",
                    name: "Sample BAM",
                    sourcePath: "alignments/sample.bam",
                    indexPath: "alignments/sample.bam.bai"
                )
            ]
        )
        try manifest.save(to: bundleURL)
        return vcfURL
    }
}

private extension JSONDecoder {
    static var workflowRunDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
