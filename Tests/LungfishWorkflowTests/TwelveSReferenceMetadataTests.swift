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

    /// A loose FASTA whose amplicon differs from the bundle's (trimmed or
    /// deduplicated differently) misses the SHA-256 lookup. When its header
    /// carries the scientific name, taxid and group still come from the
    /// table's row for that species; alternates stay the record's own.
    func testEnrichmentFallsBackToScientificNameWhenSequenceIsUnknown() throws {
        let index = try TwelveSReferenceIndex.parse("""
        >rhesus macaque (Macaca mulatta)|locus=12S|len=8|also_matches=Japanese macaque (Macaca fuscata)
        ACGTACGT
        >human (Homo sapiens)|locus=12S|len=8
        GGGGCCCC
        >dog (Canis lupus familiaris)|locus=12S|len=8
        TTTTAAAA
        """)
        let table = TwelveSReferenceMetadataIndex(entries: [
            TwelveSReferenceMetadataEntry(
                targetID: "macaque-other-amplicon",
                sequenceSHA256: "sha-for-a-different-macaque-amplicon",
                displayName: "rhesus macaque (Macaca mulatta)",
                scientificName: "Macaca mulatta",
                commonName: "rhesus macaque",
                taxid: "9544",
                taxonGroup: "Mammal",
                taxonomy: "Eukaryota;Chordata;Mammalia;Primates",
                nameSource: "ncbi_common",
                metadata: ["length": "120", "sequence_sha256": "sha-for-a-different-macaque-amplicon"],
                alternateMatches: [
                    TwelveSAlternateMatch(displayName: "Macaca cyclopis", scientificName: "Macaca cyclopis", commonName: nil, reason: "shared_exact_amplicon"),
                ]
            ),
            TwelveSReferenceMetadataEntry(
                targetID: "human",
                sequenceSHA256: index.records[1].metadata["sequence_sha256"]!,
                displayName: "human (Homo sapiens)",
                scientificName: "Homo sapiens",
                commonName: "human",
                taxid: "9606",
                taxonGroup: "Mammal",
                taxonomy: nil,
                nameSource: "ncbi_common",
                metadata: [:],
                alternateMatches: []
            ),
        ])

        let enriched = index.enriched(with: table).records

        // Name fallback: taxonomy filled, alternates and length untouched.
        let macaque = enriched[0].target
        XCTAssertEqual(macaque.taxid, "9544")
        XCTAssertEqual(macaque.taxonGroup, "Mammal")
        XCTAssertEqual(macaque.taxonomy, "Eukaryota;Chordata;Mammalia;Primates")
        XCTAssertEqual(macaque.nameSource, "ncbi_common")
        XCTAssertEqual(macaque.length, 8)
        XCTAssertEqual(enriched[0].metadata["sequence_sha256"], index.records[0].metadata["sequence_sha256"])
        XCTAssertEqual(enriched[0].alternateMatches.map(\.displayName), ["Japanese macaque (Macaca fuscata)"])

        // Sequence match still wins and behaves as before.
        XCTAssertEqual(enriched[1].target.taxid, "9606")

        // No row for the species: nothing invented.
        XCTAssertNil(enriched[2].target.taxid)
        XCTAssertNil(enriched[2].target.taxonGroup)
    }

    func testScientificNameLookupRefusesRowsThatDisagreeOnTaxid() {
        func entry(_ id: String, taxid: String?) -> TwelveSReferenceMetadataEntry {
            TwelveSReferenceMetadataEntry(
                targetID: id, sequenceSHA256: "sha-\(id)", displayName: id,
                scientificName: "Macaca mulatta", commonName: nil, taxid: taxid,
                taxonGroup: "Mammal", taxonomy: nil, nameSource: nil, metadata: [:], alternateMatches: []
            )
        }
        let agreeing = TwelveSReferenceMetadataIndex(entries: [entry("a", taxid: "9544"), entry("b", taxid: "9544")])
        XCTAssertEqual(agreeing.entry(scientificName: "macaca MULATTA")?.taxid, "9544")

        let disagreeing = TwelveSReferenceMetadataIndex(entries: [entry("a", taxid: "9544"), entry("b", taxid: "9545")])
        XCTAssertNil(disagreeing.entry(scientificName: "Macaca mulatta"))
        XCTAssertNil(disagreeing.entry(scientificName: ""))
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
