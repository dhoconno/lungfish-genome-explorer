// AlignmentConsensusRowReplayTests.swift - What the viewer's Generate Consensus row shows, from the action itself
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A51 M2, the row table of the consensus route (U-a, UX 1), which the publication pin
// does not hold. Each case runs the viewer's own `presentAlignmentConsensusGeneration()` in a window
// on the sarscov2 BAM, picks a destination in the destination sheet and presses its button, answers
// the save panel, the all-N sheet and the failure sheet through the viewer's seams, and records the
// row's title, end, detail, error, outputs and scope line, each sheet it showed and the files it left.
// Clipboard and share are left out, because they write the user's pasteboard or open a share picker.
//
// The route runs `lungfish-cli` from the build products, so the name ends in ReplayTests and the
// class runs in the integration tier.
//
// The table moved once, as the ruling predicted, when the route moved onto `bam consensus`: the
// destination comes before the row, so a cancel of the sheet or the save panel leaves no row, and
// the save panel shows before the all-N sheet. A failed run reads "Alignment consensus failed"
// with the sheet "Generate Consensus Failed", since one command generates and publishes. Every
// other line kept its words.

import AppKit
import SwiftUI
import XCTest
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp

@MainActor
final class AlignmentConsensusRowReplayTests: XCTestCase {
    /// The save panel, which answers with `url` and keeps the name it suggested.
    private final class SavePanel: SavePanelPresenting {
        let url: URL?
        var suggestedNames: [String] = []
        init(url: URL?) { self.url = url }
        func present(suggestedName: String, on window: NSWindow) async -> URL? {
            suggestedNames.append(suggestedName)
            return url
        }
    }

    private enum Choice {
        case cancelTheDialog
        case destination(DialogDestination)
    }

    private static let contig = "MT192765.1"
    private static let contigLength = 29829
    private static let bam = ProvenanceCompatCorpus.repositoryRoot.appendingPathComponent("Tests/Fixtures/sarscov2/test.paired_end.sorted.bam")

    private var scratch: URL!
    private var viewer: ViewerViewController!
    private var window: NSWindow!
    private var sheets: [String] = []
    private var priorCLIPath: String?

