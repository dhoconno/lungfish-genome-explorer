import XCTest
@testable import LungfishWorkflow

final class VarVAMPCoverageAdvisoriesTests: XCTestCase {
    private let inputID = UUID()

    private func document(
        engine: PrimerSchemeEngine = .varvamp, mode: PrimerSchemeMode = .tiled,
        requestedThreshold: PrimerSchemeJSONValue = .null,
        resolution: [String: PrimerSchemeJSONValue], coveredEnd: Int
    ) -> (PrimerSchemeResultsDocument, PrimerSchemeTarget) {
        let assays = [
            PrimerSchemeAssay(id: UUID(), start: 0, end: coveredEnd / 2 + 20, memberIDs: [], pool: "1",
                status: .selected, rank: nil, nativeMetadata: [:]),
            PrimerSchemeAssay(id: UUID(), start: coveredEnd / 2, end: coveredEnd, memberIDs: [], pool: "2",
                status: .selected, rank: nil, nativeMetadata: [:]),
        ]
        let target = PrimerSchemeTarget(id: UUID(), label: "Mamu-A1", referencePath: "native/ref.fasta",
            referenceID: "consensus", referenceLength: 1000, sourceInputID: inputID,
            bindingProjectionPath: "results/map.json", assays: assays, oligos: [])
        let resultID = UUID()
        let document = PrimerSchemeResultsDocument(analysisID: UUID(), runID: UUID(), resultID: resultID,
            engine: engine, engineVersion: "1.3.2", adapterVersion: "1.0.0", mode: mode,
            resolvedOptions: [
                "cumulativeConsensusThreshold": requestedThreshold,
                "adapterResolution": .object(resolution),
            ],
            results: [.init(id: resultID, inputIDs: [inputID], targets: [target])],
            artifacts: [], provenancePath: "native/provenance-v1.json")
        return (document, target)
    }

    private var key: String { inputID.uuidString.lowercased() }

    /// The adapter's words for amplicons outside the requested size range (G1), one per engine.
    private let varVAMPSpanWarning = "2 of 3 amplicons are outside the requested size range of 360 to 440 bp. "
        + "varVAMP_48 is 354 bp. varVAMP_63 is 444 bp. varVAMP wrote them, so the scheme keeps them. "
        + "Check their lengths against your protocol before you order primers."
    private let olivarSpanWarning = "1 of 1 amplicon is outside the requested size range of 200 to 220 bp. "
        + "scheme_1 is 198 bp. Olivar wrote it, so the scheme keeps it. "
        + "Check its length against your protocol before you order primers."

    /// An adapter resolution that holds `warnings` for this document's input, the shape both adapters write.
    private func recorded(_ warnings: [String], inputKey: String? = nil) -> [String: PrimerSchemeJSONValue] {
        ["coverageDiagnostics": .object([inputKey ?? key: .object([
            "nativeWarnings": .array(warnings.map { .string($0) }),
        ])])]
    }

    func testRecordedDiagnosticsExplainThresholdWarningsAndSingleChain() {
        let (document, target) = document(resolution: [
            "nativeCumulativeConsensusThresholds": .object([key: .number(0.99)]),
            "coverageDiagnostics": .object([key: .object([
                "sequenceCount": .integer(6),
                "thresholdSource": .string("automatic"),
                "effectiveThreshold": .number(0.99),
                "requiredAgreeing": .integer(6),
                "equivalentThresholdRange": .array([.number(0.84), .integer(1)]),
                "nativeWarnings": .array([.string("coverage < 70 %. Possible solutions: lower threshold")]),
                "tilingModel": .string("longestContiguousChain"),
            ])]),
        ], coveredEnd: 666)

        let advisories = document.varVAMPCoverageAdvisories(for: target)
        XCTAssertEqual(advisories.map(\.severity), [.info, .warning, .warning])
        XCTAssertEqual(advisories[0].message,
            "Consensus threshold 0.99, chosen automatically by varVAMP. A base counts as conserved only when 6 of 6 sequences agree. Any threshold from 0.84 to 1.00 gives the same consensus for this alignment.")
        XCTAssertEqual(advisories[1].message, "varVAMP warning: coverage < 70 %. Possible solutions: lower threshold")
        XCTAssertTrue(advisories[2].message.hasPrefix("varVAMP keeps only the longest unbroken chain"))
    }

