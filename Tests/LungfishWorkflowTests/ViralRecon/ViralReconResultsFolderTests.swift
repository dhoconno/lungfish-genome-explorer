// ViralReconResultsFolderTests.swift - A Viral Recon request refuses a results folder that already holds files
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.21 STALE-OUT, M2. A run into a folder an earlier run used leaves that run's files beside its own,
// so the request refuses the folder before anything runs, in the words UX fixed (W1). "Holds files" is any directory
// entry, hidden ones included (MD26, Reading A). A missing or empty folder is accepted, which the pin tests hold.

import XCTest
@testable import LungfishWorkflow

final class ViralReconResultsFolderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("viral-recon-results-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    static func w1Text(folder: String) -> String {
        "\"\(folder)\" already holds files, and a Viral Recon run would leave its results beside them. "
            + "Choose an empty folder or a new one."
    }

    func testAFolderHoldingAFileIsRefusedAndTheRefusalNamesTheFolder() throws {
        let output = root.appendingPathComponent("viralrecon-results-a1b2c3d4", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try "an earlier run\n".write(
            to: output.appendingPathComponent("multiqc_report.html"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertThrowsError(try ViralReconResultsFolderPinTests.makeRequest(outputDirectory: output)) { error in
            XCTAssertEqual(error.localizedDescription, Self.w1Text(folder: "viralrecon-results-a1b2c3d4"))
        }
    }

    func testAFolderHoldingOnlyAHiddenFileIsRefused() throws {
        let output = root.appendingPathComponent("opened-in-finder", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Data().write(to: output.appendingPathComponent(".DS_Store"))

        XCTAssertThrowsError(try ViralReconResultsFolderPinTests.makeRequest(outputDirectory: output)) { error in
            XCTAssertEqual(error.localizedDescription, Self.w1Text(folder: "opened-in-finder"))
        }
    }

    func testAFolderHoldingOnlyAFolderIsRefused() throws {
        let output = root.appendingPathComponent("results", isDirectory: true)
        try FileManager.default.createDirectory(
            at: output.appendingPathComponent("pipeline_info", isDirectory: true),
            withIntermediateDirectories: true
        )

        XCTAssertThrowsError(try ViralReconResultsFolderPinTests.makeRequest(outputDirectory: output)) { error in
            XCTAssertEqual(error.localizedDescription, Self.w1Text(folder: "results"))
        }
    }

    func testTheSharedCheckCountsAnyEntryAndNothingElse() throws {
        let missing = root.appendingPathComponent("missing", isDirectory: true)
        let empty = root.appendingPathComponent("empty", isDirectory: true)
        let withFile = root.appendingPathComponent("with-file", isDirectory: true)
        let withHidden = root.appendingPathComponent("with-hidden", isDirectory: true)
        let aFile = root.appendingPathComponent("a-file.txt")
        for folder in [empty, withFile, withHidden] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try "x".write(to: withFile.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try Data().write(to: withHidden.appendingPathComponent(".DS_Store"))
        try "x".write(to: aFile, atomically: true, encoding: .utf8)

        XCTAssertFalse(ViralReconRunRequest.ResultsFolder.holdsFiles(missing))
        XCTAssertFalse(ViralReconRunRequest.ResultsFolder.holdsFiles(empty))
        XCTAssertTrue(ViralReconRunRequest.ResultsFolder.holdsFiles(withFile))
        XCTAssertTrue(ViralReconRunRequest.ResultsFolder.holdsFiles(withHidden))
        XCTAssertFalse(ViralReconRunRequest.ResultsFolder.holdsFiles(aFile), "a path that names a file is no folder")
    }

    func testTheRefusalIsTheTypedErrorWithTheFolderAndOnlyItHasATitle() throws {
        let output = root.appendingPathComponent("viralrecon-results-a1b2c3d4", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try "x".write(to: output.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try ViralReconResultsFolderPinTests.makeRequest(outputDirectory: output)) { error in
            XCTAssertEqual(error as? ViralReconRunRequest.ValidationError, .resultsFolderHoldsFiles(output))
            XCTAssertEqual(ViralReconRunRequest.ResultsFolder.title(for: error), "Choose an empty results folder")
        }
        XCTAssertNil(ViralReconRunRequest.ResultsFolder.title(for: ViralReconRunRequest.ValidationError.emptySamples))
        XCTAssertNil(ViralReconRunRequest.ResultsFolder.title(for: CancellationError()))
    }

    /// UX's words W1, word for word. The app's alert has a title and a text and the leaf prints one line that names
    /// its own option.
    func testTheWordsAreUXsW1Verbatim() {
        XCTAssertEqual(ViralReconRunRequest.ResultsFolder.alertTitle, "Choose an empty results folder")
        XCTAssertEqual(
            ViralReconRunRequest.ResultsFolder.alertText(folderName: "results"),
            "\"results\" already holds files, and a Viral Recon run would leave its results beside them. "
                + "Choose an empty folder or a new one."
        )
        XCTAssertEqual(
            ViralReconRunRequest.ResultsFolder.leafRefusal(optionName: "--results-dir", path: "/runs/results"),
            "--results-dir /runs/results already holds files. Name an empty or new folder."
        )
    }
}
