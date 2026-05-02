import LungfishCore
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
        XCTAssertFalse(fileManager.fileExists(atPath: result.collectionURL.appendingPathComponent("Binary Artifacts").path))
        XCTAssertFalse(fileManager.fileExists(atPath: result.collectionURL.appendingPathComponent("Source").path))
        XCTAssertFalse(fileManager.fileExists(atPath: result.collectionURL.appendingPathComponent("Decoded FASTA").path))
        XCTAssertTrue(fileManager.fileExists(atPath: result.inventoryURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: result.reportURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: result.provenanceURL.path))

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

    func testImportPreservesUnsupportedArchiveMembersAsBinaryArtifactsWhenRequested() async throws {
        let root = try makeTempDirectory()
        let projectURL = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try fileManager.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let archiveURL = try makeGeneiousArchive(root: root, name: "Example.geneious")

        let result = try await makeService().importGeneiousExport(
            sourceURL: archiveURL,
            projectURL: projectURL,
            options: GeneiousImportOptions(
                preserveRawSource: true,
                preserveUnsupportedArtifacts: true
            )
        )

        let artifactRoot = result.collectionURL.appendingPathComponent("Binary Artifacts", isDirectory: true)
        XCTAssertTrue(fileManager.fileExists(atPath: result.collectionURL.appendingPathComponent("Source/Example.geneious").path))
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

    func testImportDecodesPackedGeneiousNucleotideSequencesIntoReferenceBundle() async throws {
        let root = try makeTempDirectory()
        let projectURL = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try fileManager.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("packed-source", isDirectory: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        try writePackedGeneiousSequenceXML(to: source.appendingPathComponent("Example.geneious"))
        try writePackedGeneiousSequence("ACGTACGT", to: source.appendingPathComponent("fileData.0"))
        try writeFourBitPackedGeneiousSequence([0, 1, 2, 3, 5, 9], to: source.appendingPathComponent("fileData.1"))
        let archiveURL = root.appendingPathComponent("Packed.geneious")
        try runZip(workingDirectory: source, archiveURL: archiveURL, entries: ["Example.geneious", "fileData.0", "fileData.1"])
        let capture = ReferenceImportCapture()
        let annotationCapture = AnnotationImportCapture()
        let service = GeneiousImportCollectionService(
            scanner: GeneiousImportScanner(),
            referenceImporter: { sourceURL, outputDirectory, preferredName in
                await capture.record(
                    sourceURL: sourceURL,
                    outputDirectory: outputDirectory,
                    preferredName: preferredName,
                    fastaText: try? String(contentsOf: sourceURL, encoding: .utf8)
                )
                let bundle = outputDirectory.appendingPathComponent("\(preferredName).lungfishref", isDirectory: true)
                try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
                return ReferenceBundleImportResult(bundleURL: bundle, bundleName: preferredName)
            },
            annotationImporter: { gffURL, bundleURL in
                try await annotationCapture.record(gffURL: gffURL, bundleURL: bundleURL)
            }
        )

        let result = try await service.importGeneiousExport(
            sourceURL: archiveURL,
            projectURL: projectURL,
            options: .default
        )

        let calls = await capture.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.preferredName, "Packed Haplotypes")
        let fasta = try XCTUnwrap(calls.first?.fastaText)
        XCTAssertTrue(calls.first?.sourceURL.path.contains("/Project.lungfish/.tmp/geneious-import-") == true)
        XCTAssertTrue(fasta.contains(">Seq One"))
        XCTAssertTrue(fasta.contains("ACGTACGT"))
        XCTAssertTrue(fasta.contains(">Seq Two"))
        XCTAssertTrue(fasta.contains("ACGTNN"))
        XCTAssertEqual(result.nativeBundleURLs.count, 1)
        XCTAssertFalse(result.preservedArtifactURLs.contains { $0.lastPathComponent == "fileData.0" })
        XCTAssertFalse(result.preservedArtifactURLs.contains { $0.lastPathComponent == "fileData.1" })
        XCTAssertFalse(result.warnings.contains { $0.contains("fileData.0 contains native Geneious data") })
        XCTAssertFalse(result.warnings.contains { $0.contains("fileData.1 contains native Geneious data") })
        XCTAssertFalse(fileManager.fileExists(atPath: result.collectionURL.appendingPathComponent("Decoded FASTA").path))

        let annotationCalls = await annotationCapture.calls
        XCTAssertEqual(annotationCalls.count, 1)
        let gff3 = try XCTUnwrap(annotationCalls.first?.gff3Text)
        XCTAssertTrue(annotationCalls.first?.gffURL.path.contains("/Project.lungfish/.tmp/geneious-import-") == true)
        XCTAssertTrue(gff3.contains("Seq One\tGeneious\tgene\t2\t5\t.\t+\t."))
        XCTAssertTrue(gff3.contains("Name=Test%20gene"))
        XCTAssertTrue(gff3.contains("Seq One\tGeneious\tCDS\t1\t2\t.\t+\t.\tID=geneious-2;part=1;Name=Split%20CDS"))
        XCTAssertTrue(gff3.contains("Seq One\tGeneious\tCDS\t5\t6\t.\t+\t.\tID=geneious-2;part=2;Name=Split%20CDS"))
        XCTAssertFalse(gff3.contains("Parent=geneious-2"))
        let tempChildren = (try? fileManager.contentsOfDirectory(
            at: projectURL.appendingPathComponent(".tmp", isDirectory: true),
            includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertFalse(tempChildren.contains { $0.lastPathComponent.hasPrefix("geneious-import-") })
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

    private func writePackedGeneiousSequenceXML(to url: URL) throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <geneious version="2026.0.2" minimumVersion="2025.2">
          <geneiousDocument class="com.biomatters.geneious.publicapi.documents.sequence.DefaultSequenceListDocument">
            <hiddenFields>
              <override_cache_name>Packed Haplotypes</override_cache_name>
            </hiddenFields>
            <originalElement>
              <XMLSerialisableRootElement>
                <nucleotideSequence type="DefaultNucleotideSequence">
                  <fields>
                    <cache_name>Seq One</cache_name>
                    <sequence_length type="int">8</sequence_length>
                  </fields>
                  <name>Seq One</name>
                  <sequenceAnnotations>
                    <annotation>
                      <description>Test gene</description>
                      <type>gene</type>
                      <intervals>
                        <interval>
                          <minimumIndex>1</minimumIndex>
                          <maximumIndex>4</maximumIndex>
                          <direction>leftToRight</direction>
                        </interval>
                      </intervals>
                      <qualifiers>
                        <qualifier>
                          <name>note</name>
                          <value>converted from Geneious</value>
                        </qualifier>
                      </qualifiers>
                    </annotation>
                    <annotation>
                      <description>Split CDS</description>
                      <type>CDS</type>
                      <intervals>
                        <interval>
                          <minimumIndex>0</minimumIndex>
                          <maximumIndex>1</maximumIndex>
                          <direction>leftToRight</direction>
                        </interval>
                        <interval>
                          <minimumIndex>4</minimumIndex>
                          <maximumIndex>5</maximumIndex>
                          <direction>leftToRight</direction>
                        </interval>
                      </intervals>
                    </annotation>
                  </sequenceAnnotations>
                  <charSequence xmlFileData="fileData.0" fileSize="12" length="8" />
                </nucleotideSequence>
                <nucleotideSequence type="DefaultNucleotideSequence">
                  <fields>
                    <cache_name>Seq Two</cache_name>
                    <sequence_length type="int">6</sequence_length>
                  </fields>
                  <name>Seq Two</name>
                  <charSequence xmlFileData="fileData.1" fileSize="12" length="6" />
                </nucleotideSequence>
              </XMLSerialisableRootElement>
            </originalElement>
          </geneiousDocument>
        </geneious>
        """
        try xml.write(to: url, atomically: true, encoding: .utf8)
    }

    private func writePackedGeneiousSequence(_ sequence: String, to url: URL) throws {
        let values = sequence.map { base -> UInt8 in
            switch base {
            case "A": return 0
            case "C": return 1
            case "G": return 2
            case "T": return 3
            default: return 0
            }
        }
        var packed = Data()
        var index = 0
        while index < values.count {
            var byte: UInt8 = 0
            for offset in 0..<4 {
                let value = index + offset < values.count ? values[index + offset] : 0
                byte |= value << UInt8(6 - (offset * 2))
            }
            packed.append(byte)
            index += 4
        }

        var payload = Data([0x20])
        var packedLength = UInt32(packed.count).bigEndian
        payload.append(Data(bytes: &packedLength, count: MemoryLayout<UInt32>.size))
        payload.append(packed)

        var stream = Data([0xAC, 0xED, 0x00, 0x05, 0x77, UInt8(payload.count)])
        stream.append(payload)
        try stream.write(to: url)
    }

    private func writeFourBitPackedGeneiousSequence(_ values: [UInt8], to url: URL) throws {
        var packed = Data()
        var index = 0
        while index < values.count {
            let first = values[index] & 0x0F
            let second = index + 1 < values.count ? values[index + 1] & 0x0F : 0
            packed.append((first << 4) | second)
            index += 2
        }

        var payload = Data([0x30])
        var packedLength = UInt32(packed.count).bigEndian
        payload.append(Data(bytes: &packedLength, count: MemoryLayout<UInt32>.size))
        payload.append(packed)

        var stream = Data([0xAC, 0xED, 0x00, 0x05, 0x77, UInt8(payload.count)])
        stream.append(payload)
        try stream.write(to: url)
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
        let fastaText: String?
    }

    private var storage: [Call] = []

    var calls: [Call] { storage }

    func record(
        sourceURL: URL,
        outputDirectory: URL,
        preferredName: String,
        fastaText: String? = nil
    ) {
        storage.append(Call(
            sourceURL: sourceURL,
            outputDirectory: outputDirectory,
            preferredName: preferredName,
            fastaText: fastaText
        ))
    }
}

private actor AnnotationImportCapture {
    struct Call: Equatable {
        let gffURL: URL
        let bundleURL: URL
        let gff3Text: String
    }

    private var storage: [Call] = []

    var calls: [Call] { storage }

    func record(gffURL: URL, bundleURL: URL) throws -> ReferenceBundleAnnotationImportResult {
        let gff3Text = try String(contentsOf: gffURL, encoding: .utf8)
        storage.append(Call(gffURL: gffURL, bundleURL: bundleURL, gff3Text: gff3Text))
        return ReferenceBundleAnnotationImportResult(
            bundleURL: bundleURL,
            track: AnnotationTrackInfo(
                id: "geneious_annotations",
                name: "Geneious annotations",
                path: "annotations/geneious_annotations.db",
                annotationType: .custom,
                featureCount: gff3Text.split(separator: "\n").filter { !$0.hasPrefix("#") }.count,
                source: gffURL.path
            ),
            featureCount: gff3Text.split(separator: "\n").filter { !$0.hasPrefix("#") }.count
        )
    }
}
