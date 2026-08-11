import XCTest
@testable import LungfishApp
import LungfishKit

@MainActor
final class ClassifierFullBAMViewerIntegrationTests: XCTestCase {
    func testMainSplitCreatesTheAppOwnedDetachedEvidenceProvider() {
        let split = MainSplitViewController()
        split.loadViewIfNeeded()

        let provider = split.makeClassifierAlignmentEvidenceViewport()

        XCTAssertEqual(provider.viewer.windowStateScope, split.windowStateScope)
    }

    func testMissingEvidenceDoesNotCreateAReferenceBundleOrWriteFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("classifier-no-write-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let split = MainSplitViewController(); split.loadViewIfNeeded()
        let provider = split.makeClassifierAlignmentEvidenceViewport()
        let request = try ClassifierAlignmentEvidenceRequest(
            workflow: .esViritu,
            resultIdentity: .init(stableID: "result", finalResultURL: directory, provenanceID: "prov"),
            bamURL: directory.appendingPathComponent("missing.bam"),
            index: .init(url: directory.appendingPathComponent("missing.bam.bai"), kind: .bai),
            sample: .init(canonicalID: "S1"), contig: .init(name: "ctg", expectedLength: 1),
            referenceCandidate: nil,
            presentation: .init(workflowLabel: "EsViritu", resultLabel: "result", sampleLabel: "S1", contigLabel: "ctg")
        )
        provider.display(request)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("result.lungfishref").path))
    }

    func testSuccessfulValidatedEvidenceDisplayAndClearDoNotWriteAReferenceBundle() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("classifier-success-no-write-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bam = directory.appendingPathComponent("evidence.bam")
        let index = directory.appendingPathComponent("evidence.bam.bai")
        try Data([0x42, 0x41, 0x4D]).write(to: bam)
        try Data([0x42, 0x41, 0x49]).write(to: index)
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        let validator = ClassifierAlignmentEvidenceValidator(
            headerReader: { _ in "@SQ\tSN:ctg\tLN:1\n" },
            indexQuery: { _, _, _ in },
            fileManager: .default
        )
        let provider = ClassifierAlignmentEvidenceViewportController(validator: validator)
        let request = try ClassifierAlignmentEvidenceRequest(
            workflow: .nvd,
            resultIdentity: .init(stableID: "result", finalResultURL: directory, provenanceID: "prov"),
            bamURL: bam,
            index: .init(url: index, kind: .bai),
            sample: .init(canonicalID: "S1"), contig: .init(name: "ctg", expectedLength: 1),
            referenceCandidate: nil,
            presentation: .init(workflowLabel: "NVD", resultLabel: "result", sampleLabel: "S1", contigLabel: "ctg")
        )
        provider.display(request)
        for _ in 0..<100 where provider.status == .loading { await Task.yield() }
        XCTAssertEqual(provider.status, .available(referenceStrength: "not provided", reason: nil))
        provider.clear()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("result.lungfishref").path))
    }

    func testAllClassifierHostHidePathsClearTheirLeafEvidence() throws {
        let paths = [
            "Sources/LungfishApp/Views/Viewer/ViewerViewController+EsViritu.swift",
            "Sources/LungfishApp/Views/Viewer/ViewerViewController+TaxTriage.swift",
            "Sources/LungfishApp/Views/Viewer/ViewerViewController+Nvd.swift",
        ]
        for path in paths {
            let source = try String(contentsOfFile: path, encoding: .utf8)
            XCTAssertTrue(source.contains("clearClassifierAlignmentEvidence()"), path)
        }
    }
}
