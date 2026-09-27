// FastpTrimOptionsTests.swift - One fastp argv and one length-filter plan for the CLI and the window
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class FastpTrimOptionsTests: XCTestCase {
    func testCombinedTrimRendersWindowAndAdapterFlagsInOrder() {
        let options = FastpTrimOptions.options(
            for: .combined(threshold: 20, window: 4, mode: .cutRight, adapterTrimming: true, adapterSequence: nil),
            threads: 8
        )
        XCTAssertEqual(options, [
            "-w", "8", "-W", "4", "-M", "20",
            "--disable_quality_filtering", "--disable_length_filtering",
            "--json", "/dev/null", "--html", "/dev/null",
            "--cut_right",
        ])
        XCTAssertTrue(FastpTrimOperation.combined(threshold: 20, window: 4, mode: .cutRight, adapterTrimming: true, adapterSequence: nil).detectsPairedAdapters)
    }

    func testCombinedTrimWithLiteralAdapterOrNoAdapterTrimming() {
        let literal = FastpTrimOptions.options(
            for: .combined(threshold: 30, window: 5, mode: .cutBoth, adapterTrimming: true, adapterSequence: "AGATCGGAAGAG"),
            threads: 2
        )
        XCTAssertTrue(literal.containsSequence(["--adapter_sequence", "AGATCGGAAGAG"]))
        XCTAssertTrue(literal.suffix(2).elementsEqual(["--cut_front", "--cut_right"]))
        XCTAssertFalse(literal.contains("--disable_adapter_trimming"))
        XCTAssertFalse(FastpTrimOperation.combined(threshold: 30, window: 5, mode: .cutBoth, adapterTrimming: true, adapterSequence: "AGATCGGAAGAG").detectsPairedAdapters)

        let none = FastpTrimOptions.options(
            for: .combined(threshold: 20, window: 4, mode: .cutTail, adapterTrimming: false, adapterSequence: nil),
            threads: 2
        )
        XCTAssertTrue(none.contains("--disable_adapter_trimming"))
        XCTAssertFalse(none.contains("--adapter_sequence"))
        XCTAssertTrue(none.suffix(1).elementsEqual(["--cut_tail"]))
    }

    func testQualityTrimDisablesAdaptersAndAppendsExtraArguments() {
        let options = FastpTrimOptions.options(
            for: .quality(threshold: 25, window: 6, mode: .cutFront),
            threads: 3,
            extraArguments: ["--cut_mean_quality", "25"]
        )
        XCTAssertEqual(options, [
            "-w", "3", "-W", "6", "-M", "25", "--disable_adapter_trimming",
            "--disable_quality_filtering", "--disable_length_filtering",
            "--json", "/dev/null", "--html", "/dev/null",
            "--cut_front", "--cut_mean_quality", "25",
        ])
        XCTAssertFalse(FastpTrimOperation.quality(threshold: 25, window: 6, mode: .cutFront).detectsPairedAdapters)
    }

    func testAdapterTrimRendersEveryAdapterSource() {
        let auto = FastpTrimOptions.options(for: .adapter(sequence: nil, sequenceR2: nil, adapterFastaPath: nil), threads: 1)
        XCTAssertEqual(auto, [
            "-w", "1", "--disable_quality_filtering", "--disable_length_filtering",
            "--json", "/dev/null", "--html", "/dev/null",
        ])
        XCTAssertTrue(FastpTrimOperation.adapter(sequence: nil, sequenceR2: nil, adapterFastaPath: nil).detectsPairedAdapters)

        let literal = FastpTrimOptions.options(for: .adapter(sequence: "ACGT", sequenceR2: "TTGG", adapterFastaPath: nil), threads: 1)
        XCTAssertTrue(literal.suffix(4).elementsEqual(["--adapter_sequence", "ACGT", "--adapter_sequence_r2", "TTGG"]))
        XCTAssertFalse(FastpTrimOperation.adapter(sequence: "ACGT", sequenceR2: nil, adapterFastaPath: nil).detectsPairedAdapters)

        let fasta = FastpTrimOptions.options(for: .adapter(sequence: nil, sequenceR2: nil, adapterFastaPath: "/b/adapters.fa"), threads: 1)
        XCTAssertTrue(fasta.suffix(2).elementsEqual(["--adapter_fasta", "/b/adapters.fa"]))
        XCTAssertFalse(FastpTrimOperation.adapter(sequence: nil, sequenceR2: nil, adapterFastaPath: "/b/adapters.fa").detectsPairedAdapters)
    }

    func testFixedTrimOmitsZeroEnds() {
        XCTAssertEqual(FastpTrimOptions.options(for: .fixed(front: 3, tail: 0), threads: 4).suffix(2), ["--trim_front1", "3"])
        XCTAssertEqual(FastpTrimOptions.options(for: .fixed(front: 0, tail: 7), threads: 4).suffix(2), ["--trim_tail1", "7"])
        let both = FastpTrimOptions.options(for: .fixed(front: 3, tail: 7), threads: 4)
        XCTAssertTrue(both.contains("--disable_adapter_trimming"))
        XCTAssertTrue(both.suffix(4).elementsEqual(["--trim_front1", "3", "--trim_tail1", "7"]))
    }

    func testDefaultThreadCountStaysWithinFastpMaximum() {
        XCTAssertGreaterThanOrEqual(FastpTrimOptions.defaultThreadCount, 1)
        XCTAssertLessThanOrEqual(FastpTrimOptions.defaultThreadCount, 16)
        let options = FastpTrimOptions.options(for: .fixed(front: 1, tail: 0))
        XCTAssertEqual(options.prefix(2), ["-w", String(FastpTrimOptions.defaultThreadCount)])
    }

    func testQualityTrimModeCLITokensRoundTrip() {
        XCTAssertEqual(FASTQQualityTrimMode.cliTokens, ["cut-right", "cut-front", "cut-tail", "cut-both"])
        for mode in FASTQQualityTrimMode.allCases {
            XCTAssertEqual(FASTQQualityTrimMode(cliToken: mode.cliToken), mode)
        }
        XCTAssertNil(FASTQQualityTrimMode(cliToken: "cutRight"))
    }

    func testFastpTrimOperationNamesItsSubcommand() {
        XCTAssertEqual(FastpTrimOperation.combined(threshold: 20, window: 4, mode: .cutRight, adapterTrimming: true, adapterSequence: nil).subcommandName, "trim")
        XCTAssertEqual(FastpTrimOperation.quality(threshold: 20, window: 4, mode: .cutRight).subcommandName, "quality-trim")
        XCTAssertEqual(FastpTrimOperation.adapter(sequence: nil, sequenceR2: nil, adapterFastaPath: nil).subcommandName, "adapter-trim")
        XCTAssertEqual(FastpTrimOperation.fixed(front: 1, tail: 1).subcommandName, "fixed-trim")
    }
}

