import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

@MainActor
final class AssemblyDocumentSectionTests: XCTestCase {
    func testAssemblyDocumentStateOrdersLayoutBeforeProvenanceAndArtifacts() {
        let state = AssemblyDocumentState(
            title: "spades-2026-04-21T09-20-22",
            subtitle: "SPAdes • Illumina Short Reads",
            sourceData: [
                .projectLink(name: "reads.fastq.gz", targetURL: URL(fileURLWithPath: "/tmp/reads.fastq.gz"))
            ],
            contextRows: [("Assembler", "SPAdes")],
            artifactRows: [
                .init(label: "Contigs FASTA", fileURL: URL(fileURLWithPath: "/tmp/contigs.fasta"))
            ]
        )

        XCTAssertEqual(
            state.visibleSectionOrder,
            [.header, .layout, .sourceData, .assemblyContext, .sourceArtifacts]
        )
    }

    func testDocumentSectionViewModelUpdateAssemblyDocumentStoresAssemblyContent() {
        let viewModel = DocumentSectionViewModel()
        let state = AssemblyDocumentState(
            title: "assembly",
            subtitle: "SPAdes • Illumina Short Reads",
            sourceData: [],
            contextRows: [],
            artifactRows: []
        )

        viewModel.updateAssemblyDocument(state)

        XCTAssertEqual(viewModel.assemblyDocument, state)
        XCTAssertTrue(viewModel.hasAnyContent)
    }

    func testInspectorUpdateAssemblyDocumentBuildsArtifactsAndSourceRows() throws {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("assembly-doc-inspector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let inputURL = projectURL
            .appendingPathComponent("Imports", isDirectory: true)
            .appendingPathComponent("reads.fastq.gz")
        try FileManager.default.createDirectory(at: inputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: inputURL.path, contents: Data())

        let result = try makeAssemblyResult()
        let provenance = AssemblyProvenance(
            assembler: "SPAdes",
            assemblerVersion: "4.0.0",
            executionBackend: .micromamba,
            managedEnvironment: "spades-env",
            launcherCommand: "spades.py",
            containerImage: nil,
            containerImageDigest: nil,
            containerRuntime: nil,
            hostOS: "macOS 26.0",
            hostArchitecture: "arm64",
            lungfishVersion: "1.0.0",
            assemblyDate: Date(timeIntervalSince1970: 1_700_000_000),
            wallTimeSeconds: result.wallTimeSeconds,
            commandLine: result.commandLine,
            parameters: AssemblyParameters(
                mode: "default",
                kmerSizes: "auto",
                memoryGB: 32,
                threads: 8,
                skipErrorCorrection: false,
                minContigLength: 0
            ),
            inputs: [
                .init(filename: inputURL.lastPathComponent, originalPath: inputURL.path, sha256: nil, sizeBytes: 128)
            ],
            statistics: result.statistics
        )

        let inspector = InspectorViewController()
        inspector.loadViewIfNeeded()

        inspector.updateAssemblyDocument(result: result, provenance: provenance, projectURL: projectURL)

        let state = try XCTUnwrap(inspector.viewModel.documentSectionViewModel.assemblyDocument)
        XCTAssertEqual(state.title, result.outputDirectory.lastPathComponent)
        XCTAssertEqual(state.subtitle, "\(result.tool.displayName) • \(result.readType.displayName)")
        XCTAssertEqual(state.sourceData.count, 1)
        XCTAssertEqual(
            state.sourceData.first,
            .projectLink(name: inputURL.lastPathComponent, targetURL: inputURL)
        )
        XCTAssertTrue(state.contextRows.contains { $0.0 == "Assembler" && $0.1 == "SPAdes" })
        XCTAssertTrue(state.artifactRows.contains { $0.label == "Contigs FASTA" && $0.fileURL == result.contigsPath })
        XCTAssertTrue(
            state.artifactRows.contains {
                $0.label == "Provenance" &&
                    $0.fileURL == result.outputDirectory.appendingPathComponent(AssemblyProvenance.filename)
            }
        )
    }
}
