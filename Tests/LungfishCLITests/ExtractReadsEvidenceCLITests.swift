// ExtractReadsEvidenceCLITests.swift - extract reads on alignment evidence, with its index, filters and record
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A51 M3, census row 22 (gaps alignment-region-reads and alignment-selected-reads).
// With `--index`, `--by-region` and `--by-id --bam` read the alignment through that index and publish
// a `.lungfishfastq` bundle at `--output` with its record, as the viewer's Extract Reads in Selected
// Region and Extract Selected Reads did in the app. The region run applies `--min-mapq`,
// `--exclude-flags` and `--read-group`, and selected reads come from a file of names that the record
// names with its digest (SWIFT, BIO g22, UX). The record's argv is the command, which replays. The
// runs use samtools on the sarscov2 BAM.

import ArgumentParser
import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishCLI

final class ExtractReadsEvidenceCLITests: XCTestCase {
    private var scratch: ImportStreamCapture.Scratch!

    override func setUpWithError() throws {
        scratch = try ImportStreamCapture.Scratch()
    }

    override func tearDown() {
        scratch?.remove()
    }

    private static let fixtureBAM = ProvenanceCompatCorpus.repositoryRoot
        .appendingPathComponent("Tests/Fixtures/sarscov2/test.paired_end.sorted.bam")

