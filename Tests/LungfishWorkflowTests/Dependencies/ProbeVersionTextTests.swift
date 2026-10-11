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

    /// The left-most dotted number wins, outside paths and echoed commands.
    func testTheFirstDottedNumberWins() {
        XCTAssertEqual(version(["samtools 1.24", "Using htslib 1.24"]), "1.24")
        XCTAssertEqual(version(["no number here", "tool 2.5.1"]), "2.5.1")
        XCTAssertNil(version(["no number here"]))
    }
}
