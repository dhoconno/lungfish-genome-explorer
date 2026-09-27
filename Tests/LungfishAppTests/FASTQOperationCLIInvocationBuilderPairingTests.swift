// FASTQOperationCLIInvocationBuilderPairingTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The Tools menu runs `lungfish-cli fastq <op>` on the bare FASTQ inside a
// .lungfishfastq bundle. The bundle's metadata knows the file is interleaved;
// the CLI, handed only a path, used to guess from read names and split
// identical-name mates. The builder must therefore pass the recorded pairing
// explicitly, so GUI and CLI agree and Copy CLI Command reproduces the run.

import Foundation
import LungfishIO
import LungfishTestSupport
@testable import LungfishApp
import XCTest

final class FASTQOperationCLIInvocationBuilderPairingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("builder-pairing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testPairingArgumentsMapRecordedModes() {
        XCTAssertEqual(FASTQOperationCLIInvocationBuilder.pairingArguments(for: .interleaved), ["--pairing", "interleaved"])
        XCTAssertEqual(FASTQOperationCLIInvocationBuilder.pairingArguments(for: .singleEnd), ["--pairing", "single"])
        XCTAssertEqual(FASTQOperationCLIInvocationBuilder.pairingArguments(for: .pairedEnd), [])
        XCTAssertEqual(FASTQOperationCLIInvocationBuilder.pairingArguments(for: nil), [])
    }

    func testEveryAffectedSubcommandCarriesInterleavedPairingFromBundleMetadata() throws {
        let bundle = try InterleavedFASTQFixture.writeBundle(
            named: "hg002", in: root, pairCount: 2, naming: .identical, pairingMode: .interleaved
        )
        let requests: [FASTQDerivativeRequest] = [
            .subsampleProportion(0.1),
            .subsampleCount(1000),
            .lengthFilter(min: 50, max: nil),
            .searchText(query: "frag1", field: .id, regex: false),
            .searchMotif(pattern: "GATTACA", regex: false),
            .deduplicate(preset: .exactPCR, substitutions: 0, optical: false, opticalDistance: 40),
            .contaminantFilter(mode: .phix, referenceFasta: nil, kmerSize: 31, hammingDistance: 1),
            .lowComplexityFilter(entropy: 0.6, window: 50, kmer: 5),
            .sequencePresenceFilter(
                sequence: "ACGT", fastaPath: nil, searchEnd: .fivePrime, minOverlap: 16,
                errorRate: 0.15, keepMatched: true, searchReverseComplement: false
            ),
            .humanReadScrub(databaseID: "deacon-panhuman", removeReads: true),
            .ribosomalRNAFilter(retention: .nonRRNA, ensure: .none),
        ]

        for request in requests {
            let launch = FASTQOperationLaunchRequest.derivative(
                request: request,
                inputURLs: [bundle.fastqURL],
                outputMode: .perInput
            )
            let invocation = try FASTQOperationCLIInvocationBuilder()
                .buildInvocation(for: launch, outputTargetPath: "<derived>")
            XCTAssertEqual(invocation.subcommand, "fastq")
            XCTAssertTrue(
                invocation.arguments.containsSequence(["--pairing", "interleaved"]),
                "\(invocation.arguments.first ?? "?") must pass the bundle's pairing: \(invocation.arguments)"
            )
        }
    }

    func testMixedBundleRecordedAsInterleavedPassesSinglePairing() throws {
        // A VSP2 bundle records pairingMode=interleaved while holding merged
        // reads. The recorded pairing is verified against the records, so the
        // CLI is told `single` and no positional pair tool ever sees the file.
        let bundle = try InterleavedFASTQFixture.writeMixedBundle(
            named: "vsp2", in: root, pairCount: 6, mergedCount: 3, naming: .identical, pairingMode: .interleaved
        )
        for inputURL in [bundle.fastqURL, bundle.bundleURL] {
            let launch = FASTQOperationLaunchRequest.derivative(
                request: .subsampleCount(10),
                inputURLs: [inputURL],
                outputMode: .perInput
            )
            let invocation = try FASTQOperationCLIInvocationBuilder().buildInvocation(for: launch)
            XCTAssertTrue(invocation.arguments.containsSequence(["--pairing", "single"]), "\(inputURL.lastPathComponent): \(invocation.arguments)")
        }

        // The execution service passes the ORIGINAL bundle's pairing for a
        // materialized scratch copy; the copy is verified with the bundle's
        // metadata as hints.
        let scratch = root.appendingPathComponent("materialized-mixed.fastq")
        try FileManager.default.copyItem(at: bundle.fastqURL, to: scratch)
        let launch = FASTQOperationLaunchRequest.derivative(
            request: .searchMotif(pattern: "ACGT", regex: false),
            inputURLs: [scratch],
            outputMode: .perInput
        )
        let invocation = try FASTQOperationCLIInvocationBuilder().buildInvocation(
            for: launch,
            outputTargetPath: "<derived>",
            pairingMode: .interleaved,
            pairingMetadataURL: bundle.bundleURL
        )
        XCTAssertTrue(invocation.arguments.containsSequence(["--pairing", "single"]), "\(invocation.arguments)")
    }

    func testPairingArgumentsVerifyARecordedInterleavedClaimAgainstTheRecords() throws {
        let strict = root.appendingPathComponent("strict.fastq")
        try InterleavedFASTQFixture.write(pairCount: 4, naming: .casava, to: strict)
        XCTAssertEqual(
            FASTQOperationCLIInvocationBuilder.pairingArguments(for: .interleaved, verifiedAgainst: strict, metadataFrom: nil),
            ["--pairing", "interleaved"]
        )
        let mixed = root.appendingPathComponent("mixed.fastq")
        try InterleavedFASTQFixture.writeMixed(pairCount: 4, mergedCount: 2, naming: .casava, to: mixed)
        XCTAssertEqual(
            FASTQOperationCLIInvocationBuilder.pairingArguments(for: .interleaved, verifiedAgainst: mixed, metadataFrom: nil),
            ["--pairing", "single"]
        )
        XCTAssertEqual(
            FASTQOperationCLIInvocationBuilder.pairingArguments(for: .singleEnd, verifiedAgainst: mixed, metadataFrom: nil),
            ["--pairing", "single"]
        )
        XCTAssertEqual(
            FASTQOperationCLIInvocationBuilder.pairingArguments(for: nil, verifiedAgainst: mixed, metadataFrom: nil),
            []
        )
    }

    func testExplicitSingleEndBundleMetadataPassesSinglePairing() throws {
        let bundle = try InterleavedFASTQFixture.writeBundle(
            named: "single", in: root, pairCount: 2, naming: .slashSuffix,
            pairingMode: .singleEnd, pairingSource: .explicit
        )
        for inputURL in [bundle.fastqURL, bundle.bundleURL] {
            let launch = FASTQOperationLaunchRequest.derivative(
                request: .subsampleCount(10),
                inputURLs: [inputURL],
                outputMode: .perInput
            )
            let invocation = try FASTQOperationCLIInvocationBuilder().buildInvocation(for: launch)
            XCTAssertTrue(invocation.arguments.containsSequence(["--pairing", "single"]), "\(invocation.arguments)")
        }
    }

    func testDefaultedSingleEndOverInterleavedRecordsPassesInterleavedPairing() throws {
        // Pre-2026-09-25 imports with no pairing choice recorded single_end
        // over files that alternate /1 /2 mates. Only an explicit choice is
        // final; the records decide otherwise.
        let bundle = try InterleavedFASTQFixture.writeBundle(
            named: "legacy-single", in: root, pairCount: 4, naming: .slashSuffix, pairingMode: .singleEnd
        )
        for inputURL in [bundle.fastqURL, bundle.bundleURL] {
            let launch = FASTQOperationLaunchRequest.derivative(
                request: .subsampleCount(10),
                inputURLs: [inputURL],
                outputMode: .perInput
            )
            let invocation = try FASTQOperationCLIInvocationBuilder().buildInvocation(for: launch)
            XCTAssertTrue(invocation.arguments.containsSequence(["--pairing", "interleaved"]), "\(invocation.arguments)")
        }
    }

    func testRecordedInterleavedBundleDirectoryPassesInterleavedPairing() throws {
        let bundle = try InterleavedFASTQFixture.writeBundle(
            named: "strict-dir", in: root, pairCount: 3, naming: .identical, pairingMode: .interleaved
        )
        let launch = FASTQOperationLaunchRequest.derivative(
            request: .subsampleCount(10),
            inputURLs: [bundle.bundleURL],
            outputMode: .perInput
        )
        let invocation = try FASTQOperationCLIInvocationBuilder().buildInvocation(for: launch)
        XCTAssertTrue(invocation.arguments.containsSequence(["--pairing", "interleaved"]), "\(invocation.arguments)")
    }

    func testLooseFASTQWithoutMetadataLeavesTheCLIInAutoMode() throws {
        let launch = FASTQOperationLaunchRequest.derivative(
            request: .subsampleProportion(0.25),
            inputURLs: [URL(fileURLWithPath: "/tmp/input.fastq")],
            outputMode: .perInput
        )
        let invocation = try FASTQOperationCLIInvocationBuilder().buildInvocation(for: launch)
        XCTAssertFalse(invocation.arguments.contains("--pairing"))
    }

    func testExplicitPairingOverridesWhatIsNextToTheResolvedInput() throws {
        // A derived bundle is materialized to a scratch file with no metadata;
        // the execution service passes the ORIGINAL bundle's pairing instead.
        let scratchFASTQ = root.appendingPathComponent("materialized.fastq")
        try InterleavedFASTQFixture.write(pairCount: 2, naming: .identical, to: scratchFASTQ)
        let launch = FASTQOperationLaunchRequest.derivative(
            request: .searchMotif(pattern: "ACGT", regex: false),
            inputURLs: [scratchFASTQ],
            outputMode: .perInput
        )
        let invocation = try FASTQOperationCLIInvocationBuilder().buildInvocation(
            for: launch,
            outputTargetPath: "<derived>",
            pairingMode: .interleaved
        )
        XCTAssertTrue(invocation.arguments.containsSequence(["--pairing", "interleaved"]))
    }

    // `length-filter` joined the pair-aware subcommands (seqkit seq orphaned
    // 1,856 mates on the HG002 fixture); reverse-complement rewrites every
    // record on its own and never takes the flag.
    func testUnaffectedSubcommandsDoNotReceiveThePairingFlag() throws {
        let bundle = try InterleavedFASTQFixture.writeBundle(
            named: "length", in: root, pairCount: 2, naming: .identical, pairingMode: .interleaved
        )
        let launch = FASTQOperationLaunchRequest.derivative(
            request: .reverseComplement,
            inputURLs: [bundle.fastqURL],
            outputMode: .perInput
        )
        let invocation = try FASTQOperationCLIInvocationBuilder().buildInvocation(for: launch)
        XCTAssertFalse(invocation.arguments.contains("--pairing"))
    }

    /// The four fastp trims: `fastq trim` on the HG002 chr20 bundle lost 250
    /// reads (240 orphaned mates) because fastp ran single-end. The builder
    /// now passes the bundle's pairing so the CLI runs fastp paired.
    private static let fastpRequests: [FASTQDerivativeRequest] = [
        .fastpTrim(threshold: 20, windowSize: 4, mode: .cutRight, adapterMode: .autoDetect, adapterSequence: nil),
        .qualityTrim(threshold: 20, windowSize: 4, mode: .cutRight),
        .adapterTrim(mode: .autoDetect, sequence: nil, sequenceR2: nil, fastaFilename: nil),
        .fixedTrim(from5Prime: 5, from3Prime: 0),
    ]

    func testFastpTrimsCarryInterleavedPairingFromBundleMetadata() throws {
        let bundle = try InterleavedFASTQFixture.writeBundle(
            named: "hg002-trim", in: root, pairCount: 4, naming: .identical, pairingMode: .interleaved
        )
        for request in Self.fastpRequests {
            let launch = FASTQOperationLaunchRequest.derivative(
                request: request, inputURLs: [bundle.fastqURL], outputMode: .perInput
            )
            let invocation = try FASTQOperationCLIInvocationBuilder().buildInvocation(for: launch, outputTargetPath: "/tmp/out.fastq.gz")
            XCTAssertTrue(
                invocation.arguments.containsSequence(["--pairing", "interleaved"]),
                "\(invocation.arguments.first ?? "?"): \(invocation.arguments)"
            )
            XCTAssertEqual(invocation.arguments.suffix(2), ["-o", "/tmp/out.fastq.gz"], "\(invocation.arguments)")
            let shown = request.cliCommand(inputPath: bundle.fastqURL.path, outputPath: "/tmp/out.fastq.gz", pairingMode: .interleaved)
            XCTAssertTrue(shown.contains("--pairing interleaved"), shown)
        }
    }

    func testFastpTrimsOnAMixedBundleAreToldInterleavedBecauseTheyPartitionByName() throws {
        // A positional tool (subsample) is told `single` for a mixed file;
        // the fastp trims partition the file by name, run its pairs paired
        // and its unpaired reads single-end, so they are told `interleaved`
        // and verify it against the records themselves.
        let bundle = try InterleavedFASTQFixture.writeMixedBundle(
            named: "vsp2-trim", in: root, pairCount: 6, mergedCount: 3, naming: .identical, pairingMode: .interleaved
        )
        for request in Self.fastpRequests + [.subsampleCount(10)] {
            let launch = FASTQOperationLaunchRequest.derivative(
                request: request, inputURLs: [bundle.fastqURL], outputMode: .perInput
            )
            let invocation = try FASTQOperationCLIInvocationBuilder().buildInvocation(for: launch)
            let expected = invocation.arguments.first == "subsample" ? "single" : "interleaved"
            XCTAssertTrue(
                invocation.arguments.containsSequence(["--pairing", expected]),
                "\(invocation.arguments.first ?? "?"): \(invocation.arguments)"
            )
        }
    }

    func testDisplayCommandCarriesTheSamePairingFlag() {
        let request = FASTQDerivativeRequest.subsampleCount(500)
        let command = request.cliCommand(inputPath: "/tmp/in.fastq", outputPath: "/tmp/out.fastq", pairingMode: .interleaved)
        XCTAssertTrue(command.contains("--pairing interleaved"), command)

        let plain = request.cliCommand(inputPath: "/tmp/in.fastq", outputPath: "/tmp/out.fastq")
        XCTAssertFalse(plain.contains("--pairing"), plain)
    }
}

private extension Array where Element == String {
    func containsSequence(_ sequence: [String]) -> Bool {
        guard !sequence.isEmpty, sequence.count <= count else { return false }
        return indices.contains { index in
            guard let end = self.index(index, offsetBy: sequence.count, limitedBy: endIndex) else { return false }
            return Array(self[index..<end]) == sequence
        }
    }
}
