import Foundation
import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow

final class TwelveSReferenceMetadataTests: XCTestCase {
    func testReferenceRecordPrefersStructuredMetadataNamesOverHeaderParsing() {
        let sequence = "ACGTACGT"
        let sequenceSHA256 = "opaque-sequence-sha"
        let record = TwelveSReferenceRecord(
            targetID: "opaque",
            displayName: "MIDORI-opaque-label",
            sequence: sequence,
            metadata: ["sequence_sha256": sequenceSHA256]
        )
        let metadata = TwelveSReferenceMetadataEntry(
            targetID: "opaque",
            sequenceSHA256: sequenceSHA256,
            displayName: "MIDORI-opaque-label",
            scientificName: "Homo sapiens",
            commonName: "human",
            taxid: "9606",
            taxonGroup: "Mammal",
            taxonomy: nil,
            nameSource: "ncbi_common",
            metadata: ["scientific_name": "Homo sapiens", "common_name": "human"],
            alternateMatches: []
        )

        let enriched = TwelveSReferenceIndex(records: [record])
            .enriched(with: TwelveSReferenceMetadataIndex(entries: [metadata]))
            .records[0]

        XCTAssertEqual(enriched.target.scientificName, "Homo sapiens")
        XCTAssertEqual(enriched.target.commonName, "human")
        XCTAssertEqual(enriched.target.taxid, "9606")
    }

    func testBuildsTargetMetadataFromDeduplicatedFastaAndMidoriTable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwelveSReferenceMetadataTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fastaURL = root.appendingPathComponent("amplicons_12s_deduplicated.fa")
        let midoriURL = root.appendingPathComponent("12s_reference.tsv")
        let outputURL = root.appendingPathComponent("12s-target-metadata.tsv")

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

        let result = try await TwelveSReferenceMetadataBuilder().build(
            TwelveSReferenceMetadataBuildConfiguration(
                deduplicatedFASTA: fastaURL,
                midoriMetadataTSV: midoriURL,
                outputURL: outputURL,
                forceOverwrite: true
            )
        )

        XCTAssertEqual(result.metadataURL, outputURL.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.provenanceURL.path))

        let records = try TwelveSReferenceIndex.load(from: fastaURL, metadataURL: outputURL).records
        let human = try XCTUnwrap(records.first { $0.displayName == "human (Homo sapiens)" })
        XCTAssertEqual(human.metadata["taxon_group"], "Mammal")
        XCTAssertEqual(human.metadata["taxid"], "9606")
        XCTAssertEqual(human.metadata["name_source"], "ncbi_common")
        XCTAssertEqual(human.alternateMatches.map(\.scientificName), ["Homo heidelbergensis"])
        XCTAssertEqual(human.alternateMatches.first?.taxid, "1425170")

        let trout = try XCTUnwrap(records.first { $0.displayName == "rainbow trout (Oncorhynchus mykiss)" })
        XCTAssertEqual(trout.metadata["taxon_group"], "Fish")
        XCTAssertEqual(trout.metadata["taxid"], "8022")
        XCTAssertEqual(trout.alternateMatches, [])

        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: result.provenanceURL))
        XCTAssertEqual(provenance.workflowName, "lungfish fastq 12s-reference-metadata")
        XCTAssertTrue(provenance.argv.contains("--force"))
        XCTAssertTrue(provenance.files.contains { $0.path == fastaURL.path })
        XCTAssertTrue(provenance.files.contains { $0.path == midoriURL.path })
        XCTAssertTrue(provenance.outputs.contains { $0.path == outputURL.path })
    }
}
