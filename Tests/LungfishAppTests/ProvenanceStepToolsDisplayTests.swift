// ProvenanceStepToolsDisplayTests.swift - The Step Tools row of the Run Summary
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import ViewInspector
import XCTest
@testable import LungfishApp
import LungfishTestSupport
import LungfishWorkflow

/// Phase 2.8 lane U3, decision P3. A classifier that runs through `lungfish-cli` records `lungfish-cli` as its
/// tool, so the Tool row of the Run Summary never named Kraken2 or EsViritu above the Lineage. The Step Tools row
/// names the tool and version of each step that ran a program other than LGE, from that step's own record and
/// never from the managed tool lock. A step LGE ran itself, such as `lungfish-cli fastq materialize` or a result
/// sidecar writer, stays in the Lineage alone. The row shows only when the run-level tool is `lungfish-cli`.
///
/// The cases edit the bytes of the committed cancelled `fastq trim` record, copy them into a temporary project and
/// read them through the real lookup, so the Copy text and the view are the ones a scientist gets.
@MainActor
final class ProvenanceStepToolsDisplayTests: XCTestCase {

    // MARK: - The row

    func testTheRowNamesEachStepsToolAndVersionOnceInStepOrder() async throws {
        let model = try await loadedModel(
            try commandLineRecord(steps: [("EsViritu", "1.3.3"), ("samtools", "1.21"), ("EsViritu", "1.3.3")])
        )

        XCTAssertTrue(model.copyableText.contains("Step Tools: EsViritu v1.3.3, samtools v1.21\n"), model.copyableText)
        let texts = try summaryTexts(of: model)
        XCTAssertTrue(texts.contains("Step Tools") && texts.contains("EsViritu v1.3.3, samtools v1.21"), "\(texts)")
    }

    /// The version is the step's own. No tool is pinned at 0.0.1, so a version read from the managed tool lock
    /// could not produce this text.
    func testEachVersionIsTheStepsOwnAndNeverTheLocksVersion() async throws {
        let model = try await loadedModel(try commandLineRecord(steps: [("kraken2", "0.0.1"), ("bracken", "9.9.9")]))

        XCTAssertTrue(model.copyableText.contains("Step Tools: kraken2 v0.0.1, bracken v9.9.9\n"), model.copyableText)
    }

    func testAStepWithNoVersionShowsItsToolAloneAndAStepWithNoToolShowsNothing() async throws {
        let model = try await loadedModel(
            try commandLineRecord(steps: [("bracken", ""), ("unknown", "1.0"), ("", "2.0"), ("kraken2", "unknown")])
        )

        XCTAssertTrue(model.copyableText.contains("Step Tools: bracken, kraken2\n"), model.copyableText)
    }

    func testARecordWhoseStepsNameNoToolShowsNoRow() async throws {
        let model = try await loadedModel(try commandLineRecord(steps: [("unknown", "1.0"), ("", "2.0")]))

        XCTAssertFalse(model.copyableText.contains("Step Tools"), model.copyableText)
        XCTAssertFalse(try summaryTexts(of: model).contains("Step Tools"))
    }

    /// The row is for the run-level tool that runs other tools. A run whose own tool is the scientific tool
    /// already names it in the Tool row, and its record shows no second row.
    func testARunWhoseOwnToolIsNotTheCommandLineShowsNoRow() async throws {
        let model = try await loadedModel(try recordBytes())

        XCTAssertEqual(model.summary.toolName, "fastp")
        XCTAssertFalse(model.copyableText.contains("Step Tools"), model.copyableText)
        XCTAssertFalse(try summaryTexts(of: model).contains("Step Tools"))
    }

    /// The steps of the committed CLI-route Kraken2 record, with `LGE primer ordering` added. Four of the six are
    /// LGE's own, and the Lineage lists them. The row names the programs LGE ran, so it reads two entries.
    func testLGEsOwnStepsAreLeftOutOfTheRow() async throws {
        let model = try await loadedModel(try commandLineRecord(steps: [
            ("lungfish-cli fastq materialize", "2026.10.14"),
            ("kraken2", "2.17.1"),
            ("lungfish-kraken2-index", "Lungfish 2026.10.14 (dev)"),
            ("gzip", "system"),
            ("Lungfish Classification Result Sidecar", "Lungfish 2026.10.14 (dev)"),
            ("LGE primer ordering", "1.0"),
        ]))

        XCTAssertTrue(model.copyableText.contains("Step Tools: kraken2 v2.17.1, gzip system\n"), model.copyableText)
        let texts = try summaryTexts(of: model)
        XCTAssertTrue(texts.contains("kraken2 v2.17.1, gzip system"), "\(texts)")
    }

