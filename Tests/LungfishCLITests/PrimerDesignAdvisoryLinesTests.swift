import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

/// The two scheme design commands print what the result card shows, one line for each advisory (G1).
final class PrimerDesignAdvisoryLinesTests: XCTestCase {
    private let inputID = UUID()

    private let varVAMPSpanWarning = "1 of 1 amplicon is outside the requested size range of 360 to 440 bp. "
        + "varVAMP_48 is 354 bp. varVAMP wrote it, so the scheme keeps it. "
        + "Check its length against your protocol before you order primers."
    private let olivarSpanWarning = "1 of 1 amplicon is outside the requested size range of 200 to 220 bp. "
        + "scheme_1 is 198 bp. Olivar wrote it, so the scheme keeps it. "
        + "Check its length against your protocol before you order primers."

    /// Writes a saved analysis folder whose result document records `warnings` for the target's input.
    private func savedAnalysis(engine: PrimerSchemeEngine, warnings: [String]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("advisory-lines-\(UUID().uuidString).lungfishprimeranalysis")
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("results"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let assays = [
            PrimerSchemeAssay(id: UUID(), start: 0, end: 515, memberIDs: [], pool: "1",
                status: .selected, rank: nil, nativeMetadata: [:]),
            PrimerSchemeAssay(id: UUID(), start: 495, end: 990, memberIDs: [], pool: "2",
                status: .selected, rank: nil, nativeMetadata: [:]),
        ]
        let target = PrimerSchemeTarget(id: UUID(), label: "Mamu-A1", referencePath: "native/ref.fasta",
            referenceID: "consensus", referenceLength: 1000, sourceInputID: inputID,
            bindingProjectionPath: "results/map.json", assays: assays, oligos: [])
        let resultID = UUID()
        var resolution: [String: PrimerSchemeJSONValue] = [:]
        if !warnings.isEmpty {
            resolution["coverageDiagnostics"] = .object([inputID.uuidString.lowercased(): .object([
                "nativeWarnings": .array(warnings.map { .string($0) }),
            ])])
        }
        let document = PrimerSchemeResultsDocument(analysisID: UUID(), runID: UUID(), resultID: resultID,
            engine: engine, engineVersion: engine == .olivar ? "1.3.3" : "1.3.2", adapterVersion: "1.0.0",
            mode: .tiled, resolvedOptions: ["adapterResolution": .object(resolution)],
            results: [.init(id: resultID, inputIDs: [inputID], targets: [target])],
            artifacts: [], provenancePath: "native/provenance-v1.json")
        try JSONEncoder().encode(document).write(
            to: folder.appendingPathComponent(PrimerSchemeResultsDocument.storedRelativePath))
        return folder
    }

    func testVarVAMPAnalysisPrintsItsRecordedWarningUnderTheTargetLabel() throws {
        let folder = try savedAnalysis(engine: .varvamp, warnings: [varVAMPSpanWarning])
        XCTAssertEqual(PrimerDesignCommand.advisoryLines(analysisURL: folder),
                       ["[warning] Mamu-A1: varVAMP warning: \(varVAMPSpanWarning)"])
    }

    func testOlivarAnalysisPrintsItsRecordedWarningUnderTheTargetLabel() throws {
        let folder = try savedAnalysis(engine: .olivar, warnings: [olivarSpanWarning])
        XCTAssertEqual(PrimerDesignCommand.advisoryLines(analysisURL: folder),
                       ["[warning] Mamu-A1: Olivar warning: \(olivarSpanWarning)"])
    }

    func testOlivarAnalysisWithoutWarningsPrintsNothing() throws {
        let folder = try savedAnalysis(engine: .olivar, warnings: [])
        XCTAssertEqual(PrimerDesignCommand.advisoryLines(analysisURL: folder), [])
    }

    func testFolderWithoutASavedResultPrintsNothing() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("advisory-lines-empty-\(UUID().uuidString)")
        XCTAssertEqual(PrimerDesignCommand.advisoryLines(analysisURL: folder), [])
    }
}
