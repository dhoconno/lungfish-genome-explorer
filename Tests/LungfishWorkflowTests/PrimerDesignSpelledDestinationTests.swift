// PrimerDesignSpelledDestinationTests.swift - Where a destination spelled through a link reaches the bundle writer
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.49 M1 (moved-out row M852, PARENT-NOFOLLOW). These are pins of today's behaviour, each passing at
// the base. `/tmp` and `/var` are links into `/private`, and `PrimerAnalysisBundleWriter` opens every component of the
// destination parent from `/` with `O_NOFOLLOW`. Primer3 and PrimalScheme3 spell the parent physically with
// `realpath(3)` before the writer (`Primer3DesignPipeline.physicalDestination`, `PrimalScheme3DesignPipeline.physicalParent`)
// and save. `PrimerSchemeDesignPipeline`, which runs Olivar and varVAMP, hands the writer the destination as the caller
// spelled it, and the writer refuses it with "destination parent traversal is unsafe". M2 turns the four Olivar and
// varVAMP pins into saves.

import Foundation
import XCTest
@testable import LungfishWorkflow

final class PrimerDesignSpelledDestinationTests: XCTestCase {
    // MARK: - Olivar and varVAMP hand the writer the spelled destination, which it refuses

    func testOlivarUnderASpelledTmpParentIsRefusedAtTheDestinationWalk() async throws {
        assertSchemeEngineRefused(try await SpelledDestinationHarness.olivar(.tmp))
    }

    func testOlivarUnderASpelledVarFoldersParentIsRefusedAtTheDestinationWalk() async throws {
        assertSchemeEngineRefused(try await SpelledDestinationHarness.olivar(.varFolders))
    }

    func testVarVAMPUnderASpelledTmpParentIsRefusedAtTheDestinationWalk() async throws {
        assertSchemeEngineRefused(try await SpelledDestinationHarness.varvamp(.tmp))
    }

    func testVarVAMPUnderASpelledVarFoldersParentIsRefusedAtTheDestinationWalk() async throws {
        assertSchemeEngineRefused(try await SpelledDestinationHarness.varvamp(.varFolders))
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

    /// The writer refused the destination parent walk, and the pipeline's private storage, where the writer's source
    /// files sit, is spelled through the same link.
    private func assertSchemeEngineRefused(_ run: SpelledRun, file: StaticString = #filePath, line: UInt = #line) {
        defer { run.project.remove() }
        assertSpelledThroughALink(run, file: file, line: line)
        assertSpelledRunRefusedAtTheDestinationParent(run, file: file, line: line)
        assertRunnerPath(run, isSpelled: true, file: file, line: line)
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
