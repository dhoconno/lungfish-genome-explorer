// VersionParserOutputPinTests.swift - What the production version parsers return on real output
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

/// Pins the value each production version parser returns today on captured real probe output.
///
/// Two parsers are reachable. `NativeToolRunner.parseVersionProbe` reads stdout and then stderr
/// of a native tool probe. `parseToolVersion(from:)` reads stdout and stderr joined, and serves
/// `detectToolVersion`, which both `ManagedMappingPipeline` and `ManagedAssemblyPipeline` call.
/// The third parser, the inline one in `CLIProvenanceSupport.detectCondaToolVersion`, lives in
/// the CLI target inside a function that runs a process, so it cannot be driven from here.
///
/// The outputs are captured from the managed environment with the storage root replaced by
/// `/Users/test/.lungfish/conda`. The wrong values sit in `knownDefects`. They are pinned so a
/// parser change shows as a deliberate diff. Phase 2.6 fixes them under the provenance schema bump
/// and Phase 2.7 merges the parsers, and both must update this table in the same commit.
final class VersionParserOutputPinTests: XCTestCase {
    private struct Capture {
        let name: String
        let exitCode: Int32
        let stdout: String
        let stderr: String
        /// What `NativeToolRunner.parseVersionProbe` returns today.
        let native: String?
        /// What `parseToolVersion(from: stdout + stderr)` returns today.
        let detect: String?
        /// The version the tool really reports, for defect rows.
        let correct: String
    }

    private static let root = "/Users/test/.lungfish/conda"

    private static func bbtoolsBanner(javaLine: String, tail: String) -> String {
        "Detected 67108864KB total memory on macOS, estimating 43620761KB available\n"
            + "Detected 36971360KB free memory on macOS (vm_stat)\n"
            + javaLine + "\n" + tail
    }

    // MARK: - Clean outputs, both parsers right

    private static let clean: [Capture] = [
        Capture(name: "samtools", exitCode: 0,
                stdout: "samtools 1.24\nUsing htslib 1.24\nCopyright (C) 2026 Genome Research Ltd.\n", stderr: "",
                native: "1.24", detect: "1.24", correct: "1.24"),
        Capture(name: "minimap2", exitCode: 0, stdout: "2.31-r1302\n", stderr: "",
                native: "2.31", detect: "2.31", correct: "2.31"),
        Capture(name: "kraken2", exitCode: 0,
                stdout: "Kraken version 2.17.1\nCopyright 2013-2023, Derrick Wood (dwood@cs.jhu.edu)\n", stderr: "",
                native: "2.17.1", detect: "2.17.1", correct: "2.17.1"),
        Capture(name: "seqkit", exitCode: 0, stdout: "seqkit v2.13.0\n", stderr: "",
                native: "2.13.0", detect: "2.13.0", correct: "2.13.0"),
        Capture(name: "blastn", exitCode: 0,
                stdout: "blastn: 2.16.0+\n Package: blast 2.16.0, build Mar 28 2025 16:33:14\n", stderr: "",
                native: "2.16.0", detect: "2.16.0", correct: "2.16.0"),
        Capture(name: "lofreq", exitCode: 0,
                stdout: "version: 2.1.5\ncommit: unknown\nbuild-date: Jul 15 2026\n", stderr: "",
                native: "2.1.5", detect: "2.1.5", correct: "2.1.5"),
        Capture(name: "ivar", exitCode: 0,
                stdout: "iVar version 1.4.4\n\nPlease raise issues and bug reports at https://github.com/andersen-lab/ivar/\n\n", stderr: "",
                native: "1.4.4", detect: "1.4.4", correct: "1.4.4"),
        Capture(name: "freyja", exitCode: 0, stdout: "freyja, version 2.0.3\n", stderr: "",
                native: "2.0.3", detect: "2.0.3", correct: "2.0.3"),
        Capture(name: "mafft", exitCode: 0, stdout: "", stderr: "v7.526 (2024/Apr/26)\n",
                native: "7.526", detect: "7.526", correct: "7.526"),
        Capture(name: "flye", exitCode: 0, stdout: "2.9.6-b1802\n", stderr: "",
                native: "2.9.6", detect: "2.9.6", correct: "2.9.6"),
        Capture(name: "spades", exitCode: 0, stdout: "SPAdes genome assembler v4.3.0\n", stderr: "",
                native: "4.3.0", detect: "4.3.0", correct: "4.3.0"),
        Capture(name: "skesa", exitCode: 0, stdout: "SKESA 2.5.1\n", stderr: "skesa --version \n\n",
                native: "2.5.1", detect: "2.5.1", correct: "2.5.1"),
        Capture(name: "bowtie2", exitCode: 0,
                stdout: "\(root)/envs/bowtie2/bin/bowtie2-align-s version 2.5.5\n64-bit\nBuilt on VM-8b0b7afd3b\n", stderr: "",
                native: "2.5.5", detect: "2.5.5", correct: "2.5.5"),
        Capture(name: "fasterq-dump", exitCode: 0,
                stdout: "\(root)/envs/sra-tools/bin/fasterq-dump : 3.4.1\n\n", stderr: "",
                native: "3.4.1", detect: "3.4.1", correct: "3.4.1"),
        // Right for the wrong reason in the native parser, which reads 40.02 out of the bbmap-40.02-0
        // install directory in the echoed java line. The detect parser skips the path and reads the banner.
        Capture(name: "reformat.sh", exitCode: 0, stdout: "",
                stderr: "java -ea   -Xmx300m -Xms300m -cp \(root)/envs/bbtools/opt/bbmap-40.02-0/current/ jgi.ReformatReads --version\n"
                    + "BBTools version 40.02\nFor help, please run the shellscript with no parameters, or look in /docs/.\n",
                native: "40.02", detect: "40.02", correct: "40.02"),
        Capture(name: "clumpify.sh", exitCode: 0, stdout: "",
                stderr: bbtoolsBanner(
                    javaLine: "java -ea   -Xmx29205m -Xms29205m -cp \(root)/envs/bbtools/opt/bbmap-40.02-0/current/ clump.Clumpify --version",
                    tail: "BBTools version 40.02\nFor help, please run the shellscript with no parameters, or look in /docs/.\n"),
                native: "40.02", detect: "40.02", correct: "40.02"),
    ]

