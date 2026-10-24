// ImportFastqAdoptOptionsTests.swift - `import fastq --adopt` refuses every setting option by name (CHTC C4 lane A)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCLI

final class ImportFastqAdoptOptionsTests: XCTestCase {
    private static let base = ["import", "fastq", "/data/returned/S", "--adopt", "--project", "/data/Project.lungfish"]

    private func parsed(_ arguments: [String], file: StaticString = #filePath, line: UInt = #line) throws -> ImportCommand.FastqSubcommand {
        try XCTUnwrap(LungfishCLI.parseAsRoot(arguments) as? ImportCommand.FastqSubcommand, file: file, line: line)
    }

    /// C4 design section 2: the plan fixed every setting, so each setting option is refused with one sentence that
    /// names it, before anything is read.
    func testAdoptRefusesSettingOptions() throws {
        let cases: [(arguments: [String], option: String)] = [
            (["--platform", "illumina"], "--platform"), (["--pairing", "paired"], "--pairing"),
            (["--quality-binning", "none"], "--quality-binning"), (["--compression", "fast"], "--compression"),
            (["--recipe", "vsp2"], "--recipe"), (["--remove-duplicates"], "--remove-duplicates"),
            (["--no-remove-ribosomal-rna"], "--remove-ribosomal-rna"), (["--no-optimize-storage"], "--no-optimize-storage"),
            (["--clumping-tool", "bbtools"], "--clumping-tool"), (["--clumpify-heap-gb", "8"], "--clumpify-heap-gb"),
            (["--threads", "4"], "--threads"), (["--samplesheet", "/data/sheet.csv"], "--samplesheet"),
            (["--log-dir", "/data/logs"], "--log-dir"), (["--recursive"], "--recursive"),
        ]
        for (arguments, option) in cases {
            let command = try parsed(Self.base + arguments)
            let sentence = try XCTUnwrap(command.adoptRefusal, option)
            XCTAssertTrue(sentence.hasPrefix("\(option) cannot be used with --adopt, because "), sentence)
            XCTAssertTrue(sentence.hasSuffix("."), sentence)
            XCTAssertFalse(sentence.dropLast().contains(". "), "\(option) is refused with more than one sentence: \(sentence)")
        }

        // --name, --dry-run, --force and --format json keep their meaning.
        let kept = try parsed(Self.base + ["--name", "S2", "--dry-run", "--force", "--format", "json"])
        XCTAssertTrue(kept.adoptOptions.adopt)
        XCTAssertNil(kept.adoptRefusal)
        XCTAssertEqual(kept.name, "S2")
        XCTAssertTrue(kept.dryRun)
        XCTAssertTrue(kept.force)

        let two = try parsed(Self.base + ["/data/returned/T"])
        XCTAssertEqual(two.adoptRefusal, "--adopt takes one returned plan folder, and 2 inputs were given.")
        XCTAssertFalse(try parsed(["import", "fastq", "/data/r.fastq", "--project", "/data/P.lungfish"]).adoptOptions.adopt)
    }
}
