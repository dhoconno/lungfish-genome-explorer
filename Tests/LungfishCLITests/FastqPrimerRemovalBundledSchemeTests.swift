// FastqPrimerRemovalBundledSchemeTests.swift - fastq primer-remove runs on the bundled primer schemes without --kmer
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `--kmer` defaulted to 23, longer than the shortest primer of every bundled
// scheme (20 or 22 bases), so a `--ref` run of a whole scheme without `--kmer`
// was refused, and before the refusal it trimmed none of the shorter primers.
// The default is now 15, the Primer Trimming dialog's k (L5, ruling on
// concern 3). The schemes' BEDs place each primer on MN908947.3, so the
// primers are cut from that fixture genome.

import Foundation
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow
import XCTest

final class FastqPrimerRemovalBundledSchemeTests: XCTestCase {
    private var root: URL!
    private var repositoryRoot: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "fastq-primer-remove-schemes")
        repositoryRoot = CLITestBinaryResolver.repositoryRoot(containing: #filePath)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    func testAReferenceRunOfABundledSchemeWithoutKmerTrimsItsPrimers() async throws {
        guard await NativeToolRunner.shared.isToolAvailable(.bbduk) else {
            try ToolAvailability.skipOrFail("bbduk is not available in this test environment")
        }
        let scheme = try BundledScheme(named: "ARTIC-nCoV-2019-V3", repositoryRoot: repositoryRoot)
        let genome = try BundledScheme.genome(repositoryRoot: repositoryRoot)
        let primersURL = root.appendingPathComponent("artic-v3.fasta")
        try scheme.fasta(genome: genome).write(to: primersURL, atomically: true, encoding: .utf8)
        // Full-length reads of amplicon 5, one each way, run from one of its
        // primers to the other.
        let amplicon = try scheme.amplicon(left: "nCoV-2019_5_LEFT", right: "nCoV-2019_5_RIGHT", genome: genome)
        let inputURL = root.appendingPathComponent("artic-v3.fastq")
        try (record("forward", amplicon.sequence) + record("reverse", reverseComplement(amplicon.sequence)))
            .write(to: inputURL, atomically: true, encoding: .utf8)
        let outputURL = root.appendingPathComponent("artic-v3.trimmed.fastq")
        try await FastqPrimerRemovalSubcommand.parse([inputURL.path, "--ref", primersURL.path, "-o", outputURL.path]).run()

        let output = try await InterleavedFASTQFixture.readRecords(at: outputURL)
        XCTAssertEqual(output.map(\.identifier), ["forward", "reverse"])
        XCTAssertEqual(
            output.map(\.sequence), [amplicon.insert, reverseComplement(amplicon.insert)],
            "both primers of amplicon 5 go, from either orientation, and nothing else"
        )
    }

    func testTheDefaultKmerFitsEveryBundledScheme() throws {
        let command = try FastqPrimerRemovalSubcommand.parse(["reads.fastq", "--ref", "primers.fasta", "-o", "trimmed.fastq"])
        let names = try BundledScheme.names(repositoryRoot: repositoryRoot)
        XCTAssertFalse(names.isEmpty)
        for name in names {
            let scheme = try BundledScheme(named: name, repositoryRoot: repositoryRoot)
            XCTAssertLessThanOrEqual(
                command.kmerSize, scheme.shortestPrimer,
                "\(name): a run without --kmer is refused for its \(scheme.shortestPrimer)-base primers"
            )
        }
    }

    // MARK: - Fixture

    /// A primer scheme the app bundles, whose BED places each primer on
    /// MN908947.3.
    struct BundledScheme {
        let name: String
        let primers: [(name: String, start: Int, end: Int, strand: String)]

        static func directory(_ repositoryRoot: URL) -> URL {
            repositoryRoot.appendingPathComponent("Sources/LungfishApp/Resources/PrimerSchemes", isDirectory: true)
        }

        static func names(repositoryRoot: URL) throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: directory(repositoryRoot).path)
                .filter { $0.hasSuffix(".lungfishprimers") }
                .map { String($0.dropLast(".lungfishprimers".count)) }
                .sorted()
        }

        /// MN908947.3, the bundled schemes' reference.
        static func genome(repositoryRoot: URL) throws -> [UInt8] {
            let fasta = repositoryRoot.appendingPathComponent("Tests/Fixtures/sarscov2-srr36291587/MN908947.3.fasta")
            return Array(try String(contentsOf: fasta, encoding: .utf8)
                .split(separator: "\n")
                .filter { !$0.hasPrefix(">") }
                .joined()
                .utf8)
        }

        init(named name: String, repositoryRoot: URL) throws {
            self.name = name
            let bed = Self.directory(repositoryRoot).appendingPathComponent("\(name).lungfishprimers/primers.bed")
            primers = try String(contentsOf: bed, encoding: .utf8).split(separator: "\n").compactMap { line in
                let fields = line.split(separator: "\t")
                guard fields.count >= 6, let start = Int(fields[1]), let end = Int(fields[2]) else { return nil }
                return (String(fields[3]), start, end, String(fields[5]))
            }
        }

        var shortestPrimer: Int {
            primers.map { $0.end - $0.start }.min() ?? 0
        }

        /// The scheme as the FASTA `--ref` takes, each primer as written, so a
        /// right primer is the reverse complement of its site.
        func fasta(genome: [UInt8]) -> String {
            primers.map { primer in
                let site = String(decoding: genome[primer.start..<primer.end], as: UTF8.self)
                let sequence = primer.strand == "-"
                    ? FastqPrimerRemovalReadCorrectnessTests.Amplicons.reverseComplement(site)
                    : site
                return ">\(primer.name)\n\(sequence)\n"
            }.joined()
        }

        /// An amplicon from its left primer's start to its right primer's
        /// end, and the insert between the two primers.
        func amplicon(left: String, right: String, genome: [UInt8]) throws -> (sequence: String, insert: String) {
            let leftPrimer = try XCTUnwrap(primers.first { $0.name == left }, "\(name) lists \(left)")
            let rightPrimer = try XCTUnwrap(primers.first { $0.name == right }, "\(name) lists \(right)")
            return (
                String(decoding: genome[leftPrimer.start..<rightPrimer.end], as: UTF8.self),
                String(decoding: genome[leftPrimer.end..<rightPrimer.start], as: UTF8.self)
            )
        }
    }

    private func record(_ name: String, _ sequence: String) -> String {
        "@\(name)\n\(sequence)\n+\n\(String(repeating: "I", count: sequence.count))\n"
    }

    private func reverseComplement(_ sequence: String) -> String {
        FastqPrimerRemovalReadCorrectnessTests.Amplicons.reverseComplement(sequence)
    }
}
