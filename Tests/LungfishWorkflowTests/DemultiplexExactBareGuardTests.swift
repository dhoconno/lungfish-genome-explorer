// DemultiplexExactBareGuardTests.swift - Which runs the Exact Bare Barcode guard refuses, case by case (5.6 TV-DEMUX item 3)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `supportsExactBareBarcodeDemux` (`DemultiplexingPipeline+ExactBareMatching.swift:274-287`) returns false for five reasons: sample
// assignments, a dual-index kit, a kit that is neither single-end nor symmetric, a context that is not bare, and a barcode with an
// i5 sequence or a letter outside A, C, G and T. The refusal words of BIO-EXACT-BARE-RC item 3 must be true for each case, so this
// table pins each one. It changes no result and reads no words.

import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow

final class DemultiplexExactBareGuardTests: XCTestCase {
    private func config(_ kit: BarcodeKitDefinition, assignments: [FASTQSampleBarcodeAssignment] = []) -> DemultiplexConfig {
        DemultiplexConfig(
            inputURL: URL(fileURLWithPath: "/tmp/reads.fastq"), barcodeKit: kit,
            outputDirectory: URL(fileURLWithPath: "/tmp/out"), engine: .exactBareBarcode, sampleAssignments: assignments)
    }

    private func supports(_ kit: BarcodeKitDefinition, assignments: [FASTQSampleBarcodeAssignment] = []) -> Bool {
        DemultiplexingPipeline().supportsExactBareBarcodeDemux(config(kit, assignments: assignments))
    }

    private func custom(_ text: String) throws -> BarcodeKitDefinition {
        try BarcodeKitRegistry.loadCustomKit(data: Data(text.utf8), name: "guard-case")
    }

    private func builtIn(_ id: String) throws -> BarcodeKitDefinition {
        try XCTUnwrap(BarcodeKitRegistry.kit(byID: id), id)
    }

    private func assignment() -> FASTQSampleBarcodeAssignment {
        FASTQSampleBarcodeAssignment(
            sampleID: "S1", sampleName: "S1", forwardBarcodeID: "BC01", forwardSequence: "ACGTACGTAC")
    }

    // MARK: The runs that go ahead

    func testTheGuardAcceptsTheFluidigmKitAndACustomDefinitionWithNoKitLine() throws {
        XCTAssertTrue(supports(try builtIn("fluidigm-access-array")))
        XCTAssertTrue(supports(try custom("id,sequence\nBC01,ACGTACGTAC\nBC02,TTGGCCAATT\n")))
        XCTAssertTrue(supports(try custom("id,sequence\nBC01,acgtacgtac\n")), "lower case is read as upper case")
    }

    /// BIO-EXACT-BARE-RC item 2: of the built-in kits only Fluidigm Access Array reaches the matcher.
    func testOnlyTheFluidigmKitOfTheBuiltInKitsReachesTheMatcher() {
        XCTAssertEqual(BarcodeKitRegistry.builtinKits().filter { supports($0) }.map(\.id), ["fluidigm-access-array"])
    }

    // MARK: The five cases

    /// Case 1. No dialog or command line option gives sample assignments to this engine (`FastqCommand.swift:315-337` builds the
    /// config with none, `FASTQOperationCLIInvocationBuilder.swift:638-639` refuses to encode them), so a person cannot reach it.
    func testCase1SampleAssignmentsRefuseAnOtherwiseAcceptedKit() throws {
        let kit = try custom("id,sequence\nBC01,ACGTACGTAC\n")
        XCTAssertTrue(supports(kit))
        XCTAssertFalse(supports(kit, assignments: [assignment()]))
    }

    /// Case 2. A built-in dual-index kit (the command line) or a Custom Definition with a secondary sequence (both).
    func testCase2ADualIndexKitIsRefused() throws {
        let builtInDual = try builtIn("truseq-ht-dual")
        XCTAssertTrue(builtInDual.isDualIndexed)
        XCTAssertFalse(supports(builtInDual))
        let customDual = try custom("id,sequence,secondary_sequence\nBC01,ACGTACGTACGT,TTGGCCAATTGG\n")
        XCTAssertTrue(customDual.isDualIndexed)
        XCTAssertFalse(supports(customDual))
    }

    /// Case 3. Every built-in kit whose pairing is neither single-end nor symmetric is refused. The table prints each one
    /// with its other terms, to show whether case 3 ever stands alone.
    func testCase3AKitThatIsNeitherSingleEndNorSymmetricIsRefused() {
        let neither = BarcodeKitRegistry.builtinKits().filter { $0.pairingMode != .singleEnd && $0.pairingMode != .symmetric }
        XCTAssertFalse(neither.isEmpty)
        for kit in neither {
            XCTAssertFalse(supports(kit), kit.id)
            print("GUARD-TABLE case 3: \(kit.id) pairing \(kit.pairingMode) dual \(kit.isDualIndexed) bare \(kit.adapterContext is BareAdapterContext)")
        }
    }

    /// Case 4. A built-in Illumina, ONT or PacBio kit, or a Custom Definition with a kit line naming one, has a context that is
    /// not bare. A Custom Definition with no kit line has one that is.
    func testCase4AContextThatIsNotBareIsRefused() throws {
        for id in ["truseq-single-a", "truseq-single-b", "nextera-xt-v2", "ont-nbd114", "m13-universal-primers"] {
            XCTAssertFalse(supports(try builtIn(id)), id)
        }
        XCTAssertFalse(supports(try custom("# kit: truseq-single-a\nid,sequence\nBC01,ACGTACGTAC\n")), "a kit line naming an Illumina kit")
        XCTAssertTrue(supports(try custom("id,sequence\nBC01,ACGTACGTAC\n")), "no kit line")
    }

    /// Case 5. A barcode with a letter outside A, C, G and T, of more than 31 letters, or with an i5 sequence is refused. A
    /// definition that does not load at all is refused earlier, by the loader's own words.
    func testCase5ABarcodeWithALetterOutsideACGTOrOver31LettersIsRefused() throws {
        let rows = [
            "id,sequence\nBC01,ACGTNACGTA\n",
            "id,sequence\nBC01,ACGTRACGTA\n",
            "id,sequence\nBC01,\(String(repeating: "A", count: 32))\n",
        ]
        for text in rows {
            if let kit = try? custom(text) {
                XCTAssertFalse(supports(kit), text)
                print("GUARD-TABLE case 5: loads, guard refuses: \(text.split(separator: "\n").last ?? "")")
            } else {
                print("GUARD-TABLE case 5: refused at load: \(text.split(separator: "\n").last ?? "")")
            }
        }
        XCTAssertTrue(supports(try custom("id,sequence\nBC01,\(String(repeating: "A", count: 31))\n")), "31 letters is the longest")
    }
}
