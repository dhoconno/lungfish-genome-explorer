// PrimerDesignSpelledDestinationTests.swift - Where a destination spelled through a link reaches the bundle writer
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.49 (moved-out row M852, PARENT-NOFOLLOW). `/tmp` and `/var` are links into `/private`, and
// `PrimerAnalysisBundleWriter` opens every component of the destination parent from `/` with `O_NOFOLLOW`, so every
// engine must hand it a physical parent. Primer3 and PrimalScheme3 resolve the parent with `realpath(3)` in their own
// pipelines (`Primer3DesignPipeline.physicalDestination`, `PrimalScheme3DesignPipeline.physicalParent`).
// `PrimerSchemeDesignPipeline`, which runs Olivar and varVAMP, resolves it once the same way in `preflight` (M2), so its
// private storage and every source file are physical too. The writer keeps its strict contract, which the last tests
// pin, and refuses a parent or a bundle name that is a link by the time it walks.

import Foundation
import XCTest
@testable import LungfishWorkflow

final class PrimerDesignSpelledDestinationTests: XCTestCase {
    // MARK: - Olivar and varVAMP resolve the parent once in preflight, so they save at the physical path

    func testOlivarUnderASpelledTmpParentSavesAtThePhysicalPath() async throws {
        assertEngineSavedAtThePhysicalPath(try await SpelledDestinationHarness.olivar(.tmp))
    }

    func testOlivarUnderASpelledVarFoldersParentSavesAtThePhysicalPath() async throws {
        assertEngineSavedAtThePhysicalPath(try await SpelledDestinationHarness.olivar(.varFolders))
    }

    func testVarVAMPUnderASpelledTmpParentSavesAtThePhysicalPath() async throws {
        assertEngineSavedAtThePhysicalPath(try await SpelledDestinationHarness.varvamp(.tmp))
    }

    func testVarVAMPUnderASpelledVarFoldersParentSavesAtThePhysicalPath() async throws {
        assertEngineSavedAtThePhysicalPath(try await SpelledDestinationHarness.varvamp(.varFolders))
    }

    // MARK: - A link the user chose is followed once, a link that appears later is refused

    /// The user's `Analyses` folder is a link to `Analyses-real`. The run works in the folder the link named when it
    /// began, the user's link stays, and the record names the physical path while the argv keeps the typed one.
    func testOlivarUnderAnAnalysesFolderTheUserLinkedSavesAtThePhysicalPath() async throws {
        let run = try await SpelledDestinationHarness.olivar(.tmp) { project in
            let real = project.physical.appendingPathComponent("Analyses-real", isDirectory: true)
            try FileManager.default.moveItem(at: project.analyses, to: real)
            try FileManager.default.createSymbolicLink(at: project.analyses, withDestinationURL: real)
        }
        defer { run.project.remove() }
        let real = run.project.physical.appendingPathComponent("Analyses-real", isDirectory: true)
        let destination = real.appendingPathComponent("result.lungfishprimeranalysis")
        assertSpelledThroughALink(run)
        let bundle = assertSpelledRunSaved(run, at: destination)
        XCTAssertTrue(
            run.runnerPath?.hasPrefix(real.path + "/") == true, "\(run.runnerPath ?? "no runner path") is in \(real.path)")
        XCTAssertTrue(isSymbolicLink(run.project.analyses), "the user's link is still a link")
        guard let bundle else { return }
        XCTAssertEqual(bundle.manifest.publishedRootPath, destination.path)
        let envelope = try ProvenanceEnvelopeReader.load(
            fromSidecar: bundle.artifactURL(forRelativePath: "provenance/wrapper.json"))
        XCTAssertEqual(envelope?.argv.last, run.project.spelledDestination.path, "the argv keeps the typed path")
        XCTAssertEqual(envelope?.outputs.isEmpty, false)
        XCTAssertTrue(
            envelope?.outputs.allSatisfy { $0.path.hasPrefix(destination.path + "/") } == true,
            "every recorded output is under the physical bundle")
    }

