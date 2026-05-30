import Foundation
import XCTest
@testable import LungfishIO

final class TwelveSAmpliconResultBundleTests: XCTestCase {
    func testLoadsTargetRowBundleWithSampleCountsAndReadFate() throws {
        let bundleURL = try makeSyntheticBundle()

        let result = try TwelveSAmpliconResultBundle.loadResult(from: bundleURL)

        XCTAssertTrue(TwelveSAmpliconResultBundle.isBundleURL(bundleURL))
        XCTAssertEqual(result.manifest.kind, "12s-amplicon-match")
        XCTAssertEqual(result.sampleNames, ["HI_Hilo_F09", "ExtractionBlank"])
        XCTAssertEqual(result.samples.count, 2)
        XCTAssertEqual(result.targets.count, 4)
        XCTAssertEqual(result.targetRows.map(\.targetID), ["human-a", "dog", "human-b", "pig"])
        XCTAssertEqual(result.targetRows[0].totalExactReads, 12)
        XCTAssertEqual(result.targetRows[0].count(forSample: "HI_Hilo_F09"), 10)
        XCTAssertEqual(result.targetRows[0].count(forSample: "ExtractionBlank"), 2)
        XCTAssertEqual(result.targetRows[0].target.scientificName, "Homo sapiens")
        XCTAssertEqual(result.targetRows[0].target.taxonGroup, "Mammal")
        XCTAssertEqual(result.targetRows[0].target.taxid, "9606")
        XCTAssertEqual(result.targetRows[0].target.alternateMatches.map(\.scientificName), [
            "Homo heidelbergensis"
        ])
        XCTAssertEqual(result.targetRows[0].target.metadata["n_refs"], "1572")
        XCTAssertEqual(result.targetRows[1].maxSamplePercent, 22.222222, accuracy: 0.0001)
        XCTAssertEqual(result.readFate.totalReads, 68)
        XCTAssertEqual(result.readFate.exactMatchReads, 20)
        XCTAssertEqual(result.readFate.unresolvedPercent, 70.588235, accuracy: 0.0001)
        XCTAssertEqual(result.unresolvedSequences.count, 2)
        XCTAssertEqual(result.unresolvedSequences.first?.chimeraStatus, .candidate)
        XCTAssertEqual(result.chimeraCandidateCount, 1)
        XCTAssertEqual(result.artifacts.provenanceURL.lastPathComponent, ".lungfish-provenance.json")
    }

    func testAggregatesTargetRowsByScientificNameAndPotentialMatches() throws {
        let bundleURL = try makeSyntheticBundle()

        let result = try TwelveSAmpliconResultBundle.loadResult(from: bundleURL)

        XCTAssertEqual(result.scientificNameRows.map(\.scientificName), [
            "Homo sapiens",
            "Canis lupus familiaris",
            "Sus scrofa",
        ])
        XCTAssertEqual(result.scientificNameRows[0].targetIDs.sorted(), ["human-a", "human-b"])
        XCTAssertEqual(result.scientificNameRows[0].totalExactReads, 15)
        XCTAssertEqual(result.scientificNameRows[0].count(forSample: "HI_Hilo_F09"), 13)
        XCTAssertEqual(result.scientificNameRows[0].count(forSample: "ExtractionBlank"), 2)
        XCTAssertEqual(result.scientificNameRows[0].potentialMatches, [
            "Heidelberg man (Homo heidelbergensis)",
            "Neanderthal (Homo neanderthalensis)",
        ])
        XCTAssertEqual(result.scientificNameRows[0].taxonGroups, ["Mammal"])
        XCTAssertEqual(result.scientificNameRows[1].taxonGroups, ["Mammal", "Fish"])
        XCTAssertEqual(result.scientificNameRows[1].taxids, ["9615", "8022"])
        XCTAssertEqual(result.scientificNameRows[0].alternateMatches.map(\.scientificName), [
            "Homo heidelbergensis",
            "Homo neanderthalensis",
        ])
        XCTAssertEqual(
            result.scientificNameRows[0].potentialMatchesText,
            "Heidelberg man (Homo heidelbergensis); Neanderthal (Homo neanderthalensis)"
        )
    }

