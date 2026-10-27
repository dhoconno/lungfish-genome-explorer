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
            "qin=33", "qout=33", "maxcalledquality=93",
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

    // MARK: - The recipe dedupe launches, and the one place status 3 becomes the sentence

    private let mateOne = URL(fileURLWithPath: "/work/in_R1.fastq")
    private let mateTwo = URL(fileURLWithPath: "/work/in_R2.fastq")
    private let outOne = URL(fileURLWithPath: "/work/out_R1.fastq")
    private let outTwo = URL(fileURLWithPath: "/work/out_R2.fastq")

    /// Both recipe dedupe builders: separate mates, then one file interleaved and one file not.
    private func recipeDedupeLaunches(optical: Bool) -> [[String]] {
        [
            FASTQBatchImporter.pairedDedupeArguments(
                r1: mateOne, r2: mateTwo, outR1: outOne, outR2: outTwo, heapGB: 4, substitutions: 0,
                optical: optical, opticalDistance: 2500, threads: 4),
            FASTQBatchImporter.interleavedDedupeArguments(
                input: reads, output: out, optical: optical, threads: 4, interleaved: true),
            FASTQBatchImporter.interleavedDedupeArguments(
                input: reads, output: out, optical: optical, threads: 4, interleaved: false),
        ]
    }

    func testEveryRecipeDedupeLaunchCarriesEoomOnce() throws {
        for optical in [true, false] {
            let launches = recipeDedupeLaunches(optical: optical)
            for args in launches {
                XCTAssertEqual(args.filter { $0 == "-eoom" }.count, 1, "optical \(optical): \(args)")
            }
            let paired = launches[0]
            let heap = try XCTUnwrap(paired.firstIndex(of: "-Xmx4g"), "\(paired)")
            XCTAssertEqual(paired[heap + 1], "-eoom", "the JVM flags stay together: \(paired)")
        }
    }

    func testTheRecipeDedupeLaunchesKeepEveryOtherArgumentTheyHadBeforeTheFlag() {
        let optical = FASTQBatchImporter.pairedDedupeArguments(
            r1: mateOne, r2: mateTwo, outR1: outOne, outR2: outTwo, heapGB: 4, substitutions: 2,
            optical: true, opticalDistance: 100, threads: 4)
        XCTAssertEqual(optical, [
            "in1=/work/in_R1.fastq", "in2=/work/in_R2.fastq", "out1=/work/out_R1.fastq", "out2=/work/out_R2.fastq",
            "-Xmx4g", "-eoom", "dedupe=t", "subs=2", "ow=t", "threads=4", "optical=t", "dupedist=100",
        ] + ["qin=33", "qout=33", "maxcalledquality=93"])
        let plain = FASTQBatchImporter.pairedDedupeArguments(
            r1: mateOne, r2: mateTwo, outR1: outOne, outR2: outTwo, heapGB: 4, substitutions: 0,
            optical: false, opticalDistance: 2500, threads: 4)
        XCTAssertEqual(plain, [
            "in1=/work/in_R1.fastq", "in2=/work/in_R2.fastq", "out1=/work/out_R1.fastq", "out2=/work/out_R2.fastq",
            "-Xmx4g", "-eoom", "dedupe=t", "subs=0", "ow=t", "threads=4",
        ] + ["qin=33", "qout=33", "maxcalledquality=93"])
        XCTAssertEqual(
            FASTQBatchImporter.interleavedDedupeArguments(
                input: reads, output: out, optical: false, threads: 4, interleaved: true),
            ["in=/work/reads.fastq", "out=/work/out.fastq.gz", "-eoom", "dedupe=t", "optical=f", "threads=4",
             "interleaved=t", "qin=33", "qout=33", "maxcalledquality=93"])
        XCTAssertEqual(
            FASTQBatchImporter.interleavedDedupeArguments(
                input: reads, output: out, optical: true, threads: 2, interleaved: false),
            ["in=/work/reads.fastq", "out=/work/out.fastq.gz", "-eoom", "dedupe=t", "optical=t", "threads=2",
             "interleaved=f", "qin=33", "qout=33", "maxcalledquality=93"])
    }

    func testOnlyStatusThreeBecomesTheSentence() {
        let args = ["in=/work/reads.fastq", "-Xmx4g", "-eoom"]
        guard case .outOfMemory(let sentence)? = BBToolsOutOfMemory.error(
            exitCode: 3, tool: "clumpify.sh", arguments: args, optionPinsHeap: true)
        else { return XCTFail("status 3 must end as the out-of-memory error") }
        XCTAssertEqual(
            sentence, BBToolsOutOfMemory.message(tool: "clumpify.sh", arguments: args, optionPinsHeap: true))
        for status: Int32 in [0, 1, 2, 137] {
            XCTAssertNil(
                BBToolsOutOfMemory.error(exitCode: status, tool: "clumpify.sh", arguments: args, optionPinsHeap: true),
                "status \(status)")
        }
    }
}
