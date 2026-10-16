// ClassifierBlastExtractionConfigTests.swift - BLAST Verify reads from an indexed BAM
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// BLAST Verify on a TaxTriage or EsViritu result extracts the reads of the
// selected organism from the result's BAM. Region extraction refuses a BAM
// without an explicit index, so the config the BLAST handlers build must carry
// the index the result view hands them. Dropping it failed every BLAST Verify
// with "An explicit index is required".

import XCTest
@testable import LungfishApp
import LungfishWorkflow

final class ClassifierBlastExtractionConfigTests: XCTestCase {
    private let bam = URL(fileURLWithPath: "/tmp/run/minimap2/S1.S1.dwnld.references.bam")
    private let index = URL(fileURLWithPath: "/tmp/run/minimap2/S1.S1.dwnld.references.bam.bai")
    private let temp = URL(fileURLWithPath: "/tmp/blast-temp", isDirectory: true)

    func testConfigCarriesTheExplicitIndex() {
        let config = ViewerViewController.classifierBlastExtractionConfig(
            bamURL: bam, indexURL: index, accessions: ["NC_045512.2"], outputDirectory: temp
        )
        XCTAssertEqual(config.bamURL, bam)
        XCTAssertEqual(config.indexURL, index)
        XCTAssertEqual(config.regions, ["NC_045512.2"])
        XCTAssertFalse(config.fallbackToAll)
        XCTAssertTrue(config.deduplicateReads)
        XCTAssertEqual(config.outputDirectory, temp)
        XCTAssertEqual(config.outputBaseName, "blast_extract")
    }

    func testMissingIndexStillFailsAsExplicitIndexRequired() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fakeBAM = dir.appendingPathComponent("x.bam")
        FileManager.default.createFile(atPath: fakeBAM.path, contents: Data())

        let config = ViewerViewController.classifierBlastExtractionConfig(
            bamURL: fakeBAM, indexURL: nil, accessions: ["NC_045512.2"], outputDirectory: dir
        )
        do {
            _ = try await ReadExtractionService().extractByBAMRegion(config: config)
            XCTFail("extraction without an index must refuse")
        } catch let error as ExtractionError {
            guard case .explicitIndexRequired = error else { return XCTFail("unexpected \(error)") }
        }
    }
}
