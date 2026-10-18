// PrimerSelectionExportParityTests.swift - The folder a primer selection export writes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.15 (A67-M3). "Save Primer FASTA Bundle" and "Extract Reference Amplicon" write a new
// .lungfishref folder through PrimerAnalysisSelectionExportService. M1 pins at the base what the app writes
// for a primer, an amplicon, a numbered pool and a native pool, and the argv the app records for it, which
// names `Lungfish.app export-primer-selection`, a command that does not exist. M2 adds the parity test that
// runs the command the row records through the real leaf and compares its folder with the app's.

import Darwin
import Foundation
import LungfishCore
import LungfishIO
import LungfishKit
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
@testable import LungfishWorkflow

@MainActor
final class PrimerSelectionExportParityTests: XCTestCase {
    /// One selection the viewer offers, with what its folder must hold.
    private struct Case {
        let label: String
        let selection: PrimerAnalysisExportSelection
        let kind: PrimerAnalysisExportKind
        /// The sequences of the payload records, in file order.
        let sequences: [String]
        /// Text every record header holds.
        let headerParts: [String]
        /// The rows of binding-sites.bed, nil when the folder holds none.
        let bedRows: Int?
        /// The key `selection.json` stores the selection under.
        let selectionKey: String
        /// One option the provenance resolves for this selection.
        let option: (String, ParameterValue)
    }

    private struct Fixture {
        let root: URL
        let bundle: URL
    }

    // MARK: - Pins at the base

