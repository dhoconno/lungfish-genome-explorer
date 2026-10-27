// FinderCopyExtractSourceTests.swift - Extract in a project folder that Finder named `P.lungfish copy`
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.0 lane PROJECT-ROOT (walk WF-3, the UX ruling of 2026-10-26). Finder names a copy of
// `Pathogen Detection.lungfish` `Pathogen Detection.lungfish copy`, and the app opens it as a project. An older
// Kraken2 result in the copy stores absolute paths into the original, which is still there. Extract reads the
// copy's own Imports, and when the copy no longer holds the reads it refuses and reads nothing from any other
// folder.

import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class FinderCopyExtractSourceTests: XCTestCase {
    /// The read bundle the walk's result came from, inside each project.
    private static let bundlePath = "Imports/SRR12486983.lungfishfastq"
    /// The folder the run stored, inside the original.
    private static let storedResultPath = "Analyses/kraken2-walk62"
    /// The same result after the walk renamed it, inside each project.
    private static let resultPath = "Analyses/kraken2-walk62-renamed"

    /// The refusal of the UX ruling (`rulings/UX-WALK.md`, WF-3), under the alert title "Could not extract reads".
    private static let refusalWords = "The reads this result came from, Imports/SRR12486983.lungfishfastq, are not in "
        + "this project, so Lungfish did not look for them anywhere else. "
        + "Import SRR12486983 into this project again, then choose Extract."

    private static let collection = TaxaCollection(
        id: "project-root-walk", name: "Walk", description: "", sfSymbol: "circle",
        taxa: [TaxonTarget(name: "Escherichia coli", taxId: 562)]
    )

    /// Both projects hold the reads, as a Finder copy does while the original is kept. Every file Extract and
    /// BLAST read is the copy's own. At the base the copy is no project to `findProjectRoot`, so they are the
    /// original's.
    func testExtractInAFolderNamedLungfishCopyReadsTheCopysOwnImports() async throws {
        let root = try makeRoot()
        let projects = try makeOriginalAndFinderCopy(in: root)
        let loaded = try ClassificationResult.load(from: projects.copy.appendingPathComponent(Self.resultPath))

        let sources = try await KrakenResultReadSources.resolve(
            result: loaded,
            materializationDirectory: root.appendingPathComponent("scratch", isDirectory: true)
        )

        let copyImports = projects.copy.appendingPathComponent("Imports").standardizedFileURL.path + "/"
        XCTAssertFalse(sources.urls.isEmpty)
        for url in sources.urls {
            XCTAssertTrue(url.path.hasPrefix(copyImports), "\(url.path) is not the copy's own read")
        }
    }

    /// The copy no longer holds the reads, though the original does. Extract refuses in the UX words, writes no
    /// file, and the loaded result names no read outside the open project, so nothing outside it is opened.
    func testExtractRefusesWhenTheProjectNoLongerHoldsItsSource() async throws {
        let root = try makeRoot()
        let projects = try makeOriginalAndFinderCopy(in: root)
        try FileManager.default.removeItem(at: projects.copy.appendingPathComponent(Self.bundlePath))
        let resultFolder = projects.copy.appendingPathComponent(Self.resultPath, isDirectory: true)
        let loaded = try ClassificationResult.load(from: resultFolder)
        let output = root.appendingPathComponent("extracted", isDirectory: true)

        do {
            let files = try await ClassifierReadResolver().extractCollection(
                Self.collection, resultPath: resultFolder, classification: loaded, outputDirectory: output
            )
            XCTFail("Extract wrote \(files.map(\.path)) although the open project no longer holds its reads")
        } catch {
            XCTAssertEqual(error.localizedDescription, Self.refusalWords)
        }
        // The Extract dialog and `extract reads --by-classifier` refuse in the same words.
        do {
            _ = try await ClassifierReadResolver().resolveAndExtract(
                tool: .kraken2, resultPath: resultFolder, selections: [ClassifierRowSelector(taxIds: [562])],
                options: ExtractionOptions(), destination: .file(output.appendingPathComponent("dialog.fastq"))
            )
            XCTFail("the Extract dialog read reads that the open project does not hold")
        } catch {
            XCTAssertEqual(error.localizedDescription, Self.refusalWords)
        }

        let originalPrefix = projects.original.standardizedFileURL.path + "/"
        let named = loaded.config.inputFiles + (loaded.config.originalInputFiles ?? []) + loaded.config.singleReadFiles
        XCTAssertFalse(named.isEmpty)
        for url in named {
            XCTAssertFalse(url.standardizedFileURL.path.hasPrefix(originalPrefix), "\(url.path) lies in another project")
        }
        let written = (try? FileManager.default.contentsOfDirectory(atPath: output.path)) ?? []
        XCTAssertEqual(written.filter { !$0.hasPrefix(".") }, [], "a refused Extract writes no file")
    }

    // MARK: - Fixture

    /// `Pathogen Detection.lungfish`, made as the app makes a project, holding the reads and a result whose
    /// sidecar names them by absolute path, and its Finder copy `Pathogen Detection.lungfish copy`.
    private func makeRoot() throws -> URL {
        let root = try TestTempDirectory.make(prefix: "finder-copy-extract-source")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        return root
    }

    private func makeOriginalAndFinderCopy(in root: URL) throws -> (original: URL, copy: URL) {
        let original = root.appendingPathComponent("Pathogen Detection.lungfish", isDirectory: true)
        _ = try ProjectFile.create(at: original, name: "Pathogen Detection")
        let helper = ProjectCopyResultFixture(root: root)
        let bundle = original.appendingPathComponent(Self.bundlePath, isDirectory: true)
        try helper.makeRead(at: bundle)
        var config = ClassificationConfig(
            inputFiles: [bundle.appendingPathComponent("reads.fastq")],
            isPairedEnd: false,
            databaseName: "TestDB",
            databasePath: URL(fileURLWithPath: "/nonexistent/db", isDirectory: true),
            outputDirectory: original.appendingPathComponent(Self.storedResultPath, isDirectory: true)
        )
        config.originalInputFiles = [bundle]
        try helper.writeResult(config: config, in: original.appendingPathComponent(Self.resultPath, isDirectory: true))
        let copy = root.appendingPathComponent("Pathogen Detection.lungfish copy", isDirectory: true)
        try FileManager.default.copyItem(at: original, to: copy)
        return (original, copy)
    }
}
