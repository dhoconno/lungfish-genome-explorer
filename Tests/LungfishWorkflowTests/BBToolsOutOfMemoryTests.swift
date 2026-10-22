// BBToolsOutOfMemoryTests.swift - The import paths start BBTools with -eoom and say what ran out (CHTC lane C2-EOOM)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishIO
@testable import LungfishWorkflow

/// A storage `clumpify.sh` run that outgrows its heap must stop at once. Without `-eoom` BBTools 40.02 hung idle in 7
/// of 27 measured runs. Each test reads the argv a launch gets or the sentence a failure shows, never the source.
final class BBToolsOutOfMemoryTests: XCTestCase {

    private let reads = URL(fileURLWithPath: "/work/reads.fastq")
    private let mate = URL(fileURLWithPath: "/work/reads_2.fastq")
    private let out = URL(fileURLWithPath: "/work/out.fastq.gz")

    /// Every shape of storage clumpify launch: single, interleaved, two files, binned and not.
    private func launches(heapGB: Int) -> [[String]] {
        var all: [[String]] = []
        for binning in [QualityBinningScheme.none, .illumina4, .eightLevel] {
            all.append(FASTQIngestionPipeline.clumpifyArguments(
                input: reads, output: out, interleaved: false, heapGB: heapGB, threads: 4, qualityBinning: binning))
            all.append(FASTQIngestionPipeline.clumpifyArguments(
                input: reads, output: out, interleaved: true, heapGB: heapGB, threads: 4, qualityBinning: binning))
            all.append(FASTQIngestionPipeline.clumpifyArguments(
                input: reads, input2: mate, output: out, interleaved: true, heapGB: heapGB, threads: 1,
                qualityBinning: binning))
        }
        return all
    }

    func testEveryStorageClumpifyLaunchCarriesEoomOnceBesideTheHeap() throws {
        for args in launches(heapGB: 6) {
            XCTAssertEqual(args.filter { $0 == "-eoom" }.count, 1, "\(args)")
            let heap = try XCTUnwrap(args.firstIndex(of: "-Xmx6g"), "\(args)")
            XCTAssertEqual(args[heap + 1], "-eoom", "the JVM flags stay together: \(args)")
        }
    }

    func testTheLaunchKeepsEveryOtherArgumentItHadBeforeTheFlag() {
        let args = FASTQIngestionPipeline.clumpifyArguments(
            input: reads, input2: mate, output: out, interleaved: true, heapGB: 6, threads: 4, qualityBinning: .none)
        XCTAssertEqual(args, [
            "in=/work/reads.fastq", "out=/work/out.fastq.gz", "-Xmx6g", "-eoom", "ow=t", "reorder", "groups=auto",
            "pigz=t", "zl=4", "threads=4", "in2=/work/reads_2.fastq", "interleaved=t",
        ])
    }

    func testStatusThreeIsTheOnlyOutOfMemoryEnd() {
        XCTAssertTrue(BBToolsOutOfMemory.isOutOfMemory(exitCode: 3))
        for status: Int32 in [0, 1, 2, 137] {
            XCTAssertFalse(BBToolsOutOfMemory.isOutOfMemory(exitCode: status), "status \(status)")
        }
    }

    func testTheSentenceNamesTheOutOfMemoryTheHeapThatRanAndTheOptionThatRaisesIt() {
        let args = FASTQIngestionPipeline.clumpifyArguments(
            input: reads, output: out, interleaved: false, heapGB: 4, threads: 4, qualityBinning: .none)
        let sentence = BBToolsOutOfMemory.message(tool: "clumpify.sh", arguments: args, optionPinsHeap: true)
        XCTAssertTrue(sentence.contains("ran out of memory"), sentence)
        XCTAssertTrue(sentence.contains("4 GB heap"), sentence)
        XCTAssertTrue(sentence.contains("--clumpify-heap-gb 8"), sentence)
        XCTAssertTrue(sentence.contains("original files were kept"), sentence)
    }

    func testARecipeStepThatSizesItsOwnHeapDoesNotSendTheUserToAnOptionThatDoesNotReachIt() {
        let pinned = BBToolsOutOfMemory.message(
            tool: "clumpify.sh", arguments: ["-Xmx4g", "-eoom"], optionPinsHeap: false)
        XCTAssertTrue(pinned.contains("4 GB heap"), pinned)
        XCTAssertFalse(pinned.contains("--clumpify-heap-gb"), pinned)
        let unpinned = BBToolsOutOfMemory.message(tool: "clumpify.sh", arguments: ["-eoom"], optionPinsHeap: false)
        XCTAssertTrue(unpinned.contains("ran out of memory"), unpinned)
        XCTAssertFalse(unpinned.contains("--clumpify-heap-gb"), unpinned)
    }
}