    /// A record whose every step is LGE's own names no program, so the row does not show.
    func testARecordWhoseStepsAreAllLGEsOwnShowsNoRow() async throws {
        let model = try await loadedModel(try commandLineRecord(steps: [
            ("lungfish-cli fastq materialize", "2026.10.14"),
            ("Lungfish EsViritu Result Sidecar", "Lungfish 2026.10.14 (dev)"),
        ]))

        XCTAssertFalse(model.copyableText.contains("Step Tools"), model.copyableText)
        XCTAssertFalse(try summaryTexts(of: model).contains("Step Tools"))
    }

    // MARK: - Pins at the base (Phase 2.10 lane U35, M1 item 1)

    /// A full commit as TaxTriage's executor records the revision of its step. The first starts with a letter and
    /// the second with a digit, since the Lineage puts `v` before a version that starts with a digit.
    private static let letterCommit = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
    private static let digitCommit = "3a5c9d1e7b2f40886d9a1c3e5f7092b4d6e8a0c2"

    /// T12. At the base a record the CLI route writes for a TaxTriage run, the tool `taxtriage` at a commit with the
    /// release tag beside it, read the 40 characters in Step Tools. W5 moved that shape to `<tool> <tag> (<7 chars>)`,
    /// so this case holds the record that names the commit and no tag, an older one, which still prints it as recorded.
    func testATaxTriageRecordWithACommitAndNoTagShowsTheFortyHexCommitInStepTools() async throws {
        let commit = Self.letterCommit
        let model = try await loadedModel(try commandLineRecord(steps: [("taxtriage", commit)]))

        XCTAssertEqual(model.stepToolsText, "taxtriage \(commit)")
        XCTAssertTrue(model.copyableText.contains("Step Tools: taxtriage \(commit)\n"), model.copyableText)
        let texts = try summaryTexts(of: model)
        XCTAssertTrue(texts.contains("Step Tools") && texts.contains("taxtriage \(commit)"), "\(texts)")
    }

    /// T12. At the base a commit that starts with a digit read `v<commit>` in Step Tools, in the Lineage and in the
    /// Copy text, as a version such as `1.24` reads `v1.24`. A commit is not a release number, so it now reads as
    /// recorded in all three (U35 M1 item 3). The record names no tag, since W5 shows a tagged commit as its tag.
    func testACommitThatStartsWithADigitReadsAsRecordedInStepToolsAndTheLineage() async throws {
        let commit = Self.digitCommit
        let model = try await loadedModel(try commandLineRecord(steps: [("taxtriage", commit)]))

        XCTAssertEqual(model.stepToolsText, "taxtriage \(commit)")
        XCTAssertEqual(model.lineageRuns.last?.steps.first?.toolVersion, commit)
        XCTAssertTrue(model.copyableText.contains("\n1. taxtriage \(commit)\n"), model.copyableText)
    }

    /// The same commit as a run's own tool, the Tool row and the heading of its Lineage run, reads without `v`.
    func testARunWhoseOwnToolIsTaxTriageAtADigitCommitReadsItWithoutV() async throws {
        let commit = Self.digitCommit
        let model = try await loadedModel(
            try commandLineRecord(steps: [("taxtriage", commit)], runTool: ("taxtriage", commit))
        )

        XCTAssertEqual(model.toolText, "taxtriage \(commit)")
        XCTAssertEqual(model.lineageRuns.last?.subtitle, "taxtriage \(commit)")
        XCTAssertTrue(model.copyableText.contains("\nTool: taxtriage \(commit)\n"), model.copyableText)
    }

    // MARK: - Helper steps LGE records for its own calls (Phase 2.10 lane U35, M2 item 1)

