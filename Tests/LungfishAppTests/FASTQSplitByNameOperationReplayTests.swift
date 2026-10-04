// FASTQSplitByNameOperationReplayTests.swift - The dialog's pair-aware runs and their recorded commands agree
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// fastq deduplicate and fastq primer-remove split a file that mixes mate
// pairs with single reads by name, and run a strictly interleaved file in
// their tool's paired mode (lane A8). Each test runs the Operations dialog
// path on a fixture bundle (the execution service with the real subcommand
// in process and the real importer), takes the command the dialog records,
// replays it through the real CLI on the same bundle, and checks that both
// hold the same pairs and single reads, every pair whole. The managed tools
// run, so the class sits in the integration tier by its name.

import ArgumentParser
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

final class FASTQSplitByNameOperationReplayTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "split-by-name-replay")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    private func requireTool(_ tool: NativeTool) async throws {
        guard await NativeToolRunner.shared.isToolAvailable(tool) else {
            try ToolAvailability.skipOrFail("managed \(tool.rawValue) is not installed")
        }
    }

    /// The mate sequences of each pair and the sequence of each single read
    /// of a file, sorted so two runs compare whatever order their tool wrote.
    private struct Fragments: Equatable {
        var pairs: [[String]]
        var singles: [String]
    }

    private func fragments(_ url: URL) async throws -> Fragments {
        let records = try await InterleavedFASTQFixture.readRecords(at: url)
        var pairs: [[String]] = []
        var singles: [String] = []
        var index = 0
        while index < records.count {
            if index + 1 < records.count,
               InterleavedFASTQFixture.fragmentKey(records[index]) == InterleavedFASTQFixture.fragmentKey(records[index + 1]) {
                pairs.append([records[index].sequence, records[index + 1].sequence])
                index += 2
            } else {
                singles.append(records[index].sequence)
                index += 1
            }
        }
        return Fragments(pairs: pairs.sorted { $0.joined() < $1.joined() }, singles: singles.sorted())
    }

    /// Runs the dialog path and returns the imported derivative's reads and
    /// the command the dialog row records.
    private func dialogRun(
        _ request: FASTQDerivativeRequest,
        on bundle: URL,
        label: String
    ) async throws -> (payload: URL, recordedCommand: String) {
        let destination = root.appendingPathComponent("Derived-\(label)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let service = FASTQOperationExecutionService(
            commandRunner: InProcessFASTQCommandRunner(),
            directImporter: BundleFASTQOperationImporter(
                destinationDirectory: destination,
                fastqBundleWriter: AppFASTQOutputBundleWriter(
                    ingestor: CopyingFASTQOutputIngestor(),
                    statisticsCalculator: AppFASTQOutputBundleWriter.swiftReaderStatisticsCalculator
                )
            )
        )
        let launch = FASTQOperationLaunchRequest.derivative(request: request, inputURLs: [bundle], outputMode: .perInput)
        let recorded = FASTQOperationCLIInvocationBuilder.commandLine(for: try service.buildInvocation(for: launch))
        let result = try await service.execute(
            request: launch,
            workingDirectory: root.appendingPathComponent("work-\(label)", isDirectory: true)
        )
        let imported = try XCTUnwrap(result.importedURLs.first, "\(label): one derivative was imported")
        let payload = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: imported), "\(label): the derivative holds its reads")
        return (payload, recorded)
    }

    /// Runs the recorded command through the real CLI with `<derived>`
    /// replaced by an output path.
    private func replay(_ recordedCommand: String, label: String) async throws -> URL {
        let outputURL = root.appendingPathComponent("replay-\(label).fastq")
        let words = try RecordedCLICommand.arguments(of: recordedCommand).map { $0 == "<derived>" ? outputURL.path : $0 }
        let command = try LungfishCLI.parseAsRoot(LungfishCLI.normalizedArgumentsForParsing(words))
        guard var runnable = command as? AsyncParsableCommand else {
            XCTFail("\(label): \(type(of: command)) is not runnable")
            return outputURL
        }
        try await runnable.run()
        return outputURL
    }

    // MARK: - Deduplicate

    func testDeduplicateOfAMixedBundleReplaysToTheSamePairsAndSingleReads() async throws {
        try await requireTool(.clumpify)
        // Pair 6 repeats pair 1 and merged read 3 repeats merged read 0.
        let bundle = try InterleavedFASTQFixture.writeMixedBundle(
            named: "mixed-dedup", in: root, pairCount: 8, mergedCount: 4, naming: .identical,
            sequences: { InterleavedFASTQFixture.defaultSequences($0 == 6 ? 1 : $0) },
            mergedSequences: { InterleavedFASTQFixture.defaultMergedSequence($0 == 3 ? 0 : $0) }
        )
        let request = FASTQDerivativeRequest.deduplicate(preset: .exactPCR, substitutions: 0, optical: false, opticalDistance: 40)
        let dialog = try await dialogRun(request, on: bundle.bundleURL, label: "dedup")
        let parsed = try RecordedCLICommand.parse(dialog.recordedCommand, as: FastqDeduplicateSubcommand.self)
        XCTAssertEqual(parsed.pairing.pairing, .interleaved, dialog.recordedCommand)
        XCTAssertEqual(parsed.input, bundle.bundleURL.path)

        let dialogReads = try await fragments(dialog.payload)
        XCTAssertEqual(dialogReads.pairs.count, 7, "one copy of the repeated pair, every pair whole")
        XCTAssertEqual(dialogReads.singles.count, 3, "one copy of the repeated merged read")
        let replayed = try await fragments(try await replay(dialog.recordedCommand, label: "dedup"))
        XCTAssertEqual(replayed, dialogReads, "the recorded command reproduces the dialog's reads")
    }

    // MARK: - Primer removal

    /// ARTIC nCoV-2019 pairs 5 and 6 at their MT192765.1 coordinates
    /// (Tests/Fixtures/sarscov2/test.bed) on the fixture genome.
    private struct Amplicons {
        let left5: String
        let right5: String
        let left6: String
        let right6: String
        let amplicon5: String
        let amplicon6: String

        init() throws {
            let fixtures = CLITestBinaryResolver.repositoryRoot(containing: #filePath)
                .appendingPathComponent("Tests/Fixtures/sarscov2")
            let genome = Array(try String(contentsOf: fixtures.appendingPathComponent("genome.fasta"), encoding: .utf8)
                .split(separator: "\n")
                .filter { !$0.hasPrefix(">") }
                .joined())
            var spans: [String: Range<Int>] = [:]
            for line in try String(contentsOf: fixtures.appendingPathComponent("test.bed"), encoding: .utf8).split(separator: "\n") {
                let fields = line.split(separator: "\t")
                guard fields.count >= 4, let start = Int(fields[1]), let end = Int(fields[2]) else { continue }
                spans[String(fields[3])] = start..<end
            }
            func span(_ name: String) throws -> Range<Int> { try XCTUnwrap(spans[name], name) }
            func bases(_ range: Range<Int>) -> String { String(genome[range]) }
            let l5 = try span("nCoV-2019_5_LEFT"), r5 = try span("nCoV-2019_5_RIGHT")
            let l6 = try span("nCoV-2019_6_LEFT"), r6 = try span("nCoV-2019_6_RIGHT")
            left5 = bases(l5)
            right5 = Self.reverseComplement(bases(r5))
            left6 = bases(l6)
            right6 = Self.reverseComplement(bases(r6))
            amplicon5 = bases(l5.lowerBound..<r5.upperBound)
            amplicon6 = bases(l6.lowerBound..<r6.upperBound)
        }

        static func reverseComplement(_ sequence: String) -> String {
            let complement: [Character: Character] = ["A": "T", "C": "G", "G": "C", "T": "A", "N": "N"]
            return String(sequence.reversed().map { complement[$0] ?? "N" })
        }

        /// The left primer, 60 bases of amplicon 5 behind it, and the right
        /// primer's reverse complement: a read of 110 bases runs through it.
        func shortInsert(_ index: Int) -> String {
            let start = amplicon5.index(amplicon5.startIndex, offsetBy: left5.count + index * 7)
            return left5 + String(amplicon5[start...].prefix(60)) + Self.reverseComplement(right5)
        }

        /// 2x150 pairs of both long amplicons, read-through pairs of short
        /// inserts, and pairs whose mate 1 is the primer and 5 bases.
        var pairs: [(name: String, mate1: String, mate2: String)] {
            var pairs: [(String, String, String)] = []
            for index in 0..<6 {
                pairs.append(("long5_\(index)", String(amplicon5.prefix(150)), String(Self.reverseComplement(amplicon5).prefix(150))))
                pairs.append(("long6_\(index)", String(amplicon6.prefix(150)), String(Self.reverseComplement(amplicon6).prefix(150))))
            }
            for index in 0..<3 {
                let insert = shortInsert(index)
                pairs.append(("short_\(index)", insert, Self.reverseComplement(insert)))
            }
            for index in 0..<2 {
                pairs.append(("dimer_\(index)", left5 + String(amplicon5.dropFirst(left5.count + index).prefix(5)), String(Self.reverseComplement(amplicon5).prefix(150))))
            }
            return pairs
        }
    }

    private static func record(_ name: String, _ sequence: String) -> String {
        "@\(name)\n\(sequence)\n+\n\(String(repeating: "I", count: sequence.count))\n"
    }

    /// A `.lungfishfastq` bundle of `merged` single reads followed by
    /// `pairs`, recorded as interleaved, as a paired or merge-recipe import is.
    private func writeBundle(
        named name: String,
        merged: [(String, String)] = [],
        pairs: [(name: String, mate1: String, mate2: String)]
    ) throws -> URL {
        let bundleURL = root.appendingPathComponent("\(name).\(FASTQBundle.directoryExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let fastqURL = bundleURL.appendingPathComponent("\(name).fastq")
        let text = merged.map { Self.record($0.0, $0.1) }.joined()
            + pairs.map { Self.record("\($0.name) 1:N:0:1", $0.mate1) + Self.record("\($0.name) 2:N:0:1", $0.mate2) }.joined()
        try text.write(to: fastqURL, atomically: true, encoding: .utf8)
        FASTQMetadataStore.save(
            PersistedFASTQMetadata(ingestion: IngestionMetadata(pairingMode: .interleaved, originalFilenames: ["\(name).fastq"])),
            for: fastqURL
        )
        return bundleURL
    }

    func testLiteralPrimerRemovalReplaysOnAStrictAndAMixedBundle() async throws {
        try await requireTool(.bbduk)
        let amplicons = try Amplicons()
        let request = FASTQDerivativeRequest.primerRemoval(configuration: FASTQPrimerTrimConfiguration(
            source: .literal,
            forwardSequence: amplicons.left5,
            tool: .bbduk,
            kmerSize: 15,
            minKmer: 11,
            hammingDistance: 1
        ))
        let strict = try writeBundle(named: "amplicons-strict", pairs: amplicons.pairs)
        let mixed = try writeBundle(
            named: "amplicons-mixed",
            merged: (0..<3).map { ("merged_\($0)", amplicons.shortInsert($0)) },
            pairs: amplicons.pairs
        )
        for (bundle, label, singles) in [(strict, "literal-strict", 0), (mixed, "literal-mixed", 3)] {
            let dialog = try await dialogRun(request, on: bundle, label: label)
            let dialogReads = try await fragments(dialog.payload)
            XCTAssertEqual(dialogReads.pairs.count, amplicons.pairs.count - 2, "\(label): the two primer-dimer pairs go whole, every other pair stays whole")
            XCTAssertEqual(dialogReads.singles.count, singles, "\(label): the merged reads stay single")
            XCTAssertFalse(
                dialogReads.pairs.contains { $0[0].hasPrefix(amplicons.left5) } || dialogReads.singles.contains { $0.hasPrefix(amplicons.left5) },
                "\(label): no read still starts with the primer"
            )
            let replayed = try await fragments(try await replay(dialog.recordedCommand, label: label))
            XCTAssertEqual(replayed, dialogReads, "\(label): the recorded command reproduces the dialog's reads")
        }
    }

    func testLinkedPrimerRemovalReplaysOnAStrictBundle() async throws {
        try await requireTool(.cutadapt)
        let amplicons = try Amplicons()
        let referenceURL = root.appendingPathComponent("primers.fasta")
        try ">amp5-F\n\(amplicons.left5)\n>amp5-R\n\(amplicons.right5)\n>amp6-F\n\(amplicons.left6)\n>amp6-R\n\(amplicons.right6)\n"
            .write(to: referenceURL, atomically: true, encoding: .utf8)
        // Mate 2 of short_1 lost its last 30 bases and its read-through primer.
        var pairs = amplicons.pairs.filter { $0.name.hasPrefix("short") }
        pairs[1].mate2 = String(pairs[1].mate2.dropLast(30))
        let bundle = try writeBundle(named: "linked-strict", pairs: pairs)
        let request = FASTQDerivativeRequest.primerRemoval(configuration: FASTQPrimerTrimConfiguration(
            source: .reference,
            mode: .linked,
            referenceFasta: referenceURL.path,
            tool: .cutadapt
        ))
        let dialog = try await dialogRun(request, on: bundle, label: "linked-strict")
        let dialogReads = try await fragments(dialog.payload)
        XCTAssertEqual(dialogReads.pairs.count, 2, "the pair whose mate 2 lacks its linked primer goes whole")
        XCTAssertEqual(dialogReads.singles, [], "no mate is orphaned")
        let replayed = try await fragments(try await replay(dialog.recordedCommand, label: "linked-strict"))
        XCTAssertEqual(replayed, dialogReads, "the recorded command reproduces the dialog's reads")
    }
}

/// Runs each invocation with the real `lungfish-cli` subcommand in this
/// process, as the shipped binary would parse it.
private struct InProcessFASTQCommandRunner: FASTQOperationCommandRunning {
    func run(
        invocation: FASTQCLIInvocation,
        outputDirectory: URL,
        progress: @escaping FASTQOperationProgressHandler
    ) async throws -> FASTQCLIExecutionResult {
        let words = invocation.subcommand.split(separator: " ").map(String.init) + invocation.arguments
        let parsed = try LungfishCLI.parseAsRoot(LungfishCLI.normalizedArgumentsForParsing(words))
        guard var command = parsed as? AsyncParsableCommand else {
            throw CocoaError(.featureUnsupported)
        }
        try await command.run()
        return FASTQCLIExecutionResult(outputURLs: [])
    }
}

/// Stands in for the re-ingestion and copies the operation's output into
/// the staging bundle unchanged, so the replay compares the CLI's own output.
private struct CopyingFASTQOutputIngestor: FASTQOutputIngesting {
    func ingest(
        config: FASTQIngestionConfig,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> FASTQIngestionResult {
        let input = config.inputFiles[0]
        try FileManager.default.createDirectory(at: config.outputDirectory, withIntermediateDirectories: true)
        let output = config.outputDirectory.appendingPathComponent(input.lastPathComponent)
        try FileManager.default.copyItem(at: input, to: output)
        return FASTQIngestionResult(
            outputFile: output,
            wasClumpified: false,
            qualityBinning: config.qualityBinning,
            originalFilenames: [input.lastPathComponent],
            originalSizeBytes: 0,
            finalSizeBytes: 0,
            pairingMode: config.pairingMode
        )
    }
}
