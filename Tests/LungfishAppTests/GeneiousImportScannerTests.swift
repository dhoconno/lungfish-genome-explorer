import XCTest
@testable import LungfishApp

final class GeneiousImportScannerTests: XCTestCase {
    private let fileManager = FileManager.default
    private var tempRoots: [URL] = []

    override func tearDownWithError() throws {
        for url in tempRoots {
            try? fileManager.removeItem(at: url)
        }
        tempRoots.removeAll()
        try super.tearDownWithError()
    }

    func testScannerInventoriesGeneiousArchiveMembersAndNativeMetadata() async throws {
        let root = try makeTempDirectory()
        let source = root.appendingPathComponent("source", isDirectory: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        try writeGeneiousXML(to: source.appendingPathComponent("Example.geneious"))
        try "sidecar".write(to: source.appendingPathComponent("fileData.0"), atomically: true, encoding: .utf8)
        try fileManager.createDirectory(at: source.appendingPathComponent("reads", isDirectory: true), withIntermediateDirectories: true)
        try ">sample\nACGT\n".write(
            to: source.appendingPathComponent("reads/sample.fa"),
            atomically: true,
            encoding: .utf8
        )
        let archiveURL = root.appendingPathComponent("Example.geneious")
        try runZip(workingDirectory: source, archiveURL: archiveURL, entries: ["Example.geneious", "fileData.0", "reads/sample.fa"])
        let scanTemp = try makeProjectTempDirectory(in: root, name: "scan")

        let inventory = try await GeneiousImportScanner().scan(sourceURL: archiveURL, temporaryDirectory: scanTemp)

        XCTAssertEqual(inventory.sourceKind, .geneiousArchive)
        XCTAssertEqual(inventory.geneiousVersion, "2026.0.2")
        XCTAssertEqual(inventory.geneiousMinimumVersion, "2025.2")
        XCTAssertTrue(inventory.unresolvedURNs.contains("urn:local:test"))
        XCTAssertTrue(inventory.documentClasses.contains("com.biomatters.geneious.publicapi.documents.sequence.DefaultSequenceListDocument"))

        let itemsByPath = Dictionary(uniqueKeysWithValues: inventory.items.map { ($0.sourceRelativePath, $0) })
        XCTAssertEqual(itemsByPath["Example.geneious"]?.kind, .geneiousXML)
        XCTAssertEqual(itemsByPath["fileData.0"]?.kind, .geneiousSidecar)
        XCTAssertEqual(itemsByPath["reads/sample.fa"]?.kind, .standaloneReferenceSequence)
        XCTAssertEqual(
            itemsByPath["Example.geneious"]?.geneiousDocumentClass,
            "com.biomatters.geneious.publicapi.documents.sequence.DefaultSequenceListDocument"
        )
        XCTAssertEqual(itemsByPath["Example.geneious"]?.geneiousDocumentName, "MCM MHC Haplotypes")
        XCTAssertNotNil(itemsByPath["reads/sample.fa"]?.sha256)
        XCTAssertEqual(itemsByPath["reads/sample.fa"]?.sizeBytes, 13)
        XCTAssertFalse(fileManager.fileExists(atPath: scanTemp.path))
    }

    func testArchiveScanRequiresExplicitProjectTempDirectory() async throws {
        let root = try makeTempDirectory()
        let source = root.appendingPathComponent("source", isDirectory: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        try writeGeneiousXML(to: source.appendingPathComponent("Example.geneious"))
        let archiveURL = root.appendingPathComponent("Example.geneious")
        try runZip(workingDirectory: source, archiveURL: archiveURL, entries: ["Example.geneious"])

        do {
            _ = try await GeneiousImportScanner().scan(sourceURL: archiveURL)
            XCTFail("Archive scan should require an explicit project-local temp directory.")
        } catch let error as GeneiousImportScannerError {
            XCTAssertEqual(error, .temporaryDirectoryRequired)
        }
    }

    func testScannerClassifiesStandardFilesInFolderExport() async throws {
        let folder = try makeTempDirectory().appendingPathComponent("Folder Export", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try ">chr1\nACGT\n".write(to: folder.appendingPathComponent("reference.fasta"), atomically: true, encoding: .utf8)
        try "chr1\tsource\tgene\t1\t4\t.\t+\t.\tID=gene1\n".write(
            to: folder.appendingPathComponent("features.gff3"),
            atomically: true,
            encoding: .utf8
        )
        try "##fileformat=VCFv4.2\n".write(to: folder.appendingPathComponent("variants.vcf"), atomically: true, encoding: .utf8)
        try "@r1\nACGT\n+\n!!!!\n".write(to: folder.appendingPathComponent("reads.fastq"), atomically: true, encoding: .utf8)
        try "binary".write(to: folder.appendingPathComponent("fileData.1"), atomically: true, encoding: .utf8)

        let inventory = try await GeneiousImportScanner().scan(sourceURL: folder)

        XCTAssertEqual(inventory.sourceKind, .folder)
        let kinds = Dictionary(uniqueKeysWithValues: inventory.items.map { ($0.sourceRelativePath, $0.kind) })
        XCTAssertEqual(kinds["reference.fasta"], .standaloneReferenceSequence)
        XCTAssertEqual(kinds["features.gff3"], .annotationTrack)
        XCTAssertEqual(kinds["variants.vcf"], .variantTrack)
        XCTAssertEqual(kinds["reads.fastq"], .fastq)
        XCTAssertEqual(kinds["fileData.1"], .geneiousSidecar)
    }

    func testSafeArchiveMemberValidationRejectsTraversalAndAbsolutePaths() throws {
        XCTAssertThrowsError(try GeneiousArchiveTool.validateSafeMemberPath("/absolute.fa"))
        XCTAssertThrowsError(try GeneiousArchiveTool.validateSafeMemberPath("../escape.fa"))
        XCTAssertThrowsError(try GeneiousArchiveTool.validateSafeMemberPath("nested/../../escape.fa"))
        XCTAssertThrowsError(try GeneiousArchiveTool.validateSafeMemberPath("nested/.."))
        XCTAssertNoThrow(try GeneiousArchiveTool.validateSafeMemberPath("nested/reference.fa"))
    }

    func testScannerRecordsUnresolvedGeneiousSourceURNs() async throws {
        let folder = try makeTempDirectory().appendingPathComponent("URN Export", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeGeneiousXML(to: folder.appendingPathComponent("Example.geneious"))

        let inventory = try await GeneiousImportScanner().scan(sourceURL: folder)

        XCTAssertEqual(inventory.unresolvedURNs, ["urn:local:test"])
    }

    func testExternalSampleInventoryWhenAvailable() async throws {
        guard let path = ProcessInfo.processInfo.environment["LUNGFISH_GENEIOUS_SAMPLE"], !path.isEmpty else {
            throw XCTSkip("Set LUNGFISH_GENEIOUS_SAMPLE to run the external Geneious sample smoke test.")
        }

        let root = try makeTempDirectory()
        let scanTemp = try makeProjectTempDirectory(in: root, name: "external-scan")
        let inventory = try await GeneiousImportScanner().scan(
            sourceURL: URL(fileURLWithPath: path),
            temporaryDirectory: scanTemp
        )

        XCTAssertEqual(inventory.sourceKind, .geneiousArchive)
        XCTAssertEqual(inventory.items.filter { $0.kind == .geneiousXML }.count, 1)
        XCTAssertEqual(inventory.items.filter { $0.kind == .geneiousSidecar }.count, 13)
        XCTAssertEqual(inventory.geneiousVersion, "2026.0.2")
        XCTAssertFalse(inventory.unresolvedURNs.isEmpty)
    }

    private func makeTempDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory.appendingPathComponent("geneious-scanner-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        tempRoots.append(url)
        return url
    }

    private func makeProjectTempDirectory(in root: URL, name: String) throws -> URL {
        let projectURL = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let url = projectURL
            .appendingPathComponent(".tmp", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeGeneiousXML(to url: URL) throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <geneious version="2026.0.2" minimumVersion="2025.2">
          <geneiousDocument class="com.biomatters.geneious.publicapi.documents.sequence.DefaultSequenceListDocument">
            <hiddenField name="cache_name">MCM MHC Haplotypes</hiddenField>
            <hiddenField name="override_cache_name">Ignored Override</hiddenField>
            <excludedDocument class="urn">urn:local:test</excludedDocument>
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
