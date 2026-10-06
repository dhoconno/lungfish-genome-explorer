// OutputReplacementCheckTests.swift - The overlap rule every --replace command runs before it deletes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

final class OutputReplacementCheckTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OutputReplacementCheckTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testAnInputThatIsTheOutputOrSitsInsideItIsRefused() throws {
        let output = root.appendingPathComponent("Out.lungfishref", isDirectory: true)
        let inner = output.appendingPathComponent("mapping/reads.bam")
        try FileManager.default.createDirectory(at: inner.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: inner.path, contents: Data("bam".utf8))

        XCTAssertThrowsError(try OutputReplacementCheck.refuseInputs([inner], inside: output)) { error in
            XCTAssertEqual(
                error as? OutputReplacementRefusal,
                .inputInsideOutput(input: inner.standardizedFileURL.path, output: output.standardizedFileURL.path)
            )
            let reason = error.localizedDescription
            XCTAssertFalse(reason.contains("\n"), "one line")
            XCTAssertTrue(reason.contains(inner.standardizedFileURL.path) && reason.contains(output.standardizedFileURL.path), reason)
        }
        XCTAssertThrowsError(try OutputReplacementCheck.refuseInputs([output], inside: output)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Refusing to write \(output.standardizedFileURL.path), which is also an input of this run."
            )
        }
    }

    func testAnInputBesideTheOutputIsAccepted() throws {
        let output = root.appendingPathComponent("Out.lungfishref", isDirectory: true)
        let sibling = root.appendingPathComponent("Out.lungfishref-other/reads.bam")
        let parent: URL = root
        XCTAssertNoThrow(try OutputReplacementCheck.refuseInputs([sibling, parent], inside: output))
    }

    func testPathsAreComparedThroughSymlinks() throws {
        let real = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real.appendingPathComponent("Out.lungfishref"), withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        XCTAssertThrowsError(try OutputReplacementCheck.refuseInputs(
            [real.appendingPathComponent("Out.lungfishref/manifest.json")],
            inside: link.appendingPathComponent("Out.lungfishref")
        ))
    }

    func testAnOutputInsideACopiedInputIsRefusedAndTheInputItselfIsLeftToTheCaller() throws {
        let source = root.appendingPathComponent("Source.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let nested = source.appendingPathComponent("Inner.lungfishref", isDirectory: true)

        XCTAssertThrowsError(try OutputReplacementCheck.refuseOutput(nested, inside: source)) { error in
            XCTAssertEqual(
                error as? OutputReplacementRefusal,
                .outputInsideInput(output: nested.standardizedFileURL.path, input: source.standardizedFileURL.path)
            )
            XCTAssertFalse(error.localizedDescription.contains("\n"), "one line")
        }
        XCTAssertNoThrow(try OutputReplacementCheck.refuseOutput(source, inside: source))
        XCTAssertNoThrow(try OutputReplacementCheck.refuseOutput(root.appendingPathComponent("Other.lungfishref"), inside: source))
    }

    func testThePublishedBundleNameFollowsTheBuilder() {
        let directory = URL(fileURLWithPath: "/tmp/out", isDirectory: true)
        XCTAssertEqual(
            OutputReplacementCheck.publishedReferenceBundleURL(outputDirectory: directory, name: "My Genes").path,
            "/tmp/out/My_Genes.lungfishref"
        )
        XCTAssertEqual(
            OutputReplacementCheck.publishedReferenceBundleURL(outputDirectory: directory, name: "genes").path,
            "/tmp/out/genes.lungfishref"
        )
    }
}
