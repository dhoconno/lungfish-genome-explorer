// ExecutorPlanFolderWriterTests.swift - The plan folder writer stages regular files and cleans up after a refusal (CHTC lane K4)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import LungfishPortable
import LungfishTestSupport
@testable import LungfishWorkflow

// `ExecutorPlanTestSupport`, the request a plan test hands the emitter, is in LungfishTestSupport, so the CLI's process
// tests of `import fastq --adopt` build the same plan.
final class ExecutorPlanFolderWriterTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "ExecutorPlanFolderWriter")
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func emission(_ inputs: [URL], clumping: ClumpingTool = .bbtools) throws -> ExecutorPlanEmission {
        try ExecutorPlanEmitter.emission(
            ExecutorPlanTestSupport.request(root: root, "S", inputs: inputs, clumping: clumping), host: ExecutorPlanTestSupport.mac24
        )
    }

    /// SWIFT fix 4 of the K4 part A review: an input given as a symbolic link is staged as the regular file it names,
    /// with equal bytes, and the node's resolver accepts every entry of the written folder.
    func testFolderWriterStagesRegularFilesAndCleansUp() throws {
        let pair = try ExecutorPlanTestSupport.writePair(root: root, "S")
        let link = root.appendingPathComponent("S_R1_link.fastq")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: pair[0])
        let emitted = try emission([link, pair[1]])
        let file = try ExecutorPlanFolderWriter.write(emitted, into: root.appendingPathComponent("linked-plan", isDirectory: true))
        let staged = file.deletingLastPathComponent().appendingPathComponent("inputs/R1.fastq")
        let type = try FileManager.default.attributesOfItem(atPath: staged.path)[.type] as? FileAttributeType
        XCTAssertEqual(type, .typeRegular)
        XCTAssertEqual(try Data(contentsOf: staged), try Data(contentsOf: pair[0]))
        let resolver = try PlanResourceResolver(planFile: file)
        for entry in emitted.plan.entries {
            XCTAssertNoThrow(try resolver.verify(entry), entry.relativePath)
        }
    }

    /// QA fix 9 (a) and SWIFT fix 4 of the K4 part A review: a Mac file changed after the plan was made refuses the write
    /// with the node's words for its entry, and the folder the writer made is gone.
    func testPlanFolderWriterRemovesItsFolderWhenASourceChanges() throws {
        let pair = try ExecutorPlanTestSupport.writePair(root: root, "S")
        let emitted = try emission(pair)
        var bytes = try Data(contentsOf: pair[1])
        bytes[1] = UInt8(ascii: "X")
        try bytes.write(to: pair[1])
        let folder = root.appendingPathComponent("changed-plan", isDirectory: true)
        XCTAssertThrowsError(try ExecutorPlanFolderWriter.write(emitted, into: folder)) { error in
            let refusal = error as? ExecutorPlanError
            XCTAssertEqual(refusal?.field, "entries[2]")
            XCTAssertTrue(refusal?.reason.hasPrefix("The plan's file inputs/R2.fastq has SHA-256 ") ?? false, "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    /// QA fix 9 (b) and SWIFT fix 4 of the K4 part A review: a folder that exists is refused and keeps its contents.
    func testPlanFolderWriterRefusesAnExistingFolder() throws {
        let pair = try ExecutorPlanTestSupport.writePair(root: root, "S")
        let emitted = try emission(pair)
        let folder = root.appendingPathComponent("existing-plan", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("marker".utf8).write(to: folder.appendingPathComponent("marker.txt"))
        XCTAssertThrowsError(try ExecutorPlanFolderWriter.write(emitted, into: folder)) { error in
            XCTAssertEqual((error as? ExecutorPlanError)?.field, "folder")
        }
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("marker.txt"), encoding: .utf8), "marker")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["marker.txt"])
    }

    /// QA fix 9 (c) of the K4 part A review: a recipe step with no plan form refuses the plan by the `steps` field.
    /// RiboDetector has none (a lone trim has one since C5 lane BF, D18).
    func testPlanEmitterRefusesAStepWithNoPlanForm() throws {
        let pair = try ExecutorPlanTestSupport.writePair(root: root, "S")
        let lone = Recipe(formatVersion: 1, id: "lone-ribodetector", name: "Lone RiboDetector", platforms: [.illumina],
                          requiredInput: .paired, steps: [RecipeStep(type: "ribodetector-filter")])
        XCTAssertThrowsError(try ExecutorPlanEmitter.emission(
            ExecutorPlanTestSupport.request(root: root, "S", inputs: pair, clumping: .bbtools, recipe: lone),
            host: ExecutorPlanTestSupport.mac24
        )) { error in
            let refusal = error as? ExecutorPlanError
            XCTAssertEqual(refusal?.field, "steps")
            XCTAssertTrue(refusal?.reason.hasSuffix("has no plan form yet, so this recipe cannot run from a plan.") ?? false, "\(error)")
        }
    }

    /// QA fix 9 (d) of the K4 part A review (tally-r2 K4-13, writer half): the Mac refuses pigz beside BBTools with the
    /// decoder's own sentence.
    func testPlanEmitterRefusesPigzForBBTools() throws {
        let pair = try ExecutorPlanTestSupport.writePair(root: root, "S")
        XCTAssertThrowsError(try ExecutorPlanEmitter.emit(
            ExecutorPlanTestSupport.request(root: root, "S", inputs: pair, clumping: .bbtools, compressor: .pigz),
            host: ExecutorPlanTestSupport.mac24
        )) { error in
            let refusal = error as? PlanDecodeError
            XCTAssertEqual(refusal?.field, "storage.compressor")
            XCTAssertEqual(refusal?.reason, "This plan names pigz as the compressor for step storage, which runs clumpify.sh. BBTools compresses its output with bgzip, so the plan must name bgzip.")
        }
    }
}
