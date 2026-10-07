// ImportFastqFolderPairsTests.swift - import fastq pairs a mate only with a file of its own folder
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
/// pairs only inside its own folder, however the files are listed.
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

    // MARK: - Helpers

    /// `reads_R1.fastq` and `reads_R2.fastq`, two pairs of mates named after
    /// `folder`, in a folder of that name.
    private func writeMates(in folder: String) throws -> [URL] {
        let directory = root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try [1, 2].map { mate in
            let url = directory.appendingPathComponent("reads_R\(mate).fastq")
            let text = [1, 2].map { "@\(folder).\($0)/\(mate)\nACGTACGT\n+\nIIIIIIII\n" }.joined()
            try Data(text.utf8).write(to: url)
            return url
        }
    }
}
