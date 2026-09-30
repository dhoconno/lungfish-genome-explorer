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
            [.header, .sourceData, .assemblyContext, .sourceArtifacts]
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

    func testCLIAssemblyRehydratesSourceAndContextFromCanonicalSidecar() throws {
        let result = try makeAssemblyResult()
        defer { try? FileManager.default.removeItem(at: result.outputDirectory) }
        let input = result.outputDirectory.appendingPathComponent("reads.fastq")
        try Data().write(to: input)
        let envelope = ProvenanceEnvelope(
            workflowName: "assemble", toolName: "lungfish-cli", toolVersion: "2026.9.13",
            argv: ["lungfish-cli", "assemble", input.path],
            runtimeIdentity: ProvenanceRuntimeIdentity(condaEnvironment: "flye-env"),
            files: [.init(path: input.path, checksumSHA256: "abc", fileSize: 0, role: .input)],
            exitStatus: 0
        )
        let sidecar = result.outputDirectory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(envelope).write(to: sidecar)
        let originalData = try Data(contentsOf: sidecar)
        let inspector = InspectorViewController()
        inspector.loadViewIfNeeded()
        inspector.updateAssemblyDocument(result: result, provenance: nil, projectURL: nil)
        let state = try XCTUnwrap(inspector.viewModel.documentSectionViewModel.assemblyDocument)
        XCTAssertEqual(state.sourceData, [.filesystemLink(name: "reads.fastq", fileURL: input)])
        XCTAssertTrue(state.contextRows.contains { $0.0 == "Environment" && $0.1 == "flye-env" })
        XCTAssertTrue(state.contextRows.contains { $0.0 == "Workflow Command" && $0.1 == envelope.reproducibleCommand })
        XCTAssertTrue(state.artifactRows.contains { $0.label == "Provenance" && $0.fileURL == sidecar })
        XCTAssertEqual(try Data(contentsOf: sidecar), originalData)
    }

    // A window Flye run records the profile and why it was chosen, but the
    // Inspector's Assembly Context never showed either row.
    func testAssemblyContextShowsTheRecordedProfileAndItsBasis() throws {
        let result = try makeAssemblyResult()
        defer { try? FileManager.default.removeItem(at: result.outputDirectory) }
        let envelope = ProvenanceEnvelope(
            workflowName: "assemble", toolName: "lungfish-cli", toolVersion: "2026.9.61",
            argv: ["lungfish-cli", "assemble"],
            options: ProvenanceOptions(explicit: [
                "profile": .string("nano-raw"),
                "profileBasis": .string("Nano Raw preselected: median read quality Q8 is below Q10"),
            ]),
            exitStatus: 0
        )
        let inspector = InspectorViewController()
        inspector.loadViewIfNeeded()
        let rows = inspector.assemblyContextRows(result: result, provenance: nil, scientificProvenance: envelope)
        XCTAssertTrue(rows.contains { $0.0 == "Profile" && $0.1 == "nano-raw" })
        XCTAssertTrue(rows.contains { $0.0 == "Profile Basis" && $0.1.contains("Q8") })

        let defaultEnvelope = ProvenanceEnvelope(
            workflowName: "assemble", toolName: "lungfish-cli", toolVersion: "2026.9.61",
            options: ProvenanceOptions(explicit: ["profile": .string("default"), "profileBasis": .null])
        )
        let defaultRows = inspector.assemblyContextRows(result: result, provenance: nil, scientificProvenance: defaultEnvelope)
        XCTAssertFalse(defaultRows.contains { $0.0 == "Profile" || $0.0 == "Profile Basis" })
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
        XCTAssertEqual(inspector.viewModel.provenanceSectionViewModel.currentItem?.url, result.outputDirectory)
        XCTAssertEqual(inspector.viewModel.provenanceSectionViewModel.currentItem?.sidebarType, .analysisResult)
    }
}