    /// A dangling link planted at the bundle's own name is not part of the parent. The writer refuses it, and nothing
    /// is written through it.
    func testASchemeDesignRefusesALinkPlantedAtTheBundleName() async throws {
        let run = try await SpelledDestinationHarness.olivar(.tmp) { project in
            let elsewhere = project.physical.appendingPathComponent("elsewhere", isDirectory: true)
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                at: project.physicalDestination,
                withDestinationURL: elsewhere.appendingPathComponent("planted.lungfishprimeranalysis"))
        }
        defer { run.project.remove() }
        let elsewhere = run.project.physical.appendingPathComponent("elsewhere", isDirectory: true)
        let target = elsewhere.appendingPathComponent("planted.lungfishprimeranalysis")
        guard let text = failureText(run) else { return }
        XCTAssertTrue(text.contains("Primer analysis destination already exists"), text)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), [], "nothing went through the link")
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: run.project.physicalDestination.path), target.path)
        let names = try FileManager.default.contentsOfDirectory(atPath: run.project.analyses.path)
        XCTAssertTrue(names.contains("result.lungfishprimeranalysis"), "\(names)")
        XCTAssertTrue(
            names.allSatisfy { $0 == "result.lungfishprimeranalysis" || $0.hasPrefix(".primer-scheme-failure-") },
            "\(names)")
    }

    /// The stand-in runner swaps the resolved parent for a link to another folder after it wrote its output. The run is
    /// refused, and nothing is published or staged in the folder the link names. A step before the writer refuses it
    /// first, the adapter output inventory check (`PrimerSchemeAdapterResultLoader.loadVerified`,
    /// `PrimerSchemeAdapterRunner.swift:411-415`), which reads the output tree through the link. The writer's own walk
    /// of a linked parent is pinned by `PrimerAnalysisBundleWriterSpelledPathTests`.
    func testASchemeDesignRefusesItsResolvedParentSwappedForALinkDuringTheRun() async throws {
        let run = try await SpelledDestinationHarness.olivar(.tmp, afterRunner: { project in
            let moved = project.physical.appendingPathComponent("Analyses-moved", isDirectory: true)
            try FileManager.default.moveItem(at: project.analyses, to: moved)
            try FileManager.default.createSymbolicLink(at: project.analyses, withDestinationURL: moved)
        })
        defer { run.project.remove() }
        assertSpelledThroughALink(run)
        assertRunnerPath(run, isSpelled: false)
        guard let text = failureText(run) else { return }
        XCTAssertTrue(
            text.contains("Adapter artifact inventory does not exactly cover every published native file"), text)
        XCTAssertTrue(isSymbolicLink(run.project.analyses), "the swapped link is still there")
        let moved = run.project.physical.appendingPathComponent("Analyses-moved", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: moved.path)
        XCTAssertFalse(names.contains { $0.hasSuffix(".lungfishprimeranalysis") }, "nothing was published: \(names)")
        XCTAssertFalse(names.contains { $0.contains(".staging-") }, "nothing was staged: \(names)")
        XCTAssertTrue(names.allSatisfy { $0.hasPrefix(".primer-scheme-failure-") }, "\(names)")
    }

    // MARK: - Primer3 and PrimalScheme3 spell the parent physically first, so they save

    func testPrimer3UnderASpelledTmpParentSavesAtThePhysicalPath() async throws {
        assertEngineSavedAtThePhysicalPath(try await SpelledDestinationHarness.primer3(.tmp))
    }

    func testPrimer3UnderASpelledVarFoldersParentSavesAtThePhysicalPath() async throws {
        assertEngineSavedAtThePhysicalPath(try await SpelledDestinationHarness.primer3(.varFolders))
    }

    func testPrimalScheme3UnderASpelledTmpParentSavesAtThePhysicalPath() async throws {
        assertEngineSavedAtThePhysicalPath(try await SpelledDestinationHarness.primalScheme3(.tmp))
    }

    func testPrimalScheme3UnderASpelledVarFoldersParentSavesAtThePhysicalPath() async throws {
        assertEngineSavedAtThePhysicalPath(try await SpelledDestinationHarness.primalScheme3(.varFolders))
    }

    // MARK: - Assertions

    /// `lstat` says the path is a link, which a read that follows links would not.
    private func isSymbolicLink(_ url: URL) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    /// The design saved at the physical path and its private storage was spelled physically.
    private func assertEngineSavedAtThePhysicalPath(
        _ run: SpelledRun, file: StaticString = #filePath, line: UInt = #line
    ) {
        defer { run.project.remove() }
        assertSpelledThroughALink(run, file: file, line: line)
        assertSpelledRunSaved(run, file: file, line: line)
        assertRunnerPath(run, isSpelled: false, file: file, line: line)
    }
}

