// GenotypingOutputDirectoryProjectBindingTests.swift - `--project X --output-dir <outside X>`
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class GenotypingOutputDirectoryProjectBindingTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypingOutputBinding-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// `--project /tmp/X --output-dir /private/tmp/X/run` names a directory
    /// inside the project; the check compares physical paths, not spellings.
    func testOutputDirectoryInsideProjectIsAcceptedThroughASymlinkedSpelling() throws {
        let project = root.appendingPathComponent("Study.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link-to-study", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: project)
        let physicalProject = URL(fileURLWithPath: project.canonicalFilePath, isDirectory: true)

        XCTAssertTrue(ONTBarcodeDemuxGenotypingPipeline.outputDirectory(
            link.appendingPathComponent("Analyses/run-1", isDirectory: true),
            isInsideProject: physicalProject
        ))
        XCTAssertTrue(ONTBarcodeDemuxGenotypingPipeline.outputDirectory(
            physicalProject.appendingPathComponent("Analyses/run-1", isDirectory: true),
            isInsideProject: link
        ))
        XCTAssertTrue(ONTBarcodeDemuxGenotypingPipeline.outputDirectory(link, isInsideProject: physicalProject))
        XCTAssertFalse(ONTBarcodeDemuxGenotypingPipeline.outputDirectory(
            root.appendingPathComponent("elsewhere/run-1", isDirectory: true),
            isInsideProject: link
        ))
    }

    func testOutputDirectoryInsideProjectIsAccepted() {
        let project = root.appendingPathComponent("Study.lungfish", isDirectory: true)
        XCTAssertTrue(ONTBarcodeDemuxGenotypingPipeline.outputDirectory(
            project.appendingPathComponent("Analyses/run-1", isDirectory: true),
            isInsideProject: project
        ))
        XCTAssertTrue(ONTBarcodeDemuxGenotypingPipeline.outputDirectory(project, isInsideProject: project))
        // A sibling whose name merely starts with the project path is outside.
        XCTAssertFalse(ONTBarcodeDemuxGenotypingPipeline.outputDirectory(
            root.appendingPathComponent("Study.lungfish-copy/run-1", isDirectory: true),
            isInsideProject: project
        ))
        XCTAssertFalse(ONTBarcodeDemuxGenotypingPipeline.outputDirectory(
            root.appendingPathComponent("elsewhere/run-1", isDirectory: true),
            isInsideProject: project
        ))
    }

    /// The pipeline refuses the request before creating anything, with a
    /// message that names both paths and how to fix the call, instead of
    /// failing later with an opaque owned work-directory error.
    func testRunFailsEarlyWithAClearMessageWhenOutputIsOutsideTheProject() async throws {
        let project = root.appendingPathComponent("Study.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("elsewhere/cohort-run", isDirectory: true)
        let reads = root.appendingPathComponent("sample.fastq")
        try Data("@r1\nACGT\n+\nIIII\n".utf8).write(to: reads)
        let reference = root.appendingPathComponent("ref.fasta")
        try Data(">chr\nACGT\n".utf8).write(to: reference)

        let request = ONTBarcodeDemuxGenotypingRunRequest(
            inputFASTQURLs: [reads],
            referenceSourceURL: reference,
            barcodeDefinitionsURL: nil,
            outputDirectory: outside,
            projectURL: project,
            mode: .illuminaPaired,
            readType: .illumina
        )

        do {
            _ = try await ONTBarcodeDemuxGenotypingPipeline().run(request)
            XCTFail("expected the run to be refused")
        } catch let error as ONTBarcodeDemuxGenotypingError {
            guard case .outputDirectoryOutsideProject(let outputDirectory, let projectURL) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(outputDirectory, outside)
            XCTAssertEqual(projectURL, project)
            let message = error.localizedDescription
            XCTAssertTrue(message.contains(outside.path), message)
            XCTAssertTrue(message.contains(project.path), message)
            XCTAssertTrue(message.contains("--output-dir"), message)
            XCTAssertTrue(message.contains("--project"), message)
            XCTAssertFalse(message.lowercased().contains("owned work"), message)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: outside.deletingLastPathComponent().path),
            "nothing may be created for a refused request"
        )
    }
}
