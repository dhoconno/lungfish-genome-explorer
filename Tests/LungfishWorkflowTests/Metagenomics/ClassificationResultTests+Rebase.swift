// ClassificationResultTests+Rebase.swift - A loaded Kraken2 result names the folder it was loaded from
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.0 lane W4 (OBS-W4, a Stable blocker of the 2026-10-24 walk, row 69). `classification-result.json`
// stores the absolute folder of the run that made the result. A result renamed in the app, moved, or copied
// with its project kept that folder, so Extract read from and wrote into a folder the result no longer sat in,
// and a copied project's Extract used the original project. `ClassificationResult.load(from:)` names the
// folder it read the sidecar from, and the files a run kept inside its folder follow it. Reading never
// writes, so the stored sidecar stays as it was (UX 6).

import XCTest
import LungfishTestSupport
@testable import LungfishWorkflow
@testable import LungfishIO

extension ClassificationResultTests {

    /// The report of every result here. Species 562 holds two reads.
    private static let rebaseKreport = [
        " 50.00\t2\t2\tU\t0\tunclassified",
        " 50.00\t2\t0\tR\t1\troot",
        " 50.00\t2\t2\tS\t562\t  Escherichia coli",
    ].joined(separator: "\n") + "\n"

    // MARK: - The loaded folder

    /// The red test of OBS-W4. A result saved with the folder of the run that made it, and loaded from the folder
    /// it now sits in, names that folder. At the base it named the stored one, which no longer exists after a
    /// rename and is another project's folder after a copy.
    func testLoadRebasesStaleAbsoluteOutputDirectoryToSidecarFolder() throws {
        let root = try makeRebaseRoot()
        let stored = URL(fileURLWithPath: "/nonexistent/old/kraken2-x", isDirectory: true)
        let folder = root.appendingPathComponent("new/kraken2-y", isDirectory: true)
        try writeRebaseResult(in: folder, config: rebaseConfig(outputDirectory: stored))
        let sidecar = folder.appendingPathComponent(ClassificationResult.sidecarFilename)
        let storedBytes = try Data(contentsOf: sidecar)

        let loaded = try ClassificationResult.load(from: folder)

        XCTAssertEqual(
            loaded.config.outputDirectory.standardizedFileURL.path,
            folder.standardizedFileURL.path,
            "the result is in the folder it was loaded from, whatever folder the run stored"
        )
        XCTAssertEqual(
            loaded.reportURL.deletingLastPathComponent().standardizedFileURL.path,
            folder.standardizedFileURL.path
        )
        XCTAssertEqual(try Data(contentsOf: sidecar), storedBytes, "reading a result never rewrites its sidecar (UX 6)")
    }

    /// The files a run kept inside its folder (the staged mates and compression copies under
    /// `.lungfish-classify-inputs`) are part of the result, so they follow the folder. A file outside it, the
    /// reads the run was given, stays where the run read it. A sibling folder whose name starts with the
    /// folder's name is outside it.
    func testLoadMovesTheFilesAResultKeptInsideItsFolderWithIt() throws {
        let root = try makeRebaseRoot()
        let old = URL(fileURLWithPath: "/nonexistent/old/kraken2-x", isDirectory: true)
        let staged = old.appendingPathComponent(".lungfish-classify-inputs/1-a.input.fastq.gz")
        let reads = URL(fileURLWithPath: "/nonexistent/old/kraken2-x-reads/a.fastq.gz")
        var config = rebaseConfig(outputDirectory: old, inputFiles: [staged, reads])
        config.originalInputFiles = [reads]
        config.singleReadFiles = [staged]
        let folder = root.appendingPathComponent("new/kraken2-y", isDirectory: true)
        try writeRebaseResult(in: folder, config: config)

        let loaded = try ClassificationResult.load(from: folder)

        let keptHere = folder.appendingPathComponent(".lungfish-classify-inputs/1-a.input.fastq.gz").standardizedFileURL.path
        XCTAssertEqual(loaded.config.inputFiles.map { $0.standardizedFileURL.path }, [keptHere, reads.path])
        XCTAssertEqual(loaded.config.singleReadFiles.map { $0.standardizedFileURL.path }, [keptHere])
        XCTAssertEqual(
            loaded.config.originalInputFiles?.map { $0.standardizedFileURL.path },
            [reads.path],
            "the reads the run was given stay where the run read them"
        )
    }

    // MARK: - What did not move stays as it was (passes at the base)

