// ProbeVersionTextTests.swift - The token rule the two Workflow version parsers share
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

/// Small synthetic cases for `ProbeVersionText`. The real probe output of every tool is pinned by
/// `VersionParserOutputPinTests`, and these cases name each rule on its own.
final class ProbeVersionTextTests: XCTestCase {
    private func version(_ lines: [String]) -> String? {
        ProbeVersionText.version(in: lines)
    }

    /// A token that holds a slash is a path, a URL or a DOI, and never counts (2.6).
    func testASlashMakesATokenAPath() {
        XCTAssertEqual(version(["/opt/conda/envs/e/lib/python3.14/site-packages/Tool", "1.3.3"]), "1.3.3")
        XCTAssertNil(version(["https://doi.org/10.7717/peerj.2584"]))
        XCTAssertNil(version(["2024/Apr/26"]))
    }

    /// A volume named with a version splits a path at its space, and each half still holds a slash (2.6).
    func testAVolumeNamedWithAVersionSplitsIntoTwoPathTokens() {
        XCTAssertEqual(version(["/Volumes/LGE 2.0/conda/envs/tool/bin/tool version 5.1"]), "5.1")
        XCTAssertNil(version(["/Volumes/LGE 2.0/conda/envs/tool/bin/tool"]))
    }

    /// The echoed JVM command of a BBTools wrapper is skipped by every parser (2.7), because it carries
    /// the install path and options such as minratio=0.40. A line that merely starts with java stays.
    func testAnEchoedJavaCommandIsSkipped() {
        let echo = "java -ea   -Xmx300m -Xms300m -cp /x/bbmap-40.02-0/ align2.BBMapPacBio minratio=0.40 --version"
        XCTAssertEqual(version([echo, "BBTools version 40.02"]), "40.02")
        XCTAssertEqual(parseToolVersion(from: echo + "\nBBTools version 40.02\n"), "40.02")
        XCTAssertEqual(NativeToolRunner.parseVersionProbe(exitCode: 0, stdout: "", stderr: echo + "\nBBTools version 40.02\n"), "40.02")
        XCTAssertEqual(version(["java version 21.0.2"]), "21.0.2")
    }

    /// A token written v1.2.3 is the tool naming its own version. It outranks a bare number that comes
    /// earlier, such as the zlib line in vsearch's citation block (2.6). A v inside a word is no prefix.
    func testAnExplicitVPrefixOutranksABareNumber() {
        XCTAssertEqual(
            version(["zlib version 1.2.12, compile flags 2a9", "vsearch v2.31.0_macos_aarch64, 64.0GB RAM"]),
            "2.31.0"
        )
        XCTAssertEqual(version(["(v7.526) 2024"]), "7.526")
        XCTAssertEqual(version(["rev2.5 tool 3.1"]), "2.5")
        // The trade-off: an explicit prefix wins even when it comes later than the tool's own bare number.
        XCTAssertEqual(version(["tool 1.0", "built against libfoo v2.0"]), "2.0")
    }

    /// A version keeps up to four numeric parts, as GATK writes 4.6.2.0 (2.6).
    func testAVersionKeepsFourNumericParts() {
        XCTAssertEqual(version(["The Genome Analysis Toolkit (GATK) v4.6.2.0"]), "4.6.2.0")
        XCTAssertEqual(version(["tool 4.6.2.0"]), "4.6.2.0")
        XCTAssertEqual(version(["tool 1.2.3.4.5"]), "1.2.3.4")
        XCTAssertEqual(version(["tool 2.31-r1302"]), "2.31")
    }

    /// A local build suffix after a plus sign belongs to the version, as in 3.3.0+lge.5 (2.6). A bare
    /// trailing plus does not, as blastn writes 2.16.0+.
    func testALocalBuildSuffixIsPartOfTheVersion() {
        XCTAssertEqual(version(["PrimalScheme3-LGE version: 3.3.0+lge.5"]), "3.3.0+lge.5")
        XCTAssertEqual(version(["tool 1.2+build7, built today"]), "1.2+build7")
        XCTAssertEqual(version(["blastn: 2.16.0+"]), "2.16.0")
        XCTAssertEqual(version(["tool 2.5.1+ (beta)"]), "2.5.1")
    }

    /// The detect parser's first-line fallback keeps a plain line and drops an error line (2.6).
    func testTheDetectParserRecordsNoErrorLineAsAVersion() {
        XCTAssertNil(parseToolVersion(from: "ERROR: unknown command '--version'\n"))
        XCTAssertNil(parseToolVersion(from: "Invalid option: --.\n"))
        XCTAssertNil(parseToolVersion(from: "--version is not a valid option\n"))
        XCTAssertEqual(parseToolVersion(from: "nightly-build\nsecond line\n"), "nightly-build")
    }