    func testLoadsResolvedSampleMetadataWhenManifestReferencesIt() throws {
        let bundleURL = try makeSyntheticBundle()
        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent("metadata", isDirectory: true),
            withIntermediateDirectories: true
        )
        try """
        sample_id\tsample_name\tsample_type\tsite
        HI_Hilo_F09\tHilo F09\twastewater\tHilo WWTP
        ExtractionBlank\tExtraction Blank\textraction_blank\tRun blank
        """.write(
            to: bundleURL.appendingPathComponent("metadata/resolved-sample-metadata.tsv"),
            atomically: true,
            encoding: .utf8
        )
        try """
        {
          "schemaVersion" : 1,
          "precedence" : [
            "analysisOverride",
            "fastqBundle",
            "fastqFolder",
            "intrinsic"
          ],
          "emptyOverrideCells" : "empty analysis metadata cells do not clear lower-precedence values",
          "sampleCount" : 2,
          "columns" : [
            "sample_id",
            "sample_name",
            "sample_type",
            "site"
          ],
          "sources" : [
            {
              "kind" : "analysisOverride",
              "path" : "/tmp/samples.tsv",
              "sampleColumnName" : "sample_id",
              "delimiter" : "tab",
              "totalRows" : 2,
              "matchedSampleCount" : 2,
              "unmatchedRowCount" : 0,
              "missingSampleCount" : 0
            }
          ],
          "warnings" : []
        }
        """.write(
            to: bundleURL.appendingPathComponent("metadata/sample-metadata-manifest.json"),
            atomically: true,
            encoding: .utf8
        )
        var manifest = try TwelveSAmpliconResultBundle.loadManifest(from: bundleURL)
        manifest = manifest.replacingSampleMetadata(
            resolvedSampleMetadataPath: "metadata/resolved-sample-metadata.tsv",
            sampleMetadataManifestPath: "metadata/sample-metadata-manifest.json",
            analysisSampleMetadataOriginalPath: nil
        )
        try TwelveSAmpliconResultBundle.writeManifest(manifest, to: bundleURL)

        let result = try TwelveSAmpliconResultBundle.loadResult(from: bundleURL)

