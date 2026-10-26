// ExecutorPlanStagedReadTests.swift - The batch writer's own check of reads already in the staging folder (CHTC C6 lane STAGED)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import LungfishPortable
import LungfishTestSupport
@testable import LungfishWorkflow

/// The writer owns the layout check of a staged read (ruling STAGED point 3): a caller that never checked a row's
/// `stagedPaths` cannot make a job read a path outside the staging folder or inside the batch's own folder, where the
/// jobs write, and the writer refuses such a row before it writes anything.
final class ExecutorPlanStagedReadTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "ExecutorPlanStagedRead")
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private static let staging = "/staging/groups/g/1/lge-chtc-test"
    private let image = ExecutorPlanImageRecord(
        sif: ExecutorPlanImageFile(fileName: "lge-tools-test.sif", sha256: String(repeating: "e", count: 64), size: 396_402_688),
        imageManifest: PlanImageManifestPin(sha256: ExecutorPlanTestSupport.digest, size: 4096)
    )
    private let layout = ExecutorPlanStagingLayout(folder: staging, batch: "batch")

    /// Writes a batch of one row, S1, whose reads are named only by `paths`, with the bbtools template of a pair of the
    /// same file endings on this Mac.
    private func write(stagedPaths paths: [String], into folder: URL) throws {
        let request = try ExecutorPlanTestSupport.request(
            root: root, "S1", inputs: ExecutorPlanTestSupport.writePair(root: root, "S1"), clumping: .bbtools
        ).templateRequest
        let template = try ExecutorPlanEmitter.template(request, host: ExecutorPlanTestSupport.mac24)
        let row = ExecutorPlanSampleRow(
            sampleName: "S1",
            inputs: paths.map { ExecutorPlanSourceFile(url: URL(fileURLWithPath: $0), sha256: ExecutorPlanTestSupport.digest, size: 1_000) },
            stagedPaths: paths
        )
        try ExecutorPlanBatchWriter.write(template, request: request, rows: [row], image: image, layout: layout, into: folder)
    }

    /// A path beside the staging folder that shares its name's start, a `..` or an empty name, and a relative path are
    /// each outside the staging folder.
    func testBatchWriterRefusesStagedPathOutsideFolder() throws {
        let r2 = "\(Self.staging)/input-casper/S1_R2.fastq"
        let outside = [
            "/staging/groups/g/1/lge-chtc-test-other/S1_R1.fastq",
            "\(Self.staging)/input/../../other/S1_R1.fastq",
            "\(Self.staging)//S1_R1.fastq",
            "input-casper/S1_R1.fastq",
        ]
        for (index, path) in outside.enumerated() {
            let folder = root.appendingPathComponent("refused-\(index)", isDirectory: true)
            XCTAssertThrowsError(try write(stagedPaths: [path, r2], into: folder), path) { error in
                XCTAssertEqual(error as? ExecutorPlanError, ExecutorPlanError(
                    field: "stagedPaths",
                    reason: "The read \(path) of sample S1 is not inside the staging folder \(Self.staging). With --staged-reads every read is a file in the staging folder, named by its absolute path, so plan reads on this Mac in a batch of their own."
                ))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "\(path): a refused batch writes no folder")
        }
    }

    func testBatchWriterRefusesStagedPathInBatchFolder() throws {
        let path = "\(Self.staging)/batches/batch/S1/S1_R1.fastq"
        let folder = root.appendingPathComponent("batch", isDirectory: true)
        XCTAssertThrowsError(try write(stagedPaths: [path, "\(Self.staging)/input-casper/S1_R2.fastq"], into: folder)) { error in
            XCTAssertEqual(error as? ExecutorPlanError, ExecutorPlanError(
                field: "stagedPaths",
                reason: "The read \(path) of sample S1 is inside the folder \(Self.staging)/batches/batch, where this batch's jobs write, so keep the reads outside it."
            ))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "a refused batch writes no folder")
    }
}