    /// Usage text holds no version, so no line from its first line on is read (2.7). hifiasm's help
    /// lists the -D default [5.0] before any version. The native parser only missed it because the
    /// number sits past its first 8 lines, so this help is short enough to sit inside them. A version
    /// printed before the usage block still counts, as bwa and samtools print theirs.
    func testUsageTextHoldsNoVersion() {
        let usage = Self.joined(
            "Usage: tool [options] <in.fq>", "  -t INT   number of threads [1]",
            "  -D FLOAT drop k-mers occurring >FLOAT*coverage times [5.0]")
        XCTAssertNil(parseToolVersion(from: usage))
        XCTAssertNil(NativeToolRunner.parseVersionProbe(exitCode: 0, stdout: "", stderr: usage))
        XCTAssertNil(NativeToolRunner.parseVersionProbe(exitCode: 0, stdout: usage, stderr: ""))
        let bwa = Self.joined(
            "Program: bwa (alignment via Burrows-Wheeler transformation)", "Version: 0.7.17-r1188", "",
            "Usage:   bwa <command> [options]", "  -k INT   minimum seed length 19.5")
        XCTAssertEqual(parseToolVersion(from: bwa, exitCode: 1), "0.7.17")
        XCTAssertEqual(NativeToolRunner.parseVersionProbe(exitCode: 1, stdout: "", stderr: bwa), "0.7.17")
    }

    /// A line opens usage text when its first word is `usage`, in any case. A longer word or a word
    /// inside a line is no usage text.
    func testOnlyALineWhoseFirstWordIsUsageOpensUsageText() {
        for line in ["Usage: hifiasm [options]", "usage: ribodetector_cpu [-h]", "  \tUSAGE", "Usage   bwa <command>"] {
            XCTAssertTrue(ProbeVersionText.opensUsageText(line), line)
        }
        for line in ["usagestats 2.5", "Memory usage: 3.2GB", "tool 1.0", "", "us"] {
            XCTAssertFalse(ProbeVersionText.opensUsageText(line), line)
        }
    }

    private static func joined(_ items: String...) -> String {
        items.joined(separator: "\n") + "\n"
    }

    /// A probe that exits nonzero gets no first-line fallback (2.7), because its first line is the
    /// tool's complaint in whatever words it chose. A version number it printed still counts, as
    /// bwa's `Version:` line does after its usage exit. A line with micromamba's markers is no
    /// version even when the probe exited 0.
    func testAFailedProbeGetsNoFirstLineFallback() {
        XCTAssertEqual(parseToolVersion(from: "nightly-build\n", exitCode: 0), "nightly-build")
        XCTAssertNil(parseToolVersion(from: "nightly-build\n", exitCode: 1))
        XCTAssertEqual(parseToolVersion(from: "Program: bwa\nVersion: 0.7.17-r1188\n", exitCode: 1), "0.7.17")
        XCTAssertNil(parseToolVersion(
            from: "critical libmamba The given prefix does not exist: \"/x/envs/bbmap\"\n", exitCode: 0))
    }

    /// A line that complains about the probe is no version (2.6). micromamba's own complaint is one
    /// too, because its log level and its library name mark the line (2.7).
    func testProbeErrorLinesAreRecognised() {
        for line in [
            "ERROR: unknown command '--version'", "Invalid option: --.", "--version is not a valid option",
            "usage: ribodetector_cpu [-h]", "FATAL(lofreq_main.c|main:336): Unrecognized command '--version'",
            "critical libmamba The given prefix does not exist: \"/x/envs/bbmap\"",
            "warning  libmamba Cache file \"/x/pkgs/cache/a.json\" was modified by another instance",
        ] {
            XCTAssertTrue(ProbeVersionText.looksLikeProbeError(line), line)
        }
        for line in ["nightly-build", "tool 1.2.3", "Detected 67108864KB total memory on macOS"] {
            XCTAssertFalse(ProbeVersionText.looksLikeProbeError(line), line)
        }
    }

    /// The left-most dotted number wins, outside paths and echoed commands.
    func testTheFirstDottedNumberWins() {
        XCTAssertEqual(version(["samtools 1.24", "Using htslib 1.24"]), "1.24")
        XCTAssertEqual(version(["no number here", "tool 2.5.1"]), "2.5.1")
        XCTAssertNil(version(["no number here"]))
    }
}
