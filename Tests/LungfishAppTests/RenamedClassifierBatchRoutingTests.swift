// RenamedClassifierBatchRoutingTests.swift - Regression coverage
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Reported 2026-09-23: renaming a classifier
// batch folder to anything that does not start with the tool's own prefix
// (e.g. "kraken2-batch-...") made `displayBatchGroup` fall through to
// "Unrecognized batch prefix", even though `analysis-metadata.json` still
// identifies the tool. This drives `displayBatchGroup` (and the sidebar
// selection path that calls it) against renamed batch directories and
// asserts the correct classifier viewer is installed.

import XCTest
import AppKit
import SQLite3
import LungfishTestSupport
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishKit
import LungfishNaoMgsUI
import LungfishNvdUI

@MainActor
final class RenamedClassifierBatchRoutingTests: XCTestCase {
    /// The classifier views save their column layouts to `UserDefaults.standard` under each batch's path, and every
    /// batch of this class lies in a folder named for it.
    private var hostDefaults: HostDefaultsRestorer?

    override func setUp() async throws {
        try await super.setUp()
        hostDefaults = HostDefaultsRestorer(keysContaining: "/RenamedClassifierBatchRoutingTests-")
    }

    override func tearDown() async throws {
        hostDefaults?.restore()
        try await super.tearDown()
    }

    private func makeController() -> (MainSplitViewController, NSWindow) {
        let controller = MainSplitViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        return (controller, window)
    }

    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RenamedClassifierBatchRoutingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeMetadata(tool: String, to directory: URL) throws {
        let metadata = AnalysesFolder.AnalysisMetadata(tool: tool, isBatch: true, created: Date())
        try AnalysesFolder.writeAnalysisMetadata(metadata, to: directory)
    }

    // MARK: - EsViritu (renamed, with metadata)

    private func makeEsVirituBatch(named dirName: String, in root: URL, withMetadata: Bool) throws -> URL {
        let batch = root.appendingPathComponent(dirName, isDirectory: true)
        try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
        try EsVirituDatabase.create(
            at: batch.appendingPathComponent("esviritu.sqlite"),
            rows: [
                EsVirituDetectionRow(
                    sample: "sample-a", virusName: "Example virus", description: nil,
                    contigLength: 1_000, segment: nil, accession: "NC_000001.1",
                    assembly: "ASM_1", assemblyLength: 1_000, kingdom: nil, phylum: nil,
                    tclass: nil, torder: nil, family: nil, genus: nil, species: nil,
                    subspecies: nil, rpkmf: 1, readCount: 4, uniqueReads: 3,
                    coveredBases: 1_000, meanCoverage: 1, avgReadIdentity: 0.99,
                    pi: nil, filteredReadsInSample: 4, bamPath: nil, bamIndexPath: nil
                ),
            ],
            metadata: ["tool": "esviritu"]
        )
        if withMetadata {
            try writeMetadata(tool: "esviritu", to: batch)
        }
        return batch
    }

    func testRenamedEsVirituBatchStillRoutesToEsViritu() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // A user-chosen name that does NOT start with "esviritu".
        let batch = try makeEsVirituBatch(named: "My Sequencing Run 2026-09-01", in: root, withMetadata: true)
        let (controller, window) = makeController()
        defer { window.contentViewController = nil }

        controller.displayBatchGroup(at: batch)