    /// Row 273. A step LGE records for a library or system call it makes itself names no program a scientist ran, so
    /// the row leaves it out although its name does not start with `lungfish` or `LGE `. The Lineage still lists it.
    /// `helper` is a step of a real writer with the version that writer records.
    private func assertTheRowLeavesOut(
        _ helper: (tool: String, version: String), file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let model = try await loadedModel(try commandLineRecord(steps: [helper, ("kraken2", "2.17.1")]))

        XCTAssertEqual(model.stepToolsText, "kraken2 v2.17.1", file: file, line: line)
        XCTAssertTrue(
            model.copyableText.contains("Step Tools: kraken2 v2.17.1\n"), model.copyableText, file: file, line: line
        )
        XCTAssertEqual(model.lineageRuns.last?.steps.map(\.toolName), [helper.tool, "kraken2"], file: file, line: line)
    }

    /// `DatabaseRegistry` records the download of a database, and its checksum, as `URLSession` and `CryptoKit` steps.
    func testTheURLSessionStepOfADatabaseDownloadIsLeftOutOfTheRow() async throws {
        try await assertTheRowLeavesOut(("URLSession", "Foundation"))
    }

    func testTheCryptoKitStepOfAChecksumIsLeftOutOfTheRow() async throws {
        try await assertTheRowLeavesOut(("CryptoKit", "Insecure.MD5"))
    }

    func testTheClonefileStepOfAnAPFSCopyIsLeftOutOfTheRow() async throws {
        try await assertTheRowLeavesOut(("clonefile", "APFS"))
    }

    func testTheProjectTempDirectoryStepIsLeftOutOfTheRow() async throws {
        try await assertTheRowLeavesOut(("ProjectTempDirectory", "2026.10.14"))
    }

    func testTheNCBIEFetchStepOfAFetchIsLeftOutOfTheRow() async throws {
        try await assertTheRowLeavesOut(("ncbi-efetch", "NCBI E-utilities API"))
    }

    /// `ena-fetch-fasta` is the ENA twin of `ncbi-efetch`, recorded by the same command with the same kind of version.
    func testTheENAFetchStepOfAFetchIsLeftOutOfTheRow() async throws {
        try await assertTheRowLeavesOut(("ena-fetch-fasta", "ENA Browser API"))
    }

    func testTheHTTPSDownloadStepOfAReadDownloadIsLeftOutOfTheRow() async throws {
        try await assertTheRowLeavesOut(("https-download", "URLSession"))
    }

    /// A record whose every step is one of these helpers names no program, so the row does not show.
    func testARecordWhoseStepsAreAllHelpersShowsNoRow() async throws {
        let model = try await loadedModel(
            try commandLineRecord(steps: [("URLSession", "Foundation"), ("CryptoKit", "Insecure.MD5")])
        )

        XCTAssertNil(model.stepToolsText)
        XCTAssertFalse(model.copyableText.contains("Step Tools"), model.copyableText)
    }

    /// The set names whole steps. A program whose name only contains a helper's name still shows.
    func testAProgramWhoseNameOnlyContainsAHelperNameStillShows() async throws {
        let model = try await loadedModel(try commandLineRecord(steps: [("URLSession-proxy", "1.0"), ("kraken2", "2.17.1")]))

        XCTAssertEqual(model.stepToolsText, "URLSession-proxy v1.0, kraken2 v2.17.1")
    }

    /// Row 273. The reader resolves `@/` inside the stored command and adds no quotes, so a project folder whose name
    /// has a space reached the full command of a step as two words (the M1 pin held that unquoted form). The full
    /// command, which the Copy text, the tooltip and VoiceOver carry whole, now quotes each project path as one word, and
    /// the shortened command the view shows reads the same as before.
    func testAProjectFolderNamedWithASpaceShowsTheFullCommandQuoted() async throws {
        let model = try await loadedModel(
            try commandLineRecord(steps: [("kraken2", "2.17.1")]), projectName: "Spaced Runs.lungfish"
        )

        let step = try XCTUnwrap(model.lineageRuns.last?.steps.first)
        let sidecar = try XCTUnwrap(model.resolvedSidecarURL)
        let folder = sidecar.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertEqual(folder.lastPathComponent, "Spaced Runs.lungfish")
        let spellings = Set([folder.path, folder.standardizedFileURL.path, folder.resolvingSymlinksInPath().path])
        let quoted = spellings.map {
            "lungfish-cli fastq trim '\($0)/Inputs/reads.fastq' --output '\($0)/Analyses/fastq-trim-cancelled/trimmed.fastq'"
        }
        XCTAssertTrue(quoted.contains(step.command), "the full command was \(step.command)")
        XCTAssertEqual(step.command.filter { $0 == "'" }.count, 4, step.command)
        XCTAssertEqual(
            step.displayCommand,
            "lungfish-cli fastq trim Inputs/reads.fastq --output Analyses/fastq-trim-cancelled/trimmed.fastq"
        )
        XCTAssertTrue(model.copyableText.contains("\nCommand: \(step.command)\n"), model.copyableText)
    }

