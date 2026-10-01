import XCTest
@testable import LungfishApp

final class PlainTextPreviewTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlainTextPreview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ name: String, _ data: Data) throws -> URL {
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func write(_ name: String, _ text: String) throws -> URL {
        try write(name, Data(text.utf8))
    }

    func testWorkflowExtensionsRouteToText() throws {
        for name in ["main.nf", "rules.smk", "nextflow.config", "custom.config", "analysis.R", "plot.r"] {
            XCTAssertEqual(PlainTextPreview.decision(for: try write(name, "x = 1\n")), .text, name)
        }
    }

    func testKnownExtensionlessNamesRouteToText() throws {
        for name in ["Snakefile", "Makefile", "Dockerfile", "LICENSE"] {
            XCTAssertEqual(PlainTextPreview.decision(for: try write(name, "all:\n")), .text, name)
        }
    }

    func testTypesQuickLookHandlesStayOnQuickLook() throws {
        for name in ["README.md", "notes.txt", "run.sh", "tool.py", "env.yaml", "env.yml", "data.json", "run.log"] {
            XCTAssertEqual(PlainTextPreview.decision(for: try write(name, "hello\n")), .quickLook, name)
        }
    }

    func testUnknownSmallUTF8FileSniffsAsText() throws {
        XCTAssertEqual(PlainTextPreview.decision(for: try write("params.zzq", "alpha: 1\nbeta: é\n")), .text)
        XCTAssertEqual(PlainTextPreview.decision(for: try write("NOTES_WITHOUT_EXT", "plain words\n")), .text)
    }

    func testBinaryUnknownFileIsRejected() throws {
        var bytes = Data("header".utf8)
        bytes.append(0)
        bytes.append(contentsOf: [0xFF, 0xFE, 0x01])
        XCTAssertEqual(PlainTextPreview.decision(for: try write("blob.zzq", bytes)), .quickLook)
        XCTAssertEqual(PlainTextPreview.decision(for: try write("main.nf", bytes)), .quickLook)
    }

    func testInvalidUTF8IsRejected() throws {
        XCTAssertEqual(PlainTextPreview.decision(for: try write("latin.zzq", Data([0x41, 0xE9, 0x42, 0xFF]))), .quickLook)
    }

    func testEmptyAndMissingFilesAreRejected() throws {
        XCTAssertEqual(PlainTextPreview.decision(for: try write("empty.zzq", Data())), .quickLook)
        XCTAssertEqual(PlainTextPreview.decision(for: root.appendingPathComponent("absent.zzq")), .quickLook)
    }

    func testDirectoryIsRejected() throws {
        let dir = root.appendingPathComponent("Snakefile", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertEqual(PlainTextPreview.decision(for: dir), .quickLook)
    }

    func testLargeUnknownFileIsNotSniffedButLargeWorkflowFileIsTruncated() throws {
        let big = Data(repeating: UInt8(ascii: "a"), count: PlainTextPreview.maxSniffedFileBytes + 10)
        XCTAssertEqual(PlainTextPreview.decision(for: try write("huge.zzq", big)), .quickLook)
        let nf = try write("big.nf", big)
        XCTAssertEqual(PlainTextPreview.decision(for: nf), .text)
        let content = try XCTUnwrap(PlainTextPreview.load(from: nf))
        XCTAssertTrue(content.isTruncated)
        XCTAssertEqual(content.text.utf8.count, PlainTextPreview.maxPreviewBytes)
        XCTAssertEqual(content.totalBytes, big.count)
    }

    func testTruncationDoesNotSplitMultiByteCharacter() throws {
        // "é" is two bytes; a 5 byte cap lands in the middle of the third one.
        let url = try write("utf.nf", "aéé\n")
        let content = try XCTUnwrap(PlainTextPreview.load(from: url, maxBytes: 4))
        XCTAssertTrue(content.isTruncated)
        XCTAssertEqual(content.text, "aé")
    }

    func testSmallFileLoadsWhole() throws {
        let content = try XCTUnwrap(PlainTextPreview.load(from: try write("main.nf", "process X {}\n")))
        XCTAssertFalse(content.isTruncated)
        XCTAssertEqual(content.text, "process X {}\n")
    }

    func testSniffAcceptsChunkCutMidCharacter() {
        var d = Data("ab".utf8)
        d.append(0xC3)
        XCTAssertTrue(PlainTextPreview.isLikelyText(d))
    }
}

@MainActor
final class PlainTextPreviewViewTests: XCTestCase {
    private func select(_ fileName: String, contents: String) throws -> (MainSplitViewController, URL, () -> Void) {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MainSplitTextPreview-\(UUID().uuidString)", isDirectory: true)
        let projectURL = tempRoot.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        let fileURL = projectURL.appendingPathComponent(fileName)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)

        let controller = MainSplitViewController()
        _ = controller.view
        controller.sidebarController.openProject(at: projectURL)
        controller.testingDisplayImportedProjectFile(fileURL)

        let deadline = Date().addingTimeInterval(10)
        while controller.viewerController.testQuickLookURL == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let cleanup = {
            controller.sidebarController.closeProject()
            try? FileManager.default.removeItem(at: tempRoot)
        }
        return (controller, fileURL, cleanup)
    }

    func testSelectingMainNfShowsTextPreview() throws {
        let body = "process BCFTOOLS {\n  script: 'bcftools view'\n}\n"
        let (controller, _, cleanup) = try select("main.nf", contents: body)
        defer { cleanup() }
        let viewer = try XCTUnwrap(controller.viewerController)
        XCTAssertEqual(viewer.testPlainTextPreviewString, body)
        XCTAssertEqual(viewer.testPreviewStatusText, "Previewing: main.nf")
        XCTAssertEqual(viewer.testPlainTextPreviewAccessibilityLabel, "Text preview of main.nf")
        XCTAssertFalse(viewer.testHasQuickLookView)
    }

    func testSelectingSnakefileShowsTextPreview() throws {
        let body = "rule all:\n    input: 'out.vcf'\n"
        let (controller, _, cleanup) = try select("Snakefile", contents: body)
        defer { cleanup() }
        let viewer = try XCTUnwrap(controller.viewerController)
        XCTAssertEqual(viewer.testPlainTextPreviewString, body)
        XCTAssertEqual(viewer.testPreviewStatusText, "Previewing: Snakefile")
    }

    func testSelectingMarkdownKeepsQuickLookPath() throws {
        let (controller, fileURL, cleanup) = try select("methods.md", contents: "# Methods\n")
        defer { cleanup() }
        let viewer = try XCTUnwrap(controller.viewerController)
        XCTAssertEqual(viewer.testQuickLookURL?.resolvingSymlinksInPath(), fileURL.resolvingSymlinksInPath())
        XCTAssertNil(viewer.testPlainTextPreviewString)
    }
}
