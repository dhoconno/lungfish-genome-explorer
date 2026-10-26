// ClassificationResultTests+ProjectRebase.swift - A loaded Kraken2 result reads the reads of the project it sits in
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.0 lane EXT (W4-COPY-SOURCE, the W4b design of `reviews/W4.md` section 4). A copied, renamed or moved
// project keeps the absolute paths of the run, so Extract and BLAST verification read the FASTQ of the original
// project, or failed once it was gone. `ClassificationResult.load(from:)` places a stored read that lies inside the
// stored project at the same place inside the project that holds the loaded folder, but only when every read it
// moves exists there, so one read set never takes its mates from two projects. Reading never writes, so the stored
// sidecar stays as it was. W4 already moved the folder and the files a run kept inside it
// (`ClassificationResultTests+Rebase.swift`), and those stay green.

import XCTest
import LungfishTestSupport
@testable import LungfishWorkflow

extension ClassificationResultTests {

    // MARK: - The reads of the copy (red at the base)

    /// The three lists of a run that names reads inside its project, in a project that was copied while the old one
    /// is gone, name the same places inside the copy. At the base they stay under the old project.
    func testLoadRebasesReadsInsideTheStoredProjectOntoTheLoadedProject() throws {
        let fixture = try makeProjectCopy()
        let mates = ["Imports/a_R1.fastq", "Imports/a_R2.fastq"]
        let bundle = "Imports/s.lungfishfastq"
        let single = "Imports/m.fastq"
        for relative in mates + [bundle, single] {
            try fixture.makeRead(at: fixture.copy(relative))
        }
        var config = fixture.config(inputFiles: mates.map { fixture.old($0) })
        config.originalInputFiles = [fixture.old(bundle)]
        config.singleReadFiles = [fixture.old(single)]
        try fixture.writeResult(config: config)
        let sidecar = fixture.loadedFolder.appendingPathComponent(ClassificationResult.sidecarFilename)
        let storedBytes = try Data(contentsOf: sidecar)

        let loaded = try ClassificationResult.load(from: fixture.loadedFolder)

        XCTAssertEqual(
            standardizedPaths(loaded.config.inputFiles),
            mates.map { fixture.copy($0).standardizedFileURL.path },
            "the reads the run was given are the copy's"
        )
        XCTAssertEqual(
            standardizedPaths(loaded.config.originalInputFiles),
            [fixture.copy(bundle).standardizedFileURL.path],
            "the bundle the person named is the copy's"
        )
        XCTAssertEqual(
            standardizedPaths(loaded.config.singleReadFiles),
            [fixture.copy(single).standardizedFileURL.path],
            "the single reads are the copy's"
        )
        XCTAssertEqual(try Data(contentsOf: sidecar), storedBytes, "reading a result never rewrites its sidecar")
    }

    // MARK: - What stays as stored (green at the base)

    /// One project per read set. The copy holds the first mate and the original holds both, so taking mate 1 from
    /// the copy and mate 2 from the original would pair two projects. Every list stays as stored.
    func testLoadKeepsEveryListAsStoredWhenOneReadOfTheCopyIsMissing() throws {
        let fixture = try makeProjectCopy()
        let mates = ["Imports/a_R1.fastq", "Imports/a_R2.fastq"]
        for relative in mates {
            try fixture.makeRead(at: fixture.old(relative))
        }
        try fixture.makeRead(at: fixture.copy(mates[0]))
        var config = fixture.config(inputFiles: mates.map { fixture.old($0) })
        config.originalInputFiles = mates.map { fixture.old($0) }
        try fixture.writeResult(config: config)

        let loaded = try ClassificationResult.load(from: fixture.loadedFolder)

        let stored = mates.map { fixture.old($0).standardizedFileURL.path }
        XCTAssertEqual(standardizedPaths(loaded.config.inputFiles), stored, "never mate 1 of the copy with mate 2 of the original")
        XCTAssertEqual(standardizedPaths(loaded.config.originalInputFiles), stored)
    }

    /// A read outside the stored project stays where the run read it. A folder whose name only starts with the
    /// project's name is outside it, even when the copy holds a file at the place a prefix check would map it to.
    func testLoadKeepsReadsOutsideTheStoredProject() throws {
        let fixture = try makeProjectCopy()
        let elsewhere = fixture.besideOld("Elsewhere/x.fastq")
        let backup = fixture.besideOld("Project.lungfish-backup/Imports/x.fastq")
        let prefixLookalike = URL(fileURLWithPath: fixture.copyProject.path + "-backup/Imports/x.fastq")
        for url in [elsewhere, backup, prefixLookalike] {
            try fixture.makeRead(at: url)
        }
        try fixture.writeResult(config: fixture.config(inputFiles: [elsewhere, backup]))

        let loaded = try ClassificationResult.load(from: fixture.loadedFolder)

        XCTAssertEqual(
            standardizedPaths(loaded.config.inputFiles),
            [elsewhere, backup].map { $0.standardizedFileURL.path }
        )
    }

    /// A result loaded from a folder that no project holds has no project to move its reads into.
    func testLoadKeepsStoredReadsWhenTheLoadedFolderIsInNoProject() throws {
        let fixture = try makeProjectCopy()
        let read = "Imports/a.fastq"
        try fixture.makeRead(at: fixture.old(read))
        let plain = fixture.besideOld("plain/kraken2-x")
        try fixture.writeResult(config: fixture.config(inputFiles: [fixture.old(read)]), in: plain)

        let loaded = try ClassificationResult.load(from: plain)

        XCTAssertEqual(standardizedPaths(loaded.config.inputFiles), [fixture.old(read).standardizedFileURL.path])
    }

    // MARK: - Fixtures

    private func makeProjectCopy() throws -> ProjectCopyResultFixture {
        let root = try TestTempDirectory.make(prefix: "classification-result-project-rebase")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        return ProjectCopyResultFixture(root: root)
    }

    private func standardizedPaths(_ urls: [URL]?) -> [String]? {
        urls?.map { $0.standardizedFileURL.path }
    }
}
