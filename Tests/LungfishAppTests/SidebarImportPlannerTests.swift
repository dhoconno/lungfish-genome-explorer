// SidebarImportPlannerTests.swift - Tests for sidebar import batch planning
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp

final class SidebarImportPlannerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarImportPlannerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testPlanExpandsFolderRecursivelyAndSuppressesAutoDisplay() throws {
        let droppedFolder = tempDir.appendingPathComponent("decompressed")
        let nestedFolder = droppedFolder.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nestedFolder, withIntermediateDirectories: true)

        let topLevelFASTA = droppedFolder.appendingPathComponent("alpha.fa")
        let nestedFASTA = nestedFolder.appendingPathComponent("beta.fasta")
        let hiddenFASTA = droppedFolder.appendingPathComponent(".hidden.fa")
        let unsupported = nestedFolder.appendingPathComponent("README")

        try ">alpha\nACGT\n".write(to: topLevelFASTA, atomically: true, encoding: .utf8)
        try ">beta\nTGCA\n".write(to: nestedFASTA, atomically: true, encoding: .utf8)
        try ">hidden\nNNNN\n".write(to: hiddenFASTA, atomically: true, encoding: .utf8)
        try "ignore me".write(to: unsupported, atomically: true, encoding: .utf8)

        let plan = SidebarImportPlanner.makePlan(for: [droppedFolder])

        XCTAssertEqual(
            plan.sourceURLs.map(\.lastPathComponent),
            ["alpha.fa", "beta.fasta"]
        )
        XCTAssertFalse(plan.shouldAutoDisplayImportedContent)
    }

    func testPlanAutoDisplaysSingleSource() throws {
        let fastaURL = tempDir.appendingPathComponent("single.fa")
        try ">seq\nACGT\n".write(to: fastaURL, atomically: true, encoding: .utf8)

        let plan = SidebarImportPlanner.makePlan(for: [fastaURL])

        XCTAssertEqual(plan.sourceURLs, [fastaURL.standardizedFileURL])
        XCTAssertTrue(plan.shouldAutoDisplayImportedContent)
    }

    func testPlanKeepsExplicitReferenceBundleAtomic() throws {
        let bundleURL = tempDir.appendingPathComponent("Example.lungfishref")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent("genome"),
            withIntermediateDirectories: true
        )
        try ">bundle\nACGT\n".write(
            to: bundleURL.appendingPathComponent("genome/sequence.fa"),
            atomically: true,
            encoding: .utf8
        )

        let plan = SidebarImportPlanner.makePlan(for: [bundleURL])

        XCTAssertEqual(plan.sourceURLs, [bundleURL.standardizedFileURL])
        XCTAssertTrue(plan.shouldAutoDisplayImportedContent)
    }

    func testPlanKeepsONTDirectoryAtomic() throws {
        let ontRunURL = tempDir.appendingPathComponent("Run42")
        try FileManager.default.createDirectory(at: ontRunURL, withIntermediateDirectories: true)

        let plan = SidebarImportPlanner.makePlan(
            for: [ontRunURL],
            ontDirectoryDetector: { $0.standardizedFileURL == ontRunURL.standardizedFileURL }
        )

        XCTAssertEqual(plan.sourceURLs, [ontRunURL.standardizedFileURL])
        XCTAssertTrue(plan.shouldAutoDisplayImportedContent)
    }

    func testPlanSkipsNestedBundleDescendantsWhenExpandingFolder() throws {
        let droppedFolder = tempDir.appendingPathComponent("decompressed")
        let nestedBundle = droppedFolder.appendingPathComponent("Existing.lungfishref")
        let nestedBundleGenome = nestedBundle.appendingPathComponent("genome")
        try FileManager.default.createDirectory(at: nestedBundleGenome, withIntermediateDirectories: true)
        try ">inside\nACGT\n".write(
            to: nestedBundleGenome.appendingPathComponent("sequence.fa"),
            atomically: true,
            encoding: .utf8
        )

        let plainFASTA = droppedFolder.appendingPathComponent("plain.fa")
        try FileManager.default.createDirectory(at: droppedFolder, withIntermediateDirectories: true)
        try ">plain\nTGCA\n".write(to: plainFASTA, atomically: true, encoding: .utf8)

        let plan = SidebarImportPlanner.makePlan(for: [droppedFolder])

        XCTAssertEqual(plan.sourceURLs.map(\.lastPathComponent), ["plain.fa"])
    }
}