    override func setUp() async throws {
        // The route finds lungfish-cli through CLIBinaryLocator, which takes LUNGFISH_CLI_PATH first,
        // so no `swift build --show-bin-path` waits on the lock this test run holds. The run's own
        // value comes back in tearDown (review A51, fix 3).
        priorCLIPath = ProcessInfo.processInfo.environment["LUNGFISH_CLI_PATH"]
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products), "no lungfish-cli beside \(products.path)")
        setenv("LUNGFISH_CLI_PATH", cli.path, 1)
        // A taken destination fails its row, whose report stays out of the user's ~/Library/Logs.
        OperationCenter.useTemporaryFailureReportsForTesting()
        scratch = try TestTempDirectory.make(prefix: "consensus-row")
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("out"), withIntermediateDirectories: true)
        _ = NSApplication.shared
        OperationCenter.shared.clearCompleted()
        viewer = ViewerViewController()
        window = NSWindow(contentViewController: viewer)
        _ = viewer.view
        viewer.extractionFailureAlertPresenter = { [weak self] title, message in
            self?.sheets.append("failure \(title): \(message)")
        }
    }

    override func tearDown() async throws {
        if let sheet = window?.attachedSheet { window.endSheet(sheet) }
        window?.contentViewController = nil
        OperationCenter.shared.clearCompleted()
        TestTempDirectory.cleanup(scratch)
        if let priorCLIPath {
            setenv("LUNGFISH_CLI_PATH", priorCLIPath, 1)
        } else {
            unsetenv("LUNGFISH_CLI_PATH")
        }
    }

    /// A copy of the BAM and its index in the scratch folder, which a case can replace while the row runs.
    private func copiedBAM() throws -> URL {
        let folder = scratch.appendingPathComponent("evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bam = folder.appendingPathComponent("S1.bam")
        try FileManager.default.copyItem(at: Self.bam, to: bam)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: Self.bam.path + ".bai"), to: URL(fileURLWithPath: bam.path + ".bai"))
        return bam
    }

    /// The evidence the viewer shows, the sarscov2 BAM (or `file`, a copy of it) with every filter off
    /// but the depth. With `stale`, the alignment digest the viewer holds is not the file's, as after
    /// the BAM was replaced.
    private func context(minimumDepth: Int, stale: Bool = false, over file: URL? = nil) throws -> AlignmentActionContext {
        let bam = file ?? Self.bam
        let index = URL(fileURLWithPath: bam.path + ".bai")
        func snapshot(_ url: URL) throws -> AlignmentEvidenceFileSnapshot {
            .init(url: url, byteCount: try ProvenanceFileHasher.fileSize(of: url), sha256: try ProvenanceFileHasher.sha256(of: url))
        }
        var alignmentSnapshot = try snapshot(bam)
        if stale { alignmentSnapshot = .init(url: bam, byteCount: alignmentSnapshot.byteCount, sha256: String(repeating: "0", count: 64)) }
        return try AlignmentActionContext(
            identity: .init(workflow: "mapping", resultID: "run-1", sampleID: "S1", evidenceID: Self.contig),
            alignmentURL: bam, indexURL: index, decodingReferenceURL: nil,
            contig: Self.contig, contigLength: Self.contigLength,
            alignmentSnapshot: alignmentSnapshot, indexSnapshot: try snapshot(index), decodingReferenceSnapshot: nil,
            filters: .init(minimumDepth: minimumDepth, minimumMapQ: 0, minimumBaseQuality: 0, excludedFlags: 0x904, readGroups: []),
            outputCapability: outputCapability, sourceReads: .bamFallback, presentationLabel: "S1 \(Self.contig)"
        )
    }

    private var dialog: NSHostingController<FASTASequenceExtractionDialog>? {
        window.attachedSheet?.contentViewController as? NSHostingController<FASTASequenceExtractionDialog>
    }

    private func rows(after known: Set<UUID>) -> [OperationCenter.Item] {
        OperationCenter.shared.items.filter { !known.contains($0.id) && $0.title == "Generate Alignment Consensus" }
    }

    /// Runs Generate Consensus once and returns what the row and the sheets showed.
    private func run(
        _ choice: Choice,
        savePanelAnswer: String? = "S1.fasta",
        minimumDepth: Int = 1,
        acceptAllN: Bool = true,
        expectRow: Bool = true,
        staleEvidence: Bool = false,
        evidenceFile: URL? = nil,
        whileTheSheetIsOpen: (@MainActor () throws -> Void)? = nil
    ) async throws -> [String] {
        let known = Set(OperationCenter.shared.items.map(\.id))
        let savePanel = SavePanel(url: savePanelAnswer.map { scratch.appendingPathComponent("out/\($0)") })
        viewer.alignmentExtractionSavePanelPresenter = savePanel
        viewer.alignmentConsensusAllLowDepthConfirmation = { [weak self] message, _ in
            self?.sheets.append("all-N \(message)")
            try? whileTheSheetIsOpen?()
            return acceptAllN
        }
        viewer.alignmentActionContext = try context(minimumDepth: minimumDepth, stale: staleEvidence, over: evidenceFile)

        viewer.presentAlignmentConsensusGeneration()

        await waitUntil(budget: .lookup) { self.dialog != nil || self.rows(after: known).contains { !$0.state.isActive } }
        if let host = dialog {
            switch choice {
            case .cancelTheDialog:
                host.rootView.onCancel()
            case .destination(let destination):
                host.rootView.model.destination = destination
                host.rootView.onPrimary()
            }
        }
        if expectRow {
            await waitUntil(budget: .lookup) { self.rows(after: known).contains { !$0.state.isActive } }
        } else {
            await waitUntil(timeout: .seconds(10)) { self.window.attachedSheet == nil }
            try await Task.sleep(for: .milliseconds(500))
        }
        return describe(rows(after: known), savePanel: savePanel)
    }

    private func describe(_ rows: [OperationCenter.Item], savePanel: SavePanel) -> [String] {
        let root = scratch.standardizedFileURL.path
        func masked(_ text: String) -> String {
            text.replacingOccurrences(of: "/private" + root, with: "<root>").replacingOccurrences(of: root, with: "<root>")
        }
        var lines = rows.isEmpty ? ["no row"] : []
        for row in rows {
            lines += ["row \(row.title)", "end \(row.state) \(row.detail)"]
            if let error = row.errorMessage { lines.append("error \(masked(error))") }
            lines += row.outputURLs.map { "output \(masked($0.path))" }
            lines += row.bundleURLs.map { "bundle \(masked($0.path))" }
            lines += row.logEntries.map(\.message).filter { $0.hasPrefix("Consensus scope") }.map { "log \($0)" }
        }
        lines += savePanel.suggestedNames.map { "save panel \($0)" }
        lines += sheets.map(masked)
        let out = scratch.appendingPathComponent("out")
        let enumerator = FileManager.default.enumerator(at: out, includingPropertiesForKeys: nil)
        var files: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                files.append(masked(url.standardizedFileURL.path))
            }
        }
        return lines + files.sorted().map { "file \($0)" }
    }

    private static let scopeLine = "log Consensus scope wholeContig, region \(contig):0-\(contigLength), reference fill never"
    private static let allNSheet = "all-N Every position in the requested region is below the minimum depth of 100000."
        + " The consensus will contain only N characters. You can continue without filling from the reference."

    // MARK: - Cases

    func testAFASTADestinationSavesTheFASTAAndItsRecord() async throws {
        let lines = try await run(.destination(.file))
        XCTAssertEqual(lines, [
            "row Generate Alignment Consensus",
            "end completed Consensus FASTA saved",
            "output <root>/out/S1.fasta",
            "output <root>/out/S1.fasta.lungfish-provenance.json",
            Self.scopeLine,
            "save panel S1-MT192765.1-consensus.fasta",
            "file <root>/out/S1.fasta",
            "file <root>/out/S1.fasta.lungfish-provenance.json",
        ])
    }

    func testABundleDestinationCreatesTheReferenceBundle() async throws {
        let lines = try await run(.destination(.bundle), savePanelAnswer: "S1.lungfishref")
        XCTAssertEqual(lines, [
            "row Generate Alignment Consensus",
            "end completed Consensus reference bundle created",
            "bundle <root>/out/S1.lungfishref",
            Self.scopeLine,
            "save panel S1-MT192765.1-consensus.lungfishref",
            "file <root>/out/S1.lungfishref/.lungfish-provenance.json",
            "file <root>/out/S1.lungfishref/genome/consensus.fasta",
            "file <root>/out/S1.lungfishref/genome/consensus.fasta.fai",
            "file <root>/out/S1.lungfishref/manifest.json",
        ])
    }

    func testAnAcceptedAllNConsensusIsSaved() async throws {
        let lines = try await run(.destination(.file), minimumDepth: 100_000)
        XCTAssertEqual(lines, [
            "row Generate Alignment Consensus",
            "end completed Consensus FASTA saved",
            "output <root>/out/S1.fasta",
            "output <root>/out/S1.fasta.lungfish-provenance.json",
            Self.scopeLine,
            "save panel S1-MT192765.1-consensus.fasta",
            Self.allNSheet,
            "file <root>/out/S1.fasta",
            "file <root>/out/S1.fasta.lungfish-provenance.json",
        ])
        let fasta = try String(contentsOf: scratch.appendingPathComponent("out/S1.fasta"), encoding: .utf8)
        XCTAssertEqual(fasta, ">S1 MT192765.1 consensus\n\(String(repeating: "N", count: Self.contigLength))\n")
    }

    func testADeclinedAllNConsensusEndsCancelledAndWritesNothing() async throws {
        let lines = try await run(.destination(.file), minimumDepth: 100_000, acceptAllN: false)
        // The destination now comes first, so the save panel shows before the all-N sheet.
        XCTAssertEqual(lines, [
            "row Generate Alignment Consensus",
            "end cancelled Cancelled by user",
            Self.scopeLine,
            "save panel S1-MT192765.1-consensus.fasta",
            Self.allNSheet,
        ])
    }

    func testAnExistingDestinationFailsTheRowWithItsSheet() async throws {
        try Data("kept".utf8).write(to: scratch.appendingPathComponent("out/S1.fasta"))
        let lines = try await run(.destination(.file))
        // One command generates and publishes, so the row and sheet read as a generation failure (W3).
        XCTAssertEqual(lines, [
            "row Generate Alignment Consensus",
            "end failed Alignment consensus failed",
            "error A file already exists at <root>/out/S1.fasta.",
            Self.scopeLine,
            "save panel S1-MT192765.1-consensus.fasta",
            "failure Generate Consensus Failed: A file already exists at <root>/out/S1.fasta.",
            "file <root>/out/S1.fasta",
        ])
    }

    /// The viewer hashed the BAM when it showed it, and the file was replaced before Generate Consensus.
    /// The coordinator checked those digests before it called the consensus and again before it
    /// published, and the row on the CLI must too (review A51, B1): the row fails with the
    /// stale-evidence error, the leaf never runs, and no FASTA and no record are written.
    func testAConsensusWhoseEvidenceChangedSinceItWasShownWritesNothing() async throws {
        let lines = try await run(.destination(.file), staleEvidence: true)
        let stale = AlignmentActionContext.EvidenceError.staleEvidence(Self.bam).localizedDescription
        XCTAssertTrue(stale.contains(Self.bam.lastPathComponent), "the row names the file that changed. \(stale)")
        XCTAssertEqual(lines, [
            "row Generate Alignment Consensus",
            "end failed Alignment consensus failed",
            "error \(stale)",
            Self.scopeLine,
            "save panel S1-MT192765.1-consensus.fasta",
            "failure Generate Consensus Failed: \(stale)",
        ])
    }

    /// The all-N sheet can stay open while the BAM is replaced. The coordinator validated the digests
    /// again before it published an accepted all-N consensus, so the second run of the leaf is checked
    /// too (review A51, B1): the row fails with the stale-evidence error and nothing is written.
    func testAnAcceptedAllNConsensusWhoseEvidenceChangedWhileTheSheetWasOpenWritesNothing() async throws {
        let bam = try copiedBAM()
        let lines = try await run(.destination(.file), minimumDepth: 100_000, evidenceFile: bam) {
            let handle = try FileHandle(forWritingTo: bam)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([0]))
        }
        let stale = AlignmentActionContext.EvidenceError.staleEvidence(bam).localizedDescription
        XCTAssertTrue(stale.contains(bam.lastPathComponent), "the row names the file that changed. \(stale)")
        XCTAssertEqual(lines, [
            "row Generate Alignment Consensus",
            "end failed Alignment consensus failed",
            "error \(stale)",
            Self.scopeLine,
            "save panel S1-MT192765.1-consensus.fasta",
            Self.allNSheet,
            "failure Generate Consensus Failed: \(stale)",
        ])
    }

    func testCancellingTheDestinationSheetWritesNothing() async throws {
        let lines = try await run(.cancelTheDialog, expectRow: false)
        XCTAssertEqual(lines, ["no row"], "the sheet comes before the row, so its cancel leaves none")
    }

    func testCancellingTheSavePanelWritesNothing() async throws {
        let lines = try await run(.destination(.file), savePanelAnswer: nil, expectRow: false)
        XCTAssertEqual(lines, ["no row", "save panel S1-MT192765.1-consensus.fasta"])
    }

    /// A viewer closed while its run goes on leaves no row running. The leaf wrote the FASTA and its
    /// record before it exited, so the row completes with them, as today's route completed a
    /// publication that outlived its viewer. A stand-in for the leaf holds the run open until the
    /// viewer is gone, then writes the two files and reports them as `bam consensus` does.
    func testARunThatOutlivesItsViewerStillEndsTheRow() async throws {
        let gate = scratch.appendingPathComponent("viewer-closed")
        let launched = scratch.appendingPathComponent("launched")
        let fasta = scratch.appendingPathComponent("out/S1.fasta")
        let record = scratch.appendingPathComponent("out/S1.fasta.lungfish-provenance.json")
        let complete = #"{"event":"complete","message":"Consensus FASTA saved","outputs":["\#(fasta.path)","\#(record.path)"],"progress":1,"schemaVersion":2}"#
        let cli = scratch.appendingPathComponent("lungfish-cli")
        try """
        #!/bin/sh
        touch '\(launched.path)'
        while [ ! -f '\(gate.path)' ]; do sleep 0.05; done
        printf '>S1\\nN\\n' > '\(fasta.path)'
        printf '{}' > '\(record.path)'
        printf '%s\\n' '\(complete)'
        """.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        setenv("LUNGFISH_CLI_PATH", cli.path, 1)
        let known = Set(OperationCenter.shared.items.map(\.id))
        viewer.alignmentExtractionSavePanelPresenter = SavePanel(url: fasta)
        viewer.alignmentActionContext = try context(minimumDepth: 1)
        viewer.presentAlignmentConsensusGeneration()
        await waitUntil(timeout: .seconds(30)) { self.dialog != nil }
        let host = try XCTUnwrap(dialog, "the destination sheet")
        host.rootView.model.destination = .file
        host.rootView.onPrimary()
        await waitUntil(timeout: .seconds(30)) { FileManager.default.fileExists(atPath: launched.path) }

        weak var closed = viewer
        window.contentViewController = nil
        viewer = nil
        await waitUntil(timeout: .seconds(10)) { closed == nil }
        XCTAssertNil(closed, "the viewer is gone while its run goes on")
        try Data().write(to: gate)

        await waitUntil(timeout: .seconds(30)) { self.rows(after: known).contains { !$0.state.isActive } }
        let row = try XCTUnwrap(rows(after: known).first, "the run began a row")
        XCTAssertEqual("\(row.state) \(row.detail)", "completed Consensus FASTA saved")
        XCTAssertEqual(row.outputURLs.map(\.path), [fasta.path, record.path])
    }

    // MARK: - Where a consensus saved as a bundle goes (Phase 3.0 lane CONSENSUS-DEST, owner WF-9)

    /// What the viewport names for a mapping in a project, `.projectDerivedRoot`, or with no project.
    private var outputCapability: AlignmentOutputCapability = .userSelectedDestination

    /// A save panel that this route must not open. Asked anyway, it fails the case and still answers with
    /// `url`, so the run ends and the case can say where the output went.
    private final class ForbiddenSavePanel: SavePanelPresenting {
        let url: URL
        var requests: [String] = []
        init(url: URL) { self.url = url }
        func present(suggestedName: String, on window: NSWindow) async -> URL? {
            requests.append(suggestedName)
            XCTFail("this route must open no save panel, but \(suggestedName) was asked for")
            return url
        }
    }

    /// A save panel that keeps the folder it was asked to open in, nil when the route names none.
    private final class StartFolderSavePanel: SavePanelPresenting {
        let url: URL
        var requests: [(name: String, folder: URL?)] = []
        init(url: URL) { self.url = url }
        func present(suggestedName: String, on window: NSWindow) async -> URL? {
            requests.append((suggestedName, nil))
            return url
        }
        func present(suggestedName: String, on window: NSWindow, startingIn folder: URL?) async -> URL? {
            requests.append((suggestedName, folder))
            return url
        }
    }

    /// A project folder and a mapping result in it, the root the viewport names as `.projectDerivedRoot`.
    private func makeProject() throws -> (project: URL, result: URL) {
        let project = scratch.appendingPathComponent("P.lungfish", isDirectory: true)
        let result = project.appendingPathComponent("Analyses/minimap2-run", isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return (project, result)
    }

    /// Runs Generate Consensus on a mapping result inside a project, picks `destination` in the sheet,
    /// presses its button and waits for the row to end.
    private func consensusRow(
        in result: URL, destination: DialogDestination, panel: any SavePanelPresenting
    ) async throws -> OperationCenter.Item {
        let known = Set(OperationCenter.shared.items.map(\.id))
        outputCapability = .projectDerivedRoot(result)
        viewer.alignmentExtractionSavePanelPresenter = panel
        viewer.alignmentActionContext = try context(minimumDepth: 1)
        viewer.presentAlignmentConsensusGeneration()
        await waitUntil(budget: .lookup) { self.dialog != nil }
        let host = try XCTUnwrap(dialog, "the destination sheet")
        host.rootView.model.destination = destination
        host.rootView.onPrimary()
        await waitUntil(budget: .lookup) { self.rows(after: known).contains { !$0.state.isActive } }
        return try XCTUnwrap(rows(after: known).first, "the run began a row")
    }

    /// The value after `--output` in a recorded command, which is quoted when its path holds a space.
    private func outputPath(in command: String) -> String? {
        guard let flag = command.range(of: " --output ") else { return nil }
        let rest = command[flag.upperBound...]
        guard rest.first == "'" else { return String(rest.prefix { $0 != " " }) }
        return String(rest.dropFirst().prefix { $0 != "'" })
    }

    private func isInside(_ path: String?, _ folder: URL) -> Bool {
        guard let path else { return false }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            .hasPrefix(folder.resolvingSymlinksInPath().path + "/")
    }

    /// UX's WF-9 case. In a project, Save as Bundle shows no file dialog. The run writes the `.lungfishref`
    /// into the project, and the row's command and bundle name the same path there.
    func testConsensusSaveAsBundleInAProjectWritesIntoTheProjectWithNoPanel() async throws {
        let (project, result) = try makeProject()
        let panel = ForbiddenSavePanel(url: scratch.appendingPathComponent("out/S1.lungfishref"))
        let row = try await consensusRow(in: result, destination: .bundle, panel: panel)

        XCTAssertEqual(panel.requests, [], "no save panel opens")
        XCTAssertEqual("\(row.state) \(row.detail)", "completed Consensus reference bundle created")
        let command = row.cliCommand ?? "no command"
        let output = outputPath(in: command)
        XCTAssertTrue(isInside(output, project), "the command's --output is inside the project. \(command)")
        XCTAssertEqual(row.bundleURLs.count, 1, "the row names one bundle")
        let bundle = try XCTUnwrap(row.bundleURLs.first, "the row names the bundle")
        XCTAssertTrue(isInside(bundle.path, project), "the bundle is inside the project. \(bundle.path)")
        XCTAssertEqual(
            output.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            bundle.resolvingSymlinksInPath().path,
            "the row's bundle is the command's --output"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("manifest.json").path))
    }

    /// The name typed in the dialog is made unique as the other Save as Bundle routes do, so a second
    /// consensus under the same name lands beside the first as `-2`.
    func testConsensusBundleNameIsMadeUniqueWhenTaken() async throws {
        let (project, result) = try makeProject()
        let first = try await consensusRow(
            in: result, destination: .bundle,
            panel: ForbiddenSavePanel(url: scratch.appendingPathComponent("out/first.lungfishref"))
        )
        let second = try await consensusRow(
            in: result, destination: .bundle,
            panel: ForbiddenSavePanel(url: scratch.appendingPathComponent("out/second.lungfishref"))
        )
        let one = try XCTUnwrap(first.bundleURLs.first, "the first row names its bundle")
        let two = try XCTUnwrap(second.bundleURLs.first, "the second row names its bundle")
        XCTAssertTrue(isInside(two.path, project), "the second bundle is inside the project. \(two.path)")
        XCTAssertEqual(
            two.deletingLastPathComponent().resolvingSymlinksInPath().path,
            one.deletingLastPathComponent().resolvingSymlinksInPath().path,
            "both bundles land together"
        )
        XCTAssertEqual(two.lastPathComponent, one.deletingPathExtension().lastPathComponent + "-2.lungfishref")
    }

    /// Save to File… keeps its panel, which starts in the open project and not in the last folder used.
    func testConsensusSaveToFileInAProjectStartsItsPanelInTheProject() async throws {
        let (project, result) = try makeProject()
        let panel = StartFolderSavePanel(url: scratch.appendingPathComponent("out/S1.fasta"))
        let row = try await consensusRow(in: result, destination: .file, panel: panel)

        XCTAssertEqual("\(row.state) \(row.detail)", "completed Consensus FASTA saved")
        XCTAssertEqual(panel.requests.map { $0.name }, ["S1-MT192765.1-consensus.fasta"])
        XCTAssertEqual(
            panel.requests.map { $0.folder?.resolvingSymlinksInPath().path },
            [project.resolvingSymlinksInPath().path],
            "the panel starts in the project"
        )
    }

    /// The Bundle label carries an ellipsis only where a save panel still follows, a mapping with no project.
    func testTheBundleLabelNamesASavePanelOnlyWhereOneFollows() async throws {
        let (_, result) = try makeProject()
        outputCapability = .projectDerivedRoot(result)
        viewer.alignmentActionContext = try context(minimumDepth: 1)
        viewer.presentAlignmentConsensusGeneration()
        await waitUntil(budget: .lookup) { self.dialog != nil }
        var host = try XCTUnwrap(dialog, "the destination sheet in a project")
        XCTAssertEqual(host.rootView.model.label(for: .bundle), "Save as Bundle")
        XCTAssertEqual(host.rootView.model.label(for: .file), "Save to File…")
        host.rootView.onCancel()
        await waitUntil(timeout: .seconds(10)) { self.window.attachedSheet == nil }

        outputCapability = .userSelectedDestination
        viewer.alignmentActionContext = try context(minimumDepth: 1)
        viewer.presentAlignmentConsensusGeneration()
        await waitUntil(budget: .lookup) { self.dialog != nil }
        host = try XCTUnwrap(dialog, "the destination sheet with no project")
        XCTAssertEqual(host.rootView.model.label(for: .bundle), "Save as Bundle…")
        host.rootView.onCancel()
    }
}
