// FASTQTrimParityTests.swift - The window and the CLI render the same fastp argv and length-filter plan
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// GUI/CLI parity is a binding rule: the same operation must give the same
// result in the window and on the command line. The Reads menu launches
// `lungfish-cli fastq <subcommand>` through FASTQOperationCLIInvocationBuilder,
// while import recipes and batch derivatives run the same operations
// in-process through FASTQDerivativeService. Both now render their fastp
// arguments through FastpTrimOptions and their length filter through
// FASTQLengthFilterPlan, and these tests hold the two sides to the byte.

import ArgumentParser
import Foundation
import LungfishIO
import LungfishTestSupport
@testable import LungfishApp
@testable import LungfishCLI
@testable import LungfishWorkflow
import XCTest

final class FASTQTrimParityTests: XCTestCase {
    private var root: URL!
    private var bundleURL: URL!
    private var fastqURL: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("trim-parity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bundle = try InterleavedFASTQFixture.writeBundle(
            named: "hg002", in: root, pairCount: 3, naming: .identical, pairingMode: .interleaved
        )
        bundleURL = bundle.bundleURL
        fastqURL = bundle.fastqURL
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func cliArguments(for request: FASTQDerivativeRequest) throws -> [String] {
        let launch = FASTQOperationLaunchRequest.derivative(
            request: request,
            inputURLs: [fastqURL],
            outputMode: .perInput
        )
        let invocation = try FASTQOperationCLIInvocationBuilder()
            .buildInvocation(for: launch, outputTargetPath: root.appendingPathComponent("out.fastq").path)
        XCTAssertEqual(invocation.subcommand, "fastq")
        return invocation.arguments
    }

    private func windowOptions(for request: FASTQDerivativeRequest) throws -> [String] {
        let operation = try XCTUnwrap(FASTQDerivativeService.fastpTrimOperation(for: request, sourceBundleURL: bundleURL))
        var extraArguments: [String] = []
        if case .qualityTrim(_, _, _, let extra) = request {
            extraArguments = extra
        }
        return FastpTrimOptions.options(for: operation, extraArguments: extraArguments)
    }

    func testCombinedTrimArgvMatchesBetweenWindowAndCLI() throws {
        let requests: [FASTQDerivativeRequest] = [
            .fastpTrim(threshold: 20, windowSize: 4, mode: .cutRight, adapterMode: .autoDetect, adapterSequence: nil),
            .fastpTrim(threshold: 30, windowSize: 5, mode: .cutBoth, adapterMode: .specified, adapterSequence: "AGATCGGAAGAG"),
        ]
        for request in requests {
            let arguments = try cliArguments(for: request)
            XCTAssertEqual(arguments.first, "trim")
            let command = try FastqTrimSubcommand.parse(Array(arguments.dropFirst()))
            XCTAssertEqual(try command.fastpOptions(), try windowOptions(for: request), "\(request)")
            XCTAssertEqual(
                try command.trimOperation(),
                try XCTUnwrap(FASTQDerivativeService.fastpTrimOperation(for: request, sourceBundleURL: bundleURL))
            )
            XCTAssertEqual(command.pairing.pairing, .interleaved, "the window passes the bundle's pairing")
        }
    }

    func testQualityTrimArgvMatchesIncludingExtraArguments() throws {
        let request = FASTQDerivativeRequest.qualityTrim(
            threshold: 25, windowSize: 6, mode: .cutFront, extraArguments: ["--cut_mean_quality", "25"]
        )
        let arguments = try cliArguments(for: request)
        XCTAssertEqual(arguments.first, "quality-trim")
        let command = try FastqQualityTrimSubcommand.parse(Array(arguments.dropFirst()))
        XCTAssertEqual(try command.fastpOptions(), try windowOptions(for: request))
        XCTAssertTrue(try command.fastpOptions().suffix(2).elementsEqual(["--cut_mean_quality", "25"]))
    }

    func testAdapterAndFixedTrimArgvMatch() throws {
        let adapterRequests: [FASTQDerivativeRequest] = [
            .adapterTrim(mode: .autoDetect, sequence: nil, sequenceR2: nil, fastaFilename: nil),
            .adapterTrim(mode: .specified, sequence: "ACGTACGT", sequenceR2: nil, fastaFilename: nil),
        ]
        for request in adapterRequests {
            let arguments = try cliArguments(for: request)
            XCTAssertEqual(arguments.first, "adapter-trim")
            let command = try FastqAdapterTrimSubcommand.parse(Array(arguments.dropFirst()))
            XCTAssertEqual(command.fastpOptions, try windowOptions(for: request), "\(request)")
            XCTAssertEqual(
                command.trimOperation.detectsPairedAdapters,
                try XCTUnwrap(FASTQDerivativeService.fastpTrimOperation(for: request, sourceBundleURL: bundleURL)).detectsPairedAdapters
            )
        }

        let fixed = FASTQDerivativeRequest.fixedTrim(from5Prime: 3, from3Prime: 7)
        let arguments = try cliArguments(for: fixed)
        XCTAssertEqual(arguments.first, "fixed-trim")
        let command = try FastqFixedTrimSubcommand.parse(Array(arguments.dropFirst()))
        XCTAssertEqual(command.fastpOptions, try windowOptions(for: fixed))
    }

    func testLengthFilterPlanMatchesBetweenWindowAndCLI() throws {
        let request = FASTQDerivativeRequest.lengthFilter(min: 50, max: 300)
        let arguments = try cliArguments(for: request)
        XCTAssertEqual(arguments.first, "length-filter")
        XCTAssertTrue(arguments.contains("--pairing"), "the window passes the bundle's pairing: \(arguments)")
        let command = try FastqLengthFilterSubcommand.parse(Array(arguments.dropFirst()))
        let decision = command.pairing.resolvePairing(inputURL: fastqURL)
        XCTAssertTrue(decision.pairAware)
        let cliPlan = command.plan(inputURL: fastqURL, decision: decision)
        let windowPlan = FASTQLengthFilterPlan.make(
            inputPath: fastqURL.path,
            outputPath: command.output.output,
            minLength: 50,
            maxLength: 300,
            pairAware: true
        )
        XCTAssertEqual(cliPlan, windowPlan)
        XCTAssertEqual(cliPlan.tool, .bbduk)
        XCTAssertTrue(cliPlan.arguments.contains("interleaved=t"))

        let singlePlan = command.plan(
            inputURL: fastqURL,
            decision: FASTQPairingModeResolver.resolvePairing(inputURL: fastqURL, explicit: false)
        )
        XCTAssertEqual(singlePlan.tool, .seqkit)
        XCTAssertEqual(
            singlePlan,
            FASTQLengthFilterPlan.make(inputPath: fastqURL.path, outputPath: command.output.output, minLength: 50, maxLength: 300, pairAware: false)
        )
    }
}
