// ProvenanceInspectorLoosePairAffectedTests.swift - The Inspector finds the new kinds of the 5.6 affected rows
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane AFFECTED-5.6. A CZ ID result names its kind by its sidebar type, a mapping in the Analyses folder by its tool and
// its record, and a FASTQ bundle by its record. The kinds are read by their raw values, so the tests build at the base.

import XCTest
import LungfishIO
import LungfishWorkflow
@testable import LungfishApp

@MainActor
final class ProvenanceInspectorLoosePairAffectedTests: XCTestCase {
    private func item(_ type: SidebarItemType?, at url: URL = URL(fileURLWithPath: "/tmp/affected-loose-pair-test"))
        -> ProvenanceInspectableItem {
        ProvenanceInspectableItem(url: url, sidebarType: type, contentMode: .metagenomics, displayName: "result")
    }

    private func kind(_ item: ProvenanceInspectableItem, _ envelope: ProvenanceEnvelope? = nil) -> String? {
        ProvenanceInspectorViewModel.affectedResultKind(for: item, envelope: envelope)?.rawValue
    }

    private func record(
        _ workflow: String, app: String, explicit: [String: ParameterValue] = [:], inputs: [String] = []
    ) -> ProvenanceEnvelope {
        var envelope = ProvenanceEnvelope.fixture()
        envelope.workflowName = workflow
        envelope.runtimeIdentity = ProvenanceRuntimeIdentity(appVersion: app)
        envelope.options = ProvenanceOptions(explicit: explicit)
        envelope.files = inputs.map {
            ProvenanceFileDescriptor(path: $0, checksumSHA256: String(repeating: "a", count: 64), fileSize: 12,
                                     format: .fastq, role: .input)
        }
        envelope.steps = []
        return envelope
    }

    /// The backlog ids the Warnings of a lookup of `item` that found `envelope` show, and those it told the strip.
    private func shownAndPosted(
        _ item: ProvenanceInspectableItem, _ envelope: ProvenanceEnvelope
    ) -> (shown: [String], posted: [String]?) {
        let model = ProvenanceInspectorViewModel()
        model.resolvedEnvelope = envelope
        var posted: [String]?
        let token = NotificationCenter.default.addObserver(
            forName: .affectedResultsDidChange, object: model, queue: nil
        ) { note in
            posted = (note.userInfo?[ProvenanceInspectorViewModel.affectedResultsRowsKey] as? [AffectedResultRow])?
                .map(\.backlogID)
        }
        defer { NotificationCenter.default.removeObserver(token) }
        model.applyAffectedResults(kind: ProvenanceInspectorViewModel.affectedResultKind(for: item, envelope: envelope))
        let shown = model.warnings.filter { $0.title == ProvenanceInspectorViewModel.affectedResultsWarningTitle }
            .map(\.message)
        let ids = shown.compactMap { message in AffectedResults.rows.first { $0.words == message }?.backlogID }
        return (ids, posted)
    }

    /// A mapping folder of the Analyses folder, whose metadata names the mapper.
    private func mappingFolder(_ tool: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("affected-mapping-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try AnalysesFolder.writeAnalysisMetadata(.init(tool: tool, isBatch: false), to: url)
        return url
    }

    private let loose = ["/data/run/S_R1.fastq.gz", "/data/run/S_R2.fastq.gz"]
    private let inBundle = ["/p/Imports/S.lungfishfastq/S_R1.fastq.gz", "/p/Imports/S.lungfishfastq/S_R2.fastq.gz"]

    func testACZIDResultShowsTheCZIDRowUpToPreview20261115() {
        XCTAssertEqual(kind(item(.czIdResult)), "czIdImport")
        let stable = shownAndPosted(item(.czIdResult), record("CZ-ID Import", app: "Lungfish 2026.11.14 (13927)"))
        XCTAssertEqual(stable.shown, ["CZID-REAL-EXPORT-FORMAT"])
        XCTAssertEqual(stable.posted, ["CZID-REAL-EXPORT-FORMAT"])
        XCTAssertEqual(shownAndPosted(item(.czIdResult), record("CZ-ID Import", app: "Lungfish 2026.11.16 (14073)")).shown,
                       [])
        XCTAssertEqual(kind(item(.classificationResult), record("CZ-ID Import", app: "Lungfish 2026.11.15 (14072)")),
                       "kraken2", "a Kraken 2 result keeps its own kind")
    }

    func testAMappingOfTwoLooseFilesShowsBothLoosePairRowsAndABundleMappingNothing() throws {
        let paired: [String: ParameterValue] = ["pairedEnd": .boolean(true)]
        for tool in ["minimap2", "bwa-mem2", "bowtie2", "bbmap"] {
            let folder = try mappingFolder(tool)
            let mapped = record("lungfish map", app: "Lungfish 2026.11.15 (14072)", explicit: paired, inputs: loose)
            XCTAssertEqual(kind(item(.analysisResult, at: folder), mapped), "mappingLoosePair", tool)
            let shown = shownAndPosted(item(.analysisResult, at: folder), mapped)
            XCTAssertEqual(shown.shown, ["LOOSE-PAIR-SHORT-MATE", "LOOSE-PAIR-OUT-OF-STEP"], tool)
            XCTAssertEqual(shown.posted, ["LOOSE-PAIR-SHORT-MATE", "LOOSE-PAIR-OUT-OF-STEP"], tool)
            let bundle = record("lungfish map", app: "Lungfish 2026.11.15 (14072)", explicit: paired, inputs: inBundle)
            XCTAssertEqual(kind(item(.analysisResult, at: folder), bundle), nil, "\(tool) of a bundle pair")
            XCTAssertEqual(kind(item(.analysisResult, at: folder)), nil, "\(tool) with no record")
        }
        XCTAssertEqual(ProvenanceInspectorViewModel.affectedResultKind(forTool: "minimap2"), nil,
                       "a mapper alone names no kind, its record does")
    }

    func testABundleImportedFromTwoLooseFilesShowsTheOutOfStepRow() {
        let pair: [String: ParameterValue] = [
            "r1": .file(URL(fileURLWithPath: loose[0])), "r2": .file(URL(fileURLWithPath: loose[1])),
        ]
        let imported = record("lungfish import fastq", app: "Lungfish 2026.11.14 (13927)", explicit: pair)
        XCTAssertEqual(kind(item(.fastqBundle), imported), "fastqLoosePairImport")
        let bundle = shownAndPosted(item(.fastqBundle), imported)
        XCTAssertEqual(bundle.shown, ["LOOSE-PAIR-OUT-OF-STEP"])
        XCTAssertEqual(bundle.posted, ["LOOSE-PAIR-OUT-OF-STEP"])
        let fixed = record("lungfish import fastq", app: "Lungfish 2026.11.16 (14073)", explicit: pair)
        XCTAssertEqual(shownAndPosted(item(.fastqBundle), fixed).shown, [])
        let oneFile = record("lungfish import fastq", app: "Lungfish 2026.11.14 (13927)",
                             explicit: ["r1": pair["r1"]!, "r2": .null])
        XCTAssertEqual(shownAndPosted(item(.fastqBundle), oneFile).shown, [], "an import of one file")
    }
}