        XCTAssertNotNil(controller.viewerController.esVirituViewController,
                         "Renamed EsViritu batch must still route to the EsViritu viewer")
        XCTAssertEqual(controller.inspectorController.viewModel.contentMode, .metagenomics)
    }

    func testUnrenamedEsVirituBatchStillRoutes() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let batch = try makeEsVirituBatch(named: "esviritu-batch-2026-09-01T00-00-00", in: root, withMetadata: true)
        let (controller, window) = makeController()
        defer { window.contentViewController = nil }

        controller.displayBatchGroup(at: batch)

        XCTAssertNotNil(controller.viewerController.esVirituViewController)
    }

    func testLegacyEsVirituBatchWithNoMetadataRoutesByPrefix() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // No analysis-metadata.json (legacy folder), correct prefix retained.
        let batch = try makeEsVirituBatch(named: "esviritu-batch-2026-01-01T00-00-00", in: root, withMetadata: false)
        let (controller, window) = makeController()
        defer { window.contentViewController = nil }

        controller.displayBatchGroup(at: batch)

        XCTAssertNotNil(controller.viewerController.esVirituViewController,
                         "Legacy folder with correct prefix and no metadata sidecar must still route by prefix")
    }

    // MARK: - Kraken2 (renamed, with metadata)

    private func makeKraken2Row(sample: String, taxonName: String, taxId: Int) -> Kraken2ClassificationRow {
        Kraken2ClassificationRow(
            sample: sample, taxonName: taxonName, taxId: taxId, rank: "S", rankDisplayName: "Species",
            readsDirect: 50, readsClade: 100, percentage: 1.0, parentTaxId: nil, depth: 0, fractionDirect: 0.0
        )
    }

    func testRenamedKraken2BatchStillRoutesToTaxonomy() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let batch = root.appendingPathComponent("Project Alpha Results", isDirectory: true)
        try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
        _ = try Kraken2Database.create(
            at: batch.appendingPathComponent("kraken2.sqlite"),
            rows: [makeKraken2Row(sample: "sample-a", taxonName: "Escherichia coli", taxId: 562)],
            metadata: ["tool": "kraken2"]
        )
        try writeMetadata(tool: "kraken2", to: batch)

        let (controller, window) = makeController()
        defer { window.contentViewController = nil }

        controller.displayBatchGroup(at: batch)

        XCTAssertNotNil(controller.viewerController.taxonomyViewController,
                         "Renamed Kraken2 batch must still route to the taxonomy viewer")
    }

    // MARK: - TaxTriage (renamed, with metadata)

    private func makeTaxTriageRow(sample: String, organism: String) -> TaxTriageTaxonomyRow {
        TaxTriageTaxonomyRow(
            sample: sample, organism: organism, taxId: nil, status: nil,
            tassScore: 0.9, readsAligned: 100, uniqueReads: nil,
            pctReads: nil, pctAlignedReads: nil, coverageBreadth: nil,
            meanCoverage: nil, meanDepth: nil, confidence: nil,
            k2Reads: nil, parentK2Reads: nil, giniCoefficient: nil,
            meanBaseQ: nil, meanMapQ: nil, mapqScore: nil,
            disparityScore: nil, minhashScore: nil, diamondIdentity: nil,
            k2DisparityScore: nil, siblingsScore: nil, breadthWeightScore: nil,
            hhsPercentile: nil, isAnnotated: nil, annClass: nil,
            microbialCategory: nil, highConsequence: nil, isSpecies: nil,
            pathogenicSubstrains: nil, sampleType: nil,
            bamPath: nil, bamIndexPath: nil,
            primaryAccession: nil, accessionLength: nil
        )
    }

    func testRenamedTaxTriageBatchStillRoutesToTaxTriage() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let batch = root.appendingPathComponent("Clinical Batch 7", isDirectory: true)
        try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
        _ = try TaxTriageDatabase.create(
            at: batch.appendingPathComponent("taxtriage.sqlite"),
            rows: [makeTaxTriageRow(sample: "sample-a", organism: "Example organism")],
            metadata: ["tool": "taxtriage"]
        )
        try writeMetadata(tool: "taxtriage", to: batch)

        let (controller, window) = makeController()
        defer { window.contentViewController = nil }

        controller.displayBatchGroup(at: batch)

        XCTAssertNotNil(controller.viewerController.taxTriageViewController,
                         "Renamed TaxTriage batch must still route to the TaxTriage viewer")
    }

    // MARK: - Amplicon genotyping results

    /// An amplicon genotyping run records `illumina-amplicon-genotyping` or
    /// `ont-sample-bundle-genotyping` in the analysis-metadata.json of its result bundle, never
    /// `ont-genotyping`. The sidebar knows the bundle by its `.lungfishgenotype` extension, so a
    /// selection of either opens the genotype viewer.
    func testAmpliconGenotypingResultsOpenTheGenotypeViewer() async throws {
        for tool in ["illumina-amplicon-genotyping", "ont-sample-bundle-genotyping"] {
            let root = try makeTempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let analyses = root.appendingPathComponent("Analyses/Amplicon genotyping results", isDirectory: true)
            try FileManager.default.createDirectory(at: analyses, withIntermediateDirectories: true)
            let bundle = try RoutingSafetyNetFixtures.genotypeResultBundle(in: analyses, withCalls: true)
            try AnalysesFolder.writeAnalysisMetadata(
                AnalysesFolder.AnalysisMetadata(tool: tool, isBatch: false),
                to: bundle
            )
            XCTAssertEqual(AnalysesFolder.analysisInfo(for: bundle)?.tool, tool, tool)

            let item = RoutingSafetyNetItems.scanned(bundle)
            XCTAssertEqual(item.type, .genotypeResultBundle, tool)

            let (controller, window) = makeController()
            defer { window.contentViewController = nil }
            controller.displayContent(for: item)

            let opened = await waitUntil(budget: .lookup) {
                controller.viewerController.genotypeResultViewController != nil
            }
            XCTAssertTrue(opened, "\(tool) must open the genotype viewer")
        }
    }

    // MARK: - Sidebar selection path (mirrors user interaction)

    func testSidebarSelectionOfRenamedBatchRoutesCorrectly() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let batch = try makeEsVirituBatch(named: "Weekly Surveillance", in: root, withMetadata: true)
        let (controller, window) = makeController()
        defer { window.contentViewController = nil }

        let item = SidebarItem(title: batch.lastPathComponent, type: .batchGroup, url: batch)
        controller.displayContent(for: item)

        XCTAssertNotNil(controller.viewerController.esVirituViewController)
    }
}

