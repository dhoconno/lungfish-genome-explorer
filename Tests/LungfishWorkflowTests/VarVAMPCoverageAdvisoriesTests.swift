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
}
