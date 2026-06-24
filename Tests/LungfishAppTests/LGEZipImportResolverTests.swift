// LGEZipImportResolverTests.swift - ZIP-compressed LGE object import resolution
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishIO
import XCTest
@testable import LungfishApp

final class LGEZipImportResolverTests: XCTestCase {
    private let fileManager = FileManager.default
    private var tempRoots: [URL] = []

    override func tearDownWithError() throws {
        for url in tempRoots {
            try? fileManager.removeItem(at: url)
        }
        tempRoots.removeAll()
        try super.tearDownWithError()
    }

    func testResolverExtractsSingleMHCReferenceBundleZipAndCleansTemporaryExtraction() throws {
        let root = try makeTempDirectory()
        let projectURL = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        let bundleURL = sourceRoot.appendingPathComponent("Example.lungfishmhcref", isDirectory: true)
        try fileManager.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try writeMHCReferenceBundle(at: bundleURL)

        let archiveURL = root.appendingPathComponent("Example.lungfishmhcref.zip")
        try runZip(workingDirectory: sourceRoot, archiveURL: archiveURL, entries: ["Example.lungfishmhcref"])

        let batch = try LGEZipImportResolver().resolve(urls: [archiveURL], projectURL: projectURL)

        XCTAssertTrue(fileManager.fileExists(atPath: archiveURL.path), "The original ZIP must remain untouched.")
        XCTAssertTrue(batch.failures.isEmpty)
        XCTAssertEqual(batch.sourceURLs.map(\.lastPathComponent), ["Example.lungfishmhcref"])
        let extractedBundleURL = try XCTUnwrap(batch.sourceURLs.first)
        XCTAssertTrue(extractedBundleURL.path.contains("/Project.lungfish/.tmp/sidebar-zip-import-"))
        XCTAssertTrue(MHCAmpliconReferenceBundle.isBundleURL(extractedBundleURL))

        batch.cleanup()

        XCTAssertFalse(
            fileManager.fileExists(atPath: extractedBundleURL.path),
            "Cleanup should remove the temporary extracted bundle after import has consumed it."
        )
        XCTAssertTrue(fileManager.fileExists(atPath: archiveURL.path), "Cleanup must not remove the original ZIP.")
    }

    func testResolverRejectsZipWithoutRecognizedLGEObject() throws {
        let root = try makeTempDirectory()
        let projectURL = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        try fileManager.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try "not an LGE object\n".write(
            to: sourceRoot.appendingPathComponent("README.txt"),
            atomically: true,
            encoding: .utf8
        )

        let archiveURL = root.appendingPathComponent("Plain.zip")
        try runZip(workingDirectory: sourceRoot, archiveURL: archiveURL, entries: ["README.txt"])

        let batch = try LGEZipImportResolver().resolve(urls: [archiveURL], projectURL: projectURL)

        XCTAssertTrue(batch.sourceURLs.isEmpty)
        XCTAssertEqual(batch.failures.map(\.kind), [.noRecognizedLGEObject])
        XCTAssertTrue(fileManager.fileExists(atPath: archiveURL.path))

        batch.cleanup()
    }

    func testResolverRejectsZipWithMultipleRecognizedLGEObjects() throws {
        let root = try makeTempDirectory()
        let projectURL = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        try fileManager.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try writeMHCReferenceBundle(at: sourceRoot.appendingPathComponent("Alpha.lungfishmhcref", isDirectory: true))
        try fileManager.createDirectory(
            at: sourceRoot.appendingPathComponent("Beta.lungfishref", isDirectory: true),
            withIntermediateDirectories: true
        )

        let archiveURL = root.appendingPathComponent("Ambiguous.zip")
        try runZip(
            workingDirectory: sourceRoot,
            archiveURL: archiveURL,
            entries: ["Alpha.lungfishmhcref", "Beta.lungfishref"]
        )

        let batch = try LGEZipImportResolver().resolve(urls: [archiveURL], projectURL: projectURL)

        XCTAssertTrue(batch.sourceURLs.isEmpty)
        XCTAssertEqual(batch.failures.map(\.kind), [.multipleRecognizedLGEObjects])
        XCTAssertTrue(fileManager.fileExists(atPath: archiveURL.path))

        batch.cleanup()
    }

    func testResolverLeavesNonZipURLsUntouched() throws {
        let root = try makeTempDirectory()
        let fastaURL = root.appendingPathComponent("reads.fa")
        try ">seq\nACGT\n".write(to: fastaURL, atomically: true, encoding: .utf8)

        let batch = try LGEZipImportResolver().resolve(urls: [fastaURL], projectURL: nil)

        XCTAssertEqual(batch.sourceURLs, [fastaURL.standardizedFileURL])
        XCTAssertTrue(batch.failures.isEmpty)
        batch.cleanup()
        XCTAssertTrue(fileManager.fileExists(atPath: fastaURL.path))
    }

    private func makeTempDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("lge-zip-import-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        tempRoots.append(url)
        return url
    }

    private func writeMHCReferenceBundle(at bundleURL: URL) throws {
        try fileManager.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try ">ref\nACGT\n".write(
            to: bundleURL.appendingPathComponent("reference.fa"),
            atomically: true,
            encoding: .utf8
        )
        let manifest = MHCAmpliconReferenceBundleManifest(
            name: "Example",
            referenceFastaPath: "reference.fa",
            haplotypeDefinitionPaths: [],
            defaultHaplotypeDefinitionID: nil,
            metrics: MHCAmpliconReferenceBundleMetrics(referenceCount: 1, haplotypeDefinitionCount: 0),
            createdAt: "2026-06-24T00:00:00Z"
        )
        try MHCAmpliconReferenceBundle.writeManifest(manifest, to: bundleURL)
    }

    private func runZip(workingDirectory: URL, archiveURL: URL, entries: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = workingDirectory
        process.arguments = ["-qry", archiveURL.path] + entries
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
