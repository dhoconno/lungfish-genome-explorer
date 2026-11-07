// BarcodeDefinitionPlanLayoutTests.swift - A custom barcode definition keeps awkward sample names and its kit
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.3 lane DEMUXPLAN (D1b, L8). The Demux tab's table reaches the run as a custom definition. The definition
// must read back every name a person typed (SWIFT 6) and keep the platform, pairing and search of the kit the plan
// was made on (BIO pin 1), or a plan of the default Illumina kit falls into the bare search of a custom kit.

import XCTest
@testable import LungfishIO

final class BarcodeDefinitionPlanLayoutTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("barcode-definition-plan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    private func load(_ text: String, name: String = "plan") throws -> BarcodeKitDefinition {
        let url = root.appendingPathComponent("\(name).csv")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return try BarcodeKitRegistry.loadCustomKit(from: url, name: name)
    }

    /// SWIFT 6: a name with a comma or a quote is written as a quoted CSV field and reads back whole.
    func testDefinitionRoundTripsAwkwardSampleNames() throws {
        let kit = try load("""
            id,sequence,sample_name
            Water_blank,ATTACTCG,Water (blank)
            NTC_1,TCCGGAGA,"NTC, 1"
            O_Brien_A,CGCTCATT,"O'Brien ""A\"""
            plate_A1,GAGATTCC,plate/A1

            """)
        XCTAssertEqual(kit.barcodes.map(\.id), ["Water_blank", "NTC_1", "O_Brien_A", "plate_A1"])
        XCTAssertEqual(kit.barcodes.map(\.sampleName), ["Water (blank)", "NTC, 1", "O'Brien \"A\"", "plate/A1"])
        XCTAssertEqual(kit.barcodes.map(\.i7Sequence), ["ATTACTCG", "TCCGGAGA", "CGCTCATT", "GAGATTCC"])
    }

    /// BIO pin 1: a definition whose `# kit:` line names TruSeq Single Index Set A keeps the kit's Illumina platform, so
    /// the route owner reads the read names as it does for the kit itself, and holds only the definition's rows.
    func testDefinitionThatNamesItsKitKeepsTheKitsPlatformPairingAndSearch() throws {
        let truSeq = try XCTUnwrap(BarcodeKitRegistry.kit(byID: "truseq-single-a"))
        let kit = try load("""
            # kit: truseq-single-a
            id,sequence,sample_name
            S1,ATTACTCG,Sample 1
            S2,TCCGGAGA,Sample 2

            """)
        XCTAssertEqual(kit.platform, truSeq.platform, "the definition lost the kit's platform")
        XCTAssertEqual(kit.pairingMode, truSeq.pairingMode)
        XCTAssertEqual(kit.kitType, truSeq.kitType)
        XCTAssertEqual(kit.isDualIndexed, truSeq.isDualIndexed)
        XCTAssertEqual(kit.barcodes.map(\.id), ["S1", "S2"])

        // A long-read kit keeps its full adapter and barcode search, which a bare custom definition does not have.
        let native = BarcodeKitRegistry.ontNativeBarcoding24
        let first = try XCTUnwrap(native.barcodes.first)
        let ont = try load("""
            # kit: \(native.id)
            id,sequence,sample_name
            \(first.id),\(first.i7Sequence),Patient A

            """, name: "ont-plan")
        XCTAssertEqual(ont.platform, native.platform, "the ONT definition lost the kit's platform")
        XCTAssertEqual(ont.pairingMode, native.pairingMode)
        XCTAssertTrue(ont.searchesFullPlatformConstruct, "the ONT definition lost the kit's adapter search")
    }

    /// A `# kit:` line that names no kit of this version refuses in words that name the kit, since a definition that
    /// silently lost its kit would search the bases with a bare index.
    func testDefinitionThatNamesAnUnknownKitRefusesInWords() throws {
        XCTAssertThrowsError(try load("""
            # kit: no-such-kit
            id,sequence,sample_name
            S1,ATTACTCG,Sample 1

            """)) { error in
            XCTAssertTrue(error.localizedDescription.contains("no-such-kit"), error.localizedDescription)
        }
    }

    /// Review DEMUXPLAN-ARCH, should-fix 1: two `# kit:` lines that name different kits refuse in words that name both.
    func testDefinitionWithTwoDifferentKitLinesRefusesInWords() throws {
        XCTAssertThrowsError(try load("""
            # kit: truseq-single-a
            # kit: illumina-nextera
            id,sequence,sample_name
            S1,ATTACTCG,Sample 1

            """)) { error in
            for id in ["truseq-single-a", "illumina-nextera"] {
                XCTAssertTrue(error.localizedDescription.contains(id), error.localizedDescription)
            }
        }
    }

    /// A row whose index count differs from the kit the definition names refuses in words that name the row, since the
    /// kit's search would not find the row's second index.
    func testDefinitionWhoseIndexCountDiffersFromItsKitRefusesInWords() throws {
        XCTAssertThrowsError(try load("""
            # kit: truseq-single-a
            id,sequence,secondary_sequence,sample_name
            S1,ATTACTCG,TCCGGAGA,Sample 1

            """)) { error in
            XCTAssertTrue(error.localizedDescription.contains("S1"), error.localizedDescription)
        }
    }
}
