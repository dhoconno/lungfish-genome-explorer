// ProjectMigrateTests.swift - `project migrate` and a manifest whose browser summary synthesis gives back
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCLI
import LungfishCore
import LungfishWorkflow

/// Lane 12.37 (F5a, ARCH ruling Q-S4 item 4). `save` leaves a derivable browser summary out of `manifest.json`,
/// so a current manifest without one is current. `project migrate` writes no summary back, makes no backup and
/// records no migration, with or without `--dry-run`.
final class ProjectMigrateTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectMigrateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testDerivableMissingSummaryIsCurrent() async throws {
        let projectURL = root.appendingPathComponent("Shared.lungfish", isDirectory: true)
        let bundleURL = try makeSlimReferenceBundle(named: "Slim", under: projectURL)
        let manifestURL = bundleURL.appendingPathComponent(BundleManifest.filename)
        let provenanceURL = bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        try #"{"run":"creation-provenance","outputs":["payload"]}"#
            .write(to: provenanceURL, atomically: true, encoding: .utf8)
        let manifestBytes = try Data(contentsOf: manifestURL)
        let provenanceBytes = try Data(contentsOf: provenanceURL)

        for arguments in [[projectURL.path, "--dry-run", "--quiet"], [projectURL.path, "--quiet"]] {
            let command = try ProjectCommand.MigrateSubcommand.parse(arguments)
            try await command.run()

            XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBytes, "\(arguments)")
            XCTAssertEqual(try Data(contentsOf: provenanceURL), provenanceBytes, "\(arguments)")
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent(".lungfish").path),
                "project migrate made a migration folder for a current bundle (\(arguments))"
            )
        }
        XCTAssertNil(try BundleManifest.load(from: bundleURL).browserSummary)
    }

    /// A `1.0` reference bundle whose `manifest.json` has no `browser_summary`, as `save` now writes one.
    private func makeSlimReferenceBundle(named name: String, under projectURL: URL) throws -> URL {
        let bundleURL = projectURL.appendingPathComponent("\(name).lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent("genome", isDirectory: true),
            withIntermediateDirectories: true
        )
        try ">chr1\nACGT\n".write(
            to: bundleURL.appendingPathComponent("genome/sequence.fa"), atomically: true, encoding: .utf8
        )
        try "chr1\t4\t6\t4\t5\n".write(
            to: bundleURL.appendingPathComponent("genome/sequence.fa.fai"), atomically: true, encoding: .utf8
        )
        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: name,
            identifier: "org.lungfish.test.\(name.lowercased())",
            source: SourceInfo(organism: "Test organism", assembly: "Test assembly"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: 4,
                chromosomes: [ChromosomeInfo(name: "chr1", length: 4, offset: 6, lineBases: 4, lineWidth: 5)]
            )
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: bundleURL.appendingPathComponent(BundleManifest.filename))
        return bundleURL
    }
}
