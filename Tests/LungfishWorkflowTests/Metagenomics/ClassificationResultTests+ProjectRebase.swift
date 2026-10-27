// ClassificationResultTests+ProjectRebase.swift - A loaded Kraken2 result reads the reads of the project it sits in
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.0 lane EXT (W4-COPY-SOURCE, the W4b design of `reviews/W4.md` section 4), changed by lane PROJECT-ROOT
// (walk WF-3, the UX ruling of 2026-10-26). A copied, renamed or moved project keeps the absolute paths of the run,
// so Extract and BLAST verification read the FASTQ of the original project, or failed once it was gone.
// `ClassificationResult.load(from:)` places every stored read that lies inside the stored project at the same place
// inside the project that holds the loaded folder, so a loaded result never names a read of another project and one
// read set never takes its mates from two projects. When the open project lacks one of those reads,
// `config.sourceMissingFromProject` names its place and Extract and BLAST refuse, reading nothing of the original
// even while it is kept. Reading never writes, so the stored sidecar stays as it was. W4 already moved the folder
// and the files a run kept inside it (`ClassificationResultTests+Rebase.swift`), and those stay green.

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

    // MARK: - A scratch input of the run (BIO should-fix 1 of the PROJECT-ROOT review)

    /// A run on a virtual bundle (subset, trim, demux) takes materialized inputs from `<project>/.tmp/` and deletes
    /// them when it ends, and the sidecar stores the run's effective config, so `inputFiles` can name a scratch file
    /// that no project holds. The open project holds the bundle the person named, so Extract and BLAST read that
    /// bundle and are not refused for the scratch file.
    func testLoadDoesNotRefuseForAScratchInputThatTheStoredProjectDeletedAfterTheRun() throws {
        let fixture = try makeProjectCopy()
        let bundle = "Imports/s.lungfishfastq"
        try fixture.makeRead(at: fixture.copy(bundle))
        var config = fixture.config(inputFiles: [fixture.old(".tmp/kraken2-ABC/s.fastq")])
        config.originalInputFiles = [fixture.old(bundle)]
        try fixture.writeResult(config: config)

        let loaded = try ClassificationResult.load(from: fixture.loadedFolder)

        XCTAssertNil(loaded.config.sourceMissingFromProject, "a scratch file the run deleted is not a read the project lacks")
        XCTAssertEqual(
            try KrakenResultReadSources.recordedInputs(of: loaded).map { $0.standardizedFileURL.path },
            [fixture.copy(bundle).standardizedFileURL.path],
            "the bundle the person named is the copy's"
        )
    }

    // MARK: - A copy that lacks a read, and what stays as stored

    /// One project per read set. The copy holds the first mate and the original holds both, so taking mate 1 from
    /// the copy and mate 2 from the original would pair two projects. Every list names the copy's places only,
    /// and the read the copy lacks is kept for the refusal, so nothing of the original is read (walk WF-3).
    func testLoadNamesOnlyTheOpenProjectWhenOneReadOfTheCopyIsMissing() throws {
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

        let inCopy = mates.map { fixture.copy($0).standardizedFileURL.path }
        XCTAssertEqual(standardizedPaths(loaded.config.inputFiles), inCopy, "never mate 1 of the copy with mate 2 of the original")
        XCTAssertEqual(standardizedPaths(loaded.config.originalInputFiles), inCopy)
        XCTAssertEqual(loaded.config.sourceMissingFromProject, mates[1], "the read the copy lacks")
    }

    /// The stored project is gone and its name had no `.lungfish` extension, so no file shows it was a project.
    /// The stored folder ends with the loaded folder's place inside its project, so the rest is the stored
    /// project, and the reads are the copy's (ARCH's edge for lane PROJECT-ROOT).
    func testLoadFindsAGoneStoredProjectWhoseNameHadNoExtension() throws {
        let fixture = try makeProjectCopy()
        let read = "Imports/a.fastq"
        try fixture.makeRead(at: fixture.copy(read))
        let gone = fixture.besideOld("Project copy")
        var config = fixture.config(inputFiles: [gone.appendingPathComponent(read)])
        config.outputDirectory = gone.appendingPathComponent("Analyses/kraken2-x", isDirectory: true)
        try fixture.writeResult(config: config)

        let loaded = try ClassificationResult.load(from: fixture.loadedFolder)

        XCTAssertEqual(standardizedPaths(loaded.config.inputFiles), [fixture.copy(read).standardizedFileURL.path])
        XCTAssertNil(loaded.config.sourceMissingFromProject)
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