    // MARK: - W5, a commit shown as its release tag (Phase 2.10 lane U35, M1 item 2)

    /// 2.9 W5. A step with a 40-hex `toolVersion` and a `githubReleaseVersion` reads `<tool> <tag> (<7 chars>)`, the
    /// tag as recorded and the first seven characters of the commit. A second step of the same tool at the same
    /// commit adds nothing, as before.
    func testAStepWithACommitAndATagShowsTheTagAndTheFirstSevenCharacters() async throws {
        let model = try await loadedModel(try commandLineRecord(
            steps: [("taxtriage", Self.letterCommit), ("taxtriage", Self.letterCommit), ("samtools", "1.21")],
            releases: ["taxtriage": "v3.3.8"]
        ))

        XCTAssertEqual(model.stepToolsText, "taxtriage v3.3.8 (a1b2c3d), samtools v1.21")
        XCTAssertTrue(
            model.copyableText.contains("Step Tools: taxtriage v3.3.8 (a1b2c3d), samtools v1.21\n"), model.copyableText
        )
        let texts = try summaryTexts(of: model)
        XCTAssertTrue(texts.contains("taxtriage v3.3.8 (a1b2c3d), samtools v1.21"), "\(texts)")
    }

    /// BIO. The full commit stays in the Copy text, in the Lineage step that the row abbreviates, and a commit that
    /// starts with a digit reads the same way as any other.
    func testTheCopyTextKeepsTheFullCommitOfAStepTheRowAbbreviates() async throws {
        let commit = Self.digitCommit
        let model = try await loadedModel(
            try commandLineRecord(steps: [("taxtriage", commit)], releases: ["taxtriage": "v3.3.8"])
        )

        XCTAssertEqual(model.stepToolsText, "taxtriage v3.3.8 (3a5c9d1)")
        let copy = model.copyableText
        XCTAssertTrue(copy.contains("Step Tools: taxtriage v3.3.8 (3a5c9d1)\n"), copy)
        let lineage = try XCTUnwrap(copy.range(of: "\nLineage\n"), copy)
        XCTAssertTrue(
            copy[lineage.upperBound...].contains("\n1. taxtriage \(commit)\n"), "the Lineage holds the full commit\n\(copy)"
        )
    }

    /// A step that has no tag, or whose version is not a commit, shows as it did. An older TaxTriage record has
    /// one or the other, and the tag is never guessed from a commit (BIO 4).
    func testAnOlderRecordWithoutBothFactsShowsAsToday() async throws {
        let tagOnly = try await loadedModel(
            try commandLineRecord(steps: [("taxtriage", "3.3.6")], releases: ["taxtriage": "v3.3.6"])
        )
        XCTAssertEqual(tagOnly.stepToolsText, "taxtriage v3.3.6")

        let blankTag = try await loadedModel(
            try commandLineRecord(steps: [("taxtriage", Self.letterCommit)], releases: ["taxtriage": " "])
        )
        XCTAssertEqual(blankTag.stepToolsText, "taxtriage \(Self.letterCommit)")

        let tagThatIsACommit = try await loadedModel(
            try commandLineRecord(steps: [("taxtriage", Self.letterCommit)], releases: ["taxtriage": Self.digitCommit])
        )
        XCTAssertEqual(tagThatIsACommit.stepToolsText, "taxtriage \(Self.letterCommit)")
    }

