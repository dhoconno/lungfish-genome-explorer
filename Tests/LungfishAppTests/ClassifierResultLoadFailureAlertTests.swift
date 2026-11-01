// ClassifierResultLoadFailureAlertTests.swift - A NAO-MGS or NVD result that cannot load says what did not open
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane ALERT-C5 (UX 1, UX 8). `displayNaoMgsResultFromSidebar` and `displayNvdResultFromSidebar` showed the
// error's own text as the whole body of "Failed to Load NAO-MGS Result" and "Failed to Load NVD Result". Each test
// opens a result folder that cannot load, as the sidebar does, waits for the alert's sheet on the window and reads
// the words a person reads. The faults are real ones, a folder with no manifest, a manifest with no database file and
// a manifest that is not JSON. No tool, network or defaults key is involved.

import AppKit
import LungfishKit
import LungfishTestSupport
import XCTest
@testable import LungfishApp
@testable import LungfishIO

@MainActor
final class ClassifierResultLoadFailureAlertTests: XCTestCase {
    private var root: URL!
    private var controller: MainSplitViewController!
    private var window: NSWindow!
    private var hostDefaults: HostDefaultsRestorer?

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        root = try TestTempDirectory.make(prefix: "classifier-load-failure")
        hostDefaults = HostDefaultsRestorer(keysContaining: root.lastPathComponent)
        let split = MainSplitViewController()
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        host.isReleasedWhenClosed = false
        host.contentViewController = split
        host.layoutIfNeeded()
        split.view.layoutSubtreeIfNeeded()
        controller = split
        window = host
    }

    override func tearDown() async throws {
        if let sheet = window?.attachedSheet { window.endSheet(sheet) }
        window?.contentViewController = nil
        window = nil
        controller = nil
        hostDefaults?.restore()
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    // MARK: - NAO-MGS

    func testNaoMgsFolderWithoutItsManifestSaysWhatDidNotOpenAndToImportAgain() async throws {
        let folder = try makeFolder("naomgs-no-manifest")
        controller.displayNaoMgsResultFromSidebar(at: folder)
        assertOpenFailure(
            try await sheetWords(), tool: "NAO-MGS", folder: folder, rawText: "manifest.json not found",
            nextStep: ["import the NAO-MGS result again"]
        )
    }

    func testNaoMgsFolderWithoutItsDatabaseSaysWhatDidNotOpenAndToImportAgain() async throws {
        let folder = try makeFolder("naomgs-no-database")
        try writeManifest(
            NaoMgsManifest(sampleName: "sample-a", sourceFilePath: "virus_hits_final.tsv.gz", hitCount: 0, taxonCount: 0),
            into: folder
        )
        controller.displayNaoMgsResultFromSidebar(at: folder)
        assertOpenFailure(
            try await sheetWords(), tool: "NAO-MGS", folder: folder, rawText: "hits.sqlite not found",
            nextStep: ["import the NAO-MGS result again"]
        )
    }

    func testNaoMgsFolderWithAManifestThatIsNotJSONSaysItCouldNotReadTheFolder() async throws {
        let folder = try makeFolder("naomgs-damaged-manifest")
        try Data("this is not json".utf8).write(to: folder.appendingPathComponent("manifest.json"))
        controller.displayNaoMgsResultFromSidebar(at: folder)
        assertOpenFailure(
            try await sheetWords(), tool: "NAO-MGS", folder: folder, rawText: "correct format",
            nextStep: ["select the result in the sidebar again", "import the NAO-MGS result again"]
        )
    }

    // MARK: - NVD

    func testNvdFolderWithoutItsManifestSaysWhatDidNotOpenAndToImportAgain() async throws {
        let folder = try makeFolder("nvd-no-manifest")
        controller.displayNvdResultFromSidebar(at: folder)
        assertOpenFailure(
            try await sheetWords(), tool: "NVD", folder: folder, rawText: "manifest.json not found",
            nextStep: ["import the NVD result again"]
        )
    }

    func testNvdFolderWithoutItsDatabaseSaysWhatDidNotOpenAndToImportAgain() async throws {
        let folder = try makeFolder("nvd-no-database")
        try writeManifest(
            NvdManifest(
                experiment: "100", sampleCount: 0, contigCount: 0, hitCount: 0, blastDbVersion: nil,
                snakemakeRunId: nil, sourceDirectoryPath: "nvd-source", samples: [], cachedTopContigs: nil
            ),
            into: folder
        )
        controller.displayNvdResultFromSidebar(at: folder)
        assertOpenFailure(
            try await sheetWords(), tool: "NVD", folder: folder, rawText: "hits.sqlite not found",
            nextStep: ["import the NVD result again"]
        )
    }

    func testNvdFolderWithAManifestThatIsNotJSONSaysItCouldNotReadTheFolder() async throws {
        let folder = try makeFolder("nvd-damaged-manifest")
        try Data("this is not json".utf8).write(to: folder.appendingPathComponent("manifest.json"))
        controller.displayNvdResultFromSidebar(at: folder)
        assertOpenFailure(
            try await sheetWords(), tool: "NVD", folder: folder, rawText: "correct format",
            nextStep: ["select the result in the sidebar again", "import the NVD result again"]
        )
    }

    // MARK: - The sheet

    private struct SheetWords {
        var texts: [String] = []
        var details: String?
    }

    private func makeFolder(_ name: String) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func writeManifest(_ manifest: some Encodable, into folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: folder.appendingPathComponent("manifest.json"))
    }

    /// Waits for the alert's sheet, reads its text fields and the details area, then ends the sheet.
    private func sheetWords() async throws -> SheetWords {
        _ = await waitUntil(budget: .lookup) { window.attachedSheet != nil }
        let sheet = try XCTUnwrap(window.attachedSheet, "the failed load shows its alert as a sheet on the window")
        var words = SheetWords()
        func walk(_ view: NSView) {
            if let field = view as? NSTextField, !field.stringValue.isEmpty { words.texts.append(field.stringValue) }
            if let details = view as? FailureDetailsView { words.details = details.textView.string }
            view.subviews.forEach(walk)
        }
        if let content = sheet.contentView { walk(content) }
        window.endSheet(sheet)
        return words
    }

    /// The title names the step, the body names the result that did not open and what to try, no file name of the
    /// result's insides and none of the error's own text is in it, and the error's text sits under Show Details.
    private func assertOpenFailure(
        _ words: SheetWords, tool: String, folder: URL, rawText: String, nextStep: [String],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let title = "Could not open the \(tool) result"
        XCTAssertTrue(words.texts.contains(title), "the title names the step, got \(words.texts)", file: file, line: line)
        let body = words.texts.filter { $0 != title }.joined(separator: "\n")
        XCTAssertTrue(
            body.contains(folder.lastPathComponent), "the body names the result that did not open, got \(body)",
            file: file, line: line
        )
        for fragment in nextStep {
            XCTAssertTrue(
                body.localizedCaseInsensitiveContains(fragment), "the body says to \(fragment), got \(body)",
                file: file, line: line
            )
        }
        XCTAssertFalse(body.contains(rawText), "the error's own text stays out of the body, got \(body)", file: file, line: line)
        for insideName in ["manifest.json", "hits.sqlite", "Error domain"] {
            XCTAssertFalse(body.contains(insideName), "no \(insideName) in the body, got \(body)", file: file, line: line)
        }
        XCTAssertTrue(
            words.details?.contains(rawText) ?? false,
            "the error's own text is kept under Show Details, got \(words.details ?? "no details area")",
            file: file, line: line
        )
    }
}
