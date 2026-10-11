// CLIProvenanceSupportVersionTests.swift - What the CLI's own version parser returns on real probe output
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCLI

/// Pins `CLIProvenanceSupport.parseCondaToolVersion`, the third of the three version parsers.
///
/// The other two are pinned from `VersionParserOutputPinTests` in the Workflow tests. This one
/// lives in the CLI target, and production runs it for two tools only, deacon
/// (`FastqDeaconRiboSubcommand`) and ribodetector_cpu (`FastqRiboDetectorSubcommand`). Their
/// outputs are real, captured by running each probe through `micromamba run` from the managed
/// install under `~/.lungfish/conda` on 2026-10-11, with the root written as `/Users/test/.lungfish/conda`.
/// The golden environment holds neither tool.
///
/// It shares four numeric parts, the build suffix and the error markers with the Workflow parsers,
/// still reads a number inside a path and ignores a `v` prefix, and Phase 2.7 merges the three.
final class CLIProvenanceSupportVersionTests: XCTestCase {
    private static let root = "/Users/test/.lungfish/conda"

    private static func lines(_ items: String...) -> String {
        items.joined(separator: "\n") + "\n"
    }

    // MARK: - The two tools production probes

    func testTheTwoProbedToolsReturnTheirVersion() {
        // deacon --version
        XCTAssertEqual(CLIProvenanceSupport.parseCondaToolVersion("deacon 0.16.0\n"), "0.16.0")
        // ribodetector_cpu --version
        XCTAssertEqual(CLIProvenanceSupport.parseCondaToolVersion("ribodetector_cpu 0.3.3\n"), "0.3.3")
    }

    func testEmptyOutputIsNoVersion() {
        XCTAssertNil(CLIProvenanceSupport.parseCondaToolVersion(""))
        XCTAssertNil(CLIProvenanceSupport.parseCondaToolVersion(" \n\n"))
    }

    // MARK: - Output the two tools never print today

    /// ribodetector_cpu is probed with `--version`, then `-h`, then `--help`. Nothing reaches `-h`
    /// while `--version` answers. The help text holds no dotted number and its first line is a usage
    /// line, so no version is recorded (2.6).
    func testHelpTextIsNoVersion() {
        let help = Self.lines(
            "usage: ribodetector_cpu [-h] [-c CONFIG] -l LEN -i [INPUT ...] -o [OUTPUT ...]",
            "                        [-r [RRNA ...]] [-e {rrna,norrna,both,none}]",
            "                        [-t THREADS] [-s SEED] [--chunk_size CHUNK_SIZE]",
            "                        [--log LOG] [--model-file MODEL_FILE] [-v]",
            "",
            "rRNA sequence detector",
            "",
            "options:",
            "  -h, --help            show this help message and exit",
            "  -c CONFIG, --config CONFIG",
            "                        Path of config file",
            "  -l LEN, --len LEN     Sequencing read length. Note: the accuracy reduces for reads shorter than 40.",
            "  -i [INPUT ...], --input [INPUT ...]",
            "                        Path of input sequence files (fasta and fastq), the second file will be considered as second end if two files given.",
            "  -o [OUTPUT ...], --output [OUTPUT ...]",
            "                        Path of the output sequence files after rRNAs removal (same number of files as input). ",
            "                        (Note: 2 times slower to write gz files)",
            "  -r [RRNA ...], --rrna [RRNA ...]",
            "                        Path of the output sequence file of detected rRNAs (same number of files as input)",
            "  -e {rrna,norrna,both,none}, --ensure {rrna,norrna,both,none}",
            "                        Ensure which classificaion has high confidence for paired end reads.",
            "                        norrna: output only high confident non-rRNAs, the rest are clasified as rRNAs;",
            "                        rrna: vice versa, only high confident rRNAs are classified as rRNA and the rest output as non-rRNAs;",
            "                        both: both non-rRNA and rRNA prediction with high confidence;",
            "                        none: give label based on the mean probability of read pair.",
            "                              (Only applicable for paired end reads, discard the read pair when their predicitons are discordant)",
            "  -t THREADS, --threads THREADS",
            "                        Number of threads to use. (default: 20)",
            "  -s SEED, --seed SEED  Random seed.",
            "  --chunk_size CHUNK_SIZE",
            "                        chunk_size * 1024 reads to load each time. ",
            "                        When chunk_size=1000 and threads=20, consumming ~20G memory, better to be multiples of the number of threads..",
            "  --log LOG             Log file name",
            "  --model-file MODEL_FILE",
            "                        Model file path without extension (uses .onnx). Default: packaged model_len70_101.",
            "  -v, --version         show program's version number and exit")
        XCTAssertNil(CLIProvenanceSupport.parseCondaToolVersion(help))
    }

