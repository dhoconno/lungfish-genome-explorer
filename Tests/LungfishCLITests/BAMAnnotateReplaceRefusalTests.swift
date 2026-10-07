// BAMAnnotateReplaceRefusalTests.swift - bam annotate-best and annotate-cds-best refuse --replace before deleting
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.1 lane L6, item 1. The commands run the live services, which now
// refuse an output that holds an input before anything is deleted or any
// tool runs, and say why in one line.

import XCTest
@testable import LungfishCLI
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

final class BAMAnnotateReplaceRefusalTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BAMAnnotateReplaceRefusalTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testAMappingResultInsideTheOutputIsRefusedInOneLineAndKept() async throws {
        for subcommand in ["annotate-best", "annotate-cds-best"] {
            let source = try makeSourceBundle(in: root.appendingPathComponent("\(subcommand)-source", isDirectory: true))
            let output = root.appendingPathComponent("\(subcommand)-Out.lungfishref", isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let mapping = output.appendingPathComponent("mapping", isDirectory: true)
            let bam = try makeMappingResult(in: mapping)
            let arguments = [
                subcommand,
                "--bundle", source.path,
                "--mapping-result", mapping.path,
                "--output-bundle", output.path,
                "--output-track-name", "Best",
                "--replace",
            ]

            var lines: [String] = []
            do {
                if subcommand == "annotate-best" {
                    _ = try await BAMCommand.AnnotateBestSubcommand.parse(arguments)
                        .executeForTesting(runtime: .live()) { lines.append($0) }
                } else {
                    _ = try await BAMCommand.AnnotateCDSBestSubcommand.parse(arguments)
                        .executeForTesting(runtime: .live()) { lines.append($0) }
                }
                XCTFail("\(subcommand): a mapping result inside the output must refuse the run")
            } catch {
                XCTAssertEqual(
                    error as? OutputReplacementRefusal,
                    .inputInsideOutput(input: mapping.standardizedFileURL.path, output: output.standardizedFileURL.path),
                    "\(subcommand): \(error)"
                )
            }

            let reason = OutputReplacementRefusal.inputInsideOutput(
                input: mapping.standardizedFileURL.path, output: output.standardizedFileURL.path
            ).localizedDescription
            XCTAssertEqual(lines.last, reason, "\(subcommand): the run ends with the reason")
            XCTAssertFalse(reason.contains("\n"), "\(subcommand): one line")
            XCTAssertTrue(FileManager.default.fileExists(atPath: bam.path), "\(subcommand): the mapped BAM survives")
        }
    }

    // MARK: - Fixtures

    private func makeSourceBundle(in directory: URL) throws -> URL {
        let bundle = directory.appendingPathComponent("Source.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try BundleManifest(
            name: "Replace Fixture",
            identifier: "replace-fixture.\(UUID().uuidString)",
            source: SourceInfo(organism: "Fixture organism", assembly: "Fixture assembly", database: "Fixture database")
        ).save(to: bundle)
        return bundle
    }

    private func makeMappingResult(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bam = directory.appendingPathComponent("mapped.sorted.bam")
        let bai = directory.appendingPathComponent("mapped.sorted.bam.bai")
        FileManager.default.createFile(atPath: bam.path, contents: Data("bam".utf8))
        FileManager.default.createFile(atPath: bai.path, contents: Data("bai".utf8))
        try MappingResult(
            mapper: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            bamURL: bam,
            baiURL: bai,
            totalReads: 1,
            mappedReads: 1,
            unmappedReads: 0,
            wallClockSeconds: 1.0,
            contigs: []
        ).save(to: directory)
        return bam
    }
}