    /// The evidence copied into the scratch folder, as the viewer holds it, and the output folder.
    private func evidence() throws -> (bam: URL, index: URL) {
        let folder = scratch.root.appendingPathComponent("evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratch.root.appendingPathComponent("out"), withIntermediateDirectories: true)
        let bam = folder.appendingPathComponent("S1.bam")
        let index = folder.appendingPathComponent("S1.bam.bai")
        try FileManager.default.copyItem(at: Self.fixtureBAM, to: bam)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: Self.fixtureBAM.path + ".bai"), to: index)
        return (bam, index)
    }

    private func run(_ arguments: [String]) async throws -> (events: [CLIEvent], output: ImportStreamCapture.Output) {
        let command = try ExtractReadsSubcommand.parse(arguments + ["--format", "json"])
        let output = try await ImportStreamCapture.capture(in: scratch) { try await command.run() }
        let decoder = CLIEventLineDecoder()
        return (output.standardOutput.compactMap { try? decoder.decodeLine($0)?.event }, output)
    }

    private func record(of bundle: URL) throws -> ProvenanceEnvelope {
        try XCTUnwrap(try ProvenanceEnvelopeReader.load(fromSidecar: bundle.appendingPathComponent(".lungfish-provenance.json")))
    }

    /// The read names of a FASTQ, without the /1 and /2 that samtools fastq appends.
    private func readNames(_ fastq: URL) throws -> Set<String> {
        let lines = try String(contentsOf: fastq, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
        return Set(stride(from: 0, to: lines.count - 3, by: 4).map { index in
            var name = String(lines[index].dropFirst().split(separator: " ")[0])
            if name.hasSuffix("/1") || name.hasSuffix("/2") { name.removeLast(2) }
            return name
        })
    }

    // MARK: - Runs

    func testARegionRunPublishesTheBundleWhoseRecordNamesTheCommandAndItsFilters() async throws {
        guard SamtoolsLocator.locate() != nil else { throw XCTSkip("The managed samtools is not installed.") }
        let (bam, index) = try evidence()
        let bundle = scratch.root.appendingPathComponent("out/region.lungfishfastq")
        let arguments = [
            "--by-region", "--bam", bam.path, "--index", index.path, "--region", "MT192765.1:1-3000",
            "--min-mapq", "1", "--exclude-flags", "2308", "--bundle-name", "selected-region", "--output", bundle.path,
        ]

        let (events, output) = try await run(arguments)

        XCTAssertNil(output.thrown, output.standardError.joined(separator: "\n"))
        guard case .complete(let outputs, _)? = events.last else { return XCTFail("no complete event: \(events)") }
        XCTAssertEqual(outputs, ["/work/out/region.lungfishfastq"])
        XCTAssertFalse(try readNames(bundle.appendingPathComponent("selected-region.fastq")).isEmpty)
        let record = try record(of: bundle)
        XCTAssertEqual(record.argv, [CLICommandIdentity.executableName, "extract", "reads"] + arguments, "the record names the command")
        XCTAssertEqual(record.durableReplayArgv, record.argv)
        XCTAssertEqual(record.tool.kind, "cli")
        XCTAssertEqual(record.toolVersion, LungfishAppVersion.short)
        XCTAssertEqual(record.options.explicit["minimumMapQ"], .integer(1))
        XCTAssertEqual(record.options.explicit["excludedFlags"], .integer(2308))
        XCTAssertTrue(record.steps.contains { $0.argv.contains("-X") && $0.argv.contains("2308") }, "samtools reads the explicit index with the filters")
    }

    func testSelectedReadsComeFromANamesFileThatTheRecordNamesWithItsDigest() async throws {
        guard SamtoolsLocator.locate() != nil else { throw XCTSkip("The managed samtools is not installed.") }
        let (bam, index) = try evidence()
        let names = try scratch.write("out/S1.read-names.txt", "ERR5069949.114870\nERR5069949.29668\n")
        let bundle = scratch.root.appendingPathComponent("out/S1.lungfishfastq")
        let arguments = [
            "--by-id", "--ids", names.path, "--bam", bam.path, "--index", index.path,
            "--records-without-sequence", "1", "--bundle-name", "S1_selected_2reads", "--output", bundle.path,
        ]

        let (events, output) = try await run(arguments)

        XCTAssertNil(output.thrown, output.standardError.joined(separator: "\n"))
        guard case .complete(let outputs, _)? = events.last else { return XCTFail("no complete event: \(events)") }
        XCTAssertEqual(outputs, ["/work/out/S1.lungfishfastq"])
        XCTAssertEqual(try readNames(bundle.appendingPathComponent("S1_selected_2reads.fastq")), ["ERR5069949.114870", "ERR5069949.29668"])
        let record = try record(of: bundle)
        XCTAssertEqual(record.argv, [CLICommandIdentity.executableName, "extract", "reads"] + arguments)
        let digest = try ProvenanceFileHasher.sha256(of: names)
        XCTAssertTrue(record.files.contains { $0.role == .input && $0.path == names.path && $0.checksumSHA256 == digest }, "the record names the names file")
        XCTAssertEqual(record.options.resolvedDefaults["recordsWithoutSequence"], .integer(1))
        XCTAssertEqual(record.options.resolvedDefaults["missingSequenceMessage"], .string("1 selected alignment record(s) did not contain sequence."))
    }

    // MARK: - Refusals

    func testTheEvidenceOptionsNeedTheIndexAndTheIndexPublishesABundle() {
        XCTAssertThrowsError(try ExtractReadsSubcommand.parse([
            "--by-region", "--bam", "a.bam", "--region", "c:1-2", "--min-mapq", "5", "-o", "a.fastq",
        ]), "--min-mapq needs --index")
        XCTAssertThrowsError(try ExtractReadsSubcommand.parse([
            "--by-region", "--bam", "a.bam", "--index", "a.bam.bai", "--region", "c:1-2", "-o", "a.fastq",
        ]), "with --index the output is a bundle")
        XCTAssertThrowsError(try ExtractReadsSubcommand.parse([
            "--by-id", "--ids", "n.txt", "--bam", "a.bam", "--index", "a.bam.bai", "--min-mapq", "5", "-o", "a.lungfishfastq",
        ]), "the filters apply to a region")
        XCTAssertNoThrow(try ExtractReadsSubcommand.parse([
            "--by-region", "--bam", "a.bam", "--index", "a.bam.bai", "--region", "c:1-2", "-o", "a.lungfishfastq",
        ]))
        XCTAssertNoThrow(try ExtractReadsSubcommand.parse([
            "--by-id", "--ids", "n.txt", "--source", "r1.fastq", "--keep-read-pairs", "--bam", "a.bam", "--index", "a.bam.bai",
            "-o", "a.lungfishfastq",
        ]), "with --index, --source and --bam go together")
    }

    // MARK: - A region that is not on the evidence (review A51, F2)

    /// What a refused run leaves, as `bam consensus` leaves it: the start and the failure that names the
    /// fix, exit 3, the sentence on standard error, and nothing written, no bundle and no record.
    private func assertRefused(
        _ events: [CLIEvent], _ output: ImportStreamCapture.Output, message: String, bundle: URL,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertEqual((output.thrown as? ExitCode)?.rawValue, CLIExitCode.inputError.rawValue, "a refusal exits 3: \(String(describing: output.thrown))", file: file, line: line)
        XCTAssertEqual(events, [.start(message: ExtractReadsSubcommand.startMessage), .failed(message: message, detail: nil)], file: file, line: line)
        XCTAssertTrue(output.standardError.contains { $0.contains(message) }, "the refusal is printed: \(output.standardError)", file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.path), "a refusal publishes no bundle", file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: bundle).path), "a refusal records nothing", file: file, line: line)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: bundle.deletingLastPathComponent().path), [], "a refusal writes nothing", file: file, line: line)
    }

    /// `bam consensus` refuses a contig the header does not name before samtools reads a base, and the
    /// region run, which the viewer's Extract Reads in Selected Region now runs, let samtools answer.
    func testARegionOnAContigTheHeaderDoesNotNameIsRefusedBeforeSamtoolsReadsIt() async throws {
        guard SamtoolsLocator.locate() != nil else { throw XCTSkip("The managed samtools is not installed.") }
        let (bam, index) = try evidence()
        let bundle = scratch.root.appendingPathComponent("out/region.lungfishfastq")

        let (events, output) = try await run([
            "--by-region", "--bam", bam.path, "--index", index.path, "--region", "NC_045512.2:1-3000", "--output", bundle.path,
        ])

        try assertRefused(
            events, output, message: "The alignment has no contig named NC_045512.2. Name one of its contigs in --region.", bundle: bundle
        )
    }

    /// samtools stops a region at the end of its contig without a word, so a bundle named for
    /// `MT192765.1:1-30000` would hold the reads of `MT192765.1:1-29829`.
    func testARegionThatEndsPastTheContigIsRefusedInsteadOfPublishedShort() async throws {
        guard SamtoolsLocator.locate() != nil else { throw XCTSkip("The managed samtools is not installed.") }
        let (bam, index) = try evidence()
        let bundle = scratch.root.appendingPathComponent("out/region.lungfishfastq")

        let (events, output) = try await run([
            "--by-region", "--bam", bam.path, "--index", index.path, "--region", "MT192765.1:1-30000", "--output", bundle.path,
        ])

        try assertRefused(
            events, output, message: "The region ends at 30000, past the end of MT192765.1 at 29829.", bundle: bundle
        )
    }

    /// Every region is checked, so a good region before a bad one does not carry the run.
    func testOneRegionOffTheEvidenceRefusesTheWholeRun() async throws {
        guard SamtoolsLocator.locate() != nil else { throw XCTSkip("The managed samtools is not installed.") }
        let (bam, index) = try evidence()
        let bundle = scratch.root.appendingPathComponent("out/region.lungfishfastq")

        let (events, output) = try await run([
            "--by-region", "--bam", bam.path, "--index", index.path, "--region", "MT192765.1:1-3000",
            "--region", "MT192765.1:29000-29830", "--output", bundle.path,
        ])

        try assertRefused(
            events, output, message: "The region ends at 29830, past the end of MT192765.1 at 29829.", bundle: bundle
        )
    }

    /// The guard refuses what is off the evidence and nothing else, so a region that ends on the
    /// contig's last base and a contig named without coordinates still publish.
    func testARegionOnTheEvidenceStillPublishesWhenItEndsOnTheLastBaseOrNamesTheWholeContig() async throws {
        guard SamtoolsLocator.locate() != nil else { throw XCTSkip("The managed samtools is not installed.") }
        let (bam, index) = try evidence()
        for (name, region) in [("last-base", "MT192765.1:28000-29829"), ("whole-contig", "MT192765.1")] {
            let bundle = scratch.root.appendingPathComponent("out/\(name).lungfishfastq")

            let (events, output) = try await run([
                "--by-region", "--bam", bam.path, "--index", index.path, "--region", region, "--output", bundle.path,
            ])

            XCTAssertNil(output.thrown, "\(region): \(output.standardError.joined(separator: "\n"))")
            guard case .complete(let outputs, _)? = events.last else { return XCTFail("\(region): no complete event: \(events)") }
            XCTAssertEqual(outputs, ["/work/out/\(name).lungfishfastq"], region)
        }
    }

    /// The refusal comes before the stager, so a refused region costs no samtools extraction.
    func testARegionOffTheEvidenceNeverReachesTheStager() async throws {
        struct StagerRan: Error {}
        let (bam, index) = try evidence()
        var stages = ExtractReadsEvidenceStages()
        stages.header = { _ in "@SQ\tSN:MT192765.1\tLN:29829\n" }
        stages.region = { _ in throw StagerRan() }
        let refusals = [
            ("NC_045512.2:1-3000", "The alignment has no contig named NC_045512.2. Name one of its contigs in --region."),
            ("MT192765.1:1-29830", "The region ends at 29830, past the end of MT192765.1 at 29829."),
        ]
        for (region, message) in refusals {
            let invocation = AlignmentReadExtractionInvocation(
                alignmentURL: bam, indexURL: index, decodingReferenceURL: nil,
                selection: .regions([region], minimumMapQ: nil, excludedFlags: nil, readGroups: []),
                readsName: "r", outputURL: scratch.root.appendingPathComponent("out/region.lungfishfastq")
            )

            do {
                _ = try await ExtractReadsSubcommand.extractEvidence(invocation, stages: stages)
                XCTFail("\(region) is not on the evidence")
            } catch let refusal as ExtractReadsRefusal {
                XCTAssertEqual(refusal.message, message, region)
            }
        }
    }

    /// The forms samtools takes for a region, read against a header that holds a contig with colons in its name.
    func testTheRegionFormsSamtoolsTakesAreReadAgainstTheHeader() {
        let header = "@HD\tVN:1.6\tSO:coordinate\n@SQ\tSN:chr1\tLN:1000\n@SQ\tSN:HLA-A*01:01\tLN:500\n@PG\tID:x\n"
        func refusal(_ region: String) -> String? {
            if case .failure(let refusal) = AlignmentRegionOnEvidence.contigLength(ofRegion: region, inHeader: header) { return refusal.message }
            return nil
        }
        func noContig(_ name: String) -> String { "The alignment has no contig named \(name). Name one of its contigs in --region." }

        for region in [
            "chr1", "chr1:1-1000", "chr1:1,000", "chr1:500-", "chr1:-1000", "chr1:1-1,000",
            "HLA-A*01:01", "HLA-A*01:01:100-200", "{HLA-A*01:01}:100-200",
        ] {
            XCTAssertNil(refusal(region), "\(region) is on the evidence")
        }
        XCTAssertEqual(refusal("chr1:1-1001"), "The region ends at 1001, past the end of chr1 at 1000.")
        XCTAssertEqual(refusal("chr1:-1001"), "The region ends at 1001, past the end of chr1 at 1000.")
        XCTAssertEqual(refusal("chr1:1,001"), "The region starts at 1001, past the end of chr1 at 1000.")
        XCTAssertEqual(refusal("chr1:1001-"), "The region starts at 1001, past the end of chr1 at 1000.")
        XCTAssertEqual(refusal("HLA-A*01:01:100-501"), "The region ends at 501, past the end of HLA-A*01:01 at 500.")
        XCTAssertEqual(refusal("chr2:1-10"), noContig("chr2"))
        XCTAssertEqual(refusal("chr2"), noContig("chr2"))
        XCTAssertEqual(refusal("chr1:abc"), noContig("chr1:abc"), "a text that reads as no range names a contig the header lacks")
        XCTAssertEqual(refusal("chr1:"), noContig("chr1:"))
        XCTAssertEqual(refusal("*"), noContig("*"), "the unmapped reads are no region")
        XCTAssertEqual(refusal("."), noContig("."), "a region never falls back to all reads")
    }

    // MARK: - The second check and the cancel

    /// What a stand-in stager hands back, a staged FASTQ.
    private static func stagedTransaction(in root: URL) throws -> AlignmentReadExtractionTransaction {
        let staging = root.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let payload = staging.appendingPathComponent("r.fastq")
        try "@read-1\nACGT\n+\nIIII\n".write(to: payload, atomically: true, encoding: .utf8)
        return try AlignmentReadExtractionTransaction(
            stagingDirectoryURL: staging,
            stagedFiles: [.init(stagedURL: payload, relativeFinalPath: "r.fastq", format: .fastq)],
            readCount: 1,
            pairedEnd: false
        )
    }

    /// The coordinator's second scientific gate, now the leaf's: evidence whose bytes changed after
    /// the staging is never published, and the staging goes.
    func testEvidenceThatChangesBeforePublicationIsRefusedAndNothingIsPublished() async throws {
        let (bam, index) = try evidence()
        let bundle = scratch.root.appendingPathComponent("out/region.lungfishfastq")
        let invocation = AlignmentReadExtractionInvocation(
            alignmentURL: bam, indexURL: index, decodingReferenceURL: nil,
            selection: .regions(["MT192765.1:1-3000"], minimumMapQ: nil, excludedFlags: nil, readGroups: []),
            readsName: "r", outputURL: bundle
        )
        let root = scratch.root
        var stages = ExtractReadsEvidenceStages()
        stages.header = { _ in "@SQ\tSN:MT192765.1\tLN:29829\n" }
        stages.region = { _ in try Self.stagedTransaction(in: root) }
        stages.beforeSecondCheck = { try Data("other bytes".utf8).write(to: bam) }

        do {
            _ = try await ExtractReadsSubcommand.extractEvidence(invocation, stages: stages)
            XCTFail("changed evidence is never published")
        } catch let failure as AlignmentReadExtractionFailure {
            XCTAssertEqual(failure.kind, .staleInput)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.path))
        let staged = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("staging-") }
        XCTAssertTrue(try staged.allSatisfy { try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent($0).path).isEmpty } || staged.isEmpty)
    }

    func testSIGTERMWhileTheRunHashesRecordsItCancelledBesideTheBundleAndPublishesNothing() async throws {
        let (bam, _) = try evidence()
        let index = scratch.root.appendingPathComponent("evidence/sparse.bam.bai")
        XCTAssertTrue(FileManager.default.createFile(atPath: index.path, contents: nil))
        let handle = try FileHandle(forWritingTo: index)
        try handle.truncate(atOffset: 64 << 30)
        try handle.close()
        let bundle = scratch.root.appendingPathComponent("out/region.lungfishfastq")
        let record = ProvenanceRecorder.fileSidecarURL(for: bundle)

        let cli = try CLISIGTERMHarness.launchCLI([
            "extract", "reads", "--by-region", "--bam", bam.path, "--index", index.path,
            "--region", "MT192765.1:1-3000", "--output", bundle.path, "--format", "json",
        ], testClass: Self.self)
        defer { cli.stop() }

        let pid = cli.processIdentifier
        let atWork = await waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(20)) {
            OpenFileProbe.process(pid, holdsOpen: index.path)
        }
        guard atWork else {
            let stop = await CLISIGTERMHarness.cancel(cli)
            return XCTFail("The CLI never opened the index to hash it.\(stop.diagnostics)")
        }

        let stop = await CLISIGTERMHarness.assertSIGTERMCancels(cli) {
            try ProvenanceEnvelopeReader.load(fromSidecar: record)?.status.rawValue
        }
        XCTAssertTrue(stop.standardOutput.contains("Read extraction cancelled"), stop.diagnostics)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.path), "a cancel publishes no bundle")
        XCTAssertEqual(try ProvenanceEnvelopeReader.load(fromSidecar: record)?.argv.prefix(3), ["lungfish-cli", "extract", "reads"])
    }
}
