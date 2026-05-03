import LungfishWorkflow
import XCTest
@testable import LungfishApp

final class ApplicationExportImportCollectionServiceTests: XCTestCase {
    private let fileManager = FileManager.default
    private var tempRoots: [URL] = []

    override func tearDownWithError() throws {
        for url in tempRoots {
            try? fileManager.removeItem(at: url)
        }
        tempRoots.removeAll()
        try super.tearDownWithError()
    }

    func testImportCreatesApplicationExportCollectionWithInventoryReportAndProvenance() async throws {
        let root = try makeTempDirectory()
        let projectURL = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try fileManager.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let archiveURL = try makeApplicationExportArchive(root: root, name: "Example.zip")
        let service = makeService()

        let result = try await service.importApplicationExport(
            sourceURL: archiveURL,
            projectURL: projectURL,
            kind: .clcWorkbench,
            options: .default
        )

        XCTAssertEqual(result.collectionURL.lastPathComponent, "Example CLC Workbench Import")
        XCTAssertTrue(fileManager.fileExists(atPath: result.collectionURL.appendingPathComponent("LGE Bundles").path))
        XCTAssertTrue(fileManager.fileExists(atPath: result.collectionURL.appendingPathComponent("Binary Artifacts").path))
        XCTAssertTrue(fileManager.fileExists(atPath: result.collectionURL.appendingPathComponent("Source").path))
        XCTAssertTrue(fileManager.fileExists(atPath: result.inventoryURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: result.reportURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: result.provenanceURL.path))

        let inventoryData = try Data(contentsOf: result.inventoryURL)
        let inventoryDecoder = JSONDecoder()
        inventoryDecoder.dateDecodingStrategy = .iso8601
        let inventory = try inventoryDecoder.decode(ApplicationExportImportInventory.self, from: inventoryData)
        XCTAssertEqual(inventory.applicationKind, .clcWorkbench)
        XCTAssertEqual(inventory.sourceKind, .archive)
        XCTAssertEqual(inventory.items.count, 2)

        let report = try String(contentsOf: result.reportURL, encoding: .utf8)
        XCTAssertTrue(report.contains("# CLC Workbench Import Report"))
        XCTAssertTrue(report.contains("Native bundles"))
        XCTAssertTrue(report.contains("Preserved artifacts"))

        let provenanceData = try Data(contentsOf: result.provenanceURL)
        let provenanceDecoder = JSONDecoder()
        provenanceDecoder.dateDecodingStrategy = .iso8601
        let provenance = try provenanceDecoder.decode(WorkflowRun.self, from: provenanceData)
        XCTAssertEqual(provenance.name, "Application Export Import")
        XCTAssertEqual(provenance.status, .completed)
        XCTAssertEqual(provenance.parameters["applicationExportKind"]?.stringValue, "clc-workbench-export")
        XCTAssertTrue(provenance.steps.contains { $0.toolName == "Application Export Import" })
    }

