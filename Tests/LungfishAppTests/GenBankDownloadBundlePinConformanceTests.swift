// GenBankDownloadBundlePinConformanceTests.swift - Pins the bundles the GenBank download builds
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishWorkflow
import LungfishTestSupport

/// Pins the bundle `GenBankBundleDownloadViewModel` builds from a recorded NCBI response. The
/// snapshots were recorded at the base of Phase 2.10 lane A44 (c68381a62), before the bundle
/// building moved into LungfishWorkflow, so the move and every later route must keep them. Each
/// case runs the managed bgzip and samtools faidx, so the class sits in the conformance tier and
/// skips without them unless `LUNGFISH_REQUIRE_TOOLS=1`. Record a snapshot again with
/// `LUNGFISH_PIN_SNAPSHOT_DIR=<folder>` only for a reviewed change of bundle.
final class GenBankDownloadBundlePinConformanceTests: XCTestCase {

    /// The default request fetches GFF3 and builds the annotation track from it.
    func testRecordWithGFF3BuildsTodaysBundle() async throws {
        let client = RecordedNCBIEFetchClient(
            genBank: NCBIDownloadPinFixtures.genBankRecord, gff3: .found(NCBIDownloadPinFixtures.genBankGFF3))
        try await assertBundle(client: client, pin: "genbank-record-with-gff3") { model, root in
            try await model.downloadAndBuild(accession: NCBIDownloadPinFixtures.genBankAccession, outputDirectory: root)
        }
    }

    /// NCBI holds no GFF3, so the fetch fails and the track comes from the GenBank FEATURES.
    func testRecordWithoutGFF3AtNCBIFallsBackToFeatures() async throws {
        let client = RecordedNCBIEFetchClient(genBank: NCBIDownloadPinFixtures.genBankRecord, gff3: .missing)
        try await assertBundle(client: client, pin: "genbank-record-gff3-missing") { model, root in
            try await model.downloadAndBuild(accession: NCBIDownloadPinFixtures.genBankAccession, outputDirectory: root)
        }
    }

    /// GFF3 turned off asks NCBI only for the record and builds the track from its FEATURES.
    func testRecordWithGFF3TurnedOffUsesFeatures() async throws {
        let client = RecordedNCBIEFetchClient(
            genBank: NCBIDownloadPinFixtures.genBankRecord, gff3: .found(NCBIDownloadPinFixtures.genBankGFF3))
        try await assertBundle(client: client, pin: "genbank-record-gff3-off") { model, root in
            try await model.downloadAndBuild(
                accession: NCBIDownloadPinFixtures.genBankAccession, outputDirectory: root,
                includeGFF3Annotations: false)
        }
    }

    /// A sequence with no GenBank record, as a Pathoplexus row gives it.
    func testSequenceBuildsTodaysBundle() async throws {
        let client = RecordedNCBIEFetchClient(genBank: "", gff3: .missing)
        try await assertBundle(client: client, pin: "genbank-sequence-pathoplexus") { model, root in
            try await model.buildBundleFromSequence(
                accession: "PP_00LGE01.1", title: "Lungfish stand-in Pathoplexus record",
                sequence: NCBIDownloadPinFixtures.pathoplexusSequence, outputDirectory: root,
                sourceDatabase: "Pathoplexus", sourceURL: URL(string: "https://pathoplexus.org/seq/PP_00LGE01.1"))
        }
    }

    // MARK: - Helpers

    private func assertBundle(
        client: RecordedNCBIEFetchClient,
        pin: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        build: (GenBankBundleDownloadViewModel, URL) async throws -> URL
    ) async throws {
        let model = GenBankBundleDownloadViewModel(
            ncbiService: NCBIService(apiKey: nil, httpClient: client, environment: [:]))
        do {
            try await model.validateTools()
        } catch {
            try ToolAvailability.skipOrFail("Managed bgzip and samtools are required: \(error)", file: file, line: line)
        }
        let root = try TestTempDirectory.make(prefix: "genbank-download-pin")
        defer { TestTempDirectory.cleanup(root) }

        let bundle = try await build(model, root)
        var snapshot = try await DownloadedBundleSnapshot.text(
            of: bundle, replacing: DownloadedBundleSnapshot.directoryReplacements(root, as: "<OUT>"))
        snapshot += (await client.requestedURLs).map { "\nrequest \($0)" }.joined()
        DownloadedBundleSnapshot.recordIfAsked(snapshot, name: pin)
        XCTAssertEqual(snapshot, try DownloadBundlePins.expected(pin), file: file, line: line)
    }
}

/// The recorded snapshots under `Fixtures/DownloadBundlePins`, each file ending in one line break.
enum DownloadBundlePins {
    static func expected(_ pin: String) throws -> String {
        let url = Bundle.module.resourceURL!
            .appendingPathComponent("Fixtures/DownloadBundlePins", isDirectory: true)
            .appendingPathComponent("\(pin).txt")
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.hasSuffix("\n") ? String(text.dropLast()) : text
    }
}
