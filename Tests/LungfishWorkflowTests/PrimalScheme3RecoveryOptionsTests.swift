import Foundation
import XCTest
@testable import LungfishWorkflow
import LungfishIO

final class PrimalScheme3RecoveryOptionsTests: XCTestCase {
    func testDefaultOffSalvageIsACompleteNoOpForLegacyCutoffs() throws {
        let options = PrimalScheme3LegacySalvageOptions()
        XCTAssertNoThrow(try options.validate(selectionAlgorithm: .legacy, grouping: .combined, strictCutoff: -30))
        XCTAssertEqual(options.requestedOptionNames, [])
        var args = [String](); options.appendRequestedArguments(to: &args)
        XCTAssertTrue(args.isEmpty)
    }

    func testBoundedSalvageRejectsEntropyAndGapParentIsIndependent() throws {
        let salvage = PrimalScheme3LegacySalvageOptions(mode: .bounded)
        XCTAssertThrowsError(try salvage.validate(selectionAlgorithm: .legacy, grouping: .combined, panelMode: .entropy))
        let expansion = PrimalScheme3GapExpansionOptions(mode: .bounded)
        XCTAssertThrowsError(try expansion.validate(hasParent: false))
    }

    func testBoundedSalvageRejectsAmpliconCaps() {
        let options = PrimalScheme3DesignOptions(ampliconSize: 200, poolCount: 2,
            maxAmplicons: 1, legacySalvageOptions: .init(mode: .bounded))
        XCTAssertThrowsError(try PrimalScheme3DesignPipeline.arguments(
            inputs: [URL(fileURLWithPath: "/input.fasta")], output: URL(fileURLWithPath: "/output"),
            grouping: .combined, options: options))
    }

    func testRecoveryDefaultsAndRequestedArgumentsRoundTrip() throws {
        let options = PrimalScheme3GapExpansionOptions(mode: .bounded)
        XCTAssertEqual(options.maxAnchorsPerMSA, 2_000)
        XCTAssertEqual(options.maxPairsPerMSA, 1_000)
        var args = [String](); options.appendRequestedArguments(to: &args)
        XCTAssertEqual(args, ["--gap-expansion", "bounded"])
        let decoded = try JSONDecoder().decode(PrimalScheme3GapExpansionOptions.self,
            from: JSONEncoder().encode(options))
        XCTAssertEqual(decoded, options)
    }

    func testParentResolverRejectsAmbiguousNativeResults() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["one", "two"] {
            let dir = root.appendingPathComponent("native/\(name)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for file in ["primer.bed", "reference.fasta", "config.json"] { try Data().write(to: dir.appendingPathComponent(file)) }
        }
        XCTAssertThrowsError(try PrimalScheme3ParentResolver.resolve(root))
    }

    func testSavedInputsVerifyAndRehydrateFullRows() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "saved-inputs-\(UUID().uuidString).lungfishprimeranalysis", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inputID = UUID()
        let resultID = UUID()
        let native = root.appendingPathComponent("native/\(resultID.uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source-inputs/\(inputID.uuidString)/source.fasta")
        let consumed = root.appendingPathComponent("inputs/\(inputID.uuidString)-consumed.fasta")
        let rowMap = root.appendingPathComponent("inputs/\(inputID.uuidString)-row-map.json")
        try FileManager.default.createDirectory(at: native, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: consumed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(">raw-a\nACGTAC\n>raw-b\nTGCATG\n".utf8).write(to: source)
        try Data(">native-a\nACGTAC\n>native-b\nTGCATG\n".utf8).write(to: consumed)
        let mapObject: [String: Any] = [
            "rows": [
                ["rowIndex": 0, "originalHeader": "raw-a", "normalizedHeader": "native-a"],
                ["rowIndex": 1, "originalHeader": "raw-b", "normalizedHeader": "native-b"],
            ]
        ]
        try JSONSerialization.data(withJSONObject: mapObject).write(to: rowMap)
        for name in ["primer.bed", "reference.fasta", "config.json"] {
            try Data("fixture\n".utf8).write(to: native.appendingPathComponent(name))
        }
        func artifact(_ path: String, role: String) throws -> PrimerAnalysisArtifact {
            let url = root.appendingPathComponent(path)
            return PrimerAnalysisArtifact(relativePath: path, role: role, format: url.pathExtension,
                sha256: try ProvenanceFileHasher.sha256(of: url),
                byteSize: try ProvenanceFileHasher.fileSize(of: url))
        }
        let input = PrimerAnalysisInput(id: inputID, label: "fixture", artifactPaths: [
            "source-inputs/\(inputID.uuidString)/source.fasta",
            "inputs/\(inputID.uuidString)-consumed.fasta",
            "inputs/\(inputID.uuidString)-row-map.json",
        ])
        let result = PrimerAnalysisResult(id: resultID, label: "native", inputIDs: [inputID], artifactPaths: [
            "native/\(resultID.uuidString)/primer.bed",
            "native/\(resultID.uuidString)/reference.fasta",
            "native/\(resultID.uuidString)/config.json",
        ])
        let artifacts = try input.artifactPaths.map { try artifact($0, role: "input") }
            + result.artifactPaths.map { try artifact($0, role: "nativeOutput") }
        let manifest = PrimerAnalysisManifest(analysisID: UUID(), runID: UUID(), inputs: [input],
            results: [result], artifacts: artifacts, provenance: artifacts[0], grouping: .combined,
            publishedRootPath: root.path)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("manifest.json"))

        let saved = try XCTUnwrap(PrimalScheme3ParentResolver.savedInputs(parent: root, native: native))
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved[0].sourceRows.map(\.title), ["raw-a", "raw-b"])
        XCTAssertEqual(saved[0].consumedRows.map(\.title), ["native-a", "native-b"])
        XCTAssertTrue(saved[0].preservesAmbiguity)
        XCTAssertEqual(saved[0].evidenceFiles.count, 4)
    }
}
