import XCTest
import LungfishCore
import LungfishIO
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

    // MARK: - Fixture helpers

    private func makeStubReferenceBundle() -> ReferenceBundle {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BAMPrimerTrimDialogStateTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryURLs.append(url)
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
            alignments: []
        )
        return ReferenceBundle(url: url, manifest: manifest)
    }

    private func loadSampleScheme() throws -> PrimerSchemeBundle {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sample-\(UUID().uuidString).lungfishprimers", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        temporaryURLs.append(bundleURL)
        let manifestJSON = """
        {
          "schema_version": 1,
          "name": "sample",
          "display_name": "Sample Scheme",
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