    /// 2.9 W5. Viral Recon and pbAA show as they did. A Viral Recon record names `nf-core-viralrecon` as its own
    /// tool, so it shows no Step Tools row and its Tool row reads as recorded, and a pbAA run shows its container
    /// tool at its release number.
    func testViralReconAndPBAARecordsShowAsToday() async throws {
        let commit = Self.letterCommit
        let viralRecon = try await loadedModel(try commandLineRecord(
            steps: [("nf-core-viralrecon", commit)], releases: ["nf-core-viralrecon": "3.0.0"],
            runTool: ("nf-core-viralrecon", commit)
        ))
        XCTAssertNil(viralRecon.stepToolsText)
        XCTAssertEqual(viralRecon.toolText, "nf-core-viralrecon \(commit)")
        XCTAssertFalse(viralRecon.copyableText.contains("Step Tools"), viralRecon.copyableText)
        XCTAssertTrue(viralRecon.copyableText.contains("\n1. nf-core-viralrecon \(commit)\n"), viralRecon.copyableText)

        let pbaa = try await loadedModel(try commandLineRecord(steps: [("pbaa", "1.2.0"), ("nextflow", "unknown")]))
        XCTAssertEqual(pbaa.stepToolsText, "pbaa v1.2.0, nextflow")
    }

    /// UX 6. Showing the row reads the record and writes nothing, not a byte and not a file.
    func testDisplayingAW5RecordWritesNothing() async throws {
        let placed = try place(
            try commandLineRecord(steps: [("taxtriage", Self.letterCommit)], releases: ["taxtriage": "v3.3.8"])
        )
        let before = try fileSnapshot(of: placed.root)

        let model = try await load(placed)
        XCTAssertEqual(model.stepToolsText, "taxtriage v3.3.8 (a1b2c3d)")
        XCTAssertFalse(model.copyableText.isEmpty)

        let after = try fileSnapshot(of: placed.root)
        XCTAssertEqual(Set(after.keys), Set(before.keys), "displaying added or removed a file")
        for (path, file) in before where after[path] != file {
            XCTFail("displaying changed \(path)")
        }
    }

    // MARK: - Order

    /// The row comes right after Tool in the Copy text, in the order the view lists its rows, and so in the order
    /// VoiceOver reads them (UX 5).
    func testTheRowSitsRightAfterToolInTheCopyTextTheViewAndWhatVoiceOverReads() async throws {
        let model = try await loadedModel(try commandLineRecord(steps: [("EsViritu", "1.3.3")]))

        try assertTheRowSitsRightAfterTool(of: model, reading: "EsViritu v1.3.3")
    }

    /// The abbreviated TaxTriage row keeps the place and the words in all three orders (UX 5).
    func testTheAbbreviatedRowSitsRightAfterToolInTheCopyTextTheViewAndWhatVoiceOverReads() async throws {
        let model = try await loadedModel(
            try commandLineRecord(steps: [("taxtriage", Self.letterCommit)], releases: ["taxtriage": "v3.3.8"])
        )

        try assertTheRowSitsRightAfterTool(of: model, reading: "taxtriage v3.3.8 (a1b2c3d)")
    }

    private func assertTheRowSitsRightAfterTool(
        of model: ProvenanceInspectorViewModel, reading rowText: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let copy = model.copyableText
        let tool = try XCTUnwrap(copy.range(of: "\nTool: "), copy, file: file, line: line)
        let steps = try XCTUnwrap(copy.range(of: "\nStep Tools: \(rowText)\n"), copy, file: file, line: line)
        let created = try XCTUnwrap(copy.range(of: "\nCreated: "), copy, file: file, line: line)
        XCTAssertLessThan(tool.lowerBound, steps.lowerBound, file: file, line: line)
        XCTAssertLessThan(steps.lowerBound, created.lowerBound, file: file, line: line)

        let texts = try summaryTexts(of: model)
        let shown = ["Tool", "Step Tools", rowText, "Created"].compactMap { texts.firstIndex(of: $0) }
        XCTAssertEqual(shown.count, 4, "\(texts)", file: file, line: line)
        XCTAssertEqual(shown, shown.sorted(), "\(texts)", file: file, line: line)

        let window = AccessibilityTreeProbe.host(ProvenanceSection(viewModel: model))
        defer { window.orderOut(nil) }
        func spoken() -> [String] {
            AccessibilityTreeProbe.all(in: window).flatMap { element in
                [AccessibilityTreeProbe.label(element), AccessibilityTreeProbe.value(element)].compactMap { $0 }
            }
        }
        AccessibilityTreeProbe.waitUntil { spoken().contains("Step Tools") }
        let heard = spoken()
        let heardAt = ["Tool", "Step Tools", rowText, "Created"].compactMap { heard.firstIndex(of: $0) }
        XCTAssertEqual(heardAt.count, 4, "\(heard)\n" + AccessibilityTreeProbe.dump(window), file: file, line: line)
        XCTAssertEqual(heardAt, heardAt.sorted(), "\(heard)", file: file, line: line)
    }

