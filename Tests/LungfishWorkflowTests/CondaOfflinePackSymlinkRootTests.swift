// CondaOfflinePackSymlinkRootTests.swift - Offline packs install into a conda root reached through a link
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import XCTest
@testable import LungfishWorkflow

/// Plan decision V3. Outside every project the durable writers anchor at the
/// destination folder, so a conda root reached through a link above it takes
/// its install record and the verified install is kept. Before V3 the first
/// write of that record walked from `/`, refused the link and rolled the
/// verified environments back.
final class CondaOfflinePackSymlinkRootTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CondaOfflinePackSymlinkRootTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
        try super.tearDownWithError()
    }

    func testOfflineInstallIntoACondaRootReachedThroughASymlinkCompletes() async throws {
        let packDirectory = try await exportSamtoolsPack()
        let (condaRoot, realCondaRoot) = try makeLinkedCondaRoot()

        let install = try await CondaOfflinePackService().installPack(
            from: packDirectory,
            condaRoot: condaRoot,
            overwrite: false,
            commandLine: ["lungfish-cli", "conda", "offline-install", packDirectory.path]
        )

        XCTAssertEqual(install.installedEnvironments.map(\.lastPathComponent), ["samtools"])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: realCondaRoot.appendingPathComponent("envs/samtools/samtools").path
        ), "the verified environment is kept")
        XCTAssertEqual(try workflowName(at: install.provenanceURL), "Conda Offline Pack Install")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: realCondaRoot.appendingPathComponent(CondaOfflinePackService.installFailureProvenanceFilename).path
        ), "no failure record")
    }

    func testReinstallRewritesTheRecordThroughTheSymlinkedRoot() async throws {
        let packDirectory = try await exportSamtoolsPack()
        let (condaRoot, realCondaRoot) = try makeLinkedCondaRoot()
        let service = CondaOfflinePackService()
        let commandLine = ["lungfish-cli", "conda", "offline-install", "--overwrite", packDirectory.path]
        let first = try await service.installPack(
            from: packDirectory, condaRoot: condaRoot, overwrite: true, commandLine: commandLine
        )
        let second = try await service.installPack(
            from: packDirectory, condaRoot: condaRoot, overwrite: true, commandLine: commandLine
        )

        XCTAssertEqual(first.provenanceURL, second.provenanceURL)
        XCTAssertEqual(try workflowName(at: second.provenanceURL), "Conda Offline Pack Install")
        // Stage, tombstone and aside names all start with `.` and the record's name.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: realCondaRoot.path)
            .filter { $0.hasPrefix(".\(ProvenanceWriter.provenanceFilename)") }
        XCTAssertEqual(leftovers, [], "the rewrite leaves no stage or aside copy")
    }

    // MARK: - Helpers

    /// A conda root whose parent is a link, as when the storage folder was
    /// moved to an external drive and linked back.
    private func makeLinkedCondaRoot() throws -> (condaRoot: URL, realCondaRoot: URL) {
        let externalDrive = tempRoot.appendingPathComponent("external-drive", isDirectory: true)
        let realCondaRoot = externalDrive.appendingPathComponent("conda", isDirectory: true)
        try FileManager.default.createDirectory(at: realCondaRoot, withIntermediateDirectories: true)
        let storage = tempRoot.appendingPathComponent("lungfish-storage", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: storage, withDestinationURL: externalDrive)
        return (storage.appendingPathComponent("conda", isDirectory: true), realCondaRoot)
    }

    private func exportSamtoolsPack() async throws -> URL {
        let sourceCondaRoot = tempRoot.appendingPathComponent("source-conda", isDirectory: true)
        let environment = sourceCondaRoot.appendingPathComponent("envs/samtools", isDirectory: true)
        try FileManager.default.createDirectory(at: environment, withIntermediateDirectories: true)
        try Data("samtools binary\n".utf8).write(to: environment.appendingPathComponent("samtools"))
        let pack = PluginPack(
            id: "read-mapping",
            name: "Read Mapping",
            description: "Read mapping tools",
            sfSymbol: "map",
            packages: ["samtools"],
            category: "Analysis"
        )
        return try await CondaOfflinePackService().exportPack(
            pack: pack,
            condaRoot: sourceCondaRoot,
            outputDirectory: tempRoot.appendingPathComponent("exports", isDirectory: true),
            commandLine: ["lungfish-cli", "conda", "offline-export", "--pack", "read-mapping"]
        ).packDirectory
    }

    private func workflowName(at url: URL) throws -> String {
        try ProvenanceEnvelopeReader.decode(Data(contentsOf: url)).workflowName
    }
}
