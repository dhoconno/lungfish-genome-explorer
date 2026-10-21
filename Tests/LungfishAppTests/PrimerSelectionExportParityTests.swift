// PrimerSelectionExportParityTests.swift - The folder a primer selection export writes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.15 (A67-M3). "Save Primer FASTA Bundle" and "Extract Reference Amplicon" write a new
// .lungfishref folder through PrimerAnalysisSelectionExportService. M1 pins at the base what the app writes
// for a primer, an amplicon, a numbered pool and a native pool, and the argv the app records for it, which
// names `Lungfish.app export-primer-selection`, a command that does not exist. M2 flips that argv pin to the
// command the row records and adds the parity test, which runs the recorded command through the real leaf
// and compares its folder with the app's.

import CryptoKit
import Darwin
import Foundation
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
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

    /// The argv the folder's provenance records is the command the row records, as words. At the base it
    /// named `Lungfish.app export-primer-selection`, a command that no binary has.
    func testTheAppRecordsTheRowCommandAsTheInvocation() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let snapshot = try PrimerAnalysisViewerSnapshot.load(from: fixture.bundle)
        for item in try cases(snapshot) {
            let row = MainSplitViewController.primerSelectionExportCLICommand(
                analysisURL: fixture.bundle, selection: item.selection, kind: item.kind,
                destinationURL: try appDestination(fixture, item))
            let folder = try await exportAsTheAppDoes(fixture, item)
            let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: folder), item.label)
            XCTAssertEqual(
                envelope.argv, [CLICommandIdentity.executableName] + (try RecordedCLICommand.arguments(of: row)), item.label)
            XCTAssertEqual(
                Array(envelope.argv.prefix(4)),
                [CLICommandIdentity.executableName, "primers", "analysis", "export-selection"], item.label)
        }
    }

    /// Lane 13.43 M3 item 1. The row, the record and the leaf print one argv. For each selection form, the app's row
    /// command, the record the in-process writer leaves and the record the leaf leaves when it runs the row's command
    /// are one command.
    func testTheRowTheRecordAndTheLeafPrintOneArgv() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let snapshot = try PrimerAnalysisViewerSnapshot.load(from: fixture.bundle)
        let leafParent = fixture.root.appendingPathComponent("one-argv", isDirectory: true)
        try FileManager.default.createDirectory(at: leafParent, withIntermediateDirectories: true)
        for item in try cases(snapshot) {
            let appRow = MainSplitViewController.primerSelectionExportCLICommand(
                analysisURL: fixture.bundle, selection: item.selection, kind: item.kind,
                destinationURL: try appDestination(fixture, item))
            let appFolder = try await exportAsTheAppDoes(fixture, item)
            let appRecord = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: appFolder), item.label)
            XCTAssertEqual(
                appRecord.argv, [CLICommandIdentity.executableName] + (try RecordedCLICommand.arguments(of: appRow)), item.label)

            let leafFolder = leafParent.appendingPathComponent(
                item.label.replacingOccurrences(of: " ", with: "-") + ".lungfishref", isDirectory: true)
            let leafRow = MainSplitViewController.primerSelectionExportCLICommand(
                analysisURL: fixture.bundle, selection: item.selection, kind: item.kind, destinationURL: leafFolder)
            try await RecordedCLICommand.parse(leafRow, as: PrimerAnalysisExportSelectionCommand.self).run()
            let leafRecord = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: leafFolder), item.label)
            XCTAssertEqual(
                leafRecord.argv, [CLICommandIdentity.executableName] + (try RecordedCLICommand.arguments(of: leafRow)), item.label)
        }
    }

    /// Pin at the base of lane 13.43 (QA 1), before PRIMER-EXPORT-RUN changes the route. The record of the
    /// in-process writer names its tool and the keys of its resolved options, and the begin helper registers the row
    /// with the recorded command, its type, its lock and its first detail. The continuation compares its converted
    /// route with these facts, and a difference there is a prediction row.
    func testTheRecordNamesItsToolAndResolvedKeysAndTheRowItsCommandToday() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let snapshot = try PrimerAnalysisViewerSnapshot.load(from: fixture.bundle)
        var facts: [String: String] = [:]
        for item in try cases(snapshot) {
            let folder = try await exportAsTheAppDoes(fixture, item)
            let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: folder), item.label)
            facts[item.label] = "\(envelope.tool.name)|\(envelope.tool.kind ?? "none")|"
                + envelope.options.resolvedDefaults.keys.sorted().joined(separator: ",")
            let reporter = RecordingOperationReporter()
            let row = MainSplitViewController.primerSelectionExportCLICommand(
                analysisURL: fixture.bundle, selection: item.selection, kind: item.kind, destinationURL: folder)
            MainSplitViewController.beginPrimerAnalysisSelectionExportOperation(
                title: "Save Primer FASTA Bundle", destinationURL: folder, cliCommand: row,
                routeContext: OperationRouteContext(projectURL: fixture.root, windowStateScopeID: UUID()),
                reporter: reporter) { _ in }
            let recorded = try XCTUnwrap(reporter.items.first, item.label)
            XCTAssertEqual(recorded.title, "Save Primer FASTA Bundle", item.label)
            XCTAssertEqual(recorded.initialDetail, "Verifying saved primer analysis…", item.label)
            XCTAssertEqual(recorded.operationType, .workflow, item.label)
            XCTAssertEqual(recorded.targetBundleURL, folder, item.label)
            XCTAssertEqual(
                try RecordedCLICommand.arguments(of: recorded.cliCommand),
                ["primers", "analysis", "export-selection"] + MainSplitViewController.primerSelectionExportCLIArguments(
                    analysisURL: fixture.bundle, selection: item.selection, kind: item.kind, destinationURL: folder),
                item.label)
        }
        let tool = "lungfish.primer-analysis.selection-export|cli|"
        let shared = "analysisID,compressFASTA,coordinateConvention,includePrimerSites,kind"
        let amplicon = "ampliconID,ampliconName,analysisID,candidateRank,compressFASTA,coordinateConvention,includePrimerSites,kind,nativePool,"
        XCTAssertEqual(facts, [
            "primer": tool + shared + ",outputBundle,primers,publication,recordPrimerIDs,runID,sequenceSemantics,"
                + "sourceResultIDs,targetIDs",
            "pool": tool + shared + ",outputBundle,pool,primers,publication,recordPrimerIDs,runID,sequenceSemantics,"
                + "sourceResultIDs,targetIDs",
            "native pool": tool + shared + ",nativePool,outputBundle,primers,publication,recordPrimerIDs,runID,"
                + "sequenceSemantics,sourceResultIDs,targetIDs",
            "amplicon": tool + amplicon + "orientation,outputBundle,primerMembership,primers,publication,referenceID,"
                + "runID,sequenceSemantics,sourceEnd,sourceResultIDs,sourceStart,targetIDs",
            "amplicon oligos": tool + amplicon + "outputBundle,primers,publication,recordPrimerIDs,runID,"
                + "sequenceSemantics,sourceEnd,sourceResultIDs,sourceStart,targetIDs",
        ], "the tool and the resolved keys of today's selection export")
    }

    /// The command the row records, parsed with the real leaf and run on a second folder, writes what the app
    /// wrote for the same selection. The folders differ only in the identifiers, the dates and the destination
    /// path, which the Masks row allows, and in the provenance argv. The argv is a prediction row of the lane
    /// report (ARCH export-shape ruling X-5), not a Masks-row mask.
    func testTheRecordedCommandWritesTheFolderTheAppWrote() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let snapshot = try PrimerAnalysisViewerSnapshot.load(from: fixture.bundle)
        let cliParent = fixture.root.appendingPathComponent("cli", isDirectory: true)
        try FileManager.default.createDirectory(at: cliParent, withIntermediateDirectories: true)
        for item in try cases(snapshot) {
            let appFolder = try await exportAsTheAppDoes(fixture, item)
            let cliFolder = cliParent.appendingPathComponent(appFolder.lastPathComponent, isDirectory: true)
            let row = MainSplitViewController.primerSelectionExportCLICommand(
                analysisURL: fixture.bundle, selection: item.selection, kind: item.kind, destinationURL: cliFolder)
            let command = try RecordedCLICommand.parse(row, as: PrimerAnalysisExportSelectionCommand.self)
            XCTAssertEqual(try command.selection(), item.selection, item.label)
            XCTAssertEqual(command.kind.exportKind, item.kind, item.label)
            try await command.run()

            let app = try facts(of: appFolder, analysis: fixture.bundle), cli = try facts(of: cliFolder, analysis: fixture.bundle)
            XCTAssertEqual(cli.entries, app.entries, item.label)
            XCTAssertEqual(Set(cli.files.keys), Set(app.files.keys), item.label)
            for (path, bytes) in app.files {
                XCTAssertEqual(cli.files[path], bytes, "\(item.label): \(path) differs")
            }
            XCTAssertEqual(cli.selection, app.selection, item.label)
            XCTAssertEqual(cli.manifest, app.manifest, item.label)
            XCTAssertEqual(cli.envelope.workflowName, app.envelope.workflowName, item.label)
            XCTAssertEqual(cli.envelope.exitStatus, app.envelope.exitStatus, item.label)
            XCTAssertEqual(cli.envelope.options.explicit, app.envelope.options.explicit, item.label)
            XCTAssertEqual(cli.resolved, app.resolved, item.label)
            XCTAssertEqual(cli.outputPaths, app.outputPaths, item.label)
            XCTAssertEqual(cli.outputChecksums, app.outputChecksums, item.label)
            XCTAssertEqual(cli.envelope.steps.count, app.envelope.steps.count, item.label)
            XCTAssertFalse(app.inputs.isEmpty, item.label)
            XCTAssertEqual(cli.inputs, app.inputs, item.label)
            XCTAssertEqual(cli.inputOrigins, app.inputOrigins, item.label)
            // The leaf records the canonical argv of the command it ran, which is the row's (lane 13.43 M3, ARCH
            // export-shape ruling X-5). The row was built before the folder existed, as the leaf builds its own.
            XCTAssertEqual(
                cli.envelope.argv, [CLICommandIdentity.executableName] + (try RecordedCLICommand.arguments(of: row)), item.label)
        }
    }

    /// The record names what the selection read and every output the export wrote (BIO 6). The inputs are the
    /// manifest and the files the selection needs, taken from the snapshot and not from the folder, and the
    /// folder retains exactly those files, so nothing is kept and left unnamed. Each input carries the SHA-256
    /// of the file it was read from in the saved analysis. Each output exists in the folder with the digest the
    /// record names. The check runs on the folder the app wrote and on the folder the recorded command wrote.
    func testTheRecordNamesExactlyTheFilesTheSelectionReadsAndEveryOutputItWrote() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let snapshot = try PrimerAnalysisViewerSnapshot.load(from: fixture.bundle)
        let cliParent = fixture.root.appendingPathComponent("cli", isDirectory: true)
        try FileManager.default.createDirectory(at: cliParent, withIntermediateDirectories: true)
        for item in try cases(snapshot) {
            let prepared = try PrimerAnalysisSelectionExportService.prepare(
                snapshot: snapshot, selection: item.selection, kind: item.kind)
            let expected = Set((["manifest.json"] + prepared.sourcePaths).map { "source-analysis/" + $0 })
            XCTAssertGreaterThan(expected.count, 1, "\(item.label): the selection reads more than the manifest")

            let appFolder = try await exportAsTheAppDoes(fixture, item)
            let cliFolder = cliParent.appendingPathComponent(appFolder.lastPathComponent, isDirectory: true)
            let row = MainSplitViewController.primerSelectionExportCLICommand(
                analysisURL: fixture.bundle, selection: item.selection, kind: item.kind, destinationURL: cliFolder)
            try await RecordedCLICommand.parse(row, as: PrimerAnalysisExportSelectionCommand.self).run()

            for (side, folder) in [("app", appFolder), ("leaf", cliFolder)] {
                let label = "\(item.label), \(side) folder"
                let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: folder), label)
                let inputs = try selectionInputs(of: envelope)
                let named = inputs.map { relativePath($0.path, in: folder) }
                XCTAssertEqual(named.count, expected.count, "\(label): an input is named twice or not at all")
                XCTAssertEqual(Set(named), expected, "\(label): the record names the files the selection reads")
                XCTAssertEqual(
                    try regularFilePaths(under: folder.appendingPathComponent("source-analysis"), in: folder),
                    expected, "\(label): the retained evidence is exactly the named inputs")
                for input in inputs {
                    let origin = try XCTUnwrap(input.originPath, "\(label): \(input.path) names no origin")
                    XCTAssertTrue(origin.hasPrefix(fixture.bundle.path + "/"), "\(label): \(origin)")
                    XCTAssertEqual(
                        input.checksumSHA256, try sha256Hex(of: URL(fileURLWithPath: origin)),
                        "\(label): \(input.path) does not carry the digest of its origin")
                }
                XCTAssertFalse(envelope.outputs.isEmpty, label)
                for output in envelope.outputs {
                    XCTAssertTrue(output.path.hasPrefix(folder.path + "/"), "\(label): \(output.path)")
                    let file = folder.appendingPathComponent(relativePath(output.path, in: folder))
                    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "\(label): \(output.path) is missing")
                    XCTAssertEqual(
                        output.checksumSHA256, try sha256Hex(of: file), "\(label): \(output.path) differs from its record")
                }
            }
        }
    }

    // MARK: - Helpers

    /// The files the export itself read, which its own provenance step names. The envelope also carries the
    /// native indexing steps, whose inputs name the staged genome, and those are not inputs of the selection.
    private func selectionInputs(of envelope: ProvenanceEnvelope) throws -> [ProvenanceFileDescriptor] {
        let steps = envelope.steps.filter { $0.toolName == envelope.workflowName }
        XCTAssertEqual(steps.count, 1, "the export records one step of its own")
        return steps.flatMap(\.inputs)
    }

    /// `path` relative to `folder`, or `path` itself when it lies elsewhere, so that a compare fails on it.
    private func relativePath(_ path: String, in folder: URL) -> String {
        path.hasPrefix(folder.path + "/") ? String(path.dropFirst(folder.path.count + 1)) : path
    }

    /// The regular files under `directory`, as paths relative to `folder`.
    private func regularFilePaths(under directory: URL, in folder: URL) throws -> Set<String> {
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
        var paths: Set<String> = []
        for case let url as URL in enumerator where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            paths.insert(relativePath(url.path, in: folder))
        }
        return paths
    }

    private func sha256Hex(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    /// What an export folder holds, apart from the fields that name the run.
    private struct Facts {
        /// The top level names of the folder.
        let entries: [String]
        /// The files that hold no run identity, by path in the folder.
        let files: [String: Data]
        /// selection.json without the destination path.
        let selection: NSDictionary
        /// manifest.json without the bundle identifier, the dates and the source download date.
        let manifest: NSDictionary
        let envelope: ProvenanceEnvelope
        /// The resolved options without the destination path.
        let resolved: [String: ParameterValue]
        /// The provenance outputs by path in the folder, and the checksums of the files that hold no run identity.
        let outputPaths: Set<String>
        let outputChecksums: [String: String]
        /// The provenance inputs by path in the folder, each with the SHA-256 the record names.
        let inputs: [String: String]
        /// Where each input was read from, as a path relative to the saved analysis folder.
        let inputOrigins: [String: String]
    }

    private func facts(of folder: URL, analysis: URL) throws -> Facts {
        let manager = FileManager.default
        var files: [String: Data] = [:]
        let enumerator = try XCTUnwrap(manager.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in enumerator where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            let path = String(url.path.dropFirst(folder.path.count + 1))
            // The bundle manifest holds an identifier and dates, selection.json the destination path, and the
            // provenance the run's times and paths.
            let holdsRunIdentity = path == "manifest.json" || path == "selection.json"
                || path == ProvenanceWriter.provenanceFilename
                || path.hasPrefix(ProvenanceWriter.bundleProvenanceDirectoryName + "/")
            if !holdsRunIdentity { files[path] = try Data(contentsOf: url) }
        }
        var document = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: folder.appendingPathComponent("selection.json"))) as? [String: Any])
        document.removeValue(forKey: "outputBundlePath")
        var options = try XCTUnwrap(document["options"] as? [String: Any])
        options.removeValue(forKey: "outputBundle")
        document["options"] = options
        // The manifest is compared as a dictionary. Its identifier derives from a UUID and its dates are
        // wall-clock times, so those are the only fields removed (Masks row).
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: folder.appendingPathComponent("manifest.json"))) as? [String: Any])
        for key in ["identifier", "created_date", "modified_date"] { manifest.removeValue(forKey: key) }
        var source = try XCTUnwrap(manifest["source"] as? [String: Any])
        source.removeValue(forKey: "download_date")
        // The app records the analysis URL with a trailing slash and the leaf without. Fix 5 found this and it is
        // reported as a difference the lane brief did not predict. Only that one slash is dropped here.
        if let url = source["source_url"] as? String, url.hasSuffix("/") { source["source_url"] = String(url.dropLast()) }
        manifest["source"] = source
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: folder))
        var resolved = envelope.options.resolvedDefaults
        resolved.removeValue(forKey: "outputBundle")
        var paths: Set<String> = []
        var checksums: [String: String] = [:]
        for descriptor in envelope.outputs {
            XCTAssertTrue(descriptor.path.hasPrefix(folder.path + "/"), descriptor.path)
            let path = String(descriptor.path.dropFirst(folder.path.count + 1))
            paths.insert(path)
            if files[path] != nil { checksums[path] = descriptor.checksumSHA256 }
        }
        var inputs: [String: String] = [:]
        var inputOrigins: [String: String] = [:]
        for descriptor in try selectionInputs(of: envelope) {
            XCTAssertTrue(descriptor.path.hasPrefix(folder.path + "/"), descriptor.path)
            let path = String(descriptor.path.dropFirst(folder.path.count + 1))
            inputs[path] = try XCTUnwrap(descriptor.checksumSHA256, "\(path) names no digest")
            let origin = try XCTUnwrap(descriptor.originPath, "\(path) names no origin")
            XCTAssertTrue(origin.hasPrefix(analysis.path + "/"), origin)
            inputOrigins[path] = String(origin.dropFirst(analysis.path.count + 1))
        }
        return Facts(
            entries: try manager.contentsOfDirectory(atPath: folder.path).sorted(), files: files,
            selection: document as NSDictionary, manifest: manifest as NSDictionary,
            envelope: envelope, resolved: resolved,
            outputPaths: paths, outputChecksums: checksums, inputs: inputs, inputOrigins: inputOrigins)
    }

    /// The folder `exportAsTheAppDoes` writes for a case, which does not exist yet. A test that compares the row with the
    /// record builds the row from this URL before the export, as the app does, since `standardizedFileURL` drops a
    /// leading `/private` only for a path that exists.
    private func appDestination(_ fixture: Fixture, _ item: Case) throws -> URL {
        let parent = fixture.root.appendingPathComponent("app", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        return parent.appendingPathComponent(
            item.label.replacingOccurrences(of: " ", with: "-") + ".lungfishref", isDirectory: true)
    }

    /// The service call `exportPrimerAnalysisSelection` makes, with the argv the app builds for it. The
    /// app's publish step ends in `PrimerAnalysisSelectionExportService.publishExclusively`, the default.
    private func exportAsTheAppDoes(_ fixture: Fixture, _ item: Case) async throws -> URL {
        let destination = try appDestination(fixture, item)
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
