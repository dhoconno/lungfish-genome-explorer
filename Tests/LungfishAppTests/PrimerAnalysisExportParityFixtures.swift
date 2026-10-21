// PrimerAnalysisExportParityFixtures.swift - Saved primer analyses for the tests of the two primer export leaves
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import LungfishIO
import XCTest
@testable import LungfishWorkflow

/// The saved analyses that the parity class of `primers analysis export-order` and
/// `export-selection` run on (Phase 2.13 lane 13.43 M3). They are the fixtures of the two command test classes, built in
/// a folder the caller owns, so the parity class copies one into each side root.
enum PrimerAnalysisExportParityFixtures {
    /// A saved Primer3 analysis with `pairCount` candidate pairs, written in `root`. Returns its physical URL.
    static func primer3(in root: URL, pairCount: Int) throws -> URL {
        let analysisID = UUID(), runID = UUID(), inputID = UUID(), resultID = UUID()
        let template = "ACGTACGT"
        let input = root.appendingPathComponent("input.fasta")
        try Data(">\(inputID.uuidString)\n\(template)\n".utf8).write(to: input)
        let native = root.appendingPathComponent("native.txt")
        try Data("Synthetic Primer3 fixture, not an engine execution.\n".utf8).write(to: native)
        func oligo(start: Int, end: Int, orientation: String, sequence: String) -> [String: Any] {
            ["id": UUID().uuidString, "start": start, "end": end, "orientation": orientation,
             "sequence": sequence, "meltingTemperature": 60.0, "gcPercent": 50.0]
        }
        let pairs: [[String: Any]] = (0..<pairCount).map { index in
            ["id": UUID().uuidString, "productSize": 8 - index,
             "left": oligo(start: 0, end: 2, orientation: "forward", sequence: "AC"),
             "right": oligo(start: 6 - index, end: 8 - index, orientation: "reverse", sequence: index == 0 ? "AC" : "GT")]
        }
        let result: [String: Any] = [
            "resultID": resultID.uuidString, "inputID": inputID.uuidString,
            "title": "Synthetic display fixture", "sourceKind": "fasta",
            "sourceIndex": 0, "sourceRecordID": "synthetic-display-fixture",
            "templateSequence": template, "excludedRegions": [], "pairs": pairs, "explanation": "Synthetic candidate fixture.",
        ]
        let document: [String: Any] = ["schemaVersion": 1, "analysisID": analysisID.uuidString,
            "runID": runID.uuidString, "results": [result]]
        let normalized = root.appendingPathComponent("normalized.json")
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
            artifacts: artifacts, destinationURL: root.appendingPathComponent("fixture.lungfishprimeranalysis"),
            invocation: .init(argv: ["export-order-fixture"], callerVersion: "test", explicitOptions: [:], runtimeIdentity: .init())))
        return try physical(bundle.url)
    }

    /// A PrimalScheme-style analysis with one amplicon and three primers, written in `root`. Returns its physical URL.
    static func primalScheme(in root: URL) throws -> URL {
        let inputID = UUID(), resultID = UUID()
        let payloads = [
            "inputs/source.fasta": ">reference\nAACCGGTTAACC\n",
            "native/reference.fasta": ">reference\nAACCGGTTAACC\n",
            "native/primer.bed": "reference\t2\t4\tfixture_1_LEFT_0\t1\t+\tCC\nreference\t2\t4\tfixture_1_LEFT_1\t1\t+\tCR\nreference\t8\t10\tfixture_1_RIGHT_0\t1\t-\tTT\n",
            "native/amplicon.bed": "reference\t2\t10\tfixture_1\t1\n",
        ]
        let artifacts = try payloads.sorted { $0.key < $1.key }.map { path, text in
            let source = root.appendingPathComponent(UUID().uuidString)
            try Data(text.utf8).write(to: source)
            return PrimerAnalysisSourceArtifact(sourceURL: source, relativePath: path,
                role: path.hasPrefix("inputs/") ? "input" : "nativeOutput", format: path.hasSuffix(".bed") ? "bed" : "fasta")
        }
        let bundle = try PrimerAnalysisBundleWriter(provenanceWriter: .init(signingProvider: nil)).write(.init(
            analysisID: UUID(), runID: UUID(), grouping: .independent,
            inputs: [.init(id: inputID, artifactPaths: ["inputs/source.fasta"])],
            results: [.init(id: resultID, label: "Stored synthetic MHC display example", inputIDs: [inputID],
                artifactPaths: payloads.keys.filter { $0.hasPrefix("native/") }.sorted())], artifacts: artifacts,
            destinationURL: root.appendingPathComponent("source.lungfishprimeranalysis"),
            invocation: .init(argv: ["export-selection-fixture"], callerVersion: "test", explicitOptions: [:], runtimeIdentity: .init())))
        return try physical(bundle.url)
    }

    /// The folder at `url` spelled by `realpath(3)`. Foundation's `resolvingSymlinksInPath()` turns `/private/var` back into
    /// `/var`, which the writer's no-follow walk refuses (lane 13.49), so a fixture root that the writer walks comes from here.
    static func physical(_ url: URL) throws -> URL {
        let resolved = try XCTUnwrap(realpath(url.path, nil))
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }
}
