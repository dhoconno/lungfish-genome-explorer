// PrimerSchemeImportTests.swift - PrimerSchemeImportViewModel produces a valid bundle
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishIO

final class PrimerSchemeImportTests: XCTestCase {
    private var tempProjectURL: URL!

    override func setUpWithError() throws {
        tempProjectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimerSchemeImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempProjectURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempProjectURL)
    }

    @MainActor
    func testImportFromBEDOnlyProducesValidBundle() throws {
        let bedURL = try writeSampleBED()
        let viewModel = PrimerSchemeImportViewModel()

        let result = try viewModel.performImport(
            bedURL: bedURL,
            fastaURL: nil,
            attachments: [],
            name: "my-scheme",
            displayName: "My Scheme",
            canonicalAccession: "MN908947.3",
            equivalentAccessions: [],
            projectURL: tempProjectURL
        )

        let loaded = try PrimerSchemeBundle.load(from: result.bundleURL)
        XCTAssertEqual(loaded.manifest.name, "my-scheme")
        XCTAssertEqual(loaded.manifest.displayName, "My Scheme")
        XCTAssertEqual(loaded.manifest.canonicalAccession, "MN908947.3")
        XCTAssertTrue(loaded.manifest.equivalentAccessions.isEmpty)
        XCTAssertEqual(loaded.manifest.primerCount, 4)
        XCTAssertEqual(loaded.manifest.ampliconCount, 2)
        XCTAssertEqual(loaded.manifest.source, "imported")
        XCTAssertNil(loaded.fastaURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: loaded.provenanceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: result.bundleURL.appendingPathComponent(".lungfish-provenance.json").path
        ))
    }

    @MainActor
    func testImportWithFASTAAndEquivalentAccessions() throws {
        let bedURL = try writeSampleBED()
        let fastaURL = try writeSampleFASTA()
        let viewModel = PrimerSchemeImportViewModel()

        let result = try viewModel.performImport(
            bedURL: bedURL,
            fastaURL: fastaURL,
            attachments: [],
            name: "variant-panel",
            displayName: "Variant Panel",
            canonicalAccession: "MN908947.3",
            equivalentAccessions: ["NC_045512.2", " ", "KY405475.1"],
            projectURL: tempProjectURL
        )

        let loaded = try PrimerSchemeBundle.load(from: result.bundleURL)
        XCTAssertEqual(loaded.manifest.equivalentAccessions, ["NC_045512.2", "KY405475.1"])
        XCTAssertNotNil(loaded.fastaURL)
    }

    @MainActor
    func testImportRejectsDuplicateName() throws {
        let bedURL = try writeSampleBED()
        let viewModel = PrimerSchemeImportViewModel()

        _ = try viewModel.performImport(
            bedURL: bedURL,
            fastaURL: nil,
            attachments: [],
            name: "my-scheme",
            displayName: "My Scheme",
            canonicalAccession: "MN908947.3",
            equivalentAccessions: [],
            projectURL: tempProjectURL
        )

        XCTAssertThrowsError(
            try viewModel.performImport(
                bedURL: bedURL,
                fastaURL: nil,
                attachments: [],
                name: "my-scheme",
                displayName: "Different Display",
                canonicalAccession: "MN908947.3",
                equivalentAccessions: [],
                projectURL: tempProjectURL
            )
        ) { error in
            guard case PrimerSchemeImportViewModel.ImportError.bundleAlreadyExists = error else {
                XCTFail("expected bundleAlreadyExists, got \(error)")
                return
            }
        }
    }

    @MainActor
    func testImportRejectsEmptyName() throws {
        let bedURL = try writeSampleBED()
        let viewModel = PrimerSchemeImportViewModel()

        XCTAssertThrowsError(
            try viewModel.performImport(
                bedURL: bedURL,
                fastaURL: nil,
                attachments: [],
                name: "   ",
                displayName: "Whatever",
                canonicalAccession: "MN908947.3",
                equivalentAccessions: [],
                projectURL: tempProjectURL
            )
        ) { error in
            guard case PrimerSchemeImportViewModel.ImportError.emptyName = error else {
                XCTFail("expected emptyName, got \(error)")
                return
            }
        }
    }

    @MainActor
    func testAmpliconCountStripsVariantTagSuffix() throws {
        // Regression: names like QIAseq_221-2_LEFT must collapse to QIAseq_221.
        let bedURL = tempProjectURL.appendingPathComponent("primers.bed")
        let content = """
            MN908947.3\t27\t51\tQIAseq_221_LEFT\t1\t+
            MN908947.3\t31\t56\tQIAseq_221-2_LEFT\t1\t+
            MN908947.3\t254\t276\tQIAseq_221_RIGHT\t1\t-
            MN908947.3\t258\t280\tQIAseq_221-2_RIGHT\t1\t-
            """
        try content.write(to: bedURL, atomically: true, encoding: .utf8)
        let viewModel = PrimerSchemeImportViewModel()

        let result = try viewModel.performImport(
            bedURL: bedURL,
            fastaURL: nil,
            attachments: [],
            name: "qiaseq-variant",
            displayName: "QIAseq with variants",
            canonicalAccession: "MN908947.3",
            equivalentAccessions: [],
            projectURL: tempProjectURL
        )

        let loaded = try PrimerSchemeBundle.load(from: result.bundleURL)
        XCTAssertEqual(loaded.manifest.primerCount, 4)
        XCTAssertEqual(loaded.manifest.ampliconCount, 1)
    }

    // MARK: - Fixtures

    private func writeSampleBED() throws -> URL {
        let url = tempProjectURL.appendingPathComponent("sample-primers.bed")
        let content = """
            MN908947.3\t27\t51\tPanel_1_LEFT\t1\t+
            MN908947.3\t254\t276\tPanel_1_RIGHT\t1\t-
            MN908947.3\t404\t426\tPanel_2_LEFT\t2\t+
            MN908947.3\t612\t634\tPanel_2_RIGHT\t2\t-
            """
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func writeSampleFASTA() throws -> URL {
        let url = tempProjectURL.appendingPathComponent("sample-primers.fasta")
        try ">Panel_1_LEFT\nACGT\n>Panel_1_RIGHT\nACGT\n".write(
            to: url,
            atomically: true,
            encoding: .utf8
        )
        return url
    }
}