// MARK: - The metadata tool against the folder prefix (Phase 2.10 A33)

/// A batch folder opens as the tool its `analysis-metadata.json` names, and a folder prefix names a tool only for a
/// legacy folder with no metadata. The tests below pin the viewer `displayBatchGroup` installs and the type
/// `provenanceSidebarType` returns for every pair of a metadata tool and a folder prefix.
///
/// Before the lane the arms ran Kraken2, EsViritu, TaxTriage, NAO-MGS and NVD, and each also matched the folder
/// prefix, so the prefix of an earlier arm beat the metadata of a later one. 14 pairs opened the prefix's tool
/// (the pin commit lists them) and the metadata's tool opens now.
extension RenamedClassifierBatchRoutingTests {

    /// The classifier a batch folder opens as, with the sidebar type its provenance target carries.
    private enum BatchFamily: String {
        case kraken2, esviritu, taxtriage, naomgs, nvd, none

        var sidebarType: SidebarItemType {
            switch self {
            case .kraken2: return .classificationResult
            case .esviritu: return .esvirituResult
            case .taxtriage: return .taxTriageResult
            case .naomgs: return .naoMgsResult
            case .nvd: return .nvdResult
            case .none: return .analysisResult
            }
        }
    }

    /// The tool an `analysis-metadata.json` carries for a classifier. `classification` is the word the first
    /// releases wrote for a Kraken2 run, and it opens Kraken2.
    private static let metadataTools: [(tool: String, family: BatchFamily)] = [
        ("kraken2", .kraken2), ("classification", .kraken2), ("esviritu", .esviritu),
        ("taxtriage", .taxtriage), ("naomgs", .naomgs), ("nvd", .nvd),
    ]

    /// The prefixes a folder can carry for a classifier.
    private static let folderPrefixes = [
        "kraken2-", "classification-", "esviritu-", "taxtriage-", "naomgs-", "nvd-",
    ]

    /// A batch folder that holds every classifier database, so whichever arm opens it finds its own and the
    /// database build placeholder, which would start `lungfish-cli build-db`, never shows.
    private func makeAllDatabasesBatch(named name: String, metadataTool: String?, in root: URL) throws -> URL {
        let batch = try makeEsVirituBatch(named: name, in: root, withMetadata: false)
        _ = try Kraken2Database.create(
            at: batch.appendingPathComponent("kraken2.sqlite"),
            rows: [makeKraken2Row(sample: "sample-a", taxonName: "Escherichia coli", taxId: 562)],
            metadata: ["tool": "kraken2"]
        )
        _ = try TaxTriageDatabase.create(
            at: batch.appendingPathComponent("taxtriage.sqlite"),
            rows: [makeTaxTriageRow(sample: "sample-a", organism: "Example organism")],
            metadata: ["tool": "taxtriage"]
        )
        if let metadataTool { try writeMetadata(tool: metadataTool, to: batch) }
        return batch
    }