/// The writer alone, under both spellings. A destination parent spelled through a link is refused at the destination
/// walk, and a source spelled through a link is refused at the source walk even when the destination is physical.
final class PrimerAnalysisBundleWriterSpelledPathTests: XCTestCase {
    func testTheWriterRefusesADestinationParentSpelledThroughALink() throws {
        for spelling in SpelledProject.Spelling.allCases {
            let project = try SpelledProject(spelling)
            defer { project.remove() }
            let source = project.physical.appendingPathComponent("source.txt")
            try Data("opaque input\n".utf8).write(to: source)
            let out = project.physical.appendingPathComponent("out", isDirectory: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

            let spelledDestination = project.spelled.appendingPathComponent("out", isDirectory: true)
                .appendingPathComponent("spelled.lungfishprimeranalysis")
            XCTAssertThrowsError(try Self.writer.write(try Self.makeRequest(source: source, destination: spelledDestination)))
            { error in
                XCTAssertEqual(
                    error as? PrimerAnalysisBundleWriterError, .invalidRequest("destination parent traversal is unsafe"),
                    "\(spelling)")
            }
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty, "\(spelling)")

            // The control. The same folder spelled by its physical path saves.
            let physicalDestination = out.appendingPathComponent("physical.lungfishprimeranalysis")
            XCTAssertNoThrow(
                try Self.writer.write(try Self.makeRequest(source: source, destination: physicalDestination)),
                "\(spelling)")
        }
    }

    func testTheWriterRefusesASourceSpelledThroughALinkWhenTheDestinationIsPhysical() throws {
        for spelling in SpelledProject.Spelling.allCases {
            let project = try SpelledProject(spelling)
            defer { project.remove() }
            try Data("opaque input\n".utf8).write(to: project.physical.appendingPathComponent("source.txt"))
            let spelledSource = project.spelled.appendingPathComponent("source.txt")
            let out = project.physical.appendingPathComponent("out", isDirectory: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let destination = out.appendingPathComponent("physical.lungfishprimeranalysis")

            XCTAssertThrowsError(try Self.writer.write(try Self.makeRequest(source: spelledSource, destination: destination)))
            { error in
                XCTAssertEqual(
                    error as? PrimerAnalysisBundleWriterError, .unsafeSource(spelledSource.path), "\(spelling)")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "\(spelling)")
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty, "\(spelling)")
        }
    }

    private static var writer: PrimerAnalysisBundleWriter {
        PrimerAnalysisBundleWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil))
    }

    /// The request of `PrimerAnalysisBundleWriterTests.makeRequest`, which is private to that class.
    private static func makeRequest(source: URL, destination: URL) throws -> PrimerAnalysisBundleWriteRequest {
        let resultSource = source.deletingLastPathComponent().appendingPathComponent(
            "result-\(source.lastPathComponent)")
        if !FileManager.default.fileExists(atPath: resultSource.path) {
            try Data("opaque result\n".utf8).write(to: resultSource)
        }
        return .init(
            analysisID: UUID(), runID: UUID(), grouping: .independent,
            inputs: [.init(id: UUID(), artifactPaths: ["inputs/source.txt"])], results: [],
            artifacts: [
                .init(sourceURL: source, relativePath: "inputs/source.txt", role: "input", format: "text"),
                .init(
                    sourceURL: resultSource, relativePath: "native/file.bin", role: "nativeOutput", format: "binary"),
            ], destinationURL: destination,
            invocation: .init(
                argv: ["storage-test-host", "--case", "opaque-wrap"], callerVersion: "1",
                explicitOptions: ["case": .string("opaque-wrap")], runtimeIdentity: .init()))
    }
}
