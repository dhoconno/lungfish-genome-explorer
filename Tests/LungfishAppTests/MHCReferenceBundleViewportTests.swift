import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishApp

@MainActor
final class MHCReferenceBundleViewportTests: XCTestCase {
    func testViewportModelLoadsFastaAndHaplotypeSummaryFromBundle() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MHCReferenceBundleViewport-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = tempRoot.appendingPathComponent("MCM.lungfishmhcref", isDirectory: true)
        try MHCReferenceBundleSidebarTests.writeMHCReferenceBundle(at: bundleURL, name: "MCM")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let model = try MHCReferenceBundleViewportModel.load(bundleURL: bundleURL)

        XCTAssertEqual(model.bundleURL.standardizedFileURL, bundleURL.standardizedFileURL)
        XCTAssertEqual(model.title, "MCM MHC")
        XCTAssertTrue(model.fastaText.contains(">M1"))
        XCTAssertEqual(model.referenceCount, 1)
        XCTAssertEqual(model.definitionSummaries.count, 1)
        XCTAssertEqual(model.definitionSummaries[0].displayName, "MCM MHC")
        XCTAssertEqual(model.definitionSummaries[0].locusSummaries, ["MHC-B: 1 haplotype"])
        XCTAssertEqual(model.definitionSummaries[0].diagnosticAlleleCount, 1)
        XCTAssertEqual(model.preferredMode, .haplotypes)
        XCTAssertNil(model.embeddedReferenceBundleURL)
    }

    func testViewportModelDefaultsToAnnotatedReferenceModeForSchemaVersionTwo() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MHCReferenceBundleViewport-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = tempRoot.appendingPathComponent("MCM.lungfishmhcref", isDirectory: true)
        let embeddedURL = bundleURL.appendingPathComponent("reference/MCM.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: embeddedURL.appendingPathComponent("genome"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try ">M1\nACGT\n".write(to: embeddedURL.appendingPathComponent("genome/sequence.fa"), atomically: true, encoding: .utf8)
        try "M1\t4\t4\t4\t5\n".write(to: embeddedURL.appendingPathComponent("genome/sequence.fa.fai"), atomically: true, encoding: .utf8)
        try BundleManifest(
            name: "MCM Annotated",
            identifier: "org.lungfish.mcm-annotated",
            source: SourceInfo(organism: "MCM", assembly: "MHC"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: 4,
                chromosomes: [ChromosomeInfo(name: "M1", length: 4, offset: 4, lineBases: 4, lineWidth: 5)]
            )
        ).save(to: embeddedURL)
        try MHCAmpliconReferenceBundle.writeManifest(
            MHCAmpliconReferenceBundleManifest(
                schemaVersion: 2,
                name: "MCM Annotated",
                referenceFastaPath: "reference/MCM.lungfishref/genome/sequence.fa",
                referenceBundlePath: "reference/MCM.lungfishref",
                haplotypeDefinitionPaths: [],
                defaultHaplotypeDefinitionID: nil,
                metrics: MHCAmpliconReferenceBundleMetrics(referenceCount: 1, haplotypeDefinitionCount: 0),
                warnings: [MHCReferenceBundleWarning(category: "genbank.annotation.skipped", message: "Skipped CDS")],
                createdAt: "2026-07-13T00:00:00Z"
            ),
            to: bundleURL
        )

        let model = try MHCReferenceBundleViewportModel.load(bundleURL: bundleURL)

        XCTAssertEqual(model.preferredMode, .reference)
        XCTAssertEqual(model.embeddedReferenceBundleURL, embeddedURL.standardizedFileURL)
        XCTAssertEqual(model.embeddedReferenceManifest?.name, "MCM Annotated")
        XCTAssertEqual(model.warnings.map(\.message), ["Skipped CDS"])
    }

    func testAsyncViewportModelLoadMatchesSynchronousLoad() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MHCReferenceBundleViewport-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = tempRoot.appendingPathComponent("MCM.lungfishmhcref", isDirectory: true)
        try MHCReferenceBundleSidebarTests.writeMHCReferenceBundle(at: bundleURL, name: "MCM")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let syncModel = try MHCReferenceBundleViewportModel.load(bundleURL: bundleURL)
        let asyncModel = try await MHCReferenceBundleViewportModel.loadAsync(bundleURL: bundleURL)

        // The async variant only moves the FASTA read off the main actor; the
        // resulting model must be identical to the synchronous load.
        XCTAssertEqual(asyncModel, syncModel)
        XCTAssertEqual(asyncModel.fastaText, syncModel.fastaText)
        XCTAssertTrue(asyncModel.fastaText.contains(">M1"))
    }

    func testLegacyBundleLimitsLargeFastaPreviewForSynchronousAndAsyncLoads() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MHCReferenceBundleViewport-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = tempRoot.appendingPathComponent("MCM.lungfishmhcref", isDirectory: true)
        try MHCReferenceBundleSidebarTests.writeMHCReferenceBundle(at: bundleURL, name: "MCM")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let fastaURL = try XCTUnwrap(MHCAmpliconReferenceBundle.referenceFASTAURL(in: bundleURL))
        let tailMarker = ">TAIL-MARKER"
        let largeFASTA = ">M1\n"
            + String(repeating: "ACGTACGTACGTACGTACGTACGTACGTACGT\n", count: 10_000)
            + "\(tailMarker)\nACGT\n"
        try largeFASTA.write(to: fastaURL, atomically: true, encoding: .utf8)

        let syncModel = try MHCReferenceBundleViewportModel.load(bundleURL: bundleURL)
        let asyncModel = try await MHCReferenceBundleViewportModel.loadAsync(bundleURL: bundleURL)

        XCTAssertLessThan(syncModel.fastaText.utf8.count, largeFASTA.utf8.count)
        XCTAssertTrue(syncModel.fastaText.hasPrefix(">M1\n"))
        XCTAssertFalse(syncModel.fastaText.contains(tailMarker))
        XCTAssertEqual(asyncModel, syncModel)
    }

    func testViewportModelRejectsTraversalReferencePath() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MHCReferenceBundleViewport-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = tempRoot.appendingPathComponent("MCM.lungfishmhcref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try ">outside\nACGT\n".write(to: tempRoot.appendingPathComponent("outside.fa"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let manifest = MHCAmpliconReferenceBundleManifest(
            name: "MCM MHC",
            referenceFastaPath: "../outside.fa",
            haplotypeDefinitionPaths: [],
            defaultHaplotypeDefinitionID: nil,
            metrics: MHCAmpliconReferenceBundleMetrics(referenceCount: 1, haplotypeDefinitionCount: 0),
            provenancePath: ".lungfish-provenance.json",
            createdAt: "2026-05-30T00:00:00Z"
        )
        try MHCAmpliconReferenceBundle.writeManifest(manifest, to: bundleURL)

        XCTAssertThrowsError(try MHCReferenceBundleViewportModel.load(bundleURL: bundleURL))
        do {
            _ = try await MHCReferenceBundleViewportModel.loadAsync(bundleURL: bundleURL)
            XCTFail("Async viewport load should reject traversal reference paths")
        } catch {}
    }
}