private extension Array where Element == String {
    func containsSequence(_ sequence: [String]) -> Bool {
        guard !sequence.isEmpty, count >= sequence.count else { return false }
        return indices.contains { start in
            start + sequence.count <= count && Array(self[start..<start + sequence.count]) == sequence
        }
    }
}

final class FASTQLengthFilterPlanTests: XCTestCase {
    func testPairAwarePlanRunsBBDukInterleaved() {
        let plan = FASTQLengthFilterPlan.make(
            inputPath: "/in/reads.fastq", outputPath: "/out/kept.fastq",
            minLength: 50, maxLength: nil, pairAware: true, threads: 4
        )
        XCTAssertEqual(plan.tool, .bbduk)
        XCTAssertEqual(plan.arguments, ["in=/in/reads.fastq", "out=/out/kept.fastq", "interleaved=t", "minlen=50"])
        XCTAssertTrue(plan.isPairAware)
        XCTAssertEqual(plan.timeout, 1800)
        XCTAssertEqual(plan.toolCommand, "bbduk.sh in=/in/reads.fastq out=/out/kept.fastq interleaved=t minlen=50")
    }

    func testSingleReadPlanRunsSeqkitSeq() {
        let plan = FASTQLengthFilterPlan.make(
            inputPath: "/in/reads.fastq", outputPath: "/out/kept.fastq",
            minLength: 50, maxLength: 300, pairAware: false, threads: 4
        )
        XCTAssertEqual(plan.tool, .seqkit)
        XCTAssertEqual(plan.arguments, ["seq", "-j", "4", "-m", "50", "-M", "300", "/in/reads.fastq", "-o", "/out/kept.fastq"])
        XCTAssertFalse(plan.isPairAware)
    }

    func testMaximumOnlyPlansOnBothTools() {
        let paired = FASTQLengthFilterPlan.make(inputPath: "a", outputPath: "b", minLength: nil, maxLength: 120, pairAware: true)
        XCTAssertEqual(paired.arguments, ["in=a", "out=b", "interleaved=t", "maxlen=120"])
        let single = FASTQLengthFilterPlan.make(inputPath: "a", outputPath: "b", minLength: nil, maxLength: 120, pairAware: false, threads: 2)
        XCTAssertEqual(single.arguments, ["seq", "-j", "2", "-M", "120", "a", "-o", "b"])
    }
}
