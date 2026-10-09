// ONTGenotypingAlignmentCharacterizationTests.swift - Pins MHC alignment output with the real managed tools
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import XCTest
import LungfishTestSupport
@testable import LungfishCore
@testable import LungfishWorkflow

/// Characterization of the two MHC genotyping alignment paths that launch
/// minimap2 and samtools themselves: the amplicon pipeline's minimap2 into
/// samtools sort pipe, and the full-length ONT cohort alignment builder.
///
/// The expected values were captured with the managed minimap2 and samtools
/// before those launches moved to ToolProcess, and must not change: a change
/// here is a change to the genotype calls. Each test runs only when the
/// managed tools exist, under `LUNGFISH_CHARACTERIZATION_CONDA_ROOT` or else
/// `~/.lungfish/conda`, and skips otherwise.
final class ONTGenotypingAlignmentCharacterizationTests: XCTestCase {
    // MARK: Amplicon pipeline (minimap2 | samtools sort)

    func testIlluminaCohortMappingPipeIsByteStable() async throws {
        let conda = try Self.managedCondaRoot(requiring: [
            ("minimap2", "minimap2"), ("samtools", "samtools"), ("pysam", "python"), ("openpyxl", "python"),
        ])
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let alleles = Self.alleles(count: 3, length: 300, seed: 11)
        let referenceURL = root.appendingPathComponent("alleles.fa")
        try Self.fasta(alleles).write(to: referenceURL, atomically: true, encoding: .utf8)
        let sampleA = try Self.mergedReadBundle(root: root, name: "DW001", reads: [
            (alleles[0].sequence, 12), (alleles[1].sequence, 7),
        ])
        let sampleB = try Self.mergedReadBundle(root: root, name: "DW002", reads: [
            (alleles[2].sequence, 9), (Self.mutated(alleles[0].sequence, at: [40, 151]), 4),
        ])
        let outputDirectory = root.appendingPathComponent("cohort.lungfishgenotype", isDirectory: true)
        let request = ONTBarcodeDemuxGenotypingRunRequest(
            inputFASTQURLs: [sampleA, sampleB],
            referenceSourceURL: referenceURL,
            outputDirectory: outputDirectory,
            outputName: "cohort",
            analysisName: "Cohort",
            threads: 2,
            sortThreads: 2,
            minSupport: 1,
            keepIntermediates: true,
            mode: .illuminaPaired,
            readType: .illumina
        )

        _ = try await ONTBarcodeDemuxGenotypingPipeline(condaManager: CondaManager(rootPrefix: conda)).run(request)

        let samtools = conda.appendingPathComponent("envs/samtools/bin/samtools")
        let mappingDirectory = outputDirectory.appendingPathComponent(".amplicon-genotyping/mapping", isDirectory: true)
        let sampleBAMs = try FileManager.default.contentsOfDirectory(atPath: mappingDirectory.path)
            .filter { $0.hasSuffix(".sorted.bam") }
            .sorted()
        XCTAssertEqual(sampleBAMs, ["001-DW001.sorted.bam", "002-DW002.sorted.bam"])
        var observed: [String: String] = [:]
        for name in sampleBAMs {
            let bam = mappingDirectory.appendingPathComponent(name)
            observed["\(name) records"] = try await Self.recordsHash(of: bam, samtools: samtools)
            observed["\(name) count"] = try await Self.recordCount(of: bam, samtools: samtools)
        }
        observed["merged records"] = try await Self.recordsHash(of: request.mappingBAMURL, samtools: samtools)
        observed["merged count"] = try await Self.recordCount(of: request.mappingBAMURL, samtools: samtools)
        observed["merged idxstats"] = try await Self.idxstats(of: request.mappingBAMURL, samtools: samtools)
        observed["genotypes"] = try String(
            contentsOf: outputDirectory.appendingPathComponent("cohort.retained_demux_genotypes.csv"),
            encoding: .utf8
        )
        observed["samples"] = try String(
            contentsOf: outputDirectory.appendingPathComponent("cohort.retained_demux_samples.csv"),
            encoding: .utf8
        )

        Self.assertEqual(observed, Self.illuminaCohortExpectation)
    }

