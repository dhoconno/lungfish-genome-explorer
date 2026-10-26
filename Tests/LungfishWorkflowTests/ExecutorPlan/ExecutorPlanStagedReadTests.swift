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
    /// same file endings on this Mac. The row has one input file a path, or one for each of `inputPaths` when a test
    /// gives them, so that a count of staged paths other than the count of input files can be written.
    private func write(stagedPaths paths: [String], inputPaths: [String]? = nil, into folder: URL) throws {
        let request = try ExecutorPlanTestSupport.request(
            root: root, "S1", inputs: ExecutorPlanTestSupport.writePair(root: root, "S1"), clumping: .bbtools
        ).templateRequest
        let template = try ExecutorPlanEmitter.template(request, host: ExecutorPlanTestSupport.mac24)
        let row = ExecutorPlanSampleRow(
            sampleName: "S1",
            inputs: (inputPaths ?? paths).map {
                ExecutorPlanSourceFile(url: URL(fileURLWithPath: $0), sha256: ExecutorPlanTestSupport.digest, size: 1_000)
            },
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

    /// The writer takes one staged path for each input file. A row that names another count, fewer or more, is refused in
    /// the sample's own words, and no folder is written. No caller but the CLI reaches this, and the CLI builds both lists
    /// from the same files.
    func testBatchWriterRefusesStagedPathsOfAnotherCountThanInputs() throws {
        let r1 = "\(Self.staging)/input-casper/S1_R1.fastq"
        let r2 = "\(Self.staging)/input-casper/S1_R2.fastq"
        let r3 = "\(Self.staging)/input-casper/S1_R3.fastq"
        let cases: [(staged: [String], inputs: [String], words: String)] = [
            ([r1], [r1, r2], "The sample S1 names 1 reads in the staging folder for its 2 input files."),
            ([r1, r2, r3], [r1, r2], "The sample S1 names 3 reads in the staging folder for its 2 input files."),
        ]
        for (index, row) in cases.enumerated() {
            let folder = root.appendingPathComponent("count-\(index)", isDirectory: true)
            XCTAssertThrowsError(try write(stagedPaths: row.staged, inputPaths: row.inputs, into: folder), row.words) { error in
                XCTAssertEqual(error as? ExecutorPlanError, ExecutorPlanError(field: "stagedPaths", reason: row.words))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "\(row.words): a refused batch writes no folder")
        }
    }

    /// A job takes each file it reads by its name, so two staged reads of one name are refused whatever their folders,
    /// and no folder is written.
    func testBatchWriterRefusesStagedReadsOfOneFileName() throws {
        let paths = ["\(Self.staging)/run-a/S1.fastq", "\(Self.staging)/run-b/S1.fastq"]
        let folder = root.appendingPathComponent("batch", isDirectory: true)
        XCTAssertThrowsError(try write(stagedPaths: paths, into: folder)) { error in
            XCTAssertEqual(error as? ExecutorPlanError, ExecutorPlanError(
                field: "stagedPaths",
                reason: "The R1 and R2 of sample S1 are both named S1.fastq, and a job takes each file by its name, so rename one."
            ))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "a refused batch writes no folder")
    }

    /// A folder or file name below the staging folder with a character other than letters, digits, _, . and - is refused,
    /// since a job's file transfer cannot hold it, and no folder is written.
    func testBatchWriterRefusesStagedPathWithAnotherCharacter() throws {
        let path = "\(Self.staging)/input casper/S1_R1.fastq"
        let folder = root.appendingPathComponent("batch", isDirectory: true)
        XCTAssertThrowsError(try write(stagedPaths: [path, "\(Self.staging)/input-casper/S1_R2.fastq"], into: folder)) { error in
            XCTAssertEqual(error as? ExecutorPlanError, ExecutorPlanError(
                field: "stagedPaths",
                reason: "The read \(path) of sample S1 has a name with a character other than letters, digits, _, . and -, which a job's file transfer cannot hold, so rename it."
            ))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "a refused batch writes no folder")
    }
}
