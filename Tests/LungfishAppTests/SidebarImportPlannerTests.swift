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

    func testPlanRoutesBAMReadInputButExcludesOtherScientificTracks() throws {
        let filenames = [
            "reads.bam",
            "reads.cram",
            "calls.vcf",
            "calls.vcf.gz",
            "calls.bcf",
        ]
        for filename in filenames {
            try "placeholder".write(
                to: tempDir.appendingPathComponent(filename),
                atomically: true,
                encoding: .utf8
            )
        }

        let plan = SidebarImportPlanner.makePlan(
            for: filenames.map { tempDir.appendingPathComponent($0) }
        )

        XCTAssertEqual(plan.sourceURLs, [tempDir.appendingPathComponent("reads.bam").standardizedFileURL])
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

    func testPlanKeepsMHCReferenceBundleAtomic() throws {
        let bundleURL = tempDir.appendingPathComponent("Example.lungfishmhcref")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent("haplotypes"),
            withIntermediateDirectories: true
        )
        try "{}".write(
            to: bundleURL.appendingPathComponent("mhc-reference.json"),
            atomically: true,
            encoding: .utf8
        )
        try ">ref\nACGT\n".write(
            to: bundleURL.appendingPathComponent("reference.fa"),
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

    func testPlanIncludesNestedBundleWithoutItsDescendantsWhenExpandingFolder() throws {
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

        XCTAssertEqual(plan.sourceURLs.map(\.lastPathComponent), ["Existing.lungfishref", "plain.fa"])
    }

    func testPlanIncludesNestedMHCReferenceBundleWithoutItsDescendants() throws {
        let droppedFolder = tempDir.appendingPathComponent("decompressed")
        let nestedBundle = droppedFolder.appendingPathComponent("Existing.lungfishmhcref")
        let nestedBundleHaplotypes = nestedBundle.appendingPathComponent("haplotypes")
        try FileManager.default.createDirectory(at: nestedBundleHaplotypes, withIntermediateDirectories: true)
        try "{}".write(
            to: nestedBundle.appendingPathComponent("mhc-reference.json"),
            atomically: true,
            encoding: .utf8
        )
        try ">ref\nACGT\n".write(
            to: nestedBundle.appendingPathComponent("reference.fa"),
            atomically: true,
            encoding: .utf8
        )

        let plainFASTA = droppedFolder.appendingPathComponent("plain.fa")
        try ">plain\nTGCA\n".write(to: plainFASTA, atomically: true, encoding: .utf8)

        let plan = SidebarImportPlanner.makePlan(for: [droppedFolder])

        XCTAssertEqual(plan.sourceURLs.map(\.lastPathComponent), ["Existing.lungfishmhcref", "plain.fa"])
    }

    func testEveryAdvertisedNativeDirectoryIsAtomicBeforeONTDetection() throws {
        let extensions = ["lungfishref", "lungfishfastq", "lungfishmsa", "lungfishtree", "lungfishmhcref",
                          "lungfishgenotype", "lungfish12s", "lungfish12sref", "lungfishprimers"]
        for ext in extensions {
            let bundle = tempDir.appendingPathComponent("Fixture.\(ext)", isDirectory: true)
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            try ">internal\nAC\n".write(to: bundle.appendingPathComponent("internal.fa"), atomically: true, encoding: .utf8)
            var consultedONTDetector = false
            let plan = SidebarImportPlanner.makePlan(for: [bundle], ontDirectoryDetector: { _ in
                consultedONTDetector = true
                return false
            })
            XCTAssertEqual(plan.sourceURLs, [bundle.standardizedFileURL], ext)
            XCTAssertFalse(consultedONTDetector, "Native identity must take precedence: \(ext)")
        }
        let nested = SidebarImportPlanner.makePlan(for: [tempDir])
        XCTAssertEqual(nested.sourceURLs.count, extensions.count)
        XCTAssertTrue(nested.sourceURLs.allSatisfy { extensions.contains($0.pathExtension) })
    }
}
