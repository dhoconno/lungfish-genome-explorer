// PortableStoragePlanTests.swift - Every storage argv states the quality encoding and the cap, with no tool
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishPortable
@testable import LungfishExecutor

/// Phase 3.0 lane BIN, fix round 2 (BIO-BIN-QIN, S1). BBTools guesses the quality offset from the reads when `qin` is
/// absent, and stores wrong scores, stops or hangs on reads that reach about Q55 (see
/// `StorageQualityEncodingConformanceTests`, which runs the argv through the real tools). This test pins the argv with no
/// tool. It sits in the executor's test target because it names both builders, `PortableStoragePlan.clumpifyArguments`,
/// which the Mac and the executor share, and `PlanRunner.reformatQuantizeArguments`, which only this target sees. The
/// Mac's own reformat argv is built inside `FASTQIngestionPipeline`, so only the conformance test reaches it.
final class PortableStoragePlanTests: XCTestCase {
    func testEveryStorageArgvStatesPhred33AndTheCap() throws {
        XCTAssertEqual(PortableStoragePlan.qualityEncodingArguments, ["qin=33", "qout=33", "maxcalledquality=93"])

        let input = URL(fileURLWithPath: "/work/in_R1.fastq")
        let input2 = URL(fileURLWithPath: "/work/in_R2.fastq")
        let output = URL(fileURLWithPath: "/work/out.fastq.gz")
        for scheme in [QualityBinningScheme.fiveStep, .illumina4, .eightLevel, .none] {
            let quantize = PortableStoragePlan.quantizeArgument(for: scheme)
            var argvs: [(name: String, argv: [String])] = [
                ("clumpify, one file", PortableStoragePlan.clumpifyArguments(
                    input: input, output: output, interleaved: false, heapGB: 2, threads: 2, qualityBinning: scheme
                )),
                ("clumpify, a pair", PortableStoragePlan.clumpifyArguments(
                    input: input, input2: input2, output: output, interleaved: true, heapGB: 2, threads: 2, qualityBinning: scheme
                )),
            ]
            if let quantize {
                argvs.append(("executor reformat, one file", PlanRunner.reformatQuantizeArguments(
                    inputs: [input], output: output, compressionLevel: 4, threads: 2, quantize: quantize
                )))
                argvs.append(("executor reformat, a pair", PlanRunner.reformatQuantizeArguments(
                    inputs: [input, input2], output: output, compressionLevel: 4, threads: 2, quantize: quantize
                )))
            }
            for (name, argv) in argvs {
                for flag in PortableStoragePlan.qualityEncodingArguments {
                    XCTAssertTrue(argv.contains(flag), "\(name) under \(scheme.rawValue) lacks \(flag): \(argv)")
                }
                if let quantize {
                    XCTAssertEqual(argv.last, quantize, "\(name) under \(scheme.rawValue): quantize= stays the last token")
                } else {
                    XCTAssertFalse(argv.contains { $0.hasPrefix("quantize=") }, "\(name) under none names a quantize=")
                }
            }
        }
    }
}