    /// A result that was not moved loads as it was saved, the stored folder and the files named inside and
    /// outside it, so a loader that rebases changes nothing for the common case.
    func testLoadOfAnUnmovedResultKeepsTheStoredConfig() throws {
        let root = try makeRebaseRoot()
        let folder = root.appendingPathComponent("here/kraken2-x", isDirectory: true)
        let staged = folder.appendingPathComponent(".lungfish-classify-inputs/1-a.input.fastq.gz")
        let reads = URL(fileURLWithPath: "/nonexistent/old/reads/a.fastq.gz")
        var config = rebaseConfig(outputDirectory: folder, inputFiles: [staged, reads])
        config.singleReadFiles = [staged]
        try writeRebaseResult(in: folder, config: config)

        let loaded = try ClassificationResult.load(from: folder)

        XCTAssertEqual(loaded.config.outputDirectory, folder)
        XCTAssertEqual(loaded.config.inputFiles, [staged, reads])
        XCTAssertEqual(loaded.config.singleReadFiles, [staged])
    }

    /// A sidecar that stores the folder as `.` and its reads relative to itself, as the test fixtures and a
    /// portable result do, resolves against the folder it loads from.
    func testLoadResolvesARelativeStoredFolderAgainstTheLoadedFolder() throws {
        let root = try makeRebaseRoot()
        let folder = root.appendingPathComponent("here/kraken2-x", isDirectory: true)
        let config = ClassificationConfig(
            inputFiles: [URL(string: "../reads.fastq")!], isPairedEnd: false, databaseName: "TestDB",
            databasePath: URL(string: ".")!, outputDirectory: URL(string: ".")!
        )
        try writeRebaseResult(in: folder, config: config)

        let loaded = try ClassificationResult.load(from: folder)

        XCTAssertEqual(loaded.config.outputDirectory.standardizedFileURL.path, folder.standardizedFileURL.path)
        XCTAssertEqual(
            loaded.config.inputFiles.map { $0.standardizedFileURL.path },
            [root.appendingPathComponent("here/reads.fastq").standardizedFileURL.path]
        )
    }

    // MARK: - The readers that follow the loaded folder (passes at the base)

    /// A copied result keeps naming the reads the run was given and never takes a file kept in its own
    /// `.lungfish-classify-inputs` folder as a read source (`KrakenResultReadSources.recordedInputs`). The copy
    /// is loaded while the original and its kept files still exist, as the project copy of the walk is. A loader
    /// that rebases only the folder would let the original's kept file through, since it would sit outside the
    /// copy's scratch folder, and the extraction would read the same reads twice.
    func testRecordedInputsOfACopiedResultStillLeaveOutItsKeptFiles() throws {
        let root = try makeRebaseRoot()
        let original = root.appendingPathComponent("original/kraken2-x", isDirectory: true)
        let reads = root.appendingPathComponent("original/reads.fastq")
        let kept = original.appendingPathComponent(".lungfish-classify-inputs/1-reads.input.fastq")
        var config = rebaseConfig(outputDirectory: original, inputFiles: [reads])
        config.originalInputFiles = [reads]
        config.singleReadFiles = [kept]
        try writeRebaseResult(in: original, config: config)
        try "@r1\nACGT\n+\nIIII\n".write(to: reads, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "@r1\nACGT\n+\nIIII\n".write(to: kept, atomically: true, encoding: .utf8)
        let copy = root.appendingPathComponent("copy/kraken2-x", isDirectory: true)
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: original, to: copy)

        let inputs = try KrakenResultReadSources.recordedInputs(of: try ClassificationResult.load(from: copy))

        XCTAssertEqual(inputs.map { $0.standardizedFileURL.path }, [reads.standardizedFileURL.path])
    }

    // MARK: - Fixtures

    private func makeRebaseRoot() throws -> URL {
        let root = try TestTempDirectory.make(prefix: "classification-result-rebase")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        return root
    }

    /// A config whose folder and files are the ones given, over a database that the loader never reads.
    private func rebaseConfig(outputDirectory: URL, inputFiles: [URL] = []) -> ClassificationConfig {
        ClassificationConfig(
            inputFiles: inputFiles.isEmpty ? [URL(fileURLWithPath: "/nonexistent/old/reads.fastq")] : inputFiles,
            isPairedEnd: false,
            databaseName: "TestDB",
            databasePath: URL(fileURLWithPath: "/nonexistent/db", isDirectory: true),
            outputDirectory: outputDirectory
        )
    }

    /// Writes the folder a run leaves, a report and a per-read output, and saves `config` in its sidecar as it
    /// is, whatever folder it names.
    private func writeRebaseResult(in folder: URL, config: ClassificationConfig) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let report = folder.appendingPathComponent("classification.kreport")
        try Self.rebaseKreport.write(to: report, atomically: true, encoding: .utf8)
        let output = folder.appendingPathComponent("classification.kraken")
        try "C\tr1\t562\t10\t562:3\nC\tr2\t562\t10\t562:3\nU\tr3\t0\t10\t0:3\nU\tr4\t0\t10\t0:3\n"
            .write(to: output, atomically: true, encoding: .utf8)
        try ClassificationResult(
            config: config, tree: try KreportParser.parse(url: report), reportURL: report, outputURL: output,
            brackenURL: nil, runtime: 1, toolVersion: "2.1.3", provenanceId: nil
        ).save(to: folder)
    }
}
