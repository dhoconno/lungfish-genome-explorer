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
/// The defect rows show what the regex and the first-line fallback do to output the two tools
/// never print today, so the rules stay the same as the Workflow parsers' (Phase 2.7 merges the three).
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

    // MARK: - Known defects, fixed in 2.6

    /// ribodetector_cpu is probed with `--version`, then `-h`, then `--help`. Nothing reaches `-h`
    /// while `--version` answers. The help text holds no dotted number, so the first line is recorded (2.6).
    func testHelpTextFallbackRecordsTheUsageLine() {
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
        XCTAssertEqual(
            CLIProvenanceSupport.parseCondaToolVersion(help),
            "usage: ribodetector_cpu [-h] [-c CONFIG] -l LEN -i [INPUT ...] -o [OUTPUT ...]"
        )
    }

    /// bwa-mem2 rejects `--version` and `-v`, and the error line is recorded as the version (2.6).
    func testAnErrorLineIsRecordedAsTheVersion() {
        XCTAssertEqual(
            CLIProvenanceSupport.parseCondaToolVersion("ERROR: unknown command '--version'\n"),
            "ERROR: unknown command '--version'"
        )
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

    /// The regex drops a local build suffix (2.6).
    func testALocalBuildSuffixIsDropped() {
        XCTAssertEqual(
            CLIProvenanceSupport.parseCondaToolVersion("PrimalScheme3-LGE version: 3.3.0+lge.5\n"),
            "3.3.0"
        )
    }
}