    func testONTSampleBundleMappingPipeIsByteStable() async throws {
        let conda = try Self.managedCondaRoot(requiring: [
            ("minimap2", "minimap2"), ("samtools", "samtools"), ("pysam", "python"), ("openpyxl", "python"),
        ])
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let alleles = Self.alleles(count: 3, length: 420, seed: 29)
        let referenceURL = root.appendingPathComponent("alleles.fa")
        try Self.fasta(alleles).write(to: referenceURL, atomically: true, encoding: .utf8)
        let sampleA = try Self.mergedReadBundle(root: root, name: "ONT01", reads: [
            (alleles[1].sequence, 6), (Self.mutated(alleles[2].sequence, at: [77]), 5),
        ])
        let outputDirectory = root.appendingPathComponent("ont.lungfishgenotype", isDirectory: true)
        let request = ONTBarcodeDemuxGenotypingRunRequest(
            inputFASTQURLs: [sampleA],
            referenceSourceURL: referenceURL,
            outputDirectory: outputDirectory,
            outputName: "ont",
            analysisName: "ONT",
            threads: 2,
            sortThreads: 1,
            minSupport: 1,
            keepIntermediates: true,
            mode: .ontSampleBundles,
            readType: .ont
        )

        _ = try await ONTBarcodeDemuxGenotypingPipeline(condaManager: CondaManager(rootPrefix: conda)).run(request)

        let samtools = conda.appendingPathComponent("envs/samtools/bin/samtools")
        var observed: [String: String] = [:]
        observed["records"] = try await Self.recordsHash(of: request.mappingBAMURL, samtools: samtools)
        observed["count"] = try await Self.recordCount(of: request.mappingBAMURL, samtools: samtools)
        observed["idxstats"] = try await Self.idxstats(of: request.mappingBAMURL, samtools: samtools)
        observed["genotypes"] = try String(
            contentsOf: outputDirectory.appendingPathComponent("ont.retained_demux_genotypes.csv"),
            encoding: .utf8
        )

        Self.assertEqual(observed, Self.ontSampleBundleExpectation)
    }

    // MARK: Full-length ONT cohort alignment

    func testFullLengthCohortAlignmentIsByteStable() async throws {
        let conda = try Self.managedCondaRoot(requiring: [("minimap2", "minimap2"), ("samtools", "samtools")])
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let alleles = Self.alleles(count: 4, length: 900, seed: 47)
        let referenceURL = root.appendingPathComponent("alleles.fa")
        try Self.fasta(alleles).write(to: referenceURL, atomically: true, encoding: .utf8)
        func sample(_ id: String, _ clusters: [(name: String, sequence: String)]) throws -> FullLengthONTMHCSampleAlignmentInput {
            let url = root.appendingPathComponent("\(id).clusters.fa")
            try Self.fasta(clusters).write(to: url, atomically: true, encoding: .utf8)
            return FullLengthONTMHCSampleAlignmentInput(
                sampleID: id,
                originalClustersFASTAURL: url,
                clusterRecords: clusters.map { .init(name: $0.name, sequence: $0.sequence, readCount: 1) }
            )
        }
        let samples = [
            try sample("S1", [
                ("cluster-1", alleles[0].sequence),
                ("cluster-2", Self.mutated(alleles[1].sequence, at: [100, 455, 801])),
            ]),
            try sample("S2", [
                ("cluster-1", alleles[3].sequence),
                ("cluster-2", String(alleles[2].sequence.dropFirst(60))),
            ]),
        ]
        let builder = FullLengthONTMHCCohortAlignmentBuilder(
            minimap2ExecutableURL: conda.appendingPathComponent("envs/minimap2/bin/minimap2"),
            samtoolsExecutableURL: conda.appendingPathComponent("envs/samtools/bin/samtools")
        )
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let result = try await builder.build(.init(
            samples: samples,
            referenceAlleleFASTAURL: referenceURL,
            threads: 2,
            outputDirectoryURL: root.appendingPathComponent("result.lungfishgenotype", isDirectory: true),
            workDirectoryURL: work,
            keepIntermediates: true
        ))
        XCTAssertTrue(result.commandRecords.allSatisfy { $0.exitStatus == 0 && !$0.wasCancelled })

        let samtools = conda.appendingPathComponent("envs/samtools/bin/samtools")
        var observed: [String: String] = [:]
        observed["records"] = try await Self.recordsHash(of: result.bamURL, samtools: samtools)
        observed["count"] = try await Self.recordCount(of: result.bamURL, samtools: samtools)
        observed["idxstats"] = try await Self.idxstats(of: result.bamURL, samtools: samtools)

        let view = try await builder.viewHeaderAndAlignments(
            in: result.bamURL,
            temporaryWorkDirectoryURL: work,
            samtoolsVersion: result.toolVersions.first { $0.toolName == "samtools" }?.version ?? ""
        )
        let samRecords = try String(contentsOf: view.samURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("@") }
            .joined(separator: "\n")
        observed["view records"] = Self.sha256(Data(samRecords.utf8))
        XCTAssertEqual(view.commandRecord.exitStatus, 0)

        Self.assertEqual(observed, Self.fullLengthExpectation)
    }