    func testEverySelectionFolderHoldsItsPayloadItsSelectionAndItsEvidence() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let snapshot = try PrimerAnalysisViewerSnapshot.load(from: fixture.bundle)
        for item in try cases(snapshot) {
            let folder = try await exportAsTheAppDoes(fixture, item)
            let entries = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
            let payload = item.kind == .primerFASTA ? "primers.fasta" : "amplicon.fasta"
            XCTAssertTrue(
                entries.isSuperset(of: [payload, "selection.json", "source-analysis", "manifest.json"]),
                "\(item.label): \(entries.sorted())")
            XCTAssertEqual(entries.contains("binding-sites.bed"), item.bedRows != nil, "\(item.label): \(entries.sorted())")

            let records = try fastaRecords(folder.appendingPathComponent(payload))
            XCTAssertEqual(records.map(\.sequence), item.sequences, item.label)
            for record in records {
                for part in item.headerParts {
                    XCTAssertTrue(record.header.contains(part), "\(item.label): \(record.header) lacks \(part)")
                }
            }
            if let rows = item.bedRows {
                let bed = try String(contentsOf: folder.appendingPathComponent("binding-sites.bed"), encoding: .utf8)
                XCTAssertEqual(bed.split(whereSeparator: \.isNewline).count, rows, item.label)
            }

            let document = try XCTUnwrap(JSONSerialization.jsonObject(
                with: Data(contentsOf: folder.appendingPathComponent("selection.json"))) as? [String: Any])
            XCTAssertEqual(document["kind"] as? String, item.kind.rawValue, item.label)
            XCTAssertEqual(document["outputBundlePath"] as? String, folder.path, item.label)
            XCTAssertEqual((document["selection"] as? [String: Any])?.keys.sorted(), [item.selectionKey], item.label)

            let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: folder), item.label)
            XCTAssertEqual(envelope.workflowName, "lungfish.primer-analysis.selection-export", item.label)
            XCTAssertEqual(envelope.exitStatus, 0, item.label)
            XCTAssertEqual(envelope.options.resolvedDefaults["kind"], .string(item.kind.rawValue), item.label)
            XCTAssertEqual(envelope.options.resolvedDefaults[item.option.0], item.option.1, item.label)
            XCTAssertEqual(envelope.options.resolvedDefaults["outputBundle"], .file(folder), item.label)
        }
    }

    /// At the base the argv the folder's provenance records names the app and an export command that
    /// no binary has. M2 replaces this pin with the command the row records.
    func testTheAppRecordsAnExportCommandThatDoesNotExistAsTheInvocation() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let snapshot = try PrimerAnalysisViewerSnapshot.load(from: fixture.bundle)
        for item in try cases(snapshot) {
            let folder = try await exportAsTheAppDoes(fixture, item)
            let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: folder), item.label)
            XCTAssertEqual(
                envelope.argv,
                ["Lungfish.app", "export-primer-selection", fixture.bundle.path, "--kind", item.kind.rawValue]
                    + selectionArguments(item.selection) + ["--output", folder.path],
                item.label)
        }
    }

    // MARK: - Helpers

    private func selectionArguments(_ selection: PrimerAnalysisExportSelection) -> [String] {
        switch selection {
        case .primer(let targetID, let primerID): ["--target-id", targetID, "--primer-id", primerID]
        case .amplicon(let targetID, let ampliconID): ["--target-id", targetID, "--amplicon-id", ampliconID]
        case .pool(let sourceResultID, let pool): ["--source-result-id", sourceResultID, "--pool", String(pool)]
        case .nativePool(let sourceResultID, let pool): ["--source-result-id", sourceResultID, "--native-pool", pool]
        }
    }

    /// The service call `exportPrimerAnalysisSelection` makes, with the argv the app builds for it. The
    /// app's publish step ends in `PrimerAnalysisSelectionExportService.publishExclusively`, the default.
    private func exportAsTheAppDoes(_ fixture: Fixture, _ item: Case) async throws -> URL {
        let parent = fixture.root.appendingPathComponent("app", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let destination = parent.appendingPathComponent(
            item.label.replacingOccurrences(of: " ", with: "-") + ".lungfishref", isDirectory: true)
        return try await PrimerAnalysisSelectionExportService().export(
            analysisURL: fixture.bundle, selection: item.selection, kind: item.kind,
            destinationURL: destination,
            invocationArgv: MainSplitViewController.primerSelectionExportProvenanceArgv(
                analysisURL: fixture.bundle, selection: item.selection, kind: item.kind, destinationURL: destination))
    }

    private func fastaRecords(_ url: URL) throws -> [(header: String, sequence: String)] {
        let lines = try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline).map(String.init)
        var records: [(header: String, sequence: String)] = []
        for line in lines {
            if line.hasPrefix(">") { records.append((String(line.dropFirst()), "")) }
            else if !records.isEmpty { records[records.count - 1].sequence += line }
        }
        return records
    }

    /// A primer, an amplicon, a numbered pool and a native pool of the fixture, as the viewer offers them.
    private func cases(_ snapshot: PrimerAnalysisViewerSnapshot) throws -> [Case] {
        let target = try XCTUnwrap(snapshot.designReview.first)
        let forward = try XCTUnwrap(target.primers.first { $0.name == "numbered-forward" })
        let amplicon = try XCTUnwrap(target.intervals.first { $0.nativePool == "1" })
        let numbered = ["GTAC", "GTAC", "ACGT"]
        return [
            Case(label: "primer", selection: .primer(targetID: target.id, primerID: forward.id), kind: .primerFASTA,
                 sequences: ["GTAC"], headerParts: ["name=numbered-forward", "target=consensus", "pool=1", "strand=+"],
                 bedRows: nil, selectionKey: "primer", option: ("recordPrimerIDs", .array([.string(forward.id)]))),
            Case(label: "amplicon", selection: .amplicon(targetID: target.id, ampliconID: amplicon.id),
                 kind: .referenceAmplicon,
                 sequences: [String(String(repeating: "ACGT", count: 60).dropFirst(10).prefix(70))],
                 headerParts: ["reference=consensus", "start0=10", "end=80", "pool=1"],
                 bedRows: 3, selectionKey: "amplicon", option: ("sourceStart", .integer(10))),
            Case(label: "amplicon oligos", selection: .amplicon(targetID: target.id, ampliconID: amplicon.id),
                 kind: .primerFASTA, sequences: numbered, headerParts: ["target=consensus", "pool=1"],
                 bedRows: nil, selectionKey: "amplicon", option: ("sourceEnd", .integer(80))),
            Case(label: "pool", selection: .pool(sourceResultID: target.sourceResultID, pool: 1), kind: .primerFASTA,
                 sequences: numbered, headerParts: ["target=consensus", "pool=1"],
                 bedRows: nil, selectionKey: "pool", option: ("pool", .integer(1))),
            Case(label: "native pool", selection: .nativePool(sourceResultID: target.sourceResultID, pool: "native-A"),
                 kind: .primerFASTA, sequences: ["ACGT", "ACGT", "GTAC"], headerParts: ["target=consensus", "pool=native-A"],
                 bedRows: nil, selectionKey: "nativePool", option: ("nativePool", .string("native-A"))),
        ]
    }

    /// One varVAMP-style analysis with two assays on one 240 base reference. The first assay is pool "1"
    /// and the second is the native pool "native-A", so one analysis offers all four selections. The
    /// oligos are palindromic repeats of ACGT, so a reverse oligo equals its reference slice.
    private func makeFixture() throws -> Fixture {
        let pointer = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(pointer) }
        let root = URL(fileURLWithPath: String(cString: pointer)).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let analysisID = UUID(), runID = UUID(), inputID = UUID(), resultID = UUID()
        let targetID = UUID(), firstAssayID = UUID(), secondAssayID = UUID()
        let reference = String(repeating: "ACGT", count: 60)
        func slice(_ start: Int, _ end: Int) -> String { String(reference.dropFirst(start).prefix(end - start)) }
        let oligos = [
            PrimerSchemeOligo(id: UUID(), name: "numbered-forward", role: .forward, sequence: slice(10, 14),
                start: 10, end: 14, strand: .forward, assayIDs: [firstAssayID], pool: "1", nativeMetadata: [:]),
            PrimerSchemeOligo(id: UUID(), name: "numbered-probe", role: .probe, sequence: slice(30, 34),
                start: 30, end: 34, strand: .reverse, assayIDs: [firstAssayID], pool: "1", nativeMetadata: [:]),
            PrimerSchemeOligo(id: UUID(), name: "numbered-reverse", role: .reverse, sequence: slice(76, 80),
                start: 76, end: 80, strand: .reverse, assayIDs: [firstAssayID], pool: "1", nativeMetadata: [:]),
            PrimerSchemeOligo(id: UUID(), name: "native-forward", role: .forward, sequence: slice(100, 104),
                start: 100, end: 104, strand: .forward, assayIDs: [secondAssayID], pool: "native-A", nativeMetadata: [:]),
            PrimerSchemeOligo(id: UUID(), name: "native-probe", role: .probe, sequence: slice(120, 124),
                start: 120, end: 124, strand: .reverse, assayIDs: [secondAssayID], pool: "native-A", nativeMetadata: [:]),
            PrimerSchemeOligo(id: UUID(), name: "native-reverse", role: .reverse, sequence: slice(166, 170),
                start: 166, end: 170, strand: .reverse, assayIDs: [secondAssayID], pool: "native-A", nativeMetadata: [:]),
        ]
        let assays = [
            PrimerSchemeAssay(id: firstAssayID, start: 10, end: 80, memberIDs: oligos[0...2].map(\.id),
                pool: "1", status: .selected, rank: 1, nativeMetadata: [:]),
            PrimerSchemeAssay(id: secondAssayID, start: 100, end: 170, memberIDs: oligos[3...5].map(\.id),
                pool: "native-A", status: .selected, rank: 2, nativeMetadata: [:]),
        ]
        let target = PrimerSchemeTarget(id: targetID, label: "Two pool target",
            referencePath: "generated/reference.fasta", referenceID: "consensus", referenceLength: reference.count,
            sourceInputID: inputID, bindingProjectionPath: "maps/target.json", assays: assays, oligos: oligos)
        let projection = PrimerBindingProjection(sourceInputID: inputID, sourcePath: "inputs/source.fasta",
            generatedReferencePath: target.referencePath, sourceLength: reference.count,
            generatedLength: reference.count,
            blocks: [.init(generatedStart: 0, generatedEnd: reference.count,
                sourceStart: 0, sourceEnd: reference.count, kind: .mapped)])
        let typed = PrimerSchemeDesignOptions(engine: .varvamp, mode: .qpcr, grouping: .independent,
            nominalAmpliconLength: 135, minimumAmpliconLength: 70, maximumAmpliconLength: 200,
            workers: 1, varvamp: .init(cumulativeConsensusThreshold: 0.8))
        var resolved = typed.adapterOptions
        resolved["adapterResolution"] = .object(["fixture": .boolean(true)])
        let document = PrimerSchemeResultsDocument(analysisID: analysisID, runID: runID, resultID: resultID,
            engine: .varvamp, engineVersion: "1.3.2", adapterVersion: "1.0.0", mode: .qpcr,
            resolvedOptions: resolved, results: [.init(id: resultID, inputIDs: [inputID], targets: [target])],
            artifacts: [], provenancePath: "native/provenance-v1.json")
        let payloads: [(String, Data, String, String)] = [
            ("inputs/source.fasta", Data(">source-row\n\(reference)\n".utf8), "input", "fasta"),
            ("generated/reference.fasta", Data(">consensus\n\(reference)\n".utf8), "nativeOutput", "fasta"),
            ("maps/target.json", try JSONEncoder().encode(projection), "nativeOutput", "json"),
            (PrimerSchemeResultsDocument.storedRelativePath, try JSONEncoder().encode(document), "nativeOutput", "json"),
            ("native/provenance-v1.json", Data("{\"fixture\":true}\n".utf8), "nativeOutput", "json"),
        ]
        let sourceArtifacts = try payloads.map { path, data, role, format in
            let source = root.appendingPathComponent(UUID().uuidString)
            try data.write(to: source)
            return PrimerAnalysisSourceArtifact(sourceURL: source, relativePath: path, role: role, format: format)
        }
        let resultPaths = payloads.map(\.0).filter { !$0.hasPrefix("inputs/") }
        let bundle = try PrimerAnalysisBundleWriter(provenanceWriter: .init(signingProvider: nil)).write(.init(
            analysisID: analysisID, runID: runID, grouping: .independent,
            inputs: [.init(id: inputID, label: "source-row", artifactPaths: ["inputs/source.fasta"])],
            results: [.init(id: resultID, label: "Two pool design", inputIDs: [inputID], artifactPaths: resultPaths)],
            artifacts: sourceArtifacts,
            destinationURL: root.appendingPathComponent("two-pools.lungfishprimeranalysis"),
            invocation: .init(argv: ["two-pool-selection-fixture"], callerVersion: "test",
                explicitOptions: [:], runtimeIdentity: .init())))
        return Fixture(root: root, bundle: bundle.url)
    }
}