    /// The viewer a display left in the viewport. A NAO-MGS or NVD display starts a task that reads a manifest
    /// these folders do not have, so the caller supersedes the request before the task runs.
    private func installedViewer(of controller: MainSplitViewController) -> BatchFamily {
        let viewer = controller.viewerController
        let family: BatchFamily
        if viewer?.taxonomyViewController != nil {
            family = .kraken2
        } else if viewer?.esVirituViewController != nil {
            family = .esviritu
        } else if viewer?.taxTriageViewController != nil {
            family = .taxtriage
        } else if viewer?.children.contains(where: { $0 is NaoMgsResultViewController }) == true {
            family = .naomgs
        } else if viewer?.children.contains(where: { $0 is NvdResultViewController }) == true {
            family = .nvd
        } else {
            family = .none
        }
        _ = controller.beginDisplayRequest(
            identity: controller.contentSelectionIdentity(url: URL(fileURLWithPath: "/"), kind: "pin-supersede")
        )
        return family
    }

    /// The viewer `displayBatchGroup` installs for every pair of a metadata tool and a folder prefix is the
    /// metadata tool's, whatever the folder is called.
    func testTheViewerFollowsTheMetadataToolForEveryFolderPrefix() throws {
        for metadata in Self.metadataTools {
            for prefix in Self.folderPrefixes {
                let root = try makeTempRoot()
                defer { try? FileManager.default.removeItem(at: root) }
                let batch = try makeAllDatabasesBatch(
                    named: prefix + "2026-10-13T10-00-00", metadataTool: metadata.tool, in: root
                )
                let (controller, window) = makeController()
                defer { window.contentViewController = nil }

                controller.displayBatchGroup(at: batch)

                XCTAssertEqual(
                    installedViewer(of: controller), metadata.family,
                    "metadata \(metadata.tool) in a folder named \(batch.lastPathComponent)"
                )
                XCTAssertEqual(
                    controller.inspectorController.viewModel.provenanceSectionViewModel.currentItem?.sidebarType,
                    metadata.family.sidebarType,
                    "provenance type of metadata \(metadata.tool) in a folder named \(batch.lastPathComponent)"
                )
            }
        }
    }

    /// The type `provenanceSidebarType` returns follows the tool id alone. `displayBatchGroup` hands it the
    /// metadata's tool, so the Inspector's provenance target takes the type of the tool whatever the folder is called.
    func testTheProvenanceSidebarTypeFollowsTheToolIdForEveryMetadataTool() {
        let (controller, window) = makeController()
        defer { window.contentViewController = nil }
        for metadata in Self.metadataTools {
            XCTAssertEqual(
                controller.provenanceSidebarType(forMetagenomicsToolId: metadata.tool),
                metadata.family.sidebarType,
                "metadata \(metadata.tool)"
            )
        }
        // A tool that is not a classifier keeps its own type, and the CZ-ID import has a type of its own.
        XCTAssertEqual(controller.provenanceSidebarType(forMetagenomicsToolId: "spades"), .analysisResult)
        XCTAssertEqual(controller.provenanceSidebarType(forMetagenomicsToolId: "cz-id"), .czIdResult)
    }

    /// A legacy folder has no `analysis-metadata.json`. The router reads a name with a timestamp, and a name it
    /// cannot read stays the tool id, so its prefix still names the viewer and the provenance type. Older layouts
    /// keep opening.
    func testALegacyFolderWithNoMetadataRoutesByItsPrefix() throws {
        let legacy: [(name: String, opens: BatchFamily)] = [
            ("kraken2-batch-2026-01-01T00-00-00", .kraken2),
            ("classification-batch-2026-01-01T00-00-00", .kraken2),
            ("esviritu-batch-2026-01-01T00-00-00", .esviritu),
            ("taxtriage-2026-01-01T00-00-00", .taxtriage),
            ("kraken2-sample-run", .kraken2),
            ("classification-run-001", .kraken2),
            ("esviritu-run-sampleA", .esviritu),
            ("taxtriage-run-sampleA", .taxtriage),
            ("naomgs-batch-001", .naomgs),
            ("nvd-batch-run", .nvd),
        ]
        for row in legacy {
            let root = try makeTempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let batch = try makeAllDatabasesBatch(named: row.name, metadataTool: nil, in: root)
            let (controller, window) = makeController()
            defer { window.contentViewController = nil }

            controller.displayBatchGroup(at: batch)

            XCTAssertEqual(installedViewer(of: controller), row.opens, "viewer of the legacy folder \(row.name)")
            XCTAssertEqual(
                controller.inspectorController.viewModel.provenanceSectionViewModel.currentItem?.sidebarType,
                row.opens.sidebarType,
                "provenance type of the legacy folder \(row.name)"
            )
        }
    }
}
