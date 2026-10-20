// NCBIDatasetsArchiveTests.swift - The Datasets ZIP is unpacked on ToolProcess and refused when a link leaves its folder
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

final class NCBIDatasetsArchiveTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ncbi-datasets-archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    /// Builds a ZIP with `zip -y`, which stores a symbolic link as a link.
    private func makeZip(files: [String: String], links: [String: String]) async throws -> URL {
        let staging = tempDir.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for (path, contents) in files {
            let url = staging.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        for (path, target) in links {
            try FileManager.default.createSymbolicLink(
                atPath: staging.appendingPathComponent(path).path,
                withDestinationPath: target
            )
        }
        let zip = tempDir.appendingPathComponent("datasets.zip")
        let spec = ToolProcessSpec(
            executableURL: URL(fileURLWithPath: "/usr/bin/zip"),
            arguments: ["-q", "-y", "-r", zip.path, "."],
            environment: ToolProcessSpec.inheritedEnvironment(),
            workingDirectory: staging,
            label: "zip"
        )
        let result = try await ToolProcess.run(spec)
        XCTAssertTrue(result.isSuccess, result.stderrText)
        return zip
    }

    private func outputFolder() throws -> URL {
        let out = tempDir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        return out
    }

    func testExtractsTheDatasetsLayout() async throws {
        let zip = try await makeZip(files: ["ncbi_dataset/data/GCF_1/genomic.fna": ">a\nACGT\n"], links: [:])
        let out = try outputFolder()
        try await NCBIDatasetsArchive.extract(zip, to: out)
        let fasta = out.appendingPathComponent("ncbi_dataset/data/GCF_1/genomic.fna")
        XCTAssertEqual(try String(contentsOf: fasta, encoding: .utf8), ">a\nACGT\n")
    }

    func testRefusesASymbolicLinkThatLeavesTheFolderAndRemovesTheFolder() async throws {
        let zip = try await makeZip(
            files: ["ncbi_dataset/data/GCF_1/genomic.fna": ">a\n"],
            links: ["ncbi_dataset/escape": "../../outside"]
        )
        let out = try outputFolder()
        do {
            try await NCBIDatasetsArchive.extract(zip, to: out)
            XCTFail("the archive was accepted")
        } catch DatabaseServiceError.parseError(let message) {
            XCTAssertTrue(message.contains("points outside its folder"), message)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    func testRefusesASymbolicLinkChainThroughALinkToTheFolder() async throws {
        // `up` reads `self/..`, which collapses to the folder when `..` is removed from the text,
        // but on disk `self` is the folder, so `up` really points above it.
        let zip = try await makeZip(files: ["ok.txt": "ok"], links: ["self": ".", "up": "self/.."])
        let out = try outputFolder()
        do {
            try await NCBIDatasetsArchive.extract(zip, to: out)
            XCTFail("the archive was accepted")
        } catch DatabaseServiceError.parseError(let message) {
            XCTAssertTrue(message.contains("points outside its folder"), message)
        }
    }

    func testRefusesAnAbsoluteSymbolicLink() async throws {
        let zip = try await makeZip(files: ["ok.txt": "ok"], links: ["abs": "/etc"])
        let out = try outputFolder()
        do {
            try await NCBIDatasetsArchive.extract(zip, to: out)
            XCTFail("the archive was accepted")
        } catch DatabaseServiceError.parseError(let message) {
            XCTAssertTrue(message.contains("absolute path /etc"), message)
        }
    }

    func testNamesTheExitStatusWhenUnzipFails() async throws {
        let bogus = tempDir.appendingPathComponent("bogus.zip")
        try Data(repeating: 7, count: 100).write(to: bogus)
        do {
            try await NCBIDatasetsArchive.extract(bogus, to: try outputFolder())
            XCTFail("expected a failure")
        } catch DatabaseServiceError.parseError(let message) {
            XCTAssertTrue(message.hasPrefix("Failed to extract Datasets ZIP (exit "), message)
        }
    }
}