    func testLegacyBundleStillReportsStoredThresholdWithoutCounts() {
        let (document, target) = document(requestedThreshold: .number(0.8), resolution: [
            "nativeCumulativeConsensusThresholds": .object([key: .number(0.8)]),
        ], coveredEnd: 990)

        let advisories = document.varVAMPCoverageAdvisories(for: target)
        XCTAssertEqual(advisories, [.init(severity: .info, message: "Consensus threshold 0.80, as requested.")])
    }

    func testChainAdvisoryIsTiledOnlyAndOtherEnginesGetNothing() {
        let (single, singleTarget) = document(mode: .single, resolution: [:], coveredEnd: 300)
        XCTAssertEqual(single.varVAMPCoverageAdvisories(for: singleTarget), [])
        let (olivar, olivarTarget) = document(engine: .olivar, resolution: [:], coveredEnd: 300)
        XCTAssertEqual(olivar.varVAMPCoverageAdvisories(for: olivarTarget), [])
    }

    func testSchemeAdvisoriesShowTheRecordedVarVAMPSpanWarning() {
        let (document, target) = document(resolution: recorded([varVAMPSpanWarning]), coveredEnd: 990)
        XCTAssertEqual(document.schemeAdvisories(for: target),
                       [.init(severity: .warning, message: "varVAMP warning: " + varVAMPSpanWarning)])
    }

    func testSchemeAdvisoriesShowTheRecordedOlivarSpanWarning() {
        let (document, target) = document(engine: .olivar, resolution: recorded([olivarSpanWarning]), coveredEnd: 300)
        XCTAssertEqual(document.schemeAdvisories(for: target),
                       [.init(severity: .warning, message: "Olivar warning: " + olivarSpanWarning)])
    }

    func testSchemeAdvisoriesForOlivarWithoutAWarningStayEmpty() {
        let (olivar, target) = document(engine: .olivar, resolution: [:], coveredEnd: 300)
        XCTAssertEqual(olivar.schemeAdvisories(for: target), [])
        let other = UUID().uuidString.lowercased()
        let (elsewhere, elsewhereTarget) = document(
            engine: .olivar, resolution: recorded([olivarSpanWarning], inputKey: other), coveredEnd: 300)
        XCTAssertEqual(elsewhere.schemeAdvisories(for: elsewhereTarget), [], "another input's warning is not this target's")
    }

    func testSchemeAdvisoriesForVarVAMPAreTheCoverageAdvisories() {
        let (document, target) = document(resolution: recorded([varVAMPSpanWarning]), coveredEnd: 666)
        XCTAssertEqual(document.schemeAdvisories(for: target), document.varVAMPCoverageAdvisories(for: target))
        XCTAssertEqual(document.schemeAdvisories(for: target).count, 2, "the warning and the single-chain explanation")
    }

    func testViewerPresentationCarriesTheRecordedSpanWarningOfEachEngine() throws {
        let cases: [(engine: PrimerSchemeEngine, warning: String, prefix: String)] = [
            (.varvamp, varVAMPSpanWarning, "varVAMP warning: "),
            (.olivar, olivarSpanWarning, "Olivar warning: "),
        ]
        for item in cases {
            let (document, _) = document(engine: item.engine, resolution: recorded([item.warning]), coveredEnd: 990)
            let review = try XCTUnwrap(PrimerSchemeViewerAdapter.adapt(document: document).reviews.first)
            XCTAssertEqual(review.advisories.map(\.message), [item.prefix + item.warning], "\(item.engine)")
            XCTAssertEqual(review.advisories.map(\.severity), [.warning], "\(item.engine)")
        }
    }
}
