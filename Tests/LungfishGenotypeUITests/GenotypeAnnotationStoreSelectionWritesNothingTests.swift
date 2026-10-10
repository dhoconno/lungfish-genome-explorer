import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishGenotypeUI

/// Selecting a haplotyped genotype result in the viewer writes no byte next to
/// it, whether the bundle is fresh or was annotated from the command line.
/// The analyst still sees the four built-in smart cohorts, and the first edit
/// writes them (walk finding F9).
@MainActor
final class GenotypeAnnotationStoreSelectionWritesNothingTests: GenotypeResultViewportTestCase {
    private static let builtInNames = [
        "Incomplete haplotypes",
        "Needs review",
        "Homozygous",
        "Recombinants",
    ]

    func testSelectingAFreshHaplotypedBundleWritesNoByte() throws {
        let fixture = try makeFixture()
        defer { TestTempDirectory.cleanup(fixture.root) }
        let before = try GenotypeBundleTreeSnapshot.entries(of: fixture.root)
        let controller = makeMatrixAnnotationGuardedController()
        _ = controller.view

        controller.configure(result: fixture.result)

        XCTAssertEqual(try GenotypeBundleTreeSnapshot.entries(of: fixture.root), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.annotationURL.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ONTGenotypeBundlePublicationLock.lockURL(for: fixture.bundleURL).path
        ))
        XCTAssertEqual(
            controller.annotationStore?.sidecar.smartCohorts.map(\.name),
            Self.builtInNames
        )
    }

    func testSelectingAnAnnotatedHaplotypedBundleLeavesTheSidecarAndItsRecordsUntouched() throws {
        let fixture = try makeFixture()
        defer { TestTempDirectory.cleanup(fixture.root) }
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-08-01T00:00:00Z")
        sidecar.sampleStatusFlags = [
            .init(sample: "AnimalA", value: .reviewed, author: "cli", timestamp: "2026-08-01T00:00:00Z"),
        ]
        try sidecar.encoded().write(to: fixture.annotationURL)
        try Data(#"{"outputs":[{"checksumSHA256":"recorded"}]}"#.utf8).write(
            to: ProvenanceRecorder.fileSidecarURL(for: fixture.annotationURL)
        )
        let before = try GenotypeBundleTreeSnapshot.entries(of: fixture.root)
        let controller = makeMatrixAnnotationGuardedController()
        _ = controller.view

        controller.configure(result: fixture.result)
        // Selecting the same result again is still a read.
        controller.configure(result: fixture.result)

        XCTAssertEqual(try GenotypeBundleTreeSnapshot.entries(of: fixture.root), before)
        XCTAssertEqual(
            controller.annotationStore?.sidecar.smartCohorts.map(\.name),
            Self.builtInNames
        )
        XCTAssertEqual(
            controller.annotationStore?.sidecar.sampleStatusFlags.map(\.sample),
            ["AnimalA"]
        )
    }

    /// The Haplotype Calls and Genotype Matrix switch still saves its choice
    /// (finding F10, scheduled later). That write publishes the sidecar the
    /// analyst sees, so it carries the built-ins and raises no alert.
    func testTheViewSwitchWriteCarriesTheBuiltInsOfAFreshBundle() throws {
        let fixture = try makeFixture()
        defer { TestTempDirectory.cleanup(fixture.root) }
        let controller = makeMatrixAnnotationGuardedController()
        _ = controller.view
        controller.configure(result: fixture.result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.annotationURL.path))

        var state = controller.testingDisplayState
        state.summaryViewMode = .matrix
        controller.applyDisplayState(state)

        let written = try GenotypeAnnotationSidecar.decode(Data(contentsOf: fixture.annotationURL))
        XCTAssertEqual(written.settings.preferredSummaryViewMode, GenotypeSummaryViewMode.matrix.rawValue)
        XCTAssertEqual(written.smartCohorts.map(\.name), Self.builtInNames)
        XCTAssertEqual(written, controller.annotationStore?.sidecar)
    }

    /// A candidate display change publishes its own sidecar transaction, which
    /// reads the file and so never holds the cohorts that exist only in memory.
    /// The Inspector still receives the sidecar the viewer shows, with the four
    /// cohorts, so its Smart Cohorts list does not empty out.
    func testACandidateDisplayChangeKeepsTheBuiltInsInTheSidecarTheInspectorReceives() async throws {
        let root = try TestTempDirectory.make(prefix: "SelectionCandidateDisplay")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let result = makeCandidateResult(
            bundleURL: bundleURL,
            calls: [makeCall(sample: "AnimalA", genotype: "Known", reads: 8)],
            candidates: [makeCandidate(
                id: "candidate", name: "Candidate_nov", classification: .novel,
                support: .singleton, samples: ["AnimalA"]
            )],
            observations: [makeCandidateObservation(cluster: "candidate", sample: "AnimalA", reads: 5)],
            haplotypeAnalysis: makeUsableHaplotypedMiSeqAnalysis()
        )
        let controller = makeMatrixAnnotationGuardedController()
        _ = controller.view
        var received: [GenotypeAnnotationSidecar] = []
        controller.onAnnotationSidecarChanged = { received.append($0) }
        controller.configure(result: result)
        received.removeAll()
        var state = controller.testingDisplayState
        var settings = try XCTUnwrap(state.mhcCandidateDisplaySettings)
        settings.showSingletonCandidates = false
        state.mhcCandidateDisplaySettings = settings

        controller.applyDisplayState(state)
        await controller.testingWaitForCandidateSettingsPersistence()

        XCTAssertNil(controller.testingCandidatePersistenceWarning)
        XCTAssertEqual(received.last?.smartCohorts.map(\.name), Self.builtInNames)
        XCTAssertEqual(
            controller.annotationStore?.sidecar.smartCohorts.map(\.name),
            Self.builtInNames
        )
        let written = try GenotypeAnnotationSidecar.decode(Data(
            contentsOf: bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        ))
        XCTAssertFalse(written.settings.mhcCandidateDisplay.showSingletonCandidates)
        XCTAssertTrue(written.smartCohorts.isEmpty, "the candidate transaction writes only its setting")
    }

    // MARK: - Fixture

    private struct Fixture {
        let root: URL
        let bundleURL: URL
        let result: ONTGenotypeResultBundleData

        var annotationURL: URL {
            bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = try TestTempDirectory.make(prefix: "SelectionWritesNothing")
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try installCallOverrideManifest(in: bundleURL)
        let result = makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [],
            haplotypeAnalysis: makeUsableHaplotypedMiSeqAnalysis()
        )
        return Fixture(root: root, bundleURL: bundleURL, result: result)
    }
}
