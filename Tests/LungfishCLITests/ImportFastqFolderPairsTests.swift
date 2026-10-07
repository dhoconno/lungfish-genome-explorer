// ImportFastqFolderPairsTests.swift - import fastq pairs a mate inside its own folder first, and across folders by unique names
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCLI
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

/// Detection kept one file a stem, the last one listed, so explicit files
/// of two folders that hold the same names paired folder A's R1 with folder
/// B's R2. The pair path counts records and nothing more, so two files of
/// equal counts imported as mates of two different samples (review B-S1).
/// `import fastq <folder> --recursive` groups each folder alone. A mate now
/// pairs inside its own folder first, however the files are listed.
///
/// That rule left mates of two folders, `R1/x_R1` and `R2/x_R2`, as two
/// single-end samples, even with `--pairing paired`, and nothing said why
/// (re-review N1). They pair again when no other listed file has either
/// name. When another listed file shares a name, the mates stay apart and a
/// warning names the files.
final class ImportFastqFolderPairsTests: XCTestCase {

    private var root: URL!
    private var project: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "import-fastq-folder-pairs")
        project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    func testExplicitFilesOfTwoFoldersPairEveryMateInsideItsFolder() async throws {
        let a = try writeMates(in: "A")
        let b = try writeMates(in: "B")

        let command = try ImportCommand.FastqSubcommand.parse((a + b).map(\.path) + [
            "--project", project.path, "--platform", "illumina", "--quality-binning", "none",
            "--no-optimize-storage",
        ])
        try await command.run()

        // Folder A's pair is the sample `reads`, and folder B's pair, a
        // sample of the same name, finds that bundle and is skipped. No mate
        // is left over as a single-end sample.
        let imports = project.appendingPathComponent("Imports", isDirectory: true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: imports.path), ["reads.lungfishfastq"])
        let fastq = try XCTUnwrap(
            FASTQBundle.resolvePrimaryFASTQURL(for: imports.appendingPathComponent("reads.lungfishfastq"))
        )
        XCTAssertEqual(
            try FASTQReadLayoutClassifier.readHeaders(from: fastq, limit: 100).headers,
            ["A.1/1", "A.1/2", "A.2/1", "A.2/2"]
        )
    }

    // MARK: - Mates of two folders (re-review N1)

    func testExplicitMatesOfTwoFoldersPairWhenNoOtherListedFileHasTheirNames() async throws {
        let r1 = try writeMate(1, of: "x", in: "R1", reads: "R")
        let r2 = try writeMate(2, of: "x", in: "R2", reads: "R")

        for pairing in ["auto", "paired"] {
            let project = root.appendingPathComponent("\(pairing).lungfish", isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let run = try await runImport([r1.path, r2.path], project: project, ["--pairing", pairing])

            XCTAssertNil(run.error, run.output)
            let imports = project.appendingPathComponent("Imports", isDirectory: true)
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: imports.path), ["x.lungfishfastq"],
                "--pairing \(pairing)\n\(run.output)"
            )
            let fastq = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: imports.appendingPathComponent("x.lungfishfastq")))
            XCTAssertEqual(
                try FASTQReadLayoutClassifier.readHeaders(from: fastq, limit: 100).headers,
                ["R.1/1", "R.1/2", "R.2/1", "R.2/2"], "--pairing \(pairing)"
            )
            XCTAssertEqual(FASTQMetadataStore.load(for: fastq)?.ingestion?.pairingMode, .interleaved)
            XCTAssertTrue(run.output.contains("x  [paired]"), run.output)
            XCTAssertFalse(run.output.contains("was not paired with"), "a pair by unique names needs no warning\n\(run.output)")
        }
    }

    func testAMateNameTwoFoldersShareNeverPairsAcrossFoldersAndAWarningSaysWhy() async throws {
        // Folder A holds a whole pair. B's R1 and C's R2 are named as mates,
        // but each name is also one of A's mates.
        let a = try writeMates(in: "A")
        let b1 = try writeMate(1, of: "reads", in: "B", reads: "B")
        let c2 = try writeMate(2, of: "reads", in: "C", reads: "C")

        let run = try await runImport((a + [b1, c2]).map(\.path))

        XCTAssertNil(run.error, run.output)
        XCTAssertTrue(run.output.contains("⚠ reads_R1: \(Self.mateWarning(b1, [c2]))"), run.output)
        let imports = project.appendingPathComponent("Imports", isDirectory: true)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: imports.path).sorted(),
            ["reads.lungfishfastq", "reads_R1.lungfishfastq", "reads_R2.lungfishfastq"]
        )
        let lone = try XCTUnwrap(
            FASTQBundle.resolvePrimaryFASTQURL(for: imports.appendingPathComponent("reads_R1.lungfishfastq"))
        )
        XCTAssertEqual(try FASTQReadLayoutClassifier.readHeaders(from: lone, limit: 100).headers, ["B.1/1", "B.2/1"])
    }

    func testTheWarningIsANoticeEventUnderFormatJSON() async throws {
        let a1 = try writeMate(1, of: "x", in: "A", reads: "A")
        let b2 = try writeMate(2, of: "x", in: "B", reads: "B")
        let c2 = try writeMate(2, of: "x", in: "C", reads: "C")

        let run = try await runImport([a1, b2, c2].map(\.path), ["--dry-run", "--format", "json"])

        XCTAssertNil(run.error, run.output)
        let notices = Self.jsonEvents(in: run.output).filter { $0["event"] as? String == "notice" }
        XCTAssertEqual(notices.compactMap { $0["sample"] as? String }, ["x_R1"], run.output)
        XCTAssertEqual(notices.first?["message"] as? String, Self.mateWarning(a1, [b2, c2]), run.output)
    }

    func testARunsThirdFileInAnotherFolderJoinsItsPairWhenNoOtherListedFileHasItsNames() async throws {
        let folder = root.appendingPathComponent("A", isDirectory: true)
        let other = root.appendingPathComponent("B", isDirectory: true)
        for directory in [folder, other] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let r1 = folder.appendingPathComponent("SRR7_1.fastq")
        let r2 = folder.appendingPathComponent("SRR7_2.fastq")
        let third = other.appendingPathComponent("SRR7.fastq")
        try Self.records([1, 2], mate: "/1", bases: "ACGTACGT").write(to: r1, atomically: true, encoding: .utf8)
        try Self.records([1, 2], mate: "/2", bases: "TTGGCCAA").write(to: r2, atomically: true, encoding: .utf8)
        try Self.records([3], mate: "/1", bases: "GATTACAG").write(to: third, atomically: true, encoding: .utf8)

        let run = try await runImport([r1, r2, third].map(\.path))

        XCTAssertNil(run.error, run.output)
        XCTAssertTrue(run.output.contains("Unpaired: SRR7.fastq"), run.output)
        let imports = project.appendingPathComponent("Imports", isDirectory: true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: imports.path), ["SRR7.lungfishfastq"])
        let fastq = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: imports.appendingPathComponent("SRR7.lungfishfastq")))
        XCTAssertEqual(
            try FASTQReadLayoutClassifier.readHeaders(from: fastq, limit: 100).headers,
            ["SRR7.1/1", "SRR7.1/2", "SRR7.2/1", "SRR7.2/2", "SRR7.3/1"]
        )
        let classification = try XCTUnwrap(FASTQMetadataStore.load(for: fastq)?.readClassification)
        XCTAssertEqual(classification.pairedReadCount, 4)
        XCTAssertEqual(classification.unpairedReadCount, 1)
    }

    // MARK: - --recursive pairs by the same rule (F7 ruling)

    func testARecursiveImportPairsMatesOfTwoFoldersAsExplicitFilesDo() async throws {
        _ = try writeMate(1, of: "x", in: "delivery/R1", reads: "R")
        _ = try writeMate(2, of: "x", in: "delivery/R2", reads: "R")

        let run = try await runImport([root.appendingPathComponent("delivery").path], ["--recursive"])

        XCTAssertNil(run.error, run.output)
        XCTAssertTrue(run.output.contains("x  [paired]"), run.output)
        // The pair sits in the folder that holds R1/ and R2/, the scanned folder.
        let imports = project.appendingPathComponent("Imports", isDirectory: true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: imports.path), ["x.lungfishfastq"])
        let fastq = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: imports.appendingPathComponent("x.lungfishfastq")))
        XCTAssertEqual(
            try FASTQReadLayoutClassifier.readHeaders(from: fastq, limit: 100).headers,
            ["R.1/1", "R.1/2", "R.2/1", "R.2/2"]
        )
    }

    func testARecursiveImportWarnsWhenANameTwoFoldersShareKeepsMatesApart() async throws {
        _ = try writeMate(1, of: "reads", in: "delivery/A", reads: "A")
        _ = try writeMate(2, of: "reads", in: "delivery/A", reads: "A")
        let b1 = try writeMate(1, of: "reads", in: "delivery/B", reads: "B")
        let c2 = try writeMate(2, of: "reads", in: "delivery/C", reads: "C")

        let run = try await runImport([root.appendingPathComponent("delivery").path], ["--recursive"])

        XCTAssertNil(run.error, run.output)
        XCTAssertTrue(run.output.contains("⚠ reads_R1: \(Self.mateWarning(b1, [c2]))"), run.output)
        let imports = project.appendingPathComponent("Imports", isDirectory: true)
        for bundle in ["A/reads", "B/reads_R1", "C/reads_R2"] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: imports.appendingPathComponent("\(bundle).lungfishfastq").path),
                "\(bundle)\n\(run.output)"
            )
        }
    }

    // MARK: - Helpers

    /// The warning for an R1 with no mate in its folder whose candidates in
    /// other folders share a name with another listed file.
    private static func mateWarning(_ r1: URL, _ candidates: [URL]) -> String {
        let paths = candidates.map(\.standardizedFileURL.path)
        let named = paths.count == 1 ? paths[0] : paths.dropLast().joined(separator: ", ") + " or " + paths[paths.count - 1]
        return "\(r1.standardizedFileURL.path) was not paired with \(named), because mates pair across folders "
            + "only when their names are unique among the listed files."
    }

    private struct ImportRun {
        let output: String
        let error: Error?
    }

    /// Runs `import fastq` in process and returns what it printed and the
    /// error it threw, if any. A thrown error is a non-zero exit status.
    private func runImport(_ inputs: [String], project: URL? = nil, _ extra: [String] = []) async throws -> ImportRun {
        let command = try ImportCommand.FastqSubcommand.parse(inputs + [
            "--project", (project ?? self.project).path, "--platform", "illumina", "--quality-binning", "none",
            "--no-optimize-storage", "--no-color",
        ] + extra)
        let outputFile = root.appendingPathComponent("stdout-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: outputFile.path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputFile)
        fflush(stdout)
        let savedStdout = dup(STDOUT_FILENO)
        dup2(handle.fileDescriptor, STDOUT_FILENO)
        var thrown: Error?
        do {
            try await command.run()
        } catch {
            thrown = error
        }
        fflush(stdout)
        dup2(savedStdout, STDOUT_FILENO)
        close(savedStdout)
        try handle.close()
        return ImportRun(output: String(decoding: try Data(contentsOf: outputFile), as: UTF8.self), error: thrown)
    }

    /// `reads_R1.fastq` and `reads_R2.fastq`, two pairs of mates named after
    /// `folder`, in a folder of that name.
    private func writeMates(in folder: String) throws -> [URL] {
        try [1, 2].map { try writeMate($0, of: "reads", in: folder, reads: folder) }
    }

    /// `<sample>_R<mate>.fastq` in `folder`, with two reads named
    /// `<reads>.<n>/<mate>`.
    private func writeMate(_ mate: Int, of sample: String, in folder: String, reads: String) throws -> URL {
        let directory = root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(sample)_R\(mate).fastq")
        let text = [1, 2].map { "@\(reads).\($0)/\(mate)\nACGTACGT\n+\nIIIIIIII\n" }.joined()
        try Data(text.utf8).write(to: url)
        return url
    }

    /// Records `@SRR7.<spot><mate>` for each spot.
    private static func records(_ spots: [Int], mate: String, bases: String) -> String {
        spots.map { "@SRR7.\($0)\(mate)\n\(bases)\n+\nIIIIIIII\n" }.joined()
    }

    /// The JSON objects among the printed lines.
    private static func jsonEvents(in output: String) -> [[String: Any]] {
        output.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("{"),
                  let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            else { return nil }
            return object
        }
    }
}
