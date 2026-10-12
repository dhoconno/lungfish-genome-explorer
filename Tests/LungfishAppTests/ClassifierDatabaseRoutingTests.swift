// Tests/LungfishAppTests/ClassifierDatabaseRoutingTests.swift
import XCTest
@testable import LungfishApp
@testable import LungfishIO

final class ClassifierDatabaseRoutingTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RouterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - TaxTriage

    func testRoute_taxTriageWithDB() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resultDir = dir.appendingPathComponent("taxtriage-2026-04-06T20-46-18")
        try FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: resultDir.appendingPathComponent("taxtriage.sqlite").path,
            contents: Data())

        let route = ClassifierDatabaseRouter.route(for: resultDir)
        XCTAssertNotNil(route)
        XCTAssertEqual(route?.tool, "taxtriage")
        XCTAssertEqual(route?.displayName, "TaxTriage")
        XCTAssertNotNil(route?.databaseURL)
    }

    func testRoute_taxTriageWithoutDB() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resultDir = dir.appendingPathComponent("taxtriage-2026-04-06T20-46-18")
        try FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)

        let route = ClassifierDatabaseRouter.route(for: resultDir)
        XCTAssertNotNil(route)
        XCTAssertEqual(route?.tool, "taxtriage")
        XCTAssertNil(route?.databaseURL)
    }

    // MARK: - Kraken2

    func testRoute_kraken2WithDB() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resultDir = dir.appendingPathComponent("kraken2-batch-2026-04-06T20-45-49")
        try FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: resultDir.appendingPathComponent("kraken2.sqlite").path,
            contents: Data())

        let route = ClassifierDatabaseRouter.route(for: resultDir)
        XCTAssertNotNil(route)
        XCTAssertEqual(route?.tool, "kraken2")
        XCTAssertNotNil(route?.databaseURL)
    }

    func testRoute_kraken2WithoutDB() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resultDir = dir.appendingPathComponent("kraken2-batch-2026-04-06T20-45-49")
        try FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)

        let route = ClassifierDatabaseRouter.route(for: resultDir)
        XCTAssertNotNil(route)
        XCTAssertEqual(route?.tool, "kraken2")
        XCTAssertNil(route?.databaseURL)
    }

    // MARK: - EsViritu

    func testRoute_esVirituWithDB() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resultDir = dir.appendingPathComponent("esviritu-batch-2026-04-06T20-46-01")
        try FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: resultDir.appendingPathComponent("esviritu.sqlite").path,
            contents: Data())

        let route = ClassifierDatabaseRouter.route(for: resultDir)
        XCTAssertNotNil(route)
        XCTAssertEqual(route?.tool, "esviritu")
        XCTAssertNotNil(route?.databaseURL)
    }

    func testRoute_esVirituWithoutDB() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resultDir = dir.appendingPathComponent("esviritu-batch-2026-04-06T20-46-01")
        try FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)

        let route = ClassifierDatabaseRouter.route(for: resultDir)
        XCTAssertNotNil(route)
        XCTAssertEqual(route?.tool, "esviritu")
        XCTAssertNil(route?.databaseURL)
    }

    // MARK: - Non-classifier directories

    func testRoute_perSampleSubdir() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resultDir = dir.appendingPathComponent("SRR35517702")
        try FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)

        let route = ClassifierDatabaseRouter.route(for: resultDir)
        XCTAssertNil(route)
    }

    func testRoute_unrelatedDir() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resultDir = dir.appendingPathComponent("spades-2026-04-06T10-00-00")
        try FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)

        let route = ClassifierDatabaseRouter.route(for: resultDir)
        XCTAssertNil(route)
    }

    func testRoute_classificationPrefix() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resultDir = dir.appendingPathComponent("classification-batch-2026-04-06")
        try FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: resultDir.appendingPathComponent("kraken2.sqlite").path,
            contents: Data())

        let route = ClassifierDatabaseRouter.route(for: resultDir)
        XCTAssertNotNil(route)
        XCTAssertEqual(route?.tool, "kraken2")
        XCTAssertNotNil(route?.databaseURL)
    }

    // MARK: - Parent walk (batch child subdirs)

    func testRoute_batchChildResolvesToParentBatch() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let batchDir = dir.appendingPathComponent("esviritu-batch-2026-04-06T20-46-01")
        let sampleDir = batchDir.appendingPathComponent("SRR35517702")
        try FileManager.default.createDirectory(at: sampleDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: batchDir.appendingPathComponent("esviritu.sqlite").path,
            contents: Data())

        let route = ClassifierDatabaseRouter.route(for: sampleDir)
        XCTAssertNotNil(route)
        XCTAssertEqual(route?.tool, "esviritu")
        XCTAssertEqual(route?.sampleId, "SRR35517702")
        XCTAssertNotNil(route?.databaseURL)
        XCTAssertEqual(route?.databaseURL?.path, batchDir.appendingPathComponent("esviritu.sqlite").path)
        XCTAssertEqual(route?.resultURL.path, batchDir.path)
    }

    func testRoute_topLevelHasNoSampleId() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let batchDir = dir.appendingPathComponent("esviritu-batch-2026-04-06T20-46-01")
        try FileManager.default.createDirectory(at: batchDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: batchDir.appendingPathComponent("esviritu.sqlite").path,
            contents: Data())

        let route = ClassifierDatabaseRouter.route(for: batchDir)
        XCTAssertNotNil(route)
        XCTAssertNil(route?.sampleId, "top-level route should not carry a sampleId")
        XCTAssertEqual(route?.resultURL.path, batchDir.path)
    }

    // MARK: - Renamed directories must route via analysis-metadata.json

    func testRoute_renamedTaxTriageDirectoryRoutesByMetadata() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A user-chosen name that does not start with any known tool prefix.
        let resultDir = dir.appendingPathComponent("Clinical Batch 7")
        try FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: resultDir.appendingPathComponent("taxtriage.sqlite").path,
            contents: Data())
        try AnalysesFolder.writeAnalysisMetadata(
            AnalysesFolder.AnalysisMetadata(tool: "taxtriage", isBatch: true), to: resultDir)

        let route = ClassifierDatabaseRouter.route(for: resultDir)
        XCTAssertNotNil(route, "A renamed directory with analysis-metadata.json must still route")
        XCTAssertEqual(route?.tool, "taxtriage")
        XCTAssertNotNil(route?.databaseURL)
    }

    func testRoute_renamedEsVirituDirectoryRoutesByMetadata() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resultDir = dir.appendingPathComponent("Weekly Surveillance")
        try FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: resultDir.appendingPathComponent("esviritu.sqlite").path,
            contents: Data())
        try AnalysesFolder.writeAnalysisMetadata(
            AnalysesFolder.AnalysisMetadata(tool: "esviritu", isBatch: true), to: resultDir)

        let route = ClassifierDatabaseRouter.route(for: resultDir)
        XCTAssertNotNil(route, "A renamed directory with analysis-metadata.json must still route")
        XCTAssertEqual(route?.tool, "esviritu")
        XCTAssertNotNil(route?.databaseURL)
    }

    func testRoute_renamedKraken2DirectoryRoutesByMetadata() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resultDir = dir.appendingPathComponent("Project Alpha Results")
        try FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: resultDir.appendingPathComponent("kraken2.sqlite").path,
            contents: Data())
        try AnalysesFolder.writeAnalysisMetadata(
            AnalysesFolder.AnalysisMetadata(tool: "kraken2", isBatch: true), to: resultDir)

        let route = ClassifierDatabaseRouter.route(for: resultDir)
        XCTAssertNotNil(route, "A renamed directory with analysis-metadata.json must still route")
        XCTAssertEqual(route?.tool, "kraken2")
        XCTAssertNotNil(route?.databaseURL)
    }

    // MARK: - The registry names the route by analysis id

    func testRoute_carriesTheAnalysisIDAndTheRegistryNames() throws {
        let cases: [(folder: String, id: AnalysisToolID)] = [
            ("taxtriage-batch-2026-04-06T20-46-18", .taxtriage),
            ("esviritu-batch-2026-04-06T20-46-01", .esviritu),
            ("kraken2-batch-2026-04-06T20-45-49", .kraken2),
            ("classification-batch-2026-04-06", .kraken2),
        ]
        for (folder, id) in cases {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let resultDir = dir.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)

            let route = try XCTUnwrap(ClassifierDatabaseRouter.route(for: resultDir), folder)
            let descriptor = try XCTUnwrap(AnalysisToolRegistry.descriptor(for: id), folder)
            XCTAssertEqual(route.analysisID, id, folder)
            XCTAssertEqual(route.tool, descriptor.buildDatabaseToken, folder)
            XCTAssertEqual(route.displayName, descriptor.displayName, folder)
        }
    }

    func testRoute_aSampleSubfolderCarriesItsBatchsAnalysisID() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sampleDir = dir.appendingPathComponent("esviritu-batch-2026-04-06T20-46-01").appendingPathComponent("SRR35517702")
        try FileManager.default.createDirectory(at: sampleDir, withIntermediateDirectories: true)

        let route = try XCTUnwrap(ClassifierDatabaseRouter.route(for: sampleDir))
        XCTAssertEqual(route.analysisID, .esviritu)
        XCTAssertEqual(route.tool, "esviritu")
        XCTAssertEqual(route.sampleId, "SRR35517702")
    }

    func testBuildNames_readTheRegistryDescriptor() {
        let expected: [(id: AnalysisToolID, displayName: String, token: String)] = [
            (.taxtriage, "TaxTriage", "taxtriage"),
            (.esviritu, "EsViritu", "esviritu"),
            (.kraken2, "Kraken2", "kraken2"),
        ]
        for (id, displayName, token) in expected {
            let names = ClassifierDatabaseRouter.buildNames(for: id)
            XCTAssertEqual(names.displayName, displayName, id.rawValue)
            XCTAssertEqual(names.token, token, id.rawValue)
        }
    }

    func testBuildNames_aKindWithoutATokenFallsBackToItsID() {
        let names = ClassifierDatabaseRouter.buildNames(for: .spades)
        XCTAssertEqual(names.displayName, "SPAdes")
        XCTAssertEqual(names.token, "spades")
        let unknown = ClassifierDatabaseRouter.buildNames(for: AnalysisToolID(rawValue: "from-a-newer-build"))
        XCTAssertEqual(unknown.displayName, "from-a-newer-build")
        XCTAssertEqual(unknown.token, "from-a-newer-build")
    }

    func testRoute_renamedDirectoryWithoutMetadataDoesNotRoute() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // No metadata sidecar and no recognizable prefix: legacy behaviour
        // (cannot be identified) must be preserved, not silently misrouted.
        let resultDir = dir.appendingPathComponent("Some Random Folder")
        try FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: resultDir.appendingPathComponent("kraken2.sqlite").path,
            contents: Data())

        let route = ClassifierDatabaseRouter.route(for: resultDir)
        XCTAssertNil(route)
    }

    // MARK: - A name that starts like a tool

    /// A batch sample named like `esviritu_ctrl`, which the one sanitizer keeps as it is (2.7 A9), is a
    /// sample of its batch. The router once took any folder whose name starts with a tool prefix for a
    /// result root, so this sample routed as a result of its own with no database and no sample (2.7
    /// row 445, fixed in 2.9). It routes to the batch root with `sampleId` `esviritu_ctrl` and the
    /// batch's `esviritu.sqlite`.
    func testBatchSampleNamedLikeAToolRoutesToItsBatch() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let batchDir = dir.appendingPathComponent("esviritu-batch-2026-10-11T10-00-00")
        let sampleDir = batchDir.appendingPathComponent("esviritu_ctrl")
        try FileManager.default.createDirectory(at: sampleDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: batchDir.appendingPathComponent("esviritu.sqlite").path, contents: Data())

        let route = try XCTUnwrap(ClassifierDatabaseRouter.route(for: sampleDir))
        XCTAssertEqual(route.tool, "esviritu")
        XCTAssertEqual(route.resultURL.lastPathComponent, batchDir.lastPathComponent, "the sample folder is not a root")
        XCTAssertEqual(route.sampleId, "esviritu_ctrl")
        XCTAssertEqual(route.databaseURL?.path, batchDir.appendingPathComponent("esviritu.sqlite").path)

        let control = try XCTUnwrap(ClassifierDatabaseRouter.route(for: batchDir.appendingPathComponent("ctrl")))
        XCTAssertEqual(control.sampleId, "ctrl", "A sample whose name has no tool prefix routes to its batch")
        XCTAssertNotNil(control.databaseURL)
    }

    /// A sample whose name carries the dash form of a tool prefix, `kraken2-blank`, is still a sample of its
    /// batch, also when its folder holds the tool's own sidecar, which alone identifies a folder as a result.
    func testBatchSampleNamedWithAToolPrefixAndDashRoutesToItsBatch() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let batchDir = dir.appendingPathComponent("kraken2-batch-2026-10-11T10-00-00")
        let sampleDir = batchDir.appendingPathComponent("kraken2-blank")
        try FileManager.default.createDirectory(at: sampleDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: sampleDir.appendingPathComponent("classification-result.json").path, contents: Data("{}".utf8))
        FileManager.default.createFile(atPath: batchDir.appendingPathComponent("kraken2.sqlite").path, contents: Data())

        let route = try XCTUnwrap(ClassifierDatabaseRouter.route(for: sampleDir))
        XCTAssertEqual(route.analysisID, .kraken2)
        XCTAssertEqual(route.resultURL.lastPathComponent, batchDir.lastPathComponent)
        XCTAssertEqual(route.sampleId, "kraken2-blank")
        XCTAssertNotNil(route.databaseURL)
    }

    /// A folder named like a tool is no result on that account. Only the metadata, a name the registry
    /// reads or the tool's own files make one (2.7 row 445).
    func testRoute_aFolderNamedLikeAToolIsNotAResult() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["esviritu_ctrl", "kraken2 notes", "taxtriage", "esviritu"] {
            let folder = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            XCTAssertNil(ClassifierDatabaseRouter.route(for: folder), name)
        }
    }

    /// A folder that is a grouping folder named like a tool does not make the results inside it samples.
    func testRoute_aResultInsideAFolderNamedLikeAToolKeepsItsOwnRoute() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let group = dir.appendingPathComponent("kraken2-runs")
        let result = group.appendingPathComponent("kraken2-2026-10-11T10-00-00")
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)

        let route = try XCTUnwrap(ClassifierDatabaseRouter.route(for: result))
        XCTAssertEqual(route.resultURL.lastPathComponent, result.lastPathComponent)
        XCTAssertNil(route.sampleId)
    }

    /// The first releases wrote `classification` as the tool of a Kraken2 run, and a folder with that
    /// metadata still opens as Kraken2. Older layouts keep opening.
    func testRoute_theLegacyClassificationToolInTheMetadataIsKraken2() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resultDir = dir.appendingPathComponent("Old Kraken2 run")
        try FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: resultDir.appendingPathComponent("kraken2.sqlite").path, contents: Data())
        try AnalysesFolder.writeAnalysisMetadata(AnalysesFolder.AnalysisMetadata(tool: "classification", isBatch: false), to: resultDir)

        let route = try XCTUnwrap(ClassifierDatabaseRouter.route(for: resultDir))
        XCTAssertEqual(route.analysisID, .kraken2)
        XCTAssertEqual(route.tool, "kraken2")
        XCTAssertNotNil(route.databaseURL)
    }

    /// The metadata names the tool and wins over a folder name that starts with another tool's prefix.
    func testRoute_theMetadataWinsOverANamePrefix() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resultDir = dir.appendingPathComponent("esviritu-2026-10-11T10-00-00")
        try FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)
        try AnalysesFolder.writeAnalysisMetadata(AnalysesFolder.AnalysisMetadata(tool: "taxtriage", isBatch: false), to: resultDir)

        let route = try XCTUnwrap(ClassifierDatabaseRouter.route(for: resultDir))
        XCTAssertEqual(route.analysisID, .taxtriage)
        XCTAssertEqual(route.tool, "taxtriage")
    }
}
