import Foundation
import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow

final class TwelveSReferenceBundleBuilderTests: XCTestCase {
    func testBuildsReferenceBundleWithMetadataProvenanceAndResolvableReferenceIndex() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwelveSReferenceBundleBuilderTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fastaURL = root.appendingPathComponent("amplicons_12s_deduplicated.fa")
        let midoriURL = root.appendingPathComponent("12s_reference.tsv")
        let notesURL = root.appendingPathComponent("build_db.log")
        let bundleURL = root.appendingPathComponent("MIDORI-12S.lungfish12sref", isDirectory: true)

        try """
        >human (Homo sapiens)|locus=12S|len=8|n_refs=3|n_species=2|also_matches=Heidelberg man (Homo heidelbergensis)|n_primer_pairs=1|primer_pairs=12S_vert
        ACGTACGT
        >rainbow trout (Oncorhynchus mykiss)|locus=12S|len=8|n_refs=2|n_species=1|also_matches=|n_primer_pairs=1|primer_pairs=12S_vert
        TTTTCCCC
        """.write(to: fastaURL, atomically: true, encoding: .utf8)
        try """
        seq_id\tcommon_name\tlatin_name\tgroup\ttaxid\tname_source\ttaxonomy
        AB1\thuman\tHomo sapiens\tMammal\t9606\tncbi_common\troot; Eukaryota; Chordata; Mammalia; Primates; Hominidae; Homo; Homo sapiens
        AB2\tHeidelberg man\tHomo heidelbergensis\tMammal\t1425170\tncbi_common\troot; Eukaryota; Chordata; Mammalia; Primates; Hominidae; Homo; Homo heidelbergensis
        AB3\trainbow trout\tOncorhynchus mykiss\tFish\t8022\tfishbase\troot; Eukaryota; Chordata; Actinopteri; Salmoniformes; Salmonidae; Oncorhynchus; Oncorhynchus mykiss
        """.write(to: midoriURL, atomically: true, encoding: .utf8)
        try "build log\n".write(to: notesURL, atomically: true, encoding: .utf8)

        let result = try await TwelveSReferenceBundleBuilder().build(
            TwelveSReferenceBundleBuildConfiguration(
                deduplicatedFASTA: fastaURL,
                midoriMetadataTSV: midoriURL,
                outputURL: bundleURL,
                name: "MIDORI 12S",
                sourceFiles: [notesURL],
                forceOverwrite: true,
                argv: [
                    "lungfish-cli", "fastq", "12s-reference-bundle",
                    "--dedup-fasta", fastaURL.path,
                    "--midori-metadata", midoriURL.path,
                    "--output", bundleURL.path,
                    "--name", "MIDORI 12S",
                    "--source-file", notesURL.path,
                    "--force",
                ]
            )
        )

        XCTAssertEqual(result.bundleURL, bundleURL.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.provenanceURL.path))

        let manifest = try TwelveSReferenceBundle.loadManifest(from: bundleURL)
        XCTAssertEqual(manifest.name, "MIDORI 12S")
        XCTAssertEqual(manifest.metrics.referenceCount, 2)
        XCTAssertEqual(manifest.metrics.taxidCount, 2)
        XCTAssertEqual(manifest.metrics.taxonGroupCount, 2)
        XCTAssertEqual(manifest.metrics.alternateMatchCount, 1)
        XCTAssertEqual(manifest.sourceFiles.map(\.role).sorted(), ["build_source", "deduplicated_fasta", "midori_metadata"])

        let referenceURL = try XCTUnwrap(TwelveSReferenceBundle.referenceFASTAURL(in: bundleURL))
        let metadataURL = try XCTUnwrap(TwelveSReferenceBundle.targetMetadataURL(in: bundleURL))
        let records = try TwelveSReferenceIndex.load(from: referenceURL, metadataURL: metadataURL).records
        let human = try XCTUnwrap(records.first { $0.target.scientificName == "Homo sapiens" })
        XCTAssertEqual(human.target.taxid, "9606")
        XCTAssertEqual(human.target.taxonGroup, "Mammal")
        XCTAssertEqual(human.target.taxonomy, "root; Eukaryota; Chordata; Mammalia; Primates; Hominidae; Homo; Homo sapiens")
        XCTAssertEqual(human.alternateMatches.first?.scientificName, "Homo heidelbergensis")

        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: result.provenanceURL))
        XCTAssertEqual(provenance.workflowName, "lungfish fastq 12s-reference-bundle")
        XCTAssertTrue(provenance.argv.contains("--source-file"))
        XCTAssertTrue(provenance.files.contains { $0.path == fastaURL.path })
        XCTAssertTrue(provenance.files.contains { $0.path == midoriURL.path })
        XCTAssertTrue(provenance.outputs.contains { $0.path == bundleURL.path })
        XCTAssertEqual(provenance.steps.count, 1)
        XCTAssertEqual(provenance.steps.first?.exitStatus, 0)
        XCTAssertTrue(provenance.steps.first?.inputs.contains { $0.path == fastaURL.path } == true)
        XCTAssertTrue(provenance.steps.first?.outputs.contains { $0.path == bundleURL.path } == true)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: bundleURL
                .appendingPathComponent(ProvenanceWriter.bundleProvenanceDirectoryName, isDirectory: true)
                .appendingPathComponent(ProvenanceWriter.bundleRollupFilename)
                .path
        ))
    }
}
