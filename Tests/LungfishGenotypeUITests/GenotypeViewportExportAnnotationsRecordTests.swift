import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishGenotypeUI

/// The Excel export captures the sidecar the viewer holds, which shows the
/// built-in smart cohorts before any edit has saved them. The capture keeps
/// its name `annotations.json`, so the export's own record says what the
/// captured annotations are and how they stand against the bundle's file.
@MainActor
final class GenotypeViewportExportAnnotationsRecordTests: GenotypeResultViewportTestCase {
    private static let builtInNames = [
        "Incomplete haplotypes",
        "Needs review",
        "Homozygous",
        "Recombinants",
    ]

    private static let notReadFromTheFile =
        "the sidecar the viewer held at capture, not read from the bundle's annotations.json"

    func testTheCaptureOfAFreshBundleHoldsTheBuiltInsAndTheRecordSaysTheBundleHasNoSidecar() throws {
        let (root, bundleURL) = try makeBundleFolder()
        defer { TestTempDirectory.cleanup(root) }
        let controller = configuredController(bundleURL: bundleURL)
        let before = try GenotypeBundleTreeSnapshot.entries(of: root)

        let captured = try capturedAnnotationsData(of: controller)

        XCTAssertEqual(try GenotypeBundleTreeSnapshot.entries(of: root), before, "a capture is a read")
        XCTAssertEqual(
            try GenotypeAnnotationSidecar.decode(captured).smartCohorts.map(\.name),
            Self.builtInNames
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ONTGenotypeResultBundleData.annotationSidecarURL(forBundleAt: bundleURL).path
        ))
        XCTAssertEqual(
            GenotypeViewportExportService.annotationsRecord(captured: captured, bundleURL: bundleURL),
            [
                "annotationsSource": Self.notReadFromTheFile,
                "annotationsInBundle": "the bundle has no annotations.json",
            ]
        )
    }

    func testTheRecordSaysTheFileDiffersWhileTheBundleHoldsNoBuiltIns() throws {
        let (root, bundleURL) = try makeBundleFolder()
        defer { TestTempDirectory.cleanup(root) }
        var onDisk = GenotypeAnnotationSidecar.empty(generatedAt: "2026-08-01T00:00:00Z")
        onDisk.sampleStatusFlags = [
            .init(sample: "AnimalA", value: .reviewed, author: "cli", timestamp: "2026-08-01T00:00:00Z"),
        ]
        try onDisk.encoded().write(to: ONTGenotypeResultBundleData.annotationSidecarURL(forBundleAt: bundleURL))
        let controller = configuredController(bundleURL: bundleURL)

        let captured = try capturedAnnotationsData(of: controller)

        XCTAssertEqual(
            try GenotypeAnnotationSidecar.decode(captured).smartCohorts.map(\.name),
            Self.builtInNames
        )
        XCTAssertEqual(
            GenotypeViewportExportService.annotationsRecord(captured: captured, bundleURL: bundleURL)["annotationsInBundle"],
            "annotations.json differs from the captured sidecar"
        )
    }

    func testTheRecordSaysTheFileEqualsTheCaptureOnceAnEditSavedTheBuiltIns() throws {
        let (root, bundleURL) = try makeBundleFolder()
        defer { TestTempDirectory.cleanup(root) }
        let controller = configuredController(bundleURL: bundleURL)
        let store = try XCTUnwrap(controller.annotationStore)
        try store.addSampleNote(sample: "AnimalA", body: "Saved with the built-ins")

        let captured = try capturedAnnotationsData(of: controller)

        XCTAssertEqual(
            try GenotypeAnnotationSidecar.decode(captured).smartCohorts.map(\.name),
            Self.builtInNames
        )
        XCTAssertEqual(
            GenotypeViewportExportService.annotationsRecord(captured: captured, bundleURL: bundleURL),
            [
                "annotationsSource": Self.notReadFromTheFile,
                "annotationsInBundle": "annotations.json equals the captured sidecar",
            ]
        )
    }

    func testTheRecordSaysWhenTheFileCannotBeComparedWithTheCapture() throws {
        let (root, bundleURL) = try makeBundleFolder()
        defer { TestTempDirectory.cleanup(root) }
        try Data("not json".utf8).write(to: ONTGenotypeResultBundleData.annotationSidecarURL(forBundleAt: bundleURL))

        let unreadableFile = GenotypeViewportExportService.annotationsRecord(
            captured: try GenotypeAnnotationSidecar.empty(generatedAt: "2026-08-01T00:00:00Z").encoded(),
            bundleURL: bundleURL
        )
        let noCapture = GenotypeViewportExportService.annotationsRecord(captured: nil, bundleURL: bundleURL)

        XCTAssertEqual(
            unreadableFile["annotationsInBundle"],
            "annotations.json could not be compared with the captured sidecar"
        )
        XCTAssertEqual(
            noCapture["annotationsInBundle"],
            "annotations.json could not be compared with the captured sidecar"
        )
        XCTAssertEqual(unreadableFile["annotationsSource"], Self.notReadFromTheFile)
    }

    // MARK: - Fixtures

    /// A bundle folder inside its own root, so the lock file of a publication
    /// lands in the root and goes with it.
    private func makeBundleFolder() throws -> (root: URL, bundleURL: URL) {
        let root = try TestTempDirectory.make(prefix: "ExportAnnotationsRecord")
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        return (root, bundleURL)
    }

    /// A haplotyped result on a bundle folder, opened the way the app opens one.
    private func configuredController(bundleURL: URL) -> GenotypeResultViewController {
        let genotype = "NHP01222"
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "fixture", definitionSetID: "fixture", definitionSetName: "fixture",
            speciesName: "fixture", samples: ["AnimalA", "AnimalB"].map { sample in
                .init(sample: sample, calls: [
                    .init(locus: "MHC-A", sourceLocus: "MHC-A", haplotype1: "H1-call",
                          haplotype2: "H2-call", status: .called, matchedHaplotypes: [],
                          observedGenotypeCount: 1, observedGenotypes: [genotype]),
                ])
            }
        )
        let controller = makeMatrixAnnotationGuardedController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [], calls: [
            makeCall(sample: "AnimalA", genotype: genotype, reads: 9),
            makeCall(sample: "AnimalB", genotype: genotype, reads: 7),
        ], haplotypeAnalysis: analysis))
        return controller
    }

    /// The bytes the frozen Excel capture retains under `annotations.json`.
    private func capturedAnnotationsData(of controller: GenotypeResultViewController) throws -> Data {
        let snapshot = try controller.captureExcelExportSnapshot()
        let capture = try JSONDecoder().decode(
            GenotypeWorkbookPresentation.Snapshot.self,
            from: XCTUnwrap(snapshot.excelSnapshotData)
        )
        return try XCTUnwrap(capture.capturedScientificInputs?["annotations.json"])
    }
}
