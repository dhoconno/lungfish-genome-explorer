// UnsignedWriterFamiliesSigningTests+Exports.swift - S5, builders, imports and exports
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.14 (K10). The primer order export writes its record into a staged folder and renames the folder
// whole, and a signature names its record by file name with a reference relative to the record's folder, so the pair
// made in the stage verifies after the rename. The 12S result export writes a sidecar beside its output at its final
// name.

import Darwin
import Foundation
import XCTest
import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

extension UnsignedWriterFamiliesSigningTests {
    func testPrimerOrderExportRecordIsSignedAndVerifiesAfterTheFolderIsRenamedWhole() async throws {
        let restoreKey = try useThrowawayKey()
        defer { restoreKey() }

        // The export refuses a destination folder reached through a symbolic link, so build under the physical path.
        let physical = try XCTUnwrap(realpath(root.path, nil))
        defer { free(physical) }
        let physicalRoot = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
        let bundle = try makePrimer3Bundle(in: physicalRoot)
        let snapshot = try PrimerAnalysisViewerSnapshot.load(from: bundle)
        let selection = try PrimerOrderExportService.captureSelection(
            snapshot: snapshot, scope: PrimerOrderExportService.defaultScope(for: snapshot)
        )

        let output = try await PrimerOrderExportService().export(
            selection: selection,
            metadata: .init(name: "Signed order", requestedBy: "Tester", project: "P13", notes: "Key set"),
            destinationURL: physicalRoot.appendingPathComponent("signed-order", isDirectory: true),
            invocationArgv: ["Lungfish", "test-order-export"]
        )

        let record = output.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        try assertSignedOnce(record, "a primer order export")
    }

    func testTwelveSResultExportSidecarIsSignedAtItsFinalPath() async throws {
        let restoreKey = try useThrowawayKey()
        defer { restoreKey() }

        let bundleURL = try makeTwelveSBundle()
        let outputURL = root.appendingPathComponent("species.csv")
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

        XCTAssertEqual(result.provenanceURL, ProvenanceRecorder.fileSidecarURL(for: outputURL))
        try assertSignedOnce(result.provenanceURL, "a 12S result export")
    }

    /// The bulk form of `bundle export-graphic` (lane 13.30) writes its one record into a staged folder and renames the
    /// folder whole, as the primer order export does, so the pair made in the stage verifies after the rename.
    func testBulkFigureExportFolderRecordIsSignedAndVerifiesAfterTheFolderIsRenamedWhole() throws {
        let restoreKey = try useThrowawayKey()
        defer { restoreKey() }

        let folder = root.appendingPathComponent("figures", isDirectory: true)
        let request = ScientificFileExportProvenance.Request.cliLeaf(
            workflowName: "lungfish bundle export-graphic", sourceURLs: [], outputURL: folder,
            outputFormat: FileFormat(rawValue: "png"), argv: ["lungfish-cli", "bundle", "export-graphic"],
            resolved: [:], runClock: ProvenanceRunClock()
        )

        let record = try ScientificFileExportProvenance.writeFolderAtomically(request) { staged in
            try Data("figure".utf8).write(to: staged.appendingPathComponent("a.png"))
            return ["a.png"]
        }

        XCTAssertEqual(record.deletingLastPathComponent().standardizedFileURL, folder.standardizedFileURL)
        try assertSignedOnce(record, "a bulk figure export")
    }

