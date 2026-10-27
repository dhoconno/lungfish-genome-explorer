// BBToolsQualityEncodingConformanceTests.swift - Every BBTools call that reads FASTQ keeps the scores of high-quality short reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCLI
@testable import LungfishOperations
@testable import LungfishWorkflow
import LungfishIO
import LungfishPortable
import LungfishTestSupport

/// BIO-BIN-QIN, row BBTOOLS-QIN. bbmap 40.02 runs with `qin=auto`. On a short read with a score of about Q55 or more it
/// switches to ASCII-64, then stores every later score 31 too low, stops with words that blame the reads, or never
/// exits. Its called-quality cap also lowers every score above Q50. Each test builds the argv of one site through its
/// own builder, runs the real tool on reads that hold every score from Q0 to Q93 under a 120 s deadline, and asserts
/// exit 0 and, for a step that passes reads through, that every score equals `max(input, 2)`. A called Q0 or Q1
/// comes out as Q2 from every BBTools tool, whatever the flags (measured).
///
/// A real-tool suite. Its name keeps it out of the unit tier, and it skips when a managed tool is missing, or fails
/// under LUNGFISH_REQUIRE_TOOLS=1. The bbmerge tests pass at the base, since bbmerge 40.02 never guesses the offset on
/// the sets measured, and keep the flags honest. Its unit twin is BBToolsQualityArgumentsTests.
final class BBToolsQualityEncodingConformanceTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "bbtools-qin")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - clumpify (dedupe)

    func testDedupeSubcommandArgvKeepsScores() async throws {
        let set = shortReads()
        let input = try write(set, "short.fastq")
        let output = root.appendingPathComponent("out.fastq")
        let args = FastqDeduplicateSubcommand.clumpifyArguments(
            input: input.path, output: output.path, heapGB: 1, substitutions: 0, interleaved: false,
            optical: false, opticalDistance: 40)
        try await assertKeepsScores(.clumpify, args, [output], set, minimumReads: 300)
    }

    func testDedupeSubcommandArgvKeepsHiFiScoresAboveFifty() async throws {
        let set = hifiReads()
        let input = try write(set, "hifi.fastq")
        let output = root.appendingPathComponent("out.fastq")
        let args = FastqDeduplicateSubcommand.clumpifyArguments(
            input: input.path, output: output.path, heapGB: 1, substitutions: 0, interleaved: false,
            optical: false, opticalDistance: 40)
        try await assertKeepsScores(.clumpify, args, [output], set, minimumReads: 100)
    }

    func testImporterPairedDedupeArgvKeepsScores() async throws {
        let pairs = pairReads()
        let r1 = try write(pairs.r1, "r1.fastq"), r2 = try write(pairs.r2, "r2.fastq")
        let out1 = root.appendingPathComponent("o1.fastq"), out2 = root.appendingPathComponent("o2.fastq")
        let args = FASTQBatchImporter.pairedDedupeArguments(
            r1: r1, r2: r2, outR1: out1, outR2: out2, heapGB: 1, substitutions: 0, optical: false,
            opticalDistance: 2500, threads: 2)
        try await assertKeepsScores(.clumpify, args, [out1, out2], pairs.all, minimumReads: 300)
    }

    func testImporterInterleavedDedupeArgvKeepsScores() async throws {
        let pairs = pairReads()
        let input = try write(pairs.all, "inter.fastq")
        let output = root.appendingPathComponent("out.fastq")
        let args = FASTQBatchImporter.interleavedDedupeArguments(
            input: input, output: output, optical: false, threads: 2, interleaved: true)
        try await assertKeepsScores(.clumpify, args, [output], pairs.all, minimumReads: 300)
    }

    func testDerivativeDedupeArgvKeepsScores() async throws {
        let set = shortReads()
        let input = try write(set, "short.fastq")
        let output = root.appendingPathComponent("out.fastq")
        let args = FASTQDerivativeService.dedupeArguments(
            input: input, output: output, heapGB: 1, substitutions: 0, interleaved: false, optical: false,
            opticalDistance: 2500)
        try await assertKeepsScores(.clumpify, args, [output], set, minimumReads: 300)
    }

    // MARK: - bbduk

    func testContaminantFilterArgvKeepsScores() async throws {
        let set = shortReads()
        let input = try write(set, "short.fastq")
        let reference = root.appendingPathComponent("contaminant.fa")
        try ">c\n\(bases(80, seed: 11))\n".write(to: reference, atomically: true, encoding: .utf8)
        let output = root.appendingPathComponent("out.fastq")
        let args = try FastqContaminantFilterSubcommand.bbdukArguments(
            inputURL: input, outputPath: output.path, mode: "custom", reference: reference.path, kmerSize: 31,
            hammingDistance: 1, interleaved: false)
        try await assertKeepsScores(.bbduk, args, [output], set, minimumReads: 290)
    }

    func testEntropyFilterArgvKeepsScores() async throws {
        let set = shortReads()
        let input = try write(set, "short.fastq")
        let output = root.appendingPathComponent("out.fastq")
        let args = FastqEntropyFilterSubcommand.bbdukArguments(
            inputURL: input, outputPath: output.path, entropy: 0.1, window: 50, kmer: 5, threads: 2, heapGB: 1,
            interleaved: false)
        try await assertKeepsScores(.bbduk, args, [output], set, minimumReads: 290)
    }

    func testSequenceFilterArgvKeepsScores() async throws {
        let set = shortReads()
        let input = try write(set, "short.fastq")
        let output = root.appendingPathComponent("out.fastq")
        let args = FastqSequenceFilterSubcommand.bbdukArguments(
            inputURL: input, outputPath: output.path, keepMatched: false, interleaved: false,
            literal: bases(30, seed: 12), referenceURL: nil, minOverlap: 15, errorRate: 0.1,
            searchReverseComplement: false, searchEnd: "any")
        try await assertKeepsScores(.bbduk, args, [output], set, minimumReads: 290)
    }

    func testPrimerRemovalFivePrimeArgvKeepsScores() async throws {
        let set = shortReads()
        let input = try write(set, "short.fastq")
        let output = root.appendingPathComponent("out.fastq")
        let args = primerArguments().arguments(input: input.path, output: output.path, paired: false)
        try await assertKeepsScores(.bbduk, args, [output], set, minimumReads: 290)
    }

    func testPrimerRemovalReadThroughArgvKeepsScores() async throws {
        let set = shortReads()
        let input = try write(set, "short.fastq")
        let output = root.appendingPathComponent("out.fastq")
        let args = try XCTUnwrap(primerArguments().readThroughArguments(input: input.path, output: output.path, paired: false))
        try await assertKeepsScores(.bbduk, args, [output], set, minimumReads: 290)
    }

    func testLengthFilterPlanArgvKeepsScores() async throws {
        let pairs = pairReads()
        let input = try write(pairs.all, "inter.fastq")
        let output = root.appendingPathComponent("out.fastq")
        let plan = FASTQLengthFilterPlan.make(
            inputPath: input.path, outputPath: output.path, minLength: 100, maxLength: nil, pairAware: true)
        XCTAssertEqual(plan.tool, .bbduk)
        try await assertKeepsScores(.bbduk, plan.arguments, [output], pairs.all, minimumReads: 300)
    }

    func testImporterInterleavedLengthFilterArgvKeepsScores() async throws {
        let pairs = pairReads()
        let input = try write(pairs.all, "inter.fastq")
        let output = root.appendingPathComponent("out.fastq")
        let args = FASTQBatchImporter.interleavedLengthFilterArguments(
            input: input, output: output, minLength: 100, maxLength: nil, threads: 2)
        try await assertKeepsScores(.bbduk, args, [output], pairs.all, minimumReads: 300)
    }

    func testSavontPrimerTrimArgvKeepsScores() async throws {
        let set = shortReads()
        let input = try write(set, "short.fastq")
        let primers = root.appendingPathComponent("primers.fa")
        try ">p\n\(bases(24, seed: 13))\n".write(to: primers, atomically: true, encoding: .utf8)
        let output = root.appendingPathComponent("out.fastq")
        let args = FullLengthONTMHCGenotypingPipeline.primerTrimArguments(
            input: input, output: output, primers: primers, ktrim: "l")
        try await assertKeepsScores(.bbduk, args, [output], set, minimumReads: 290)
    }

    // MARK: - reformat

    func testPairInterleaveArgvKeepsScores() async throws {
        let pairs = pairReads()
        let r1 = try write(pairs.r1, "r1.fastq"), r2 = try write(pairs.r2, "r2.fastq")
        let output = root.appendingPathComponent("out.fastq")
        let args = BBToolsPairArguments.interleave(r1: r1.path, r2: r2.path, output: output.path)
        try await assertKeepsScores(.reformat, args, [output], pairs.all, minimumReads: 300)
    }

    func testPairDeinterleaveArgvKeepsScores() async throws {
        let pairs = pairReads()
        let input = try write(pairs.all, "inter.fastq")
        let out1 = root.appendingPathComponent("o1.fastq"), out2 = root.appendingPathComponent("o2.fastq")
        let args = BBToolsPairArguments.deinterleave(input: input.path, out1: out1.path, out2: out2.path)
        try await assertKeepsScores(.reformat, args, [out1, out2], pairs.all, minimumReads: 300)
    }

    func testRecipePairedToInterleavedArgvKeepsScores() async throws {
        let pairs = pairReads()
        let r1 = try write(pairs.r1, "r1.fastq"), r2 = try write(pairs.r2, "r2.fastq")
        let output = root.appendingPathComponent("out.fastq")
        let args = RecipeEngine.pairedToInterleavedArguments(r1: r1, r2: r2, output: output, threads: 2)
        try await assertKeepsScores(.reformat, args, [output], pairs.all, minimumReads: 300)
    }

    func testRecipeInterleavedToPairedArgvKeepsScores() async throws {
        let pairs = pairReads()
        let input = try write(pairs.all, "inter.fastq")
        let out1 = root.appendingPathComponent("o1.fastq"), out2 = root.appendingPathComponent("o2.fastq")
        let args = RecipeEngine.interleavedToPairedArguments(input: input, out1: out1, out2: out2, threads: 2)
        try await assertKeepsScores(.reformat, args, [out1, out2], pairs.all, minimumReads: 300)
    }

    func testSubsampleArgvKeepsScores() async throws {
        let pairs = pairReads()
        let input = try write(pairs.all, "inter.fastq")
        let output = root.appendingPathComponent("out.fastq")
        let args = FastqSubsampleSubcommand.reformatSampleArguments(
            input: input.path, output: output.path, proportion: 0.5, count: nil, seed: 7)
        try await assertKeepsScores(.reformat, args, [output], pairs.all, minimumReads: 100)
    }

    func testSavontLengthFilterArgvKeepsScores() async throws {
        let set = shortReads()
        let input = try write(set, "short.fastq")
        let output = root.appendingPathComponent("out.fastq")
        let args = FullLengthONTMHCGenotypingPipeline.lengthFilterArguments(
            input: input, output: output, minimumLength: 100, maximumLength: 200)
        try await assertKeepsScores(.reformat, args, [output], set, minimumReads: 300)
    }

    func testTrimGaloreInterleaveArgvKeepsScores() async throws {
        let pairs = pairReads()
        let r1 = try write(pairs.r1, "r1.fastq"), r2 = try write(pairs.r2, "r2.fastq")
        let output = root.appendingPathComponent("out.fastq")
        let args = PortableStoragePlan.trimGaloreInterleaveArguments(
            r1: r1, r2: r2, output: output, compressionLevel: 4, threads: 2)
        try await assertKeepsScores(.reformat, args, [output], pairs.all, minimumReads: 300)
    }

    // MARK: - repair, tadpole

    func testRepairArgvKeepsScores() async throws {
        let pairs = pairReads()
        let input = try write(pairs.all, "inter.fastq")
        let output = root.appendingPathComponent("out.fastq")
        let singletons = root.appendingPathComponent("singletons.fastq")
        let args = FastqRepairSubcommand.repairArguments(input: input, repaired: output, singletons: singletons)
        try await assertKeepsScores(.repair, args, [output, singletons], pairs.all, minimumReads: 300)
    }

    func testErrorCorrectArgvKeepsScoresOfBasesItLeaves() async throws {
        let set = shortReads()
        let input = try write(set, "short.fastq")
        let output = root.appendingPathComponent("out.fastq")
        let args = FastqErrorCorrectSubcommand.tadpoleArguments(input: input, output: output.path, kmerSize: 31)
        try await assertKeepsScores(.tadpole, args, [output], set, minimumReads: 300)
    }

    // MARK: - bbmerge (passes at the base, see the class note)

    func testImporterMergeArgvMerges() async throws {
        let pairs = pairReads()
        let input = try write(pairs.all, "inter.fastq")
        let merged = root.appendingPathComponent("merged.fastq"), unmerged = root.appendingPathComponent("unmerged.fastq")
        let args = FASTQBatchImporter.mergeArguments(
            input: input, merged: merged, unmerged: unmerged, minOverlap: 12, threads: 2, interleaved: true, strict: false)
        try await assertMerges(args, merged: merged)
    }

    func testDerivativeMergeArgvMerges() async throws {
        let pairs = pairReads()
        let input = try write(pairs.all, "inter.fastq")
        let merged = root.appendingPathComponent("merged.fastq"), unmerged = root.appendingPathComponent("unmerged.fastq")
        let args = FASTQDerivativeService.mergeArguments(
            source: input, merged: merged, unmerged: unmerged, minOverlap: 12, interleaved: true, strict: false)
        try await assertMerges(args, merged: merged)
    }

    func testMergeSubcommandArgvMerges() async throws {
        let pairs = pairReads()
        let input = try write(pairs.all, "inter.fastq")
        let merged = root.appendingPathComponent("merged.fastq"), unmerged = root.appendingPathComponent("unmerged.fastq")
        let args = FastqMergeSubcommand.bbmergeArguments(
            input: input, merged: merged, unmerged: unmerged, minOverlap: 12, strict: false)
        try await assertMerges(args, merged: merged)
    }

    func testAmpliconPairMergerArgvMerges() async throws {
        let pairs = pairReads()
        let input = try write(pairs.all, "inter.fastq")
        let merged = root.appendingPathComponent("merged.fastq"), unmerged = root.appendingPathComponent("unmerged.fastq")
        let args = IlluminaAmpliconPairMerger.bbmergeArguments(input: input, merged: merged, unmerged: unmerged, threads: 2)
        try await assertMerges(args, merged: merged)
    }

    // MARK: - Running and checking

    private func requireManagedTool(_ tool: NativeTool) async throws {
        guard (try? await NativeToolRunner.shared.toolPath(for: tool)) != nil else {
            try ToolAvailability.skipOrFail("Managed \(tool.rawValue) is not available")
        }
    }

    /// Runs `tool` with `arguments` under the 120 s deadline of the ruling and returns its result. A tool that hangs
    /// throws at the deadline, which fails the test.
    private func run(_ tool: NativeTool, _ arguments: [String]) async throws -> NativeToolResult {
        try await requireManagedTool(tool)
        let environment = CoreToolLocator.bbToolsEnvironment(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            existingPath: ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        )
        return try await NativeToolRunner.shared.run(
            tool, arguments: arguments, workingDirectory: root, environment: environment, timeout: 120)
    }

    private func assertKeepsScores(
        _ tool: NativeTool,
        _ arguments: [String],
        _ outputs: [URL],
        _ expected: ReadSet,
        minimumReads: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let result = try await run(tool, arguments)
        XCTAssertEqual(
            result.exitCode, 0, "\(tool.executableName) stopped: \(result.stderr.suffix(300))", file: file, line: line)
        var got: [String: [Int]] = [:]
        for url in outputs {
            got.merge(try scores(in: url)) { first, _ in first }
        }
        XCTAssertGreaterThanOrEqual(got.count, minimumReads, "reads that came back", file: file, line: line)
        var wrong = 0
        var total = 0
        var examples = Set<String>()
        for (name, stored) in got {
            guard let input = expected.scores[name] else { continue }
            for (before, after) in zip(input, stored) {
                total += 1
                if after != max(before, 2) {
                    wrong += 1
                    if examples.count < 3 { examples.insert("Q\(before) to Q\(after)") }
                }
            }
        }
        XCTAssertEqual(
            wrong, 0, "\(wrong) of \(total) scores differ from max(input, 2), such as \(examples.sorted())",
            file: file, line: line)
    }

    private func assertMerges(
        _ arguments: [String], merged: URL, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let result = try await run(.bbmerge, arguments)
        XCTAssertEqual(result.exitCode, 0, "bbmerge.sh stopped: \(result.stderr.suffix(300))", file: file, line: line)
        let mergedReads = try scores(in: merged)
        XCTAssertGreaterThanOrEqual(mergedReads.count, 100, "reads that merged", file: file, line: line)
        XCTAssertTrue(mergedReads.values.allSatisfy { $0.count >= 150 }, "a merged read keeps a score for every base", file: file, line: line)
    }

    private func scores(in url: URL) throws -> [String: [Int]] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
        var records: [String: [Int]] = [:]
        var index = 0
        while index + 3 < lines.count {
            let name = lines[index].dropFirst().split(separator: " ").first.map(String.init) ?? ""
            records[name] = lines[index + 3].utf8.map { Int($0) - 33 }
            index += 4
        }
        return records
    }

    private func primerArguments() -> FastqPrimerRemovalSubcommand.ToolArguments {
        FastqPrimerRemovalSubcommand.ToolArguments(engine: .bbduk(
            primers: "literal=\(bases(24, seed: 14))", kmerSize: 15, minKmer: 11, hammingDistance: 1, searchWindow: 60,
            readThrough: FastqPrimerRemovalSubcommand.ReadThroughPass(
                primers: "literal=\(bases(24, seed: 15))", kmerSize: 15, window: 24)))
    }

    // MARK: - Read sets

    /// Reads with the names and scores a test compares against.
    struct ReadSet {
        var records: [(name: String, bases: String, scores: [Int])] = []
        var scores: [String: [Int]] { Dictionary(records.map { ($0.name, $0.scores) }) { first, _ in first } }
    }

    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private func bases(_ count: Int, seed: UInt64) -> String {
        var rng = SplitMix64(state: seed)
        return String((0..<count).map { _ in "ACGT".randomElement(using: &rng) ?? "A" })
    }

    private func reverseComplement(_ text: String) -> String {
        let pairs: [Character: Character] = ["A": "T", "C": "G", "G": "C", "T": "A"]
        return String(text.reversed().map { pairs[$0] ?? "N" })
    }

    /// Every score from Q0 to Q93 and 56 random ones, in shuffled order, the probe set of the ruling.
    private func everyScore(_ rng: inout SplitMix64) -> [Int] {
        (Array(0...93) + (0..<56).map { _ in Int.random(in: 0...93, using: &rng) }).shuffled(using: &rng)
    }

    private func shortReads() -> ReadSet {
        var rng = SplitMix64(state: 3)
        var set = ReadSet()
        for index in 0..<300 {
            set.records.append(("f\(index)", bases(150, seed: UInt64(1000 + index)), everyScore(&rng)))
        }
        return set
    }

    /// 150 pairs cut from fragments of 200 bases, so the mates overlap by 100 and bbmerge merges them.
    private func pairReads() -> (r1: ReadSet, r2: ReadSet, all: ReadSet) {
        var rng = SplitMix64(state: 4)
        var first = ReadSet(), second = ReadSet(), both = ReadSet()
        for index in 0..<150 {
            let fragment = bases(200, seed: UInt64(5000 + index))
            let forward = (name: "p\(index)/1", bases: String(fragment.prefix(150)), scores: everyScore(&rng))
            let reverse = (name: "p\(index)/2", bases: reverseComplement(String(fragment.suffix(150))), scores: everyScore(&rng))
            first.records.append(forward)
            second.records.append(reverse)
            both.records.append(forward)
            both.records.append(reverse)
        }
        return (first, second, both)
    }

    /// 100 reads of 3,000 bases, 70% Q93, 25% Q40 to Q92 and 5% Q31 to Q39, the HiFi-clean set of the ruling.
    private func hifiReads() -> ReadSet {
        var rng = SplitMix64(state: 6)
        var set = ReadSet()
        for index in 0..<100 {
            let scores = (0..<3000).map { _ -> Int in
                let draw = Int.random(in: 0..<100, using: &rng)
                if draw < 70 { return 93 }
                return draw < 95 ? Int.random(in: 40...92, using: &rng) : Int.random(in: 31...39, using: &rng)
            }
            set.records.append(("h\(index)", bases(3000, seed: UInt64(9000 + index)), scores))
        }
        return set
    }

    private func write(_ set: ReadSet, _ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        let text = set.records.map { record in
            "@\(record.name)\n\(record.bases)\n+\n\(String(decoding: record.scores.map { UInt8($0 + 33) }, as: UTF8.self))\n"
        }.joined()
        try Data(text.utf8).write(to: url)
        return url
    }
}
