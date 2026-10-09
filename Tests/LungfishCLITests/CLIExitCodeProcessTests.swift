// CLIExitCodeProcessTests.swift - Subprocess tests for CLIError exit status bridging
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import LungfishCore
import LungfishTestSupport
import XCTest
@testable import LungfishCLI

final class CLIExitCodeProcessTests: XCTestCase {
    /// Resolved once per test run from the injected CLI path or the test
    /// bundle's build-products directory.
    private static let cliBinaryURL: URL? = {
        let buildProductsDirectory = Bundle(for: CLIExitCodeProcessTests.self).bundleURL.deletingLastPathComponent()
        return CLITestBinaryResolver.cliBinaryURL(
            buildProductsDirectory: buildProductsDirectory
        )
    }()

    func testConvertMissingInputExitsWithInputError() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-exit-code-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let missingInput = tempDir.appendingPathComponent("missing.fa")
        let output = tempDir.appendingPathComponent("out.fa")

        let result = try runCLI(["convert", missingInput.path, "--to", output.path])

        XCTAssertEqual(result.exitCode, CLIExitCode.inputError.rawValue)
        XCTAssertEqual(result.stdout, "")
        XCTAssertTrue(result.stderr.contains("Input file not found"))
        assertSingleErrorLine(in: result.stderr, diagnostic: "Input file not found")
    }

    func testConvertUnsupportedOutputFormatExitsWithFormatError() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-exit-code-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let input = tempDir.appendingPathComponent("input.fa")
        let output = tempDir.appendingPathComponent("out.unsupported")
        try ">seq1\nACGT\n".write(to: input, atomically: true, encoding: .utf8)

        let result = try runCLI([
            "convert",
            input.path,
            "--to", output.path,
            "--to-format", "unsupported",
        ])

        XCTAssertEqual(result.exitCode, CLIExitCode.formatError.rawValue)
        XCTAssertTrue(result.stderr.contains("Unsupported format"))
        assertSingleErrorLine(in: result.stderr, diagnostic: "Unsupported format")
    }

    func testImportBamMissingInputExitsWithInputError() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-exit-code-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let missingInput = tempDir.appendingPathComponent("missing.bam")

        let result = try runCLI(["import", "bam", missingInput.path])

        XCTAssertEqual(result.exitCode, CLIExitCode.inputError.rawValue)
        XCTAssertTrue(combinedOutput(result).contains("Input file not found"))
    }

    func testImportVariantsParseFailureExitsWithFormatError() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-exit-code-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let input = tempDir.appendingPathComponent("broken.vcf")
        try "not a vcf\n".write(to: input, atomically: true, encoding: .utf8)

        let result = try runCLI(["import", "vcf", input.path, "--quiet"])

        XCTAssertEqual(result.exitCode, CLIExitCode.formatError.rawValue)
        XCTAssertTrue(combinedOutput(result).contains("Failed to parse VCF"))
    }

    func testImportKraken2MalformedReadableReportExitsWithFormatError() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-exit-code-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let kreport = tempDir.appendingPathComponent("broken.kreport")
        let outputDir = tempDir.appendingPathComponent("imports", isDirectory: true)
        try "not a kraken2 report\n".write(to: kreport, atomically: true, encoding: .utf8)

        let result = try runCLI(["import", "kraken2", kreport.path, "--output-dir", outputDir.path])

        XCTAssertEqual(result.exitCode, CLIExitCode.formatError.rawValue)
        XCTAssertTrue(combinedOutput(result).contains("Failed to parse"))
    }

    func testImportKraken2NonUTF8ReportDoesNotEmbedExitCodeDiagnostic() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-exit-code-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let kreport = tempDir.appendingPathComponent("non-utf8.kreport")
        try Data([0xff, 0xfe, 0xfd]).write(to: kreport)

        let result = try runCLI(["import", "kraken2", kreport.path])
        let output = combinedOutput(result)

        XCTAssertEqual(result.exitCode, CLIExitCode.formatError.rawValue)
        XCTAssertTrue(output.contains("Cannot read kreport file as text"))
        XCTAssertFalse(output.contains("ArgumentParser.ExitCode"))
    }

    func testImportFastqMissingInputExitsWithInputError() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-exit-code-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let missingInput = tempDir.appendingPathComponent("missing.fastq")
        let project = tempDir.appendingPathComponent("Project.lungfish", isDirectory: true)

        let result = try runCLI(["import", "fastq", missingInput.path, "--project", project.path])

        XCTAssertEqual(result.exitCode, CLIExitCode.inputError.rawValue)
        XCTAssertTrue(combinedOutput(result).contains("Input not found"))
    }

    func testAssembleInvalidAssemblerExitsWithInputError() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-exit-code-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let reads = tempDir.appendingPathComponent("reads.fastq")
        try "@r1\nACGT\n+\nIIII\n".write(to: reads, atomically: true, encoding: .utf8)

        let result = try runCLI(["assemble", reads.path, "--assembler", "not-an-assembler"])

        XCTAssertEqual(result.exitCode, CLIExitCode.inputError.rawValue)
        XCTAssertTrue(combinedOutput(result).contains("Unknown assembler"))
    }

    func testMapInvalidMapperExitsWithInputError() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-exit-code-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let reads = tempDir.appendingPathComponent("reads.fastq")
        let reference = tempDir.appendingPathComponent("reference.fasta")
        try "@r1\nACGT\n+\nIIII\n".write(to: reads, atomically: true, encoding: .utf8)
        try ">ref\nACGT\n".write(to: reference, atomically: true, encoding: .utf8)

        let result = try runCLI([
            "map",
            reads.path,
            "--reference", reference.path,
            "--mapper", "not-a-mapper",
        ])

        XCTAssertEqual(result.exitCode, CLIExitCode.inputError.rawValue)
        XCTAssertTrue(combinedOutput(result).contains("Invalid mapper"))
    }

    func testOrientInvalidWordLengthExitsWithInputError() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-exit-code-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let reads = tempDir.appendingPathComponent("reads.fastq")
        let reference = tempDir.appendingPathComponent("reference.fasta")
        try "@r1\nACGT\n+\nIIII\n".write(to: reads, atomically: true, encoding: .utf8)
        try ">ref\nACGT\n".write(to: reference, atomically: true, encoding: .utf8)

        let result = try runCLI([
            "orient",
            reads.path,
            "--reference", reference.path,
            "--word-length", "2",
        ])

        XCTAssertEqual(result.exitCode, CLIExitCode.inputError.rawValue)
        XCTAssertTrue(combinedOutput(result).contains("Word length must be between 3 and 15"))
    }

    func testCzIdSummaryMissingInputExitsWithInputError() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-exit-code-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let missingInput = tempDir.appendingPathComponent("missing-tax-report.tsv")

        let result = try runCLI(["cz-id", "summary", missingInput.path])

        XCTAssertEqual(result.exitCode, CLIExitCode.inputError.rawValue)
        XCTAssertTrue(combinedOutput(result).contains("Input not found"))
    }

    func testNvdImportMalformedCSVExitsWithFormatError() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-exit-code-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let nvdDir = tempDir.appendingPathComponent("nvd-run", isDirectory: true)
        let labkeyDir = nvdDir.appendingPathComponent("05_labkey_bundling", isDirectory: true)
        try FileManager.default.createDirectory(at: labkeyDir, withIntermediateDirectories: true)
        try "not,a,valid,nvd,csv\n".write(
            to: labkeyDir.appendingPathComponent("sample_blast_concatenated.csv"),
            atomically: true,
            encoding: .utf8
        )

        let outputDir = tempDir.appendingPathComponent("imports", isDirectory: true)
        let result = try runCLI([
            "nvd", "import", nvdDir.path,
            "--output-dir", outputDir.path,
            "--quiet",
        ])

        XCTAssertEqual(result.exitCode, CLIExitCode.formatError.rawValue)
        XCTAssertTrue(combinedOutput(result).contains("Missing required columns"))
    }

    func testTaxTriageMissingInputExitsWithInputError() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-exit-code-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let missingInput = tempDir.appendingPathComponent("missing.fastq")
        let outputDir = tempDir.appendingPathComponent("taxtriage", isDirectory: true)

        let result = try runCLI([
            "taxtriage", "run",
            "--input", missingInput.path,
            "--sample", "S1",
            "--output", outputDir.path,
            "--quiet",
        ])

        XCTAssertEqual(result.exitCode, CLIExitCode.inputError.rawValue)
        XCTAssertTrue(combinedOutput(result).contains("Input file not found"))
    }

    func testExtractReadsMissingIdsFileExitsWithInputError() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-exit-code-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let source = tempDir.appendingPathComponent("reads.fastq")
        try "@r1\nACGT\n+\nIIII\n".write(to: source, atomically: true, encoding: .utf8)
        let missingIds = tempDir.appendingPathComponent("missing-ids.txt")
        let output = tempDir.appendingPathComponent("extracted.fastq")

        let result = try runCLI([
            "extract", "reads",
            "--by-id",
            "--ids", missingIds.path,
            "--source", source.path,
            "--output", output.path,
            "--quiet",
        ])

        XCTAssertEqual(result.exitCode, CLIExitCode.inputError.rawValue)
        XCTAssertTrue(combinedOutput(result).contains("Read ID file not found"))
    }

    func testExtractReadsMissingStrategyExitsWithInputError() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-exit-code-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let output = tempDir.appendingPathComponent("extracted.fastq")

        let result = try runCLI([
            "extract", "reads",
            "--output", output.path,
            "--quiet",
        ])

        XCTAssertEqual(result.exitCode, CLIExitCode.inputError.rawValue)
        XCTAssertTrue(combinedOutput(result).contains("Exactly one of --by-id, --by-region, --by-db, or --by-classifier must be specified"))
    }

    func testEsVirituPairedInputCountExitsWithInputError() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-exit-code-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let reads = tempDir.appendingPathComponent("reads.fastq")
        try "@r1\nACGT\n+\nIIII\n".write(to: reads, atomically: true, encoding: .utf8)
        let dbDir = tempDir.appendingPathComponent("esviritu-db", isDirectory: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let outputDir = tempDir.appendingPathComponent("esviritu", isDirectory: true)

        let result = try runCLI([
            "esviritu", "detect",
            "--input", reads.path,
            "--paired",
            "--sample", "S1",
            "--db", dbDir.path,
            "--output", outputDir.path,
            "--quiet",
        ])

        XCTAssertEqual(result.exitCode, CLIExitCode.inputError.rawValue)
        XCTAssertTrue(combinedOutput(result).contains("Paired-end mode requires exactly 2 input files"))
    }

    func testEsVirituMissingInputExitsWithInputError() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-exit-code-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbDir = tempDir.appendingPathComponent("esviritu-db", isDirectory: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let outputDir = tempDir.appendingPathComponent("esviritu", isDirectory: true)

        let result = try runCLI([
            "esviritu", "detect",
            "--sample", "S1",
            "--db", dbDir.path,
            "--output", outputDir.path,
            "--quiet",
        ])

        XCTAssertEqual(result.exitCode, CLIExitCode.inputError.rawValue)
        XCTAssertTrue(combinedOutput(result).contains("At least one --input file is required"))
    }

    func testNaoMgsImportMissingInputExitsWithInputError() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-exit-code-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let missingInput = tempDir.appendingPathComponent("missing-virus_hits_final.tsv.gz")

        let result = try runCLI([
            "nao-mgs", "import", missingInput.path,
            "--quiet",
        ])

        XCTAssertEqual(result.exitCode, CLIExitCode.inputError.rawValue)
        XCTAssertTrue(combinedOutput(result).contains("Input not found"))
    }

    func testTaxTriageMissingInputSelectorExitsWithInputError() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-exit-code-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputDir = tempDir.appendingPathComponent("taxtriage", isDirectory: true)

        let result = try runCLI([
            "taxtriage", "run",
            "--output", outputDir.path,
            "--quiet",
        ])

        XCTAssertEqual(result.exitCode, CLIExitCode.inputError.rawValue)
        XCTAssertTrue(combinedOutput(result).contains("Provide either --input (with --sample) or --samplesheet"))
    }

    func testBlastVerifyMissingKreportExitsWithInputError() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let missingKreport = tempDir.appendingPathComponent("missing.kreport")
        let source = tempDir.appendingPathComponent("reads.fastq")
        let krakenOutput = tempDir.appendingPathComponent("classified.kraken")
        try "@r1\nACGT\n+\nIIII\n".write(to: source, atomically: true, encoding: .utf8)
        try "C\tr1\t562\t4\t562:4\n".write(to: krakenOutput, atomically: true, encoding: .utf8)

        let result = try runCLI([
            "blast", "verify",
            "--kreport", missingKreport.path,
            "--source", source.path,
            "--kraken-output", krakenOutput.path,
            "--taxid", "562",
        ])

        XCTAssertEqual(result.exitCode, CLIExitCode.inputError.rawValue)
        XCTAssertTrue(combinedOutput(result).contains("Kreport file not found"))
    }

    func testBlastVerifyMissingSourceExitsWithInputError() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let kreport = tempDir.appendingPathComponent("report.kreport")
        let missingSource = tempDir.appendingPathComponent("missing.fastq")
        let krakenOutput = tempDir.appendingPathComponent("classified.kraken")
        try "".write(to: kreport, atomically: true, encoding: .utf8)
        try "C\tr1\t562\t4\t562:4\n".write(to: krakenOutput, atomically: true, encoding: .utf8)

        let result = try runCLI([
            "blast", "verify",
            "--kreport", kreport.path,
            "--source", missingSource.path,
            "--kraken-output", krakenOutput.path,
            "--taxid", "562",
        ])

        XCTAssertEqual(result.exitCode, CLIExitCode.inputError.rawValue)
        XCTAssertTrue(combinedOutput(result).contains("Source FASTQ not found"))
    }

    func testBlastVerifyMissingKrakenOutputExitsWithInputError() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let kreport = tempDir.appendingPathComponent("report.kreport")
        let source = tempDir.appendingPathComponent("reads.fastq")
        let missingKrakenOutput = tempDir.appendingPathComponent("missing.kraken")
        try "".write(to: kreport, atomically: true, encoding: .utf8)
        try "@r1\nACGT\n+\nIIII\n".write(to: source, atomically: true, encoding: .utf8)

        let result = try runCLI([
            "blast", "verify",
            "--kreport", kreport.path,
            "--source", source.path,
            "--kraken-output", missingKrakenOutput.path,
            "--taxid", "562",
        ])

        XCTAssertEqual(result.exitCode, CLIExitCode.inputError.rawValue)
        XCTAssertTrue(combinedOutput(result).contains("Kraken output not found"))
    }

    func testBundleValidateMissingBundleExitsWithInputError() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let missingBundle = tempDir.appendingPathComponent("Missing.lungfishref")

        let result = try runCLI(["bundle", "validate", missingBundle.path])

        XCTAssertEqual(result.exitCode, CLIExitCode.inputError.rawValue)
        XCTAssertTrue(combinedOutput(result).contains("Not found"))
    }

    func testImportMSAMissingInputExitsWithInputError() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let missingInput = tempDir.appendingPathComponent("missing.fasta")
        let project = tempDir.appendingPathComponent("Project.lungfish", isDirectory: true)

        let result = try runCLI(["import", "msa", missingInput.path, "--project", project.path])

        XCTAssertEqual(result.exitCode, CLIExitCode.inputError.rawValue)
    }

    func testImportTreeMissingInputExitsWithInputError() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let missingInput = tempDir.appendingPathComponent("missing.nwk")
        let project = tempDir.appendingPathComponent("Project.lungfish", isDirectory: true)

        let result = try runCLI(["import", "tree", missingInput.path, "--project", project.path])

        XCTAssertEqual(result.exitCode, CLIExitCode.inputError.rawValue)
    }

    func testApplicationExportMissingInputExitsWithInputError() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let missingInput = tempDir.appendingPathComponent("missing-export.zip")
        let project = tempDir.appendingPathComponent("Project.lungfish", isDirectory: true)

        let result = try runCLI([
            "import", "application-export",
            "clc-workbench",
            missingInput.path,
            "--project", project.path,
        ])

        XCTAssertEqual(result.exitCode, CLIExitCode.inputError.rawValue)
    }

    func testArgumentParserErrorsKeepUsageExitCodeAndFormatting() throws {
        let result = try runCLI(["--bad-option"])

        XCTAssertEqual(result.exitCode, 64)
        XCTAssertEqual(result.stdout, "")
        assertSingleErrorLine(in: result.stderr, diagnostic: "Unknown option '--bad-option'")
        XCTAssertTrue(result.stderr.contains("Usage: lungfish"))
    }

    func testArgumentParserErrorsContainingValidationTextKeepUsageExitCode() throws {
        let result = try runCLI(["--Validation failed:"])

        XCTAssertEqual(result.exitCode, 64)
        XCTAssertEqual(result.stdout, "")
        assertSingleErrorLine(in: result.stderr, diagnostic: "Unknown option '--Validation failed:'")
        XCTAssertTrue(result.stderr.contains("Usage: lungfish"))
    }

    // MARK: - Termination signals

    // Phase 2.2 lane 5B (finding R7). Every tool runs in a process group of
    // its own, so Ctrl-C in a terminal reaches only lungfish-cli, which used
    // to die at once and leave the tool running. The CLI now stops every tool
    // it started, then ends by the signal it was sent. Each test runs
    // `conda run` against a fake micromamba under a temporary conda root.

    func testSIGINTStopsTheToolTreeAndTheCLIEndsBySIGINT() async throws {
        try await assertSignalStopsTheToolTreeAndEndsTheCLI(SIGINT)
    }

    func testSIGHUPStopsTheToolTreeAndTheCLIEndsBySIGHUP() async throws {
        try await assertSignalStopsTheToolTreeAndEndsTheCLI(SIGHUP)
    }

    /// `conda run` does not turn SIGTERM into a cooperative cancel, so the
    /// CLI-wide handler stops its tool.
    func testSIGTERMStopsTheToolTreeAndTheCLIEndsBySIGTERM() async throws {
        try await assertSignalStopsTheToolTreeAndEndsTheCLI(SIGTERM)
    }

    private func assertSignalStopsTheToolTreeAndEndsTheCLI(
        _ signalNumber: Int32,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let binary = try XCTUnwrap(Self.cliBinaryURL, "Build lungfish-cli beside the test bundle", file: file, line: line)
        // The copy the CLI compares an installed micromamba against.
        let realMicromamba = try XCTUnwrap(
            RuntimeResourceLocator.path("Tools/micromamba", in: .workflow),
            "no bundled micromamba to report its version",
            file: file,
            line: line
        )

        let root = try TestTempDirectory.make(prefix: "cli-signal")
        defer { TestTempDirectory.cleanup(root) }
        let condaRoot = root.appendingPathComponent("conda", isDirectory: true)
        let storageRoot = root.appendingPathComponent("storage", isDirectory: true)
        try FileManager.default.createDirectory(at: condaRoot.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        let toolPIDFile = root.appendingPathComponent("tool.pid")
        let childPIDFile = root.appendingPathComponent("child.pid")
        // The version probe answers as the bundled copy does, so the CLI keeps
        // this fake. The run records its pid, starts a child that stands in
        // for the tool's own workers, and waits.
        let fake = condaRoot.appendingPathComponent("bin/micromamba")
        try """
        #!/bin/sh
        if [ "$1" = "--version" ]; then exec "\(realMicromamba.path)" --version; fi
        echo $$ > "\(toolPIDFile.path)"
        /bin/sh -c 'echo $$ > "\(childPIDFile.path)"; exec /bin/sleep 300' &
        wait
        """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let environment = ToolProcessSpec.inheritedEnvironment(overriding: [
            "LUNGFISH_CONDA_ROOT": condaRoot.path,
            "LUNGFISH_STORAGE_ROOT": storageRoot.path,
            "LUNGFISH_CONDA_SHARED_PKGS": "0",
        ])
        // The CLI must use the temporary root, never the user's own.
        XCTAssertEqual(
            ManagedStorageConfigStore().currentCondaRootURL(environment: environment).standardizedFileURL.path,
            condaRoot.standardizedFileURL.path,
            file: file,
            line: line
        )

        let run = try ToolProcess.start(ToolProcessSpec(
            executableURL: binary,
            arguments: ["conda", "run", "signal-test-tool"],
            environment: environment,
            timeout: .seconds(120)
        ))
        var toolPID: Int32?
        var childPID: Int32?
        let started = await waitUntil(timeout: .seconds(30), pollInterval: .milliseconds(20)) {
            toolPID = Self.readPID(toolPIDFile)
            childPID = Self.readPID(childPIDFile)
            return toolPID != nil && childPID != nil
        }
        defer {
            for pid in [toolPID, childPID].compactMap({ $0 }) where ProcessTreeTerminator.processExists(pid: pid) {
                kill(pid, SIGKILL)
            }
        }
        guard started, let toolPID, let childPID else {
            run.cancel()
            let result = try? await run.result()
            return XCTFail("the tool never started: \(result?.stderrText ?? "")", file: file, line: line)
        }
        let cliPID = try XCTUnwrap(run.pid, file: file, line: line)

        kill(cliPID, signalNumber)

        let result = try await run.result()
        XCTAssertEqual(result.termination, .signaled(signal: signalNumber), result.stderrText, file: file, line: line)
        let stopped = await waitUntil(timeout: .seconds(5)) {
            !ProcessTreeTerminator.processExists(pid: toolPID) && !ProcessTreeTerminator.processExists(pid: childPID)
        }
        XCTAssertTrue(stopped, "the tool and its child are stopped", file: file, line: line)
    }

    private static func readPID(_ url: URL) -> Int32? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func runCLI(_ arguments: [String]) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let binary = try XCTUnwrap(
            Self.cliBinaryURL,
            "Inject LUNGFISH_CLI with the resolved swiftbuild product or build it beside the test bundle"
        )

        let process = Process()
        process.executableURL = binary
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        return (
            exitCode: process.terminationStatus,
            stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }

    private func assertSingleErrorLine(
        in stderr: String,
        diagnostic: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let errorLines = stderr
            .split(separator: "\n", omittingEmptySubsequences: true)
            .filter { $0.hasPrefix("Error:") }
        XCTAssertEqual(errorLines.count, 1, "Expected exactly one rendered Error: line in stderr:\n\(stderr)", file: file, line: line)
        XCTAssertEqual(
            stderr.nonOverlappingOccurrenceCount(of: diagnostic),
            1,
            "Expected diagnostic to be rendered exactly once in stderr:\n\(stderr)",
            file: file,
            line: line
        )
    }

    private func combinedOutput(_ result: (exitCode: Int32, stdout: String, stderr: String)) -> String {
        result.stdout + result.stderr
    }

    private func makeTemporaryDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-exit-code-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }
}

private extension String {
    func nonOverlappingOccurrenceCount(of needle: String) -> Int {
        guard !needle.isEmpty else { return 0 }

        var count = 0
        var searchStart = startIndex
        while let range = range(of: needle, range: searchStart..<endIndex) {
            count += 1
            searchStart = range.upperBound
        }
        return count
    }
}