    /// An error line is never a version (2.6). A plain first line still is, as before.
    func testAnErrorLineIsNoVersion() {
        XCTAssertNil(CLIProvenanceSupport.parseCondaToolVersion("ERROR: unknown command '--version'\n"))
        XCTAssertNil(CLIProvenanceSupport.parseCondaToolVersion("Invalid option: --.\n"))
        XCTAssertNil(CLIProvenanceSupport.parseCondaToolVersion("--version is not a valid option\n"))
        XCTAssertEqual(CLIProvenanceSupport.parseCondaToolVersion("nightly-build\n"), "nightly-build")
    }

    /// A version keeps four numeric parts (2.6).
    func testAFourPartVersionIsKept() {
        // gatk --version, the head of the real output.
        let gatk = Self.lines(
            "The Genome Analysis Toolkit (GATK) v4.6.2.0",
            "HTSJDK Version: 4.2.0",
            "Picard Version: 3.4.0",
            "Using GATK jar \(Self.root)/envs/gatk-core/share/gatk4-4.6.2.0-1/gatk-package-4.6.2.0-local.jar")
        XCTAssertEqual(CLIProvenanceSupport.parseCondaToolVersion(gatk), "4.6.2.0")
    }

    /// A local build suffix belongs to the version (2.6).
    func testALocalBuildSuffixIsKept() {
        XCTAssertEqual(
            CLIProvenanceSupport.parseCondaToolVersion("PrimalScheme3-LGE version: 3.3.0+lge.5\n"),
            "3.3.0+lge.5"
        )
        XCTAssertEqual(CLIProvenanceSupport.parseCondaToolVersion("blastn: 2.16.0+\n"), "2.16.0")
    }

    // MARK: - What this parser still reads wrongly

    /// The regex reads the first dotted number in the text, so a number inside a path wins. The two
    /// Workflow parsers skip any token that holds a slash. This parser does not, and the value is
    /// wrong. No tool the CLI probes prints a path first, so production never meets it, and the 2.7
    /// merge moves this to 1.3.3.
    func testANumberInsideAPathIsStillRead() {
        // EsViritu --version, the real output. The path holds python3.14, and the version is the next line.
        let esviritu = "\(Self.root)/envs/esviritu/lib/python3.14/site-packages/EsViritu\n1.3.3\n"
        XCTAssertEqual(CLIProvenanceSupport.parseCondaToolVersion(esviritu), "3.14")
    }

    /// The regex ignores a `v` prefix too, so a DOI on stdout wins over the banner on stderr. The
    /// Workflow parsers prefer the token written `v2.31.0`. `detectCondaToolVersion` gives this
    /// parser stdout then stderr, and the correct value is 2.31.0, which the 2.7 merge restores.
    func testAVPrefixIsStillIgnored() {
        // vsearch --version, the real output from the owner's install.
        let stdout = Self.lines(
            "Rognes T, Flouri T, Nichols B, Quince C, Mahe F (2016)",
            "VSEARCH: a versatile open source tool for metagenomics",
            "PeerJ 4:e2584 doi: 10.7717/peerj.2584 https://doi.org/10.7717/peerj.2584",
            "",
            "Compiled with support for gzip-compressed files, and the library is loaded.",
            "zlib version 1.2.12, compile flags 2a9",
            "Compiled with support for bzip2-compressed files, and the library is loaded.")
        let stderr = Self.lines(
            "vsearch v2.31.0_macos_aarch64, 64.0GB RAM, 20 cores",
            "https://github.com/torognes/vsearch",
            "")
        XCTAssertEqual(CLIProvenanceSupport.parseCondaToolVersion(stdout + stderr), "10.7717")
    }
}
