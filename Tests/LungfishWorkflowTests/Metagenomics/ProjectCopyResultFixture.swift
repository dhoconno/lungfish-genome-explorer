// ProjectCopyResultFixture.swift - A Kraken2 result that sits in a copied project
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.0 lane EXT (W4-COPY-SOURCE). A project that was copied, renamed or moved keeps the absolute paths its
// runs stored. This fixture stores the folder and the reads of a run made in `Old/Project.lungfish` and puts the
// sidecar into the copy, `New/Copy.lungfish`, the only place the result is loaded from. The old project holds only
// what a test puts in it, so a test that wants the original gone puts nothing there.

import Foundation
@testable import LungfishIO
@testable import LungfishWorkflow

struct ProjectCopyResultFixture {
    /// The words of `ClassifierExtractionError.kraken2SourceMissing` as the UX ruling of 2026-10-26 gives them,
    /// so the Extract alert, the BLAST alert and the CLI read the same (`meeting/R2-UX.md:17`).
    static let missingReadsWords = "The FASTQ reads this Kraken2 result was made from are missing. "
        + "They are not in this project or where the run recorded them. "
        + "Put their bundle back into this project and try again, "
        + "or run the classification again in this project."

    let oldProject: URL
    let copyProject: URL

    init(root: URL) {
        oldProject = root.appendingPathComponent("Old/Project.lungfish", isDirectory: true)
        copyProject = root.appendingPathComponent("New/Copy.lungfish", isDirectory: true)
    }

    /// The folder the sidecar stores, which the old project may no longer hold.
    var storedFolder: URL { oldProject.appendingPathComponent("Analyses/kraken2-x", isDirectory: true) }

    /// The folder the result is loaded from, inside the copy.
    var loadedFolder: URL { copyProject.appendingPathComponent("Analyses/kraken2-x", isDirectory: true) }

    /// `relative` inside the old project, the place a run stored.
    func old(_ relative: String) -> URL { oldProject.appendingPathComponent(relative) }

    /// `relative` inside the copy.
    func copy(_ relative: String) -> URL { copyProject.appendingPathComponent(relative) }

    /// `relative` beside the old project, outside it.
    func besideOld(_ relative: String) -> URL {
        oldProject.deletingLastPathComponent().appendingPathComponent(relative)
    }

    /// Makes `url` a small FASTQ file, or a bundle that holds one when its extension is `lungfishfastq`.
    func makeRead(at url: URL) throws {
        let file = url.pathExtension == "lungfishfastq" ? url.appendingPathComponent("reads.fastq") : url
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "@r1\nACGT\n+\nIIII\n".write(to: file, atomically: true, encoding: .utf8)
    }

    /// The config of a run made in the old project over `inputFiles`, the folder and the reads as absolute paths.
    func config(inputFiles: [URL]) -> ClassificationConfig {
        ClassificationConfig(
            inputFiles: inputFiles,
            isPairedEnd: false,
            databaseName: "TestDB",
            databasePath: URL(fileURLWithPath: "/nonexistent/db", isDirectory: true),
            outputDirectory: storedFolder
        )
    }

    /// Writes the folder a run leaves, a report and a per-read output, into `folder` (the copy by default) and
    /// saves `config` in its sidecar as it is, whatever project it names.
    func writeResult(config: ClassificationConfig, in folder: URL? = nil) throws {
        let folder = folder ?? loadedFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let report = folder.appendingPathComponent("classification.kreport")
        let kreport = [
            " 50.00\t2\t2\tU\t0\tunclassified",
            " 50.00\t2\t0\tR\t1\troot",
            " 50.00\t2\t2\tS\t562\t  Escherichia coli",
        ].joined(separator: "\n") + "\n"
        try kreport.write(to: report, atomically: true, encoding: .utf8)
        let output = folder.appendingPathComponent("classification.kraken")
        try "C\tr1\t562\t10\t562:3\nC\tr2\t562\t10\t562:3\nU\tr3\t0\t10\t0:3\nU\tr4\t0\t10\t0:3\n"
            .write(to: output, atomically: true, encoding: .utf8)
        try ClassificationResult(
            config: config, tree: try KreportParser.parse(url: report), reportURL: report, outputURL: output,
            brackenURL: nil, runtime: 1, toolVersion: "2.1.3", provenanceId: nil
        ).save(to: folder)
    }
}
