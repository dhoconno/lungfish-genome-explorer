// ProbeVersionTextTests.swift - The token rule the two Workflow version parsers share
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

/// Small synthetic cases for `ProbeVersionText`. The real probe output of every tool is pinned by
/// `VersionParserOutputPinTests`, and these cases name each rule on its own.
final class ProbeVersionTextTests: XCTestCase {
    private func version(_ lines: [String], echo: Bool = false) -> String? {
        ProbeVersionText.version(in: lines, skippingCommandEcho: echo)
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

    /// The echoed JVM command of a BBTools wrapper is skipped only when the caller asks, because the
    /// detect parser still reads it (2.7). A line that merely starts with java stays.
    func testAnEchoedJavaCommandIsSkippedOnlyWhenAsked() {
        let echo = "java -ea   -Xmx300m -Xms300m -cp /x/bbmap-40.02-0/ align2.BBMapPacBio minratio=0.40 --version"
        XCTAssertEqual(version([echo, "BBTools version 40.02"], echo: true), "40.02")
        XCTAssertEqual(version([echo, "BBTools version 40.02"], echo: false), "0.40")
        XCTAssertEqual(version(["java version 21.0.2"], echo: true), "21.0.2")
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

    /// The left-most dotted number wins, outside paths and echoed commands.
    func testTheFirstDottedNumberWins() {
        XCTAssertEqual(version(["samtools 1.24", "Using htslib 1.24"]), "1.24")
        XCTAssertEqual(version(["no number here", "tool 2.5.1"]), "2.5.1")
        XCTAssertNil(version(["no number here"]))
    }
}
