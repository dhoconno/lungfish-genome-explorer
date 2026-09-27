// CLIDocumentedOptionValuesTests.swift - Every value a subcommand's help lists must parse from the real root
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import XCTest
@testable import LungfishCLI

/// `lungfish-cli bundle export --format container` used to be rejected: the
/// program-wide `--format` (text, json, tsv) is parsed first and took the
/// value, so the export option of the same name was unreachable while its
/// help still advertised `container`. These parses go through the real root
/// command, where that shadowing happens, for every subcommand option whose
/// help lists accepted values.
final class CLIDocumentedOptionValuesTests: XCTestCase {
    private func assertParses(_ arguments: [String], as type: ParsableCommand.Type, file: StaticString = #filePath, line: UInt = #line) {
        do {
            let parsed = try LungfishCLI.parseAsRoot(arguments)
            XCTAssertTrue(
                Swift.type(of: parsed) == type,
                "\(arguments.joined(separator: " ")) parsed as \(Swift.type(of: parsed)), expected \(type)",
                file: file, line: line
            )
        } catch {
            XCTFail("\(arguments.joined(separator: " ")): \(String(describing: error))", file: file, line: line)
        }
    }

    func testBundleExportAcceptsEveryDocumentedExportFormat() {
        XCTAssertEqual(BundleExportFormat.allCases.map(\.rawValue), ["container"])
        for value in BundleExportFormat.allCases {
            assertParses(
                ["bundle", "export", "/tmp/example.lungfishref", "--export-format", value.rawValue, "--output", "/tmp/example.oci.tar"],
                as: BundleExportSubcommand.self
            )
        }
    }

    func testGenotypeExportAcceptsEveryDocumentedExportFormat() {
        for value in GenotypeExportSubcommand.ExportFormat.allCases {
            assertParses(
                ["genotype", "export", "--bundle", "/tmp/fixture.lungfishgenotype", "--export-format", value.rawValue, "--output", "/tmp/out.\(value.rawValue)"],
                as: GenotypeExportSubcommand.self
            )
        }
    }

    func testTwelveSExportAcceptsEveryDocumentedExportFormat() {
        for value in ["csv", "tsv", "xlsx"] {
            assertParses(
                ["fastq", "12s-export", "--bundle", "/tmp/fixture.lungfish12s", "--export-format", value, "--output", "/tmp/out.\(value)"],
                as: FastqTwelveSExportSubcommand.self
            )
        }
    }

    func testProvenanceExportAcceptsEveryDocumentedExportFormatThroughItsUnshadowedSpelling() {
        for value in ["shell", "python", "nextflow", "snakemake", "methods", "json"] {
            assertParses(
                ["provenance", "export", "/tmp/run", "--export-format", value, "--output", "/tmp/export"],
                as: ProvenanceCommand.ExportSubcommand.self
            )
        }
    }

    func testGlobalOutputFormatAcceptsEveryDocumentedValue() {
        for value in ["text", "json", "tsv"] {
            assertParses(["--format", value, "bundle", "info", "/tmp/example.lungfishref"], as: BundleInfoSubcommand.self)
            assertParses(["bundle", "info", "/tmp/example.lungfishref", "--format", value], as: BundleInfoSubcommand.self)
        }
    }

    func testAnalyzeValidateStrictFlagParses() {
        assertParses(["analyze", "validate", "/tmp/genome.fasta", "--strict"], as: FileValidateSubcommand.self)
    }

    /// `main()` rewrites `--format` to `--export-format` for the subcommands
    /// with an export format of their own, so the spelling the docs show for
    /// `provenance export` and `fastq 12s-export`, and the old
    /// `bundle export --format container`, keep working.
    func testMainNormalisesTheExportFormatSpellingForEverySubcommandThatHasOne() {
        let cases: [([String], ParsableCommand.Type)] = [
            (["bundle", "export", "/tmp/example.lungfishref", "--format", "container", "--output", "/tmp/example.oci.tar"], BundleExportSubcommand.self),
            (["bundle", "export", "/tmp/example.lungfishref", "--format=container", "--output", "/tmp/example.oci.tar"], BundleExportSubcommand.self),
            (["provenance", "export", "/tmp/run", "--format", "nextflow", "--output", "/tmp/export"], ProvenanceCommand.ExportSubcommand.self),
            (["fastq", "12s-export", "--bundle", "/tmp/fixture.lungfish12s", "--format", "csv", "--output", "/tmp/out.csv"], FastqTwelveSExportSubcommand.self),
        ]
        for (arguments, type) in cases {
            assertParses(LungfishCLI.normalizedArgumentsForParsing(arguments), as: type)
        }
        XCTAssertEqual(
            LungfishCLI.normalizedArgumentsForParsing(["bundle", "export", "x", "--format", "container"]),
            ["bundle", "export", "x", "--export-format", "container"]
        )
        XCTAssertEqual(
            LungfishCLI.normalizedArgumentsForParsing(["bundle", "info", "x", "--format", "json"]),
            ["bundle", "info", "x", "--format", "json"],
            "the program-wide output format is left alone elsewhere"
        )
    }
}