    /// A synthetic saved Primer3 analysis on one FASTA template, written by the real bundle writer, as
    /// `PrimerOrderCaptureSelectionTests` builds one. The fixture's own record stays unsigned, since it is not under test.
    func makePrimer3Bundle(in directory: URL) throws -> URL {
        let analysisID = UUID(), runID = UUID(), inputID = UUID(), resultID = UUID()
        let template = "ACGTACGT"
        let input = directory.appendingPathComponent("input.fasta")
        try Data(">\(inputID.uuidString)\n\(template)\n".utf8).write(to: input)
        let native = directory.appendingPathComponent("native.txt")
        try Data("Synthetic Primer3 fixture, not an engine execution.\n".utf8).write(to: native)
        func oligo(start: Int, end: Int, orientation: String, sequence: String) -> [String: Any] {
            ["id": UUID().uuidString, "start": start, "end": end, "orientation": orientation,
             "sequence": sequence, "meltingTemperature": 60.0, "gcPercent": 50.0]
        }
        let pair: [String: Any] = ["id": UUID().uuidString, "productSize": 8,
            "left": oligo(start: 0, end: 2, orientation: "forward", sequence: "AC"),
            "right": oligo(start: 6, end: 8, orientation: "reverse", sequence: "AC")]
        let result: [String: Any] = [
            "resultID": resultID.uuidString, "inputID": inputID.uuidString,
            "title": "Synthetic display fixture", "sourceKind": "fasta",
            "sourceIndex": 0, "sourceRecordID": "synthetic-display-fixture",
            "templateSequence": template, "excludedRegions": [], "pairs": [pair],
            "explanation": "Synthetic candidate fixture.",
        ]
        let document: [String: Any] = ["schemaVersion": 1, "analysisID": analysisID.uuidString,
            "runID": runID.uuidString, "results": [result]]
        let normalized = directory.appendingPathComponent("normalized.json")
        try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(to: normalized)
        let path = "results/primer3-normalized-v1.json"
        let artifacts: [PrimerAnalysisSourceArtifact] = [
            .init(sourceURL: input, relativePath: "inputs/\(inputID.uuidString).fasta", role: "input", format: "fasta"),
            .init(sourceURL: native, relativePath: "native/output.txt", role: "nativeOutput", format: "text"),
            .init(sourceURL: normalized, relativePath: path, role: "normalized", format: "json"),
        ]
        let bundle = try PrimerAnalysisBundleWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil)).write(.init(
            analysisID: analysisID, runID: runID, grouping: .independent,
            inputs: [.init(id: inputID, label: "Fixture", artifactPaths: ["inputs/\(inputID.uuidString).fasta"])],
            results: [.init(id: resultID, inputIDs: [inputID], artifactPaths: [path])],
            artifacts: artifacts, destinationURL: directory.appendingPathComponent("fixture.lungfishprimeranalysis"),
            invocation: .init(argv: CommandLine.arguments, callerVersion: "test", explicitOptions: [:], runtimeIdentity: .init())))
        return bundle.url
    }

    /// A 12S result bundle with the tables the export reads, as `TwelveSResultExportWorkflowTests` builds one.
    func makeTwelveSBundle() throws -> URL {
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
            reassignmentsTablePath: nil,
            resolvedSampleMetadataPath: nil,
            sampleMetadataManifestPath: nil,
            provenancePath: ".lungfish-provenance.json"
        )
        try TwelveSAmpliconResultBundle.writeManifest(manifest, to: bundleURL)
        try ">ref\nACGT\n".write(to: bundleURL.appendingPathComponent("reference.fa"), atomically: true, encoding: .utf8)
        try "{}".write(to: bundleURL.appendingPathComponent(".lungfish-provenance.json"), atomically: true, encoding: .utf8)
        try """
        target_id\tdisplay_name\tscientific_name\tcommon_name\ttaxid\ttaxon_group\ttaxonomy\tname_source\tlocus\tlength\tn_refs\tn_species\tprimer_pairs\tsource_header
        human\thuman (Homo sapiens)\tHomo sapiens\thuman\t9606\tMammal\troot; Eukaryota; Mammalia\tncbi_common\t12S\t107\t2\t1\t12S_vert\thuman (Homo sapiens)
        dog\tdog (Canis lupus familiaris)\tCanis lupus familiaris\tdog\t9615\tMammal\troot; Eukaryota; Mammalia\tncbi_common\t12S\t101\t4\t1\t12S_vert\tdog (Canis lupus familiaris)
        """.write(to: bundleURL.appendingPathComponent("targets.tsv"), atomically: true, encoding: .utf8)
        try """
        target_id\tdisplay_name\tscientific_name\tcommon_name\ttaxid\ttaxon_group\ttaxonomy\tname_source\treason
        dog\twolf (Canis lupus)\tCanis lupus\twolf\t9612\tMammal\troot; Eukaryota; Mammalia\tncbi_common\tshared_exact_amplicon
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
