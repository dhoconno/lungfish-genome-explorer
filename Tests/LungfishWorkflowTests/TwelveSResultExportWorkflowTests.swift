import Foundation
import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow

final class TwelveSResultExportWorkflowTests: XCTestCase {
    func testExportsFilteredSpeciesRowsWithTaxonomyAndProvenance() async throws {
        let bundleURL = try makeBundle()
        let outputURL = bundleURL.deletingLastPathComponent().appendingPathComponent("species.csv")

        let result = try await TwelveSResultExportWorkflow().export(
            TwelveSResultExportConfiguration(
                bundleURL: bundleURL,
                outputURL: outputURL,
                format: .csv,
                minimumExactReads: 4,
                filterText: "canis",
                requireAlternateMatches: true,
                argv: [
                    "lungfish-cli", "fastq", "12s-export",
                    "--bundle", bundleURL.path,
                    "--format", "csv",
                    "--output", outputURL.path,
                ]
            )
        )

        let text = try String(contentsOf: result.outputURL, encoding: .utf8)
        XCTAssertTrue(text.contains("Scientific Name,Common Names,Taxon Groups,Taxids,Exact Reads"))
        XCTAssertTrue(text.contains("Canis lupus familiaris,dog,Mammal,9615; 9612,5"))
        XCTAssertFalse(text.contains("Homo sapiens"))
        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: result.provenanceURL))
        XCTAssertEqual(provenance.workflowName, "lungfish fastq 12s-export")
        XCTAssertTrue(provenance.files.contains { $0.path == bundleURL.appendingPathComponent("targets.tsv").path })
        XCTAssertTrue(provenance.outputs.contains { $0.path == outputURL.path })
    }

    func testExportFallbackArgvIncludesNonDefaultFilters() async throws {
        let bundleURL = try makeBundle()
        let outputURL = bundleURL.deletingLastPathComponent().appendingPathComponent("species.filtered.tsv")

        let result = try await TwelveSResultExportWorkflow().export(
            TwelveSResultExportConfiguration(
                bundleURL: bundleURL,
                outputURL: outputURL,
                format: .tsv,
                minimumExactReads: 1,
                filterText: "canis",
                taxonGroups: ["Mammal"],
                excludedTaxonGroups: ["Fish"],
                excludeHuman: true,
                requireAlternateMatches: true,
                minimumUnresolvedReads: 6,
                chimeraFilter: .candidate,
                forceOverwrite: true
            )
        )

        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: result.provenanceURL))
        XCTAssertEqual(provenance.argv.prefix(3), ["lungfish-cli", "fastq", "12s-export"])
        XCTAssertTrue(provenance.argv.contains("--min-exact-reads"))
        XCTAssertTrue(provenance.argv.contains("--filter"))
        XCTAssertTrue(provenance.argv.contains("--taxon-group"))
        XCTAssertTrue(provenance.argv.contains("--exclude-taxon-group"))
        XCTAssertTrue(provenance.argv.contains("--exclude-human"))
        XCTAssertTrue(provenance.argv.contains("--require-alternate-matches"))
        XCTAssertTrue(provenance.argv.contains("--min-unresolved-reads"))
        XCTAssertTrue(provenance.argv.contains("--chimera-status"))
        XCTAssertTrue(provenance.argv.contains("--force"))
    }

    func testTaxonGroupExportFilterUsesInferredGroupsWhenReferenceMetadataIsAbsent() async throws {
        let bundleURL = try makeBundle(includeTaxonGroups: false)
        let outputURL = bundleURL.deletingLastPathComponent().appendingPathComponent("mammals.csv")

        _ = try await TwelveSResultExportWorkflow().export(
            TwelveSResultExportConfiguration(
                bundleURL: bundleURL,
                outputURL: outputURL,
                format: .csv,
                taxonGroups: ["Mammal"],
                excludeHuman: true,
                forceOverwrite: true
            )
        )

        let text = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertTrue(text.contains("Canis lupus familiaris,dog,Mammal,9615; 9612,5"))
        XCTAssertFalse(text.contains("Homo sapiens"))
    }

    func testExportsUnresolvedFastaAboveThresholdAndMetadataSidecar() async throws {
        let bundleURL = try makeBundle()
        let outputURL = bundleURL.deletingLastPathComponent().appendingPathComponent("unresolved.fasta")

        let result = try await TwelveSUnresolvedFastaExportWorkflow().export(
            TwelveSUnresolvedFastaExportConfiguration(
                bundleURL: bundleURL,
                outputURL: outputURL,
                minimumReads: 5,
                includeChimeraCandidates: false,
                argv: [
                    "lungfish-cli", "fastq", "12s-export-unresolved",
                    "--bundle", bundleURL.path,
                    "--min-reads", "5",
                    "--output", outputURL.path,
                ]
            )
        )

        let fasta = try String(contentsOf: result.outputURL, encoding: .utf8)
        XCTAssertTrue(fasta.contains(">unresolved_1"))
        XCTAssertTrue(fasta.contains("read_count=12"))
        XCTAssertFalse(fasta.contains("unresolved_2"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.metadataURL.path))
        let metadata = try String(contentsOf: result.metadataURL, encoding: .utf8)
        XCTAssertTrue(metadata.contains("sequence_id\tsequence_sha256\tread_count"))
        XCTAssertTrue(metadata.contains("unresolved_1"))
        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: result.provenanceURL))
        XCTAssertEqual(provenance.workflowName, "lungfish fastq 12s-export-unresolved")
        XCTAssertTrue(provenance.outputs.contains { $0.path == outputURL.path })
    }

    func testUnresolvedExportCanSelectExplicitChimeraSequenceIDs() async throws {
        let bundleURL = try makeBundle()
        let outputURL = bundleURL.deletingLastPathComponent().appendingPathComponent("selected-unresolved.fasta")

        let result = try await TwelveSUnresolvedFastaExportWorkflow().export(
            TwelveSUnresolvedFastaExportConfiguration(
                bundleURL: bundleURL,
                outputURL: outputURL,
                minimumReads: 5,
                includeChimeraCandidates: true,
                sequenceIDs: ["unresolved_2"],
                forceOverwrite: true
            )
        )

        let fasta = try String(contentsOf: result.outputURL, encoding: .utf8)
        XCTAssertFalse(fasta.contains(">unresolved_1"))
        XCTAssertTrue(fasta.contains(">unresolved_2"))
        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: result.provenanceURL))
        XCTAssertTrue(provenance.argv.contains("--sequence-id"))
        XCTAssertTrue(provenance.argv.contains("--include-chimera-candidates"))
        XCTAssertTrue(provenance.argv.contains("--force"))
    }

    private func makeBundle(includeTaxonGroups: Bool = true) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwelveSResultExportWorkflowTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("sample.lungfish12s", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let manifest = TwelveSAmpliconResultBundleManifest(
            outputName: "sample",
            analysisName: "Sample",
            referencePath: "reference.fa",
            targetTablePath: "targets.tsv",
            countMatrixPath: "sample-target-counts.tsv",
            sampleTablePath: "samples.tsv",
            readFatePath: "read-fate.json",
            alternateMatchesTablePath: "target-alternate-matches.tsv",
            unresolvedTablePath: "unresolved-sequences.tsv",
            unresolvedFastaPath: "unresolved-sequences.fasta",
            provenancePath: ".lungfish-provenance.json"
        )
        try TwelveSAmpliconResultBundle.writeManifest(manifest, to: bundleURL)
        try ">ref\nACGT\n".write(to: bundleURL.appendingPathComponent("reference.fa"), atomically: true, encoding: .utf8)
        try "{}".write(to: bundleURL.appendingPathComponent(".lungfish-provenance.json"), atomically: true, encoding: .utf8)
        try """
        target_id\tdisplay_name\tscientific_name\tcommon_name\ttaxid\ttaxon_group\ttaxonomy\tname_source\tlocus\tlength\tn_refs\tn_species\tprimer_pairs\tsource_header
        human\thuman (Homo sapiens)\tHomo sapiens\thuman\t9606\t\(includeTaxonGroups ? "Mammal" : "")\t\(includeTaxonGroups ? "root; Eukaryota; Mammalia" : "")\tncbi_common\t12S\t107\t2\t1\t12S_vert\thuman (Homo sapiens)
        dog\tdog (Canis lupus familiaris)\tCanis lupus familiaris\tdog\t9615\t\(includeTaxonGroups ? "Mammal" : "")\t\(includeTaxonGroups ? "root; Eukaryota; Mammalia" : "")\tncbi_common\t12S\t101\t4\t1\t12S_vert\tdog (Canis lupus familiaris)
        """.write(to: bundleURL.appendingPathComponent("targets.tsv"), atomically: true, encoding: .utf8)
        try """
        target_id\tdisplay_name\tscientific_name\tcommon_name\ttaxid\ttaxon_group\ttaxonomy\tname_source\treason
        dog\twolf (Canis lupus)\tCanis lupus\twolf\t9612\t\(includeTaxonGroups ? "Mammal" : "")\t\(includeTaxonGroups ? "root; Eukaryota; Mammalia" : "")\tncbi_common\tshared_exact_amplicon
        """.write(to: bundleURL.appendingPathComponent("target-alternate-matches.tsv"), atomically: true, encoding: .utf8)
        try """
        target_id\tSampleA
        human\t3
        dog\t5
        """.write(to: bundleURL.appendingPathComponent("sample-target-counts.tsv"), atomically: true, encoding: .utf8)
        try """
        sample_id\tdisplay_name\tinput_reads\texact_match_reads\tunresolved_reads\tambiguous_exact_reads\tchimera_candidate_reads\texact_match_percent\tunresolved_percent
        SampleA\tSample A\t30\t8\t22\t0\t8\t26.666667\t73.333333
        """.write(to: bundleURL.appendingPathComponent("samples.tsv"), atomically: true, encoding: .utf8)
        try """
        {"totalReads":30,"exactMatchReads":8,"unresolvedReads":22,"ambiguousExactReads":0,"chimeraCandidateReads":8}
        """.write(to: bundleURL.appendingPathComponent("read-fate.json"), atomically: true, encoding: .utf8)
        try """
        sequence_id\tsequence\tread_count\tsample_counts\tchimera_status\tnote
        unresolved_1\tACGTACGT\t12\tSampleA:12\tnot_detected\t
        unresolved_2\tTTTTCCCC\t8\tSampleA:8\tcandidate\t
        unresolved_3\tGGGGAAAA\t3\tSampleA:3\tnot_detected\t
        """.write(to: bundleURL.appendingPathComponent("unresolved-sequences.tsv"), atomically: true, encoding: .utf8)
        try """
        >unresolved_1
        ACGTACGT
        """.write(to: bundleURL.appendingPathComponent("unresolved-sequences.fasta"), atomically: true, encoding: .utf8)
        return bundleURL
    }
}
