import LungfishWorkflow
import XCTest
@testable import LungfishApp

final class GeneiousImportCollectionServiceTests: XCTestCase {
    private let fileManager = FileManager.default
    private var tempRoots: [URL] = []

    override func tearDownWithError() throws {
        for url in tempRoots {
            try? fileManager.removeItem(at: url)
        }
        tempRoots.removeAll()
        try super.tearDownWithError()
    }

    func testImportCreatesOneCollectionFolderWithInventoryReportAndProvenance() async throws {
        let root = try makeTempDirectory()
        let projectURL = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try fileManager.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let archiveURL = try makeGeneiousArchive(root: root, name: "Example.geneious")
        let service = makeService()

        let result = try await service.importGeneiousExport(
            sourceURL: archiveURL,
            projectURL: projectURL,
            options: .default
        )

        XCTAssertEqual(result.collectionURL.lastPathComponent, "Example Geneious Import")
        XCTAssertTrue(fileManager.fileExists(atPath: result.collectionURL.appendingPathComponent("LGE Bundles").path))
        XCTAssertTrue(fileManager.fileExists(atPath: result.collectionURL.appendingPathComponent("Binary Artifacts").path))
        XCTAssertTrue(fileManager.fileExists(atPath: result.collectionURL.appendingPathComponent("Source").path))
        XCTAssertTrue(fileManager.fileExists(atPath: result.inventoryURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: result.reportURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: result.provenanceURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: result.collectionURL.appendingPathComponent("Source/Example.geneious").path))

        let inventoryData = try Data(contentsOf: result.inventoryURL)
        let inventoryDecoder = JSONDecoder()
        inventoryDecoder.dateDecodingStrategy = .iso8601
        let inventory = try inventoryDecoder.decode(GeneiousImportInventory.self, from: inventoryData)
        XCTAssertEqual(inventory.sourceKind, .geneiousArchive)
        XCTAssertEqual(inventory.items.count, 4)

        let report = try String(contentsOf: result.reportURL, encoding: .utf8)
        XCTAssertTrue(report.contains("# Geneious Import Report"))
        XCTAssertTrue(report.contains("Example.geneious"))
        XCTAssertTrue(report.contains("Native bundles"))
        XCTAssertTrue(report.contains("Preserved artifacts"))

        let provenanceData = try Data(contentsOf: result.provenanceURL)
        let provenanceDecoder = JSONDecoder()
        provenanceDecoder.dateDecodingStrategy = .iso8601
        let provenance = try provenanceDecoder.decode(WorkflowRun.self, from: provenanceData)
        XCTAssertEqual(provenance.name, "Geneious Import")
        XCTAssertEqual(provenance.status, .completed)
        XCTAssertGreaterThanOrEqual(provenance.steps.count, 3)
        XCTAssertTrue(provenance.steps.contains { $0.toolName == "Geneious Import" })
    }

    func testImportPreservesUnsupportedArchiveMembersAsBinaryArtifacts() async throws {
        let root = try makeTempDirectory()
        let projectURL = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try fileManager.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let archiveURL = try makeGeneiousArchive(root: root, name: "Example.geneious")

        let result = try await makeService().importGeneiousExport(
            sourceURL: archiveURL,
            projectURL: projectURL,
            options: .default
        )

        let artifactRoot = result.collectionURL.appendingPathComponent("Binary Artifacts", isDirectory: true)
        XCTAssertTrue(fileManager.fileExists(atPath: artifactRoot.appendingPathComponent("Example.geneious").path))
        XCTAssertTrue(fileManager.fileExists(atPath: artifactRoot.appendingPathComponent("fileData.0").path))
        XCTAssertTrue(fileManager.fileExists(atPath: artifactRoot.appendingPathComponent("docs/notes.txt").path))
        XCTAssertTrue(result.preservedArtifactURLs.contains { $0.path.hasSuffix("docs/notes.txt") })
        XCTAssertTrue(result.warnings.contains { $0.contains("not auto-routed") || $0.contains("not decoded") })
    }

