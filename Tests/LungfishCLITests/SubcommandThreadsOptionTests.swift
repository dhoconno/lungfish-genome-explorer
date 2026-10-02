// SubcommandThreadsOptionTests.swift - A subcommand's thread count reaches it through the real root parser
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The root command parses `--threads` and `-t` (GlobalOptions) before any
// subcommand, wherever they appear on the command line, and removes them from
// the arguments the subcommand sees. Seven subcommands declared a `--threads`
// option of their own, which therefore never received a value, so the thread
// count the app passes was silently replaced by the subcommand's default
// (R3, R4). They now read the global value and keep their own default when
// none is given. Every test here parses through `LungfishCLI.parseAsRoot`
// after `normalizedArgumentsForParsing`, as `LungfishCLIMain.main` does. The
// other options of each command line are asserted too, so a command line that
// parsed before parses to the same values now.

import ArgumentParser
import XCTest
@testable import LungfishCLI

final class SubcommandThreadsOptionTests: XCTestCase {

    /// Parses `arguments` the way the shipped binary does and requires `type`.
    private func parse<Command: ParsableCommand>(
        _ arguments: [String],
        as type: Command.Type,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Command {
        let parsed = try LungfishCLI.parseAsRoot(LungfishCLI.normalizedArgumentsForParsing(arguments))
        return try XCTUnwrap(parsed as? Command, "parsed \(Swift.type(of: parsed))", file: file, line: line)
    }

    // MARK: - Each subcommand with its own thread count

    func testVariantsPhaseReceivesTheThreadCount() throws {
        let arguments = [
            "variants", "phase",
            "--reference", "/tmp/lane 1k1/ref.fa",
            "--bam", "/tmp/lane 1k1/in.bam",
            "--output-vcf", "/tmp/lane 1k1/out.vcf.gz",
            "--output-dir", "/tmp/lane 1k1/plan",
            "--sample", "S1",
            "--extra-gatk-args", "--min-base-quality-score 20",
            "--extra-whatshap-args", "--ignore-read-groups",
            "--dry-run",
        ]
        let command = try parse(arguments + ["--threads", "6"], as: VariantsCommand.PhaseSubcommand.self)
        XCTAssertEqual(command.threads, 6)
        XCTAssertEqual(command.reference, "/tmp/lane 1k1/ref.fa")
        XCTAssertEqual(command.bam, "/tmp/lane 1k1/in.bam")
        XCTAssertEqual(command.outputVCF, "/tmp/lane 1k1/out.vcf.gz")
        XCTAssertEqual(command.outputDirectory, "/tmp/lane 1k1/plan")
        XCTAssertEqual(command.sampleName, "S1")
        XCTAssertEqual(command.extraGATKArgs, "--min-base-quality-score 20")
        XCTAssertEqual(command.extraWhatsHapArgs, "--ignore-read-groups")
        XCTAssertTrue(command.dryRun)
        XCTAssertFalse(command.execute)

        XCTAssertEqual(try parse(arguments, as: VariantsCommand.PhaseSubcommand.self).threads, 1)
    }

    func testPBAAClusterReceivesTheThreadCount() throws {
        let arguments = [
            "fastq", "pbaa-cluster", "/tmp/lane 1k1/reads.fastq",
            "--guide", "/tmp/lane 1k1/guide.fasta",
            "--output-dir", "/tmp/lane 1k1/out",
            "--output-name", "sample",
            "--seed", "7",
            "--extra-args", "--min-cluster-read-count 2",
        ]
        let command = try parse(arguments + ["--threads", "6"], as: FastqPBAAClusterSubcommand.self)
        XCTAssertEqual(command.threads, 6)
        XCTAssertEqual(command.input, "/tmp/lane 1k1/reads.fastq")
        XCTAssertEqual(command.guide, "/tmp/lane 1k1/guide.fasta")
        XCTAssertEqual(command.outputDir, "/tmp/lane 1k1/out")
        XCTAssertEqual(command.outputName, "sample")
        XCTAssertEqual(command.seed, 7)
        XCTAssertEqual(command.extraArgs, "--min-cluster-read-count 2")

        XCTAssertEqual(
            try parse(arguments, as: FastqPBAAClusterSubcommand.self).threads,
            max(1, ProcessInfo.processInfo.activeProcessorCount)
        )
    }

    func testSavontClusterReceivesTheThreadCount() throws {
        let arguments = [
            "fastq", "savont-cluster", "/tmp/lane 1k1/reads.fastq.gz",
            "--output", "/tmp/lane 1k1/clusters.fa",
            "--quality-value-cutoff", "85",
            "--min-cluster-size", "7",
            "--min-read-length", "500",
            "--max-read-length", "5000",
            "--single-strand",
        ]
        let command = try parse(arguments + ["--threads", "6"], as: FastqSavontClusterSubcommand.self)
        XCTAssertEqual(command.threads, 6)
        XCTAssertEqual(command.input, "/tmp/lane 1k1/reads.fastq.gz")
        XCTAssertEqual(command.output, "/tmp/lane 1k1/clusters.fa")
        XCTAssertEqual(command.qualityValueCutoff, 85)
        XCTAssertEqual(command.minimumClusterSize, 7)
        XCTAssertEqual(command.minimumReadLength, 500)
        XCTAssertEqual(command.maximumReadLength, 5000)
        XCTAssertTrue(command.singleStrand)
        XCTAssertEqual(try command.makeRequestForTesting().threads, 6, "the request Savont runs carries the count")

        XCTAssertEqual(
            try parse(arguments, as: FastqSavontClusterSubcommand.self).threads,
            max(1, ProcessInfo.processInfo.activeProcessorCount)
        )
    }

    func testEntropyFilterReceivesTheThreadCount() throws {
        let arguments = [
            "fastq", "entropy-filter", "/tmp/lane 1k1/reads.fastq",
            "--entropy", "0.7",
            "--window", "40",
            "--kmer", "4",
            "--pairing", "single",
            "-o", "/tmp/lane 1k1/filtered.fastq",
            "--force",
        ]
        let command = try parse(arguments + ["--threads", "6"], as: FastqEntropyFilterSubcommand.self)
        XCTAssertEqual(command.threads, 6)
        XCTAssertEqual(command.input, "/tmp/lane 1k1/reads.fastq")
        XCTAssertEqual(command.entropy, 0.7)
        XCTAssertEqual(command.window, 40)
        XCTAssertEqual(command.kmer, 4)
        XCTAssertEqual(command.pairing.pairing, .single)
        XCTAssertEqual(command.output.output, "/tmp/lane 1k1/filtered.fastq")
        XCTAssertTrue(command.output.force)
        XCTAssertFalse(command.output.compress)

        XCTAssertEqual(try parse(arguments, as: FastqEntropyFilterSubcommand.self).threads, 4)
    }

    func testDemultiplexReceivesTheThreadCount() throws {
        let arguments = [
            "fastq", "demultiplex", "/tmp/lane 1k1/reads.fastq",
            "--kit", "truseq-single-a",
            "-o", "/tmp/lane 1k1/demux",
            "--location", "5prime",
            "--max-distance-5prime", "2",
            "--max-distance-3prime", "1",
            "--error-rate", "0.1",
            "--overlap", "4",
            "--engine", "cutadapt",
            "--no-trim",
            "--discard-unassigned",
            "--replace",
        ]
        let command = try parse(arguments + ["--threads", "6"], as: FastqDemultiplexSubcommand.self)
        XCTAssertEqual(command.threads, 6)
        XCTAssertEqual(command.input, "/tmp/lane 1k1/reads.fastq")
        XCTAssertEqual(command.kit, "truseq-single-a")
        XCTAssertEqual(command.output, "/tmp/lane 1k1/demux")
        XCTAssertEqual(command.location, "5prime")
        XCTAssertEqual(command.maxDistanceFrom5Prime, 2)
        XCTAssertEqual(command.maxDistanceFrom3Prime, 1)
        XCTAssertEqual(command.errorRate, 0.1)
        XCTAssertEqual(command.overlap, 4)
        XCTAssertEqual(command.engine, "cutadapt")
        XCTAssertTrue(command.noTrim)
        XCTAssertTrue(command.discardUnassigned)
        XCTAssertTrue(command.replace)

        XCTAssertEqual(try parse(arguments, as: FastqDemultiplexSubcommand.self).threads, 4)
    }

    func testONTFluidigmSamplesReceivesTheThreadCount() throws {
        let arguments = [
            "fastq", "ont-fluidigm-samples", "/tmp/lane 1k1/reads.fastq",
            "--barcodes", "/tmp/lane 1k1/barcodes.csv",
            "--output", "/tmp/lane 1k1/samples",
            "--primer-mismatches", "1",
            "--minimum-insert-length", "30",
            "--canonicalize-reverse-complements",
            "--force",
        ]
        let command = try parse(arguments + ["--threads", "6"], as: FastqONTFluidigmSamplesSubcommand.self)
        XCTAssertEqual(command.threads, 6)
        XCTAssertEqual(command.input, "/tmp/lane 1k1/reads.fastq")
        XCTAssertEqual(command.barcodes, "/tmp/lane 1k1/barcodes.csv")
        XCTAssertEqual(command.output, "/tmp/lane 1k1/samples")
        XCTAssertEqual(command.primerMismatches, 1)
        XCTAssertEqual(command.minimumInsertLength, 30)
        XCTAssertTrue(command.canonicalizeReverseComplements)
        XCTAssertTrue(command.force)

        XCTAssertEqual(try parse(arguments, as: FastqONTFluidigmSamplesSubcommand.self).threads, 1)
    }

    func testONTPacBioBarcodeDemuxReceivesTheThreadCount() throws {
        let arguments = [
            "fastq", "ont-pacbio-barcode-demux", "/tmp/lane 1k1/reads.fastq",
            "--barcodes", "/tmp/lane 1k1/pairs.csv",
            "--output", "/tmp/lane 1k1/samples",
            "--chunk-jobs", "2",
            "--max-reads-per-slice", "50000",
            "--max-bytes-per-cutadapt", "1048576",
            "--force",
        ]
        let command = try parse(arguments + ["--threads", "6"], as: FastqONTPacBioBarcodeDemuxSubcommand.self)
        XCTAssertEqual(command.threads, 6)
        XCTAssertEqual(command.input, "/tmp/lane 1k1/reads.fastq")
        XCTAssertEqual(command.barcodes, "/tmp/lane 1k1/pairs.csv")
        XCTAssertEqual(command.output, "/tmp/lane 1k1/samples")
        XCTAssertEqual(command.chunkJobs, 2)
        XCTAssertEqual(command.maxReadsPerSlice, 50_000)
        XCTAssertEqual(command.maxBytesPerCutadapt, 1_048_576)
        XCTAssertTrue(command.force)

        XCTAssertEqual(try parse(arguments, as: FastqONTPacBioBarcodeDemuxSubcommand.self).threads, 1)
    }

    // MARK: - Every spelling of the option

    /// `--threads N`, `--threads=N`, `-t N` and a `--threads` before the
    /// subcommand all reach it, as they reach every other subcommand.
    func testEverySpellingOfTheThreadCountReachesTheSubcommand() throws {
        let tail = ["/tmp/lane 1k1/reads.fastq", "--output", "/tmp/lane 1k1/clusters.fa"]
        let spellings: [[String]] = [
            ["fastq", "savont-cluster"] + tail + ["--threads", "3"],
            ["fastq", "savont-cluster"] + tail + ["--threads=3"],
            ["fastq", "savont-cluster"] + tail + ["-t", "3"],
            ["fastq", "savont-cluster", "--threads", "3"] + tail,
            ["--threads", "3", "fastq", "savont-cluster"] + tail,
        ]
        for arguments in spellings {
            let command = try parse(arguments, as: FastqSavontClusterSubcommand.self)
            XCTAssertEqual(command.threads, 3, arguments.joined(separator: " "))
        }
    }

    // MARK: - No subcommand declares a thread option of its own

    /// A `--threads` that a subcommand declares itself never receives a value,
    /// because the root takes it first. Every command that offers a thread
    /// count must offer the global `-t, --threads`.
    func testNoCommandDeclaresAThreadOptionTheRootWouldTake() {
        var offenders: [String] = []
        func visit(_ type: ParsableCommand.Type, path: String) {
            // Only an OPTIONS section lists options. The global option prints
            // as "-t, --threads", and an option a command declares itself
            // prints as "--threads".
            let help = type.helpMessage(includeHidden: true, columns: 400)
            var inOptions = false
            for line in help.split(separator: "\n", omittingEmptySubsequences: false) {
                if !line.hasPrefix(" "), line.hasSuffix(":") {
                    inOptions = line.hasSuffix("OPTIONS:")
                    continue
                }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if inOptions, trimmed.hasPrefix("--threads ") || trimmed.hasPrefix("--threads,") {
                    offenders.append(path)
                }
            }
            for subcommand in type.configuration.subcommands {
                let name = subcommand.configuration.commandName ?? String(describing: subcommand)
                visit(subcommand, path: "\(path) \(name)")
            }
        }
        visit(LungfishCLI.self, path: "lungfish-cli")
        XCTAssertEqual(offenders, [], "commands that declare their own --threads")
    }
}
