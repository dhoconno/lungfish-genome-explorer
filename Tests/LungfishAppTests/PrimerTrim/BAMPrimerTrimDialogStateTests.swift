import XCTest
import LungfishCore
import LungfishIO
import LungfishWorkflow
@testable import LungfishApp

@MainActor
final class BAMPrimerTrimDialogStateTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs.removeAll()
        try super.tearDownWithError()
    }

    func testIsRunEnabledFalseWhenNoSchemeSelected() {
        let state = BAMPrimerTrimDialogState(
            bundle: makeStubReferenceBundle(),
            availability: .available,
            builtInSchemes: [],
            projectSchemes: []
        )
        XCTAssertFalse(state.isRunEnabled)
    }

    func testIsRunEnabledTrueWhenSchemeSelectedAndPackReady() throws {
        let scheme = try loadSampleScheme()
        let state = BAMPrimerTrimDialogState(
            bundle: makeStubReferenceBundle(),
            availability: .available,
            builtInSchemes: [scheme],
            projectSchemes: []
        )
        // The stub bundle has no eligible alignment tracks, so the launcher's
        // required state (alignmentTrackID + outputTrackName) is supplied
        // directly by the test.
        state.alignmentTrackID = "test-track-id"
        state.outputTrackName = "Trimmed track"
        state.selectScheme(id: scheme.manifest.name)
        XCTAssertTrue(state.isRunEnabled)
    }

    func testIsRunEnabledFalseWhenPackUnavailable() throws {
        let scheme = try loadSampleScheme()
        let state = BAMPrimerTrimDialogState(
            bundle: makeStubReferenceBundle(),
            availability: .disabled(reason: "Requires Variant Calling Pack"),
            builtInSchemes: [scheme],
            projectSchemes: []
        )
        state.alignmentTrackID = "test-track-id"
        state.outputTrackName = "Trimmed track"
        state.selectScheme(id: scheme.manifest.name)
        XCTAssertFalse(state.isRunEnabled)
    }

    func testIsRunEnabledFalseWhenAdvancedFieldInvalid() throws {
        let scheme = try loadSampleScheme()
        let state = BAMPrimerTrimDialogState(
            bundle: makeStubReferenceBundle(),
            availability: .available,
            builtInSchemes: [scheme],
            projectSchemes: []
        )
        state.alignmentTrackID = "test-track-id"
        state.outputTrackName = "Trimmed track"
        state.selectScheme(id: scheme.manifest.name)
        XCTAssertTrue(state.isRunEnabled, "precondition: enabled with valid defaults")

        // Each invalid value should disable the run.
        state.minReadLengthText = "abc"
        XCTAssertFalse(state.isRunEnabled, "non-numeric minReadLength must disable")
        state.minReadLengthText = "30"

        state.minQualityText = "-5"
        XCTAssertFalse(state.isRunEnabled, "negative minQuality must disable")
        state.minQualityText = "20"

        state.slidingWindowText = ""
        XCTAssertFalse(state.isRunEnabled, "empty slidingWindow must disable")
        state.slidingWindowText = "4"

        state.primerOffsetText = "  "
        XCTAssertFalse(state.isRunEnabled, "whitespace-only primerOffset must disable")
        state.primerOffsetText = "0"

        XCTAssertTrue(state.isRunEnabled, "postcondition: re-enabled when all fields valid again")
    }

    func testPrepareForRunReturnsNilWhenNoSchemeSelected() {
        let state = BAMPrimerTrimDialogState(
            bundle: makeStubReferenceBundle(),
            availability: .available,
            builtInSchemes: [],
            projectSchemes: []
        )
        XCTAssertNil(state.prepareForRun())
        XCTAssertNil(state.pendingRequest)
    }

    func testPrepareForRunPopulatesPendingRequestWhenReady() throws {
        let scheme = try loadSampleScheme()
        let state = BAMPrimerTrimDialogState(
            bundle: makeStubReferenceBundle(includeAlignment: true),
            availability: .available,
            builtInSchemes: [scheme],
            projectSchemes: []
        )
        // alignmentTrackID is auto-populated by init from the bundle's first
        // eligible (non-resolvable, manifest-only) track. The output track
        // name auto-populates when the scheme is selected.
        state.selectScheme(id: scheme.manifest.name)
        state.minReadLengthText = "30"
        state.minQualityText = "20"
        state.slidingWindowText = "4"
        state.primerOffsetText = "0"

        let request = try XCTUnwrap(state.prepareForRun())
        XCTAssertEqual(request.minReadLength, 30)
        XCTAssertEqual(request.minQuality, 20)
        XCTAssertEqual(request.slidingWindow, 4)
        XCTAssertEqual(request.primerOffset, 0)
        XCTAssertEqual(state.pendingRequest?.minReadLength, 30)
    }

    func testSelectSchemePopulatesDefaultOutputTrackName() throws {
        let scheme = try loadSampleScheme()
        let state = BAMPrimerTrimDialogState(
            bundle: makeStubReferenceBundle(includeAlignment: true),
            availability: .available,
            builtInSchemes: [scheme],
            projectSchemes: []
        )

        state.selectScheme(id: scheme.manifest.name)

        XCTAssertTrue(
            state.outputTrackName.contains("Primer-trimmed"),
            "The SwiftUI picker binding routes selection through selectScheme(id:), so default output naming must run there."
        )
        XCTAssertTrue(state.isRunEnabled)
    }

    func testAddProjectSchemeSelectsBrowsedSchemeAndRefreshesOutputName() throws {
        let builtInScheme = try loadSampleScheme(name: "built-in", displayName: "Built In")
        let browsedScheme = try loadSampleScheme(name: "browsed", displayName: "Browsed Scheme")
        let state = BAMPrimerTrimDialogState(
            bundle: makeStubReferenceBundle(includeAlignment: true),
            availability: .available,
            builtInSchemes: [builtInScheme],
            projectSchemes: []
        )

        state.addProjectSchemeAndSelect(browsedScheme)

        XCTAssertEqual(state.projectSchemes.map(\.manifest.name), ["browsed"])
        XCTAssertEqual(state.selectedSchemeID, "browsed")
        XCTAssertEqual(state.selectedScheme?.manifest.displayName, "Browsed Scheme")
        XCTAssertTrue(state.outputTrackName.contains("Browsed Scheme"))
        XCTAssertTrue(state.isRunEnabled)
    }

    func testAddProjectSchemeReplacesDuplicateInsteadOfAppending() throws {
        let first = try loadSampleScheme(name: "browsed", displayName: "Browsed Scheme")
        let duplicate = try loadSampleScheme(name: "browsed", displayName: "Browsed Scheme Updated")
        let state = BAMPrimerTrimDialogState(
            bundle: makeStubReferenceBundle(includeAlignment: true),
            availability: .available,
            builtInSchemes: [],
            projectSchemes: [first]
        )

        state.addProjectSchemeAndSelect(duplicate)

        XCTAssertEqual(state.projectSchemes.map(\.manifest.name), ["browsed"])
        XCTAssertEqual(state.selectedScheme?.manifest.displayName, "Browsed Scheme Updated")
    }

    func testPrepareForRunReturnsNilWhenFieldsInvalid() throws {
        let scheme = try loadSampleScheme()
        let state = BAMPrimerTrimDialogState(
            bundle: makeStubReferenceBundle(includeAlignment: true),
            availability: .available,
            builtInSchemes: [scheme],
            projectSchemes: []
        )
        state.selectScheme(id: scheme.manifest.name)
        state.minQualityText = "not a number"
        XCTAssertNil(state.prepareForRun())
    }

    // MARK: - Fixture helpers

    private func makeStubReferenceBundle(includeAlignment: Bool = false) -> ReferenceBundle {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BAMPrimerTrimDialogStateTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryURLs.append(url)
        var alignments: [AlignmentTrackInfo] = []
        if includeAlignment {
            // Create stub BAM/BAI on disk so
            // `BAMVariantCallingEligibility.eligibleAlignmentTracks(in:)` (which
            // calls `resolveAlignmentPath` / `resolveAlignmentIndexPath`) treats
            // the manifest entry as eligible during the dialog state's init.
            let alignmentsDir = url.appendingPathComponent("alignments", isDirectory: true)
            try? FileManager.default.createDirectory(at: alignmentsDir, withIntermediateDirectories: true)
            let bamURL = alignmentsDir.appendingPathComponent("test.bam")
            let baiURL = alignmentsDir.appendingPathComponent("test.bam.bai")
            FileManager.default.createFile(atPath: bamURL.path, contents: Data(), attributes: nil)
            FileManager.default.createFile(atPath: baiURL.path, contents: Data(), attributes: nil)
            alignments = [
                AlignmentTrackInfo(
                    id: "test-track-id",
                    name: "Test alignment",
                    sourcePath: "alignments/test.bam",
                    indexPath: "alignments/test.bam.bai"
                )
            ]
        }
        let manifest = BundleManifest(
            name: "Stub",
            identifier: "stub.test",
            source: SourceInfo(organism: "Virus", assembly: "StubAssembly", database: "Test"),
            genome: GenomeInfo(
                path: "genome/ref.fa",
                indexPath: "genome/ref.fa.fai",
                totalLength: 1000,
                chromosomes: [
                    ChromosomeInfo(
                        name: "chr1",
                        length: 1000,
                        offset: 0,
                        lineBases: 60,
                        lineWidth: 61
                    )
                ]
            ),
            variants: [],
            alignments: alignments
        )
        return ReferenceBundle(url: url, manifest: manifest)
    }

    private func loadSampleScheme(
        name: String = "sample",
        displayName: String = "Sample Scheme"
    ) throws -> PrimerSchemeBundle {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).lungfishprimers", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        temporaryURLs.append(bundleURL)
        let manifestJSON = """
        {
          "schema_version": 1,
          "name": "\(name)",
          "display_name": "\(displayName)",
          "reference_accessions": [{ "accession": "MN908947.3", "canonical": true }],
          "primer_count": 1,
          "amplicon_count": 1,
          "source": "test-fixture",
          "version": "0.1.0",
          "created": "2026-04-24T00:00:00Z"
        }
        """
        try manifestJSON.write(
            to: bundleURL.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )
        try "MN908947.3\t0\t24\tp1_L\t60\t+\n".write(
            to: bundleURL.appendingPathComponent("primers.bed"),
            atomically: true,
            encoding: .utf8
        )
        try "# stub\n".write(
            to: bundleURL.appendingPathComponent("PROVENANCE.md"),
            atomically: true,
            encoding: .utf8
        )
        return try PrimerSchemeBundle.load(from: bundleURL)
    }
}