    // MARK: Expectations captured before the ToolProcess move

    static let illuminaCohortExpectation: [String: String] = [
        "001-DW001.sorted.bam count": "19",
        "001-DW001.sorted.bam records": "e45c0a0b4d3c42be62570ed9744cd53855d8dc47335c08f0601bfccf3e12a495",
        "002-DW002.sorted.bam count": "13",
        "002-DW002.sorted.bam records": "06a3a78f15a917be44510cc69a6d4946552ada3962a3d543ca4508641d0cdfd5",
        "genotypes": "sample,genotype,passed_alignments,passed_unique_reads,sample_total_reads,sample_unique_retained_reads,sample_unique_retained_percent,overall_input_reads,overall_unique_retained_reads,overall_unique_retained_percent\r\nDW001,Mamu-T1*01:01,12,12,19,19,100.000000,32,28,87.500000\r\nDW001,Mamu-T2*01:02,7,7,19,19,100.000000,32,28,87.500000\r\nDW002,Mamu-T3*01:03,9,9,13,9,69.230769,32,28,87.500000\r\n",
        "merged count": "32",
        "merged idxstats": "Mamu-T1*01:01\t300\t16\t0\nMamu-T2*01:02\t300\t7\t0\nMamu-T3*01:03\t300\t9\t0\n*\t0\t0\t0\n",
        "merged records": "ae10a29a28eb6ae30981c63cb193bf5cce33417fa9b1881e195adf9e96a23990",
        "samples": "sample,passed_alignments,passed_unique_reads,sample_total_reads,sample_unique_retained_percent,overall_input_reads,overall_unique_retained_percent\r\nDW001,19,19,19,100.000000,32,87.500000\r\nDW002,9,9,13,69.230769,32,87.500000\r\n",
    ]
    static let ontSampleBundleExpectation: [String: String] = [
        "count": "17",
        "genotypes": "sample,genotype,passed_alignments,passed_unique_reads,sample_total_reads,sample_unique_retained_reads,sample_unique_retained_percent,overall_input_reads,overall_unique_retained_reads,overall_unique_retained_percent\r\n",
        "idxstats": "Mamu-T1*01:01\t420\t6\t0\nMamu-T2*01:02\t420\t6\t0\nMamu-T3*01:03\t420\t5\t0\n*\t0\t0\t0\n",
        "records": "d028da320302823b1f32c7ed943d2b104c2c4a8be3baa5cd8d1d9733ed9aaf23",
    ]
    static let fullLengthExpectation: [String: String] = [
        "count": "15",
        "idxstats": "S1|cluster-1\t900\t4\t0\nS1|cluster-2\t900\t4\t0\nS2|cluster-1\t900\t4\t0\nS2|cluster-2\t840\t3\t0\n*\t0\t0\t0\n",
        "records": "a458ea849f3d98e3f47f47a2646fb7218bf88a7f55707ddc94c642d155cb12e3",
        "view records": "a458ea849f3d98e3f47f47a2646fb7218bf88a7f55707ddc94c642d155cb12e3",
    ]