        XCTAssertEqual(result.sampleMetadata?.columns, ["sample_id", "sample_name", "sample_type", "site"])
        XCTAssertEqual(result.sampleMetadata?.records["HI_Hilo_F09"]?["site"], "Hilo WWTP")
        XCTAssertEqual(result.sampleMetadata?.records["ExtractionBlank"]?["sample_type"], "extraction_blank")
        XCTAssertEqual(result.sampleMetadataManifest?.sampleCount, 2)
        XCTAssertEqual(result.sampleMetadataManifest?.hasAnalysisMetadata, true)
        XCTAssertEqual(result.sampleMetadataManifest?.sources.first?.matchedSampleCount, 2)
    }

    func testThrowsForMissingRequiredCountColumns() throws {
        let bundleURL = try makeSyntheticBundle()
        try "sample_id\tHI_Hilo_F09\nhuman\t10\n"
            .write(
                to: bundleURL.appendingPathComponent("sample-target-counts.tsv"),
                atomically: true,
                encoding: .utf8
            )

        XCTAssertThrowsError(try TwelveSAmpliconResultBundle.loadResult(from: bundleURL)) { error in
            XCTAssertTrue(String(describing: error).contains("target_id"))
        }
    }

    func testThrowsForNonIntegerCounts() throws {
        let bundleURL = try makeSyntheticBundle()
        try """
        target_id\tHI_Hilo_F09\tExtractionBlank
        human-a\t10.5\t0
        """.write(
            to: bundleURL.appendingPathComponent("sample-target-counts.tsv"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertThrowsError(try TwelveSAmpliconResultBundle.loadResult(from: bundleURL)) { error in
            XCTAssertTrue(String(describing: error).contains("integer"))
        }
    }

    private func makeSyntheticBundle() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwelveSAmpliconResultBundleTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("hilo-f09.lungfish12s", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let manifest = TwelveSAmpliconResultBundleManifest(
            outputName: "hilo-f09",
            analysisName: "Hilo F09 12S",
            referencePath: "reference.fa",
            targetTablePath: "targets.tsv",
            countMatrixPath: "sample-target-counts.tsv",
            sampleTablePath: "samples.tsv",
            readFatePath: "read-fate.json",
            alternateMatchesTablePath: "target-alternate-matches.tsv",
            unresolvedTablePath: "unresolved-sequences.tsv",
            unresolvedFastaPath: "unresolved-sequences.fasta",
            provenancePath: ".lungfish-provenance.json",
            createdAt: "2026-05-27T12:00:00Z"
        )
        try TwelveSAmpliconResultBundle.writeManifest(manifest, to: bundleURL)

        try "reference".write(to: bundleURL.appendingPathComponent("reference.fa"), atomically: true, encoding: .utf8)
        try "{}".write(to: bundleURL.appendingPathComponent(".lungfish-provenance.json"), atomically: true, encoding: .utf8)
        try """
        target_id\tdisplay_name\tscientific_name\tcommon_name\ttaxid\ttaxon_group\ttaxonomy\tname_source\tlocus\tlength\tn_refs\tn_species\tprimer_pairs\tsource_header
        human-a\thuman (Homo sapiens)\tHomo sapiens\thuman\t9606\tMammal\troot; Eukaryota; Chordata; Mammalia; Primates; Homo sapiens\tncbi_common\t12S\t107\t1572\t2\t12S_vert_F_x_12S_vert_R\thuman (Homo sapiens)|locus=12S|len=107|n_refs=1572|also_matches=Heidelberg man (Homo heidelbergensis)
        human-b\tancient human (Homo sapiens)\tHomo sapiens\tancient human\t9606\tMammal\troot; Eukaryota; Chordata; Mammalia; Primates; Homo sapiens\tncbi_common\t12S\t106\t12\t2\t12S_vert_F_x_12S_vert_R\tancient human (Homo sapiens)|locus=12S|len=106|n_refs=12|also_matches=Neanderthal (Homo neanderthalensis)
        dog\tdog (Canis lupus familiaris)\tCanis lupus familiaris\tdog\t9615\tMammal\troot; Eukaryota; Chordata; Mammalia; Carnivora; Canis lupus familiaris\tncbi_common\t12S\t101\t44\t1\t12S_vert_F_x_12S_vert_R\tdog (Canis lupus familiaris)|locus=12S|len=101
        pig\tpig (Sus scrofa)\tSus scrofa\tpig\t9823\tMammal\troot; Eukaryota; Chordata; Mammalia; Artiodactyla; Sus scrofa\tncbi_common\t12S\t99\t35\t1\t12S_vert_F_x_12S_vert_R\tpig (Sus scrofa)|locus=12S|len=99
        """.write(to: bundleURL.appendingPathComponent("targets.tsv"), atomically: true, encoding: .utf8)
        try """
        target_id\tdisplay_name\tscientific_name\tcommon_name\ttaxid\ttaxon_group\ttaxonomy\tname_source\treason
        human-a\tHeidelberg man (Homo heidelbergensis)\tHomo heidelbergensis\tHeidelberg man\t1425170\tMammal\troot; Eukaryota; Chordata; Mammalia; Primates; Homo heidelbergensis\tncbi_common\tshared_exact_amplicon
        human-b\tNeanderthal (Homo neanderthalensis)\tHomo neanderthalensis\tNeanderthal\t63221\tMammal\troot; Eukaryota; Chordata; Mammalia; Primates; Homo neanderthalensis\tncbi_common\tshared_exact_amplicon
        dog\trainbow trout (Oncorhynchus mykiss)\tOncorhynchus mykiss\trainbow trout\t8022\tFish\troot; Eukaryota; Chordata; Actinopteri; Oncorhynchus mykiss\tfishbase\tshared_exact_amplicon
        """.write(to: bundleURL.appendingPathComponent("target-alternate-matches.tsv"), atomically: true, encoding: .utf8)
        try """
        target_id\tHI_Hilo_F09\tExtractionBlank
        human-a\t10\t2
        human-b\t3\t0
        dog\t4\t0
        pig\t1\t0
        """.write(to: bundleURL.appendingPathComponent("sample-target-counts.tsv"), atomically: true, encoding: .utf8)
        try """
        sample_id\tdisplay_name\tinput_reads\texact_match_reads\tunresolved_reads\tambiguous_exact_reads\tchimera_candidate_reads\texact_match_percent\tunresolved_percent
        HI_Hilo_F09\tHI Hilo F09\t50\t18\t32\t0\t1\t36.0\t64.0
        ExtractionBlank\tExtraction Blank\t18\t2\t16\t0\t0\t11.111111\t88.888889
        """.write(to: bundleURL.appendingPathComponent("samples.tsv"), atomically: true, encoding: .utf8)
        try """
        {
          "totalReads": 68,
          "exactMatchReads": 20,
          "unresolvedReads": 48,
          "ambiguousExactReads": 0,
          "chimeraCandidateReads": 1
        }
        """.write(to: bundleURL.appendingPathComponent("read-fate.json"), atomically: true, encoding: .utf8)
        try """
        sequence_id\tsequence\tread_count\tsample_counts\tchimera_status\tnote
        unresolved_1\tACGTACGT\t12\tHI_Hilo_F09:12\tcandidate\tvsearch_denovo
        unresolved_2\tTTTTCCCC\t4\tExtractionBlank:4\tnot_detected\t
        """.write(to: bundleURL.appendingPathComponent("unresolved-sequences.tsv"), atomically: true, encoding: .utf8)
        try """
        >unresolved_1 read_count=12 chimera_status=candidate
        ACGTACGT
        >unresolved_2 read_count=4 chimera_status=not_detected
        TTTTCCCC
        """.write(to: bundleURL.appendingPathComponent("unresolved-sequences.fasta"), atomically: true, encoding: .utf8)

        return bundleURL
    }
}