    func testImportUsesInjectedReferenceImporterForStandaloneReferenceFiles() async throws {
        let root = try makeTempDirectory()
        let projectURL = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try fileManager.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let archiveURL = try makeGeneiousArchive(root: root, name: "Example.geneious")
        let capture = ReferenceImportCapture()
        let service = GeneiousImportCollectionService(
            scanner: GeneiousImportScanner(),
            referenceImporter: { sourceURL, outputDirectory, preferredName in
                await capture.record(sourceURL: sourceURL, outputDirectory: outputDirectory, preferredName: preferredName)
                let bundle = outputDirectory.appendingPathComponent("\(preferredName).lungfishref", isDirectory: true)
                try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
                return ReferenceBundleImportResult(bundleURL: bundle, bundleName: preferredName)
            }
        )

        let result = try await service.importGeneiousExport(
            sourceURL: archiveURL,
            projectURL: projectURL,
            options: .default
        )

        let calls = await capture.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.sourceURL.lastPathComponent, "reference.fa")
        XCTAssertEqual(calls.first?.outputDirectory.lastPathComponent, "LGE Bundles")
        XCTAssertEqual(calls.first?.preferredName, "reference")
        XCTAssertEqual(result.nativeBundleURLs.count, 1)
        XCTAssertEqual(result.nativeBundleURLs.first?.lastPathComponent, "reference.lungfishref")
    }

    func testImportFolderNameIsSanitizedAndUniqued() async throws {
        let root = try makeTempDirectory()
        let projectURL = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let folder = root.appendingPathComponent("Bad: Name?", isDirectory: true)
        try fileManager.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try ">ref\nACGT\n".write(to: folder.appendingPathComponent("reference.fa"), atomically: true, encoding: .utf8)
        let service = makeService()

        let first = try await service.importGeneiousExport(sourceURL: folder, projectURL: projectURL, options: .default)
        let second = try await service.importGeneiousExport(sourceURL: folder, projectURL: projectURL, options: .default)

        XCTAssertEqual(first.collectionURL.lastPathComponent, "Bad Name Geneious Import")
        XCTAssertEqual(second.collectionURL.lastPathComponent, "Bad Name Geneious Import 2")
        XCTAssertNotEqual(first.collectionURL, second.collectionURL)
    }

    private func makeService() -> GeneiousImportCollectionService {
        GeneiousImportCollectionService(
            scanner: GeneiousImportScanner(),
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
        let url = fileManager.temporaryDirectory.appendingPathComponent("geneious-collection-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        tempRoots.append(url)
        return url
    }

    private func makeGeneiousArchive(root: URL, name: String) throws -> URL {
        let source = root.appendingPathComponent("source-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        try writeGeneiousXML(to: source.appendingPathComponent("Example.geneious"))
        try "sidecar".write(to: source.appendingPathComponent("fileData.0"), atomically: true, encoding: .utf8)
        try fileManager.createDirectory(at: source.appendingPathComponent("refs", isDirectory: true), withIntermediateDirectories: true)
        try ">ref\nACGT\n".write(to: source.appendingPathComponent("refs/reference.fa"), atomically: true, encoding: .utf8)
        try fileManager.createDirectory(at: source.appendingPathComponent("docs", isDirectory: true), withIntermediateDirectories: true)
        try "notes".write(to: source.appendingPathComponent("docs/notes.txt"), atomically: true, encoding: .utf8)
        let archiveURL = root.appendingPathComponent(name)
        try runZip(
            workingDirectory: source,
            archiveURL: archiveURL,
            entries: ["Example.geneious", "fileData.0", "refs/reference.fa", "docs/notes.txt"]
        )
        return archiveURL
    }

    private func writeGeneiousXML(to url: URL) throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <geneious version="2026.0.2" minimumVersion="2025.2">
          <geneiousDocument class="com.biomatters.geneious.publicapi.documents.sequence.DefaultSequenceListDocument">
            <hiddenField name="cache_name">Example</hiddenField>
            <excludedDocument class="urn:local:test"/>
          </geneiousDocument>
        </geneious>
        """
        try xml.write(to: url, atomically: true, encoding: .utf8)
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
