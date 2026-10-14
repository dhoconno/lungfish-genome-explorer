// DatabaseBrowserPathoplexusRowPinConformanceTests.swift - Pins what the Pathoplexus browser's row downloads today
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A45 M2 (a), before the row moves onto lungfish-cli. One Pathoplexus row of the
// database browser's batch download, in process, over the loopback Pathoplexus and NCBI stand-ins that
// the process environment names. The four cases are the row's four ways, which the CLI route must keep.
//
// - A restricted record is refused with `DatabaseServiceError.invalidQuery` and builds no bundle.
// - A record with an INSDC accession builds from its GenBank record, with Pathoplexus's metadata
//   groups appended to the manifest.
// - When GenBank cannot serve that record, the bundle is built from the Pathoplexus FASTA.
// - A record with no INSDC accession builds from the Pathoplexus FASTA, which writes no provenance record.
//
// Each case runs the managed bgzip and samtools faidx, so the class sits in the conformance tier and
// skips without them unless `LUNGFISH_REQUIRE_TOOLS=1`.

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishWorkflow
import LungfishIO
import LungfishTestSupport

final class DatabaseBrowserPathoplexusRowPinConformanceTests: XCTestCase {
    private var root: URL!
    private var ncbi: LoopbackHTTPStandIn!
    private var lapis: LoopbackHTTPStandIn!
    private var saved: ProcessEnvironmentOverride?

    override func setUp() async throws {
        try await super.setUp()
        do {
            try await GenBankDownloadBundleBuilder(ncbiService: NCBIService(apiKey: nil, environment: [:])).validateTools()
        } catch {
            try ToolAvailability.skipOrFail("Managed bgzip and samtools are required: \(error)")
        }
        root = try TestTempDirectory.make(prefix: "pathoplexus-row-pin")
        ncbi = try await NCBIGenomeStandIn.start(servingIn: root.appendingPathComponent("served", isDirectory: true))
        lapis = try PathoplexusLAPISStandIn.start()
        saved = ProcessEnvironmentOverride(
            set: [
                NCBIServiceEndpoints.standInOriginVariable: ncbi.baseURL.absoluteString,
                PathoplexusServiceEndpoints.standInOriginVariable: lapis.baseURL.absoluteString,
            ],
            unset: ["NCBI_API_KEY"])
    }

    override func tearDown() async throws {
        saved?.restore()
        ncbi?.stop()
        lapis?.stop()
        if let root { TestTempDirectory.cleanup(root) }
        try await super.tearDown()
    }

    func testARestrictedRecordIsRefusedAndBuildsNoBundle() async throws {
        do {
            _ = try await download(PathoplexusLAPISStandIn.restricted)
            XCTFail("A restricted record downloads")
        } catch DatabaseServiceError.invalidQuery(let reason) {
            XCTAssertEqual(reason, "Record PP_000003 is restricted and cannot be downloaded")
        }
        XCTAssertEqual(bundles(under: root), [], "a refused record builds no bundle")
    }

    func testARecordWithAnINSDCAccessionBuildsFromItsGenBankRecordWithPathoplexusMetadata() async throws {
        let bundle = try await download(PathoplexusLAPISStandIn.openWithINSDC)
        let manifest = try BundleManifest.load(from: bundle)
        XCTAssertEqual(
            manifest.genome?.chromosomes.map(\.name), ["ZZ000001"],
            "the in-process route names the one sequence by the LOCUS name of the GenBank record")
        let group = try XCTUnwrap(manifest.metadata?.first { $0.name == "Pathoplexus Record" })
        XCTAssertEqual(group.items.first { $0.label == "Accession" }?.value, "PP_000001")
        XCTAssertEqual(group.items.first { $0.label == "Version" }?.value, "PP_000001.1")
        XCTAssertEqual(group.items.first { $0.label == "INSDC Accession" }?.value, NCBIDownloadPinFixtures.genBankAccession)
        XCTAssertNotNil(manifest.metadata?.first { $0.name == "Sample" }, "the metadata groups follow the GenBank groups")
        XCTAssertNotNil(ProvenanceRecorder.loadEnvelope(from: bundle), "the GenBank builder writes its record")
    }

    func testAnINSDCAccessionGenBankCannotServeFallsBackToThePathoplexusFASTA() async throws {
        let bundle = try await download(PathoplexusLAPISStandIn.openINSDCUnavailable)
        try assertFASTABundle(
            bundle, accession: PathoplexusLAPISStandIn.openINSDCUnavailable,
            notes: "Generated from Pathoplexus FASTA fallback after INSDC lookup failed")
    }

    func testARecordWithNoINSDCAccessionBuildsFromThePathoplexusFASTA() async throws {
        let bundle = try await download(PathoplexusLAPISStandIn.openNoINSDC)
        try assertFASTABundle(
            bundle, accession: PathoplexusLAPISStandIn.openNoINSDC,
            notes: "Generated from Pathoplexus sequence (no INSDC accession available)")
    }

    // MARK: - Helpers

    /// The row `accession` downloaded in process into a batch folder of an empty project.
    private func download(_ accession: String) async throws -> URL {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let record = SearchResultRecord(
            id: accession, accession: accession, title: "Stand-in Pathoplexus record", source: .pathoplexus)
        return try await DatabaseBrowserViewModel.downloadPathoplexusRow(
            record, index: 0, totalCount: 1, operationID: UUID(), organism: PathoplexusLAPISStandIn.organism,
            genBankVM: GenBankBundleDownloadViewModel(ncbiService: NCBIService()), includeGFF3Annotations: true,
            batchFolder: BatchDownloadFolder(projectURL: project))
    }

    /// A bundle built from the Pathoplexus FASTA: its one sequence named by the accession, the source
    /// Pathoplexus with the notes of its way, the Pathoplexus metadata groups, and no provenance record.
    private func assertFASTABundle(_ bundle: URL, accession: String, notes: String) throws {
        let manifest = try BundleManifest.load(from: bundle)
        XCTAssertEqual(manifest.genome?.chromosomes.map(\.name), [accession])
        XCTAssertEqual(manifest.source.database, "Pathoplexus")
        XCTAssertEqual(manifest.source.notes, notes)
        let group = try XCTUnwrap(manifest.metadata?.first { $0.name == "Pathoplexus Record" })
        XCTAssertEqual(group.items.first { $0.label == "Accession" }?.value, accession)
        XCTAssertNil(ProvenanceRecorder.loadEnvelope(from: bundle), "the FASTA route writes no provenance record")
    }

    private func bundles(under folder: URL) -> [String] {
        let walker = FileManager.default.enumerator(atPath: folder.path)
        var found: [String] = []
        while let path = walker?.nextObject() as? String {
            if path.hasSuffix(".lungfishref") { found.append(path) }
        }
        return found
    }
}