    // MARK: Helpers

    private static func assertEqual(
        _ observed: [String: String],
        _ expected: [String: String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if observed != expected {
            let dump = observed.keys.sorted().map { "\(String(reflecting: $0)): \(String(reflecting: observed[$0]!))," }
            XCTFail("Observed characterization differs:\n" + dump.joined(separator: "\n"), file: file, line: line)
        }
    }

    private static func managedCondaRoot(requiring tools: [(environment: String, name: String)]) throws -> URL {
        let root = ProcessInfo.processInfo.environment["LUNGFISH_CHARACTERIZATION_CONDA_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lungfish/conda", isDirectory: true)
        for tool in tools {
            let path = root.appendingPathComponent("envs/\(tool.environment)/bin/\(tool.name)").path
            guard FileManager.default.isExecutableFile(atPath: path) else {
                try ToolAvailability.skipOrFail("The managed \(tool.name) is not installed at \(path).")
            }
        }
        return root
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ONTGenotypingAlignmentCharacterization-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Deterministic allele sequences from a linear congruential generator.
    static func alleles(count: Int, length: Int, seed: UInt64) -> [(name: String, sequence: String)] {
        var state = seed
        let bases: [Character] = ["A", "C", "G", "T"]
        let backbone = String((0..<length).map { _ -> Character in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return bases[Int((state >> 33) % 4)]
        })
        return (0..<count).map { index in
            var positions: [Int] = []
            for step in 0..<(6 + index * 3) {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                positions.append(Int((state >> 33) % UInt64(length - 20)) + 10 + step % 2)
            }
            return ("Mamu-T\(index + 1)*01:0\(index + 1)", mutated(backbone, at: index == 0 ? [] : positions))
        }
    }

    static func mutated(_ sequence: String, at positions: [Int]) -> String {
        var bases = Array(sequence)
        let next: [Character: Character] = ["A": "C", "C": "G", "G": "T", "T": "A"]
        for position in positions where position < bases.count {
            bases[position] = next[bases[position]] ?? "A"
        }
        return String(bases)
    }

    static func fasta(_ records: [(name: String, sequence: String)]) -> String {
        records.map { ">\($0.name)\n\($0.sequence)\n" }.joined()
    }

    private static func mergedReadBundle(root: URL, name: String, reads: [(sequence: String, copies: Int)]) throws -> URL {
        let bundle = root.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        var text = ""
        var index = 0
        for read in reads {
            for _ in 0..<read.copies {
                index += 1
                text += "@\(name):1:1:1:1:1:\(index)\n\(read.sequence)\n+\n\(String(repeating: "I", count: read.sequence.count))\n"
            }
        }
        try text.write(to: bundle.appendingPathComponent("\(name).fastq"), atomically: true, encoding: .utf8)
        return bundle
    }

    private static func samtools(_ samtools: URL, _ arguments: [String]) async throws -> Data {
        let result = try await ToolProcess.run(ToolProcessSpec(
            executableURL: samtools,
            arguments: arguments,
            environment: ToolProcessSpec.inheritedEnvironment()
        ))
        guard result.isSuccess else {
            throw NSError(domain: "characterization", code: Int(result.status), userInfo: [
                NSLocalizedDescriptionKey: "samtools \(arguments.joined(separator: " ")) failed: \(result.stderrText)",
            ])
        }
        return result.stdout
    }

    /// `samtools view --no-PG <bam> | shasum -a 256`.
    private static func recordsHash(of bam: URL, samtools tool: URL) async throws -> String {
        sha256(try await samtools(tool, ["view", "--no-PG", bam.path]))
    }

    private static func recordCount(of bam: URL, samtools tool: URL) async throws -> String {
        String(decoding: try await samtools(tool, ["view", "-c", bam.path]), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func idxstats(of bam: URL, samtools tool: URL) async throws -> String {
        String(decoding: try await samtools(tool, ["idxstats", bam.path]), as: UTF8.self)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