    // MARK: - Known defects, fixed in 2.6 and 2.7

    /// Each row pins a wrong value as it is today. `correct` is what the tool reports. A row stays
    /// here until the parser change that fixes it lands, and that commit moves the row to `clean`.
    private static let knownDefects: [Capture] = [
        // GATK 4.6.2.0 is cut to 4.6.2 by both parsers (2.6, schema version 2).
        Capture(name: "gatk 4.6.2.0", exitCode: 0,
                stdout: "The Genome Analysis Toolkit (GATK) v4.6.2.0\nHTSJDK Version: 4.2.0\nPicard Version: 3.4.0\n",
                stderr: "Using GATK jar \(root)/envs/gatk-core/share/gatk4-4.6.2.0-1/gatk-package-4.6.2.0-local.jar\n",
                native: "4.6.2", detect: "4.6.2", correct: "4.6.2.0"),
        // primalscheme3 loses its local build suffix in both parsers (2.6).
        Capture(name: "primalscheme3 +lge.5", exitCode: 0,
                stdout: "PrimalScheme3-LGE version: 3.3.0+lge.5\n", stderr: "",
                native: "3.3.0", detect: "3.3.0", correct: "3.3.0+lge.5"),
        // The native parser reads Python's 3.14 out of the site-packages path (2.7 merges the parsers).
        Capture(name: "EsViritu python3.14 path", exitCode: 0,
                stdout: "\(root)/envs/esviritu/lib/python3.14/site-packages/EsViritu\n1.3.3\n", stderr: "",
                native: "3.14", detect: "1.3.3", correct: "1.3.3"),
        // The native parser reads the volume name "LGE 2.0" out of the echoed java line (2.7).
        Capture(name: "BBTools wrapper under a root named LGE 2.0", exitCode: 0, stdout: "",
                stderr: "java -ea   -Xmx300m -Xms300m -cp /Volumes/LGE 2.0/conda/envs/bbtools/opt/bbmap-40.02-0/current/ jgi.ReformatReads --version\n"
                    + "BBTools version 40.02\nFor help, please run the shellscript with no parameters, or look in /docs/.\n",
                native: "2.0", detect: "40.02", correct: "40.02"),
        Capture(name: "EsViritu under a root named LGE 2.0", exitCode: 0,
                stdout: "/Volumes/LGE 2.0/conda/envs/esviritu/lib/python3.14/site-packages/EsViritu\n1.3.3\n", stderr: "",
                native: "2.0", detect: "1.3.3", correct: "1.3.3"),
        // The detect parser reads minratio=0.40 from the echoed command line (2.7).
        Capture(name: "mapPacBio.sh minratio", exitCode: 0, stdout: "",
                stderr: bbtoolsBanner(
                    javaLine: "java -ea   -Xmx29890m -Xms29890m -cp \(root)/envs/bbtools/opt/bbmap-40.02-0/current/ "
                        + "align2.BBMapPacBio build=1 overwrite=true minratio=0.40 fastareadlen=6000 --version",
                    tail: "BBMap version 40.02\n"),
                native: "40.02", detect: "0.40", correct: "40.02"),
        // A missing conda environment prints micromamba's error and the detect parser returns that
        // first line as the version. The native parser returns nil (2.5 fixes the bbmap environment,
        // 2.7 stops the first-line fallback).
        Capture(name: "micromamba missing environment", exitCode: 1, stdout: "",
                stderr: "critical libmamba The given prefix does not exist: \"\(root)/envs/bbmap\"\n",
                native: nil, detect: "critical libmamba The given prefix does not exist: \"\(root)/envs/bbmap\"",
                correct: "40.02"),
        // bwa-mem2 rejects --version, and the detect parser records the error line (2.6).
        Capture(name: "bwa-mem2 --version", exitCode: 1, stdout: "",
                stderr: "ERROR: unknown command '--version'\n",
                native: nil, detect: "ERROR: unknown command '--version'", correct: "2.3"),
        // The installed 2.3 build prints a stale 2.2.1 from the version subcommand, so both parsers
        // read a version the package does not have. Only conda-meta says 2.3 (the lock pin).
        Capture(name: "bwa-mem2 version subcommand", exitCode: 0, stdout: "2.2.1\n", stderr: "",
                native: "2.2.1", detect: "2.2.1", correct: "2.3"),
        // vsearch prints its citation first. The native parser records the DOI prefix 10.7717 and the
        // detect parser records zlib's 1.2.12 (2.6).
        Capture(name: "vsearch citation", exitCode: 0,
                stdout: "Rognes T, Flouri T, Nichols B, Quince C, Mahe F (2016)\nVSEARCH: a versatile open source tool for metagenomics\n"
                    + "PeerJ 4:e2584 doi: 10.7717/peerj.2584 https://doi.org/10.7717/peerj.2584\n\n"
                    + "Compiled with support for gzip-compressed files, and the library is loaded.\nzlib version 1.2.12, compile flags 2a9\n",
                stderr: "vsearch v2.31.0_macos_aarch64, 64.0GB RAM, 20 cores\nhttps://github.com/torognes/vsearch\n\n",
                native: "10.7717", detect: "1.2.12", correct: "2.31.0"),
        // Tools that reject the probe: the detect parser records the error line (2.6).
        Capture(name: "bedGraphToBigWig --version", exitCode: 255, stdout: "",
                stderr: "--version is not a valid option\n",
                native: nil, detect: "--version is not a valid option", correct: "2.10"),
        Capture(name: "medaka_variant --version", exitCode: 1, stdout: "",
                stderr: "Invalid option: --.\n",
                native: nil, detect: "Invalid option: --.", correct: "2.2.2"),
    ]