    func testImportRoutesStandaloneReferencesAndPreservesOtherFiles() async throws {
        let root = try makeTempDirectory()
        let projectURL = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try fileManager.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let archiveURL = try makeApplicationExportArchive(root: root, name: "Example.zip")
        let capture = ReferenceImportCapture()
        let service = ApplicationExportImportCollectionService(
            scanner: ApplicationExportScanner(),
            referenceImporter: { sourceURL, outputDirectory, preferredName in
                await capture.record(sourceURL: sourceURL, outputDirectory: outputDirectory, preferredName: preferredName)
                let bundle = outputDirectory.appendingPathComponent("\(preferredName).lungfishref", isDirectory: true)
                try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
                return ReferenceBundleImportResult(bundleURL: bundle, bundleName: preferredName)
            }
        )

        let result = try await service.importApplicationExport(
            sourceURL: archiveURL,
            projectURL: projectURL,
            kind: .clcWorkbench,
            options: .default
        )

        let calls = await capture.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.sourceURL.lastPathComponent, "reference.fa")
        XCTAssertTrue(calls.first?.sourceURL.path.contains("/Project.lungfish/.tmp/application-export-import-") == true)
        XCTAssertEqual(calls.first?.outputDirectory.lastPathComponent, "LGE Bundles")
        XCTAssertEqual(calls.first?.preferredName, "reference")
        XCTAssertEqual(result.nativeBundleURLs.count, 1)
        XCTAssertTrue(result.preservedArtifactURLs.contains { $0.path.hasSuffix("reports/summary.tsv") })
        XCTAssertTrue(fileManager.fileExists(atPath: result.collectionURL.appendingPathComponent("Binary Artifacts/reports/summary.tsv").path))
        let tempChildren = (try? fileManager.contentsOfDirectory(
            at: projectURL.appendingPathComponent(".tmp", isDirectory: true),
            includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertFalse(tempChildren.contains { $0.lastPathComponent.hasPrefix("application-export-import-") })
    }

    func testAlignmentTreeImportRoutesNativeBundlesAndSkipsBinaryArtifacts() async throws {
        let root = try makeTempDirectory()
        let projectURL = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try fileManager.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let sourceURL = try makeAlignmentTreeExportFolder(root: root)
        let service = makeService()

        let result = try await service.importApplicationExport(
            sourceURL: sourceURL,
            projectURL: projectURL,
            kind: .alignmentTree,
            options: .default
        )

        XCTAssertEqual(Set(result.nativeBundleURLs.map(\.pathExtension)), ["lungfishmsa", "lungfishtree"])
        XCTAssertTrue(result.preservedArtifactURLs.isEmpty)
        XCTAssertFalse(fileManager.fileExists(atPath: result.collectionURL.appendingPathComponent("Binary Artifacts").path))
        XCTAssertFalse(fileManager.fileExists(atPath: result.collectionURL.appendingPathComponent("Source").path))
        XCTAssertTrue(result.warnings.contains { $0.contains("notes.txt") && $0.contains("not imported") })

        let inventoryData = try Data(contentsOf: result.inventoryURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let inventory = try decoder.decode(ApplicationExportImportInventory.self, from: inventoryData)
        XCTAssertEqual(inventory.applicationKind, .alignmentTree)
        XCTAssertTrue(inventory.items.contains {
            $0.kind == .multipleSequenceAlignment && ($0.lgeDestination?.hasSuffix(".lungfishmsa") ?? false)
        })
        XCTAssertTrue(inventory.items.contains {
            $0.kind == .phylogeneticTree && ($0.lgeDestination?.hasSuffix(".lungfishtree") ?? false)
        })
        XCTAssertTrue(inventory.items.contains {
            $0.kind == .report && $0.lgeDestination == nil
        })
    }

    func testArchiveImportRejectsUnsafeMembers() async throws {
        let root = try makeTempDirectory()
        let projectURL = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try fileManager.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let unsafeArchive = try makeUnsafeArchive(root: root)
        let service = makeService()

        do {
            _ = try await service.importApplicationExport(
                sourceURL: unsafeArchive,
                projectURL: projectURL,
                kind: .benchlingBulk,
                options: .default
            )
            XCTFail("Unsafe archive member should be rejected")
        } catch let error as GeneiousArchiveToolError {
            XCTAssertEqual(error, .unsafeMemberPath("../escape.fa"))
        }
    }

    private func makeService() -> ApplicationExportImportCollectionService {
        ApplicationExportImportCollectionService(
            scanner: ApplicationExportScanner(),
            referenceImporter: { sourceURL, outputDirectory, preferredName in
                let bundle = outputDirectory.appendingPathComponent("\(preferredName).lungfishref", isDirectory: true)
                try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
                try "bundle for \(sourceURL.lastPathComponent)".write(
                    to: bundle.appendingPathComponent("manifest.txt"),
                    atomically: true,
                    encoding: .utf8
                )
                return ReferenceBundleImportResult(bundleURL: bundle, bundleName: preferredName)
            }
        )
    }

    private func makeTempDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory.appendingPathComponent("application-export-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        tempRoots.append(url)
        return url
    }

    private func makeApplicationExportArchive(root: URL, name: String) throws -> URL {
        let source = root.appendingPathComponent("source-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: source.appendingPathComponent("refs", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: source.appendingPathComponent("reports", isDirectory: true), withIntermediateDirectories: true)
        try ">ref\nACGT\n".write(to: source.appendingPathComponent("refs/reference.fa"), atomically: true, encoding: .utf8)
        try "sample\tmetric\nA\t1\n".write(to: source.appendingPathComponent("reports/summary.tsv"), atomically: true, encoding: .utf8)
        let archiveURL = root.appendingPathComponent(name)
        try runZip(
            workingDirectory: source,
            archiveURL: archiveURL,
            entries: ["refs/reference.fa", "reports/summary.tsv"]
        )
        return archiveURL
    }

    private func makeUnsafeArchive(root: URL) throws -> URL {
        let parentFile = root.appendingPathComponent("escape.fa")
        try ">escape\nACGT\n".write(to: parentFile, atomically: true, encoding: .utf8)
        let child = root.appendingPathComponent("child", isDirectory: true)
        try fileManager.createDirectory(at: child, withIntermediateDirectories: true)
        let archiveURL = root.appendingPathComponent("Unsafe.zip")
        try runZip(workingDirectory: child, archiveURL: archiveURL, entries: ["../escape.fa"])
        return archiveURL
    }

    private func makeAlignmentTreeExportFolder(root: URL) throws -> URL {
        let source = root.appendingPathComponent("alignment-tree-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: source.appendingPathComponent("alignments", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: source.appendingPathComponent("trees", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: source.appendingPathComponent("reports", isDirectory: true), withIntermediateDirectories: true)
        try """
        CLUSTAL W

        seq1 ACGT-A
        seq2 AC-TTA
        """.write(to: source.appendingPathComponent("alignments/mhc.aln"), atomically: true, encoding: .utf8)
        try "((A:0.1,B:0.2)90:0.3,C:0.4);\n".write(
            to: source.appendingPathComponent("trees/mhc.nwk"),
            atomically: true,
            encoding: .utf8
        )
        try "not imported\n".write(
            to: source.appendingPathComponent("reports/notes.txt"),
            atomically: true,
            encoding: .utf8
        )
        return source
    }

    private func runZip(workingDirectory: URL, archiveURL: URL, entries: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = workingDirectory
        process.arguments = ["-q", archiveURL.path] + entries
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}

private actor ReferenceImportCapture {
    struct Call: Equatable {
        let sourceURL: URL
        let outputDirectory: URL
        let preferredName: String
    }

    private var storage: [Call] = []

    var calls: [Call] { storage }

    func record(sourceURL: URL, outputDirectory: URL, preferredName: String) {
        storage.append(Call(sourceURL: sourceURL, outputDirectory: outputDirectory, preferredName: preferredName))
    }
}