    // MARK: - Harness

    /// The committed cancelled `fastq trim` record, which names `fastp` as its own tool.
    private func recordBytes() throws -> Data {
        try Data(contentsOf: ProvenanceDisplayFixtures.directory
            .appendingPathComponent("Analyses/fastq-trim-cancelled/.lungfish-provenance.json"))
    }

    /// The cancelled record after it names `runTool` (`lungfish-cli` unless a case says otherwise) as its own tool
    /// and holds one step per pair. A tool named in `releases` records that release tag as its step's
    /// `githubReleaseVersion`.
    private func commandLineRecord(
        steps: [(tool: String, version: String)],
        releases: [String: String] = [:],
        runTool: (name: String, version: String) = ("lungfish-cli", "2026.10.14")
    ) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: try recordBytes()) as? [String: Any])
        let template = try XCTUnwrap((object["steps"] as? [[String: Any]])?.first)
        object["toolName"] = runTool.name
        object["toolVersion"] = runTool.version
        object["tool"] = ["kind": "cli", "name": runTool.name, "version": runTool.version]
        object["steps"] = steps.map { pair -> [String: Any] in
            var step = template
            step["id"] = UUID().uuidString
            step["toolName"] = pair.tool
            step["toolVersion"] = pair.version
            if let release = releases[pair.tool] { step["githubReleaseVersion"] = release }
            return step
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// A temporary folder that holds a project with `bytes` as the sidecar of its `classify-run` result.
    private struct PlacedRecord {
        let root: URL
        let sidecar: URL
    }

    private func place(_ bytes: Data, projectName: String = "Runs.lungfish") throws -> PlacedRecord {
        let root = try TestTempDirectory.make(prefix: "provenance-step-tools")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let project = root.appendingPathComponent(projectName, isDirectory: true)
        let sidecar = project.appendingPathComponent("Analyses/classify-run/.lungfish-provenance.json")
        try FileManager.default.createDirectory(at: sidecar.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: sidecar, options: .atomic)
        return PlacedRecord(root: root, sidecar: sidecar)
    }

    /// Every file under `root` with its bytes and modification date, to show that reading changed none.
    private func fileSnapshot(of root: URL) throws -> [String: [Data?]] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys))
        var files: [String: [Data?]] = [:]
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }
            let stamp = values.contentModificationDate.map { Data(String($0.timeIntervalSinceReferenceDate).utf8) }
            files[String(url.path.dropFirst(root.path.count))] = [try Data(contentsOf: url), stamp]
        }
        return files
    }

    private func loadedModel(_ bytes: Data, projectName: String = "Runs.lungfish") async throws -> ProvenanceInspectorViewModel {
        try await load(try place(bytes, projectName: projectName))
    }

    private func load(_ placed: PlacedRecord) async throws -> ProvenanceInspectorViewModel {
        let sidecar = placed.sidecar
        let model = ProvenanceInspectorViewModel()
        model.load(item: ProvenanceInspectableItem(
            url: sidecar.deletingLastPathComponent(),
            sidebarType: .analysisResult,
            contentMode: .genomics,
            displayName: "classify-run"
        ))
        let finished = await waitUntil(timeout: .seconds(60)) { !model.isLoading }
        XCTAssertTrue(finished, "The provenance lookup did not finish.")
        XCTAssertNotNil(model.resolvedEnvelope, "The record was not found.")
        return model
    }

    /// The text of every label and value the section draws, in the order it draws them.
    private func summaryTexts(of model: ProvenanceInspectorViewModel) throws -> [String] {
        try ProvenanceSection(viewModel: model).inspect().findAll(ViewType.Text.self).compactMap { try? $0.string() }
    }
}