    // MARK: - Tests

    func testCleanOutputsReturnTheirVersionFromBothParsers() {
        for capture in Self.clean {
            assertPins(capture)
            XCTAssertEqual(capture.native, capture.correct, "native parser on \(capture.name)")
            XCTAssertEqual(capture.detect, capture.correct, "detect parser on \(capture.name)")
        }
    }

    func testKnownDefectsAreStillPinnedAsTheyAre() {
        for capture in Self.knownDefects {
            assertPins(capture)
        }
    }

    func testEveryKnownDefectIsWrongInAtLeastOneParser() {
        for capture in Self.knownDefects {
            XCTAssertTrue(
                capture.native != capture.correct || capture.detect != capture.correct,
                "\(capture.name) is listed as a defect but both parsers return \(capture.correct)"
            )
        }
    }

    func testRequiredCapturesArePresent() {
        let names = Set((Self.clean + Self.knownDefects).map(\.name))
        for required in [
            "gatk 4.6.2.0", "primalscheme3 +lge.5", "EsViritu python3.14 path", "mapPacBio.sh minratio",
            "micromamba missing environment", "bwa-mem2 --version", "vsearch citation",
            "BBTools wrapper under a root named LGE 2.0", "samtools", "minimap2", "kraken2",
        ] {
            XCTAssertTrue(names.contains(required), required)
        }
    }

    func testDetectParserOnEmptyOutputReturnsNil() {
        XCTAssertNil(parseToolVersion(from: ""))
        XCTAssertNil(NativeToolRunner.parseVersionProbe(exitCode: 0, stdout: "", stderr: ""))
    }

    private func assertPins(_ capture: Capture, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(
            NativeToolRunner.parseVersionProbe(exitCode: capture.exitCode, stdout: capture.stdout, stderr: capture.stderr),
            capture.native, "native parser on \(capture.name)", file: file, line: line
        )
        XCTAssertEqual(
            parseToolVersion(from: capture.stdout + capture.stderr),
            capture.detect, "detect parser on \(capture.name)", file: file, line: line
        )
    }
}
