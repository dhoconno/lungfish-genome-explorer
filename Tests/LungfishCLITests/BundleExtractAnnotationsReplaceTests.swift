// BundleExtractAnnotationsReplaceTests.swift - bundle extract-annotations --replace refuses before it deletes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.1 lane L6, item 1. `--replace` deleted the path named by
// `--output-bundle` before the source bundle was read, before the track and
// feature refusals ran, and even when that path was a folder holding the
// source. Every refusal now runs first, only the bundle the build writes is
// ever replaced, and a refused run leaves every file as it was.

import ArgumentParser
import XCTest
@testable import LungfishCLI
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

final class BundleExtractAnnotationsReplaceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundleExtractAnnotationsReplaceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testReplacingTheSourceItselfIsRefusedAndTheSourceIsKept() async throws {
        let source = try makeAnnotatedBundle(in: root)

        await assertRefused(["--bundle", source.path, "--track", "genes", "--output-bundle", source.path, "--replace"])

        assertWholeSource(source)
    }

    func testAnOutputPathWithoutTheBundleExtensionNeverDeletesThatFolder() async throws {
        let data = root.appendingPathComponent("data", isDirectory: true)
        let source = try makeAnnotatedBundle(in: data)

        try await run(["--bundle", source.path, "--track", "genes", "--output-bundle", data.path, "--replace"])

        assertWholeSource(source)
        let written = root.appendingPathComponent("data.lungfishref", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: written.appendingPathComponent("manifest.json").path), "the build writes data.lungfishref")
    }

    func testASourceInsideTheOutputBundleIsRefusedAndKept() async throws {
        let output = try makeEarlierOutput(at: root.appendingPathComponent("Out.lungfishref", isDirectory: true))
        let source = try makeAnnotatedBundle(in: output.appendingPathComponent("nested", isDirectory: true))

        await assertRefused(["--bundle", source.path, "--track", "genes", "--output-bundle", output.path, "--replace"])

        assertWholeSource(source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker(in: output).path), "the earlier output survives")
    }

    func testAMissingTrackKeepsTheEarlierOutput() async throws {
        let source = try makeAnnotatedBundle(in: root)
        let output = try makeEarlierOutput(at: root.appendingPathComponent("Genes.lungfishref", isDirectory: true))

        await assertRefused(["--bundle", source.path, "--track", "no-such-track", "--output-bundle", output.path, "--replace"])

        XCTAssertTrue(FileManager.default.fileExists(atPath: marker(in: output).path), "the earlier output survives a refused run")
    }

    func testNoMatchingFeatureKeepsTheEarlierOutput() async throws {
        let source = try makeAnnotatedBundle(in: root)
        let output = try makeEarlierOutput(at: root.appendingPathComponent("Genes.lungfishref", isDirectory: true))

        await assertRefused([
            "--bundle", source.path, "--track", "genes", "--feature-type", "CDS", "--output-bundle", output.path, "--replace",
        ])

        XCTAssertTrue(FileManager.default.fileExists(atPath: marker(in: output).path), "the earlier output survives a refused run")
    }

    func testReplaceStillReplacesTheEarlierOutput() async throws {
        let source = try makeAnnotatedBundle(in: root)
        let output = try makeEarlierOutput(at: root.appendingPathComponent("Genes.lungfishref", isDirectory: true))

        try await run(["--bundle", source.path, "--track", "genes", "--output-bundle", output.path, "--replace"])

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker(in: output).path), "the earlier output is replaced")
        let manifest = try BundleManifest.load(from: output)
        XCTAssertNotNil(manifest.genome, "the new bundle holds the extracted sequences")
        XCTAssertNil(try siblings(of: output).first { $0.hasPrefix(".") }, "no hidden copy is left beside the bundle")
    }

    func testWithoutReplaceAnExistingBundleIsRefusedAndKept() async throws {
        let source = try makeAnnotatedBundle(in: root)
        let output = try makeEarlierOutput(at: root.appendingPathComponent("Genes.lungfishref", isDirectory: true))

        await assertRefused(["--bundle", source.path, "--track", "genes", "--output-bundle", output.path])

        XCTAssertTrue(FileManager.default.fileExists(atPath: marker(in: output).path))
    }

    /// The build names a bundle with spaces in its name with underscores, so
    /// `--replace` replaces that bundle, the one the run writes.
    func testReplaceOfANameWithSpacesReplacesTheBundleTheBuildWrites() async throws {
        let source = try makeAnnotatedBundle(in: root)
        let typed = root.appendingPathComponent("out/My Genes.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: typed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await run(["--bundle", source.path, "--track", "genes", "--output-bundle", typed.path])
        let written = root.appendingPathComponent("out/My_Genes.lungfishref", isDirectory: true)
        try Data("earlier".utf8).write(to: marker(in: written))

        try await run(["--bundle", source.path, "--track", "genes", "--output-bundle", typed.path, "--replace"])

        XCTAssertTrue(FileManager.default.fileExists(atPath: written.appendingPathComponent("manifest.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker(in: written).path), "the bundle the build writes is replaced")
    }

    // MARK: - Helpers

    private func run(_ arguments: [String]) async throws {
        let command = try BundleExtractAnnotationsSubcommand.parse(arguments + ["--quiet"])
        try await command.run()
    }

    private func assertRefused(_ arguments: [String], file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await run(arguments)
            XCTFail("the run must be refused", file: file, line: line)
        } catch {
            XCTAssertNotEqual((error as? ExitCode)?.rawValue, 0, "\(error)", file: file, line: line)
        }
    }

    private func assertWholeSource(_ source: URL, file: StaticString = #filePath, line: UInt = #line) {
        for relative in ["manifest.json", "genome/sequence.fa", "genome/sequence.fa.fai", "annotations/genes.db", "annotations/genes.bed"] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: source.appendingPathComponent(relative).path),
                "the source keeps \(relative)", file: file, line: line
            )
        }
    }

    private func siblings(of url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
    }

    private func marker(in bundle: URL) -> URL {
        bundle.appendingPathComponent("earlier-marker.txt")
    }

    /// An earlier output bundle with a marker file that only it holds.
    private func makeEarlierOutput(at bundle: URL) throws -> URL {
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try BundleManifest(
            formatVersion: "1.0",
            name: "Earlier Output",
            identifier: "org.lungfish.tests.earlier-output",
            source: SourceInfo(organism: "Test organism", assembly: "earlier")
        ).save(to: bundle)
        try Data("earlier".utf8).write(to: marker(in: bundle))
        return bundle
    }

    /// `tiny.lungfishref` in `directory`: one chromosome and a gene track.
    private func makeAnnotatedBundle(in directory: URL) throws -> URL {
        let sequence = "ATGAAATAAGGGCCCTTT"
        let bundleURL = directory.appendingPathComponent("tiny.lungfishref", isDirectory: true)
        let genomeDir = bundleURL.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeDir, withIntermediateDirectories: true)
        try ">chr1\n\(sequence)\n".write(to: genomeDir.appendingPathComponent("sequence.fa"), atomically: true, encoding: .utf8)
        let offset = ">chr1\n".utf8.count
        try "chr1\t\(sequence.count)\t\(offset)\t\(sequence.count)\t\(sequence.count + 1)\n"
            .write(to: genomeDir.appendingPathComponent("sequence.fa.fai"), atomically: true, encoding: .utf8)
        try BundleManifest(
            formatVersion: "1.0",
            name: "Tiny Reference",
            identifier: "org.lungfish.tests.extract-annotations-replace",
            source: SourceInfo(organism: "Test organism", assembly: "test"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: Int64(sequence.count),
                chromosomes: [
                    ChromosomeInfo(
                        name: "chr1",
                        length: Int64(sequence.count),
                        offset: Int64(offset),
                        lineBases: sequence.count,
                        lineWidth: sequence.count + 1
                    ),
                ]
            )
        ).save(to: bundleURL)

        let annotationsDir = bundleURL.appendingPathComponent("annotations", isDirectory: true)
        try FileManager.default.createDirectory(at: annotationsDir, withIntermediateDirectories: true)
        let bedURL = annotationsDir.appendingPathComponent("genes.bed")
        let dbURL = annotationsDir.appendingPathComponent("genes.db")
        try ["chr1", "0", "9", "gene1", "0", "+", "0", "9", "0", "1", "9", "0", "gene", "ID=gene1;gene=gene1"]
            .joined(separator: "\t").appending("\n").write(to: bedURL, atomically: true, encoding: .utf8)
        let featureCount = try AnnotationDatabase.createFromBED(bedURL: bedURL, outputURL: dbURL)
        let manifest = try BundleManifest.load(from: bundleURL)
        try manifest.addingAnnotationTrack(AnnotationTrackInfo(
            id: "genes",
            name: "Genes",
            path: "annotations/genes.bed",
            databasePath: "annotations/genes.db",
            annotationType: .gene,
            featureCount: featureCount
        )).save(to: bundleURL)
        return bundleURL
    }
}
