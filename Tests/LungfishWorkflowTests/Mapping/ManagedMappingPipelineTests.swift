import XCTest
@testable import LungfishWorkflow

final class ManagedMappingPipelineTests: XCTestCase {

    func testBuildsBwaMem2CommandForShortReads() throws {
        let request = makeRequest(tool: .bwaMem2)

        let command = try ManagedMappingPipeline.buildCommand(for: request)

        XCTAssertEqual(command.executable, "bwa-mem2")
        XCTAssertEqual(command.environment, "bwa-mem2")
        XCTAssertEqual(Array(command.arguments.prefix(2)), ["mem", "-t"])
        XCTAssertNil(command.nativeTool)
    }

    func testBuildsBowtie2CommandWithIndexPrefix() throws {
        let request = makeRequest(tool: .bowtie2)

        let command = try ManagedMappingPipeline.buildCommand(for: request)

        XCTAssertEqual(command.executable, "bowtie2")
        XCTAssertEqual(command.environment, "bowtie2")
        XCTAssertTrue(command.arguments.contains("-x"))
        XCTAssertNil(command.nativeTool)
    }

    func testBuildsBBMapCommandAsNativeTool() throws {
        let request = makeRequest(tool: .bbmap)

        let command = try ManagedMappingPipeline.buildCommand(for: request)

        XCTAssertEqual(command.executable, "bbmap.sh")
        XCTAssertTrue(command.arguments.contains("ref=/tmp/reference.fa"))
        XCTAssertEqual(command.nativeTool, .bbmap)
        XCTAssertNil(command.environment)
    }

    func testBuildsBBMapPacBioCommandAsNativeTool() throws {
        let request = makeRequest(tool: .bbmap, modeID: MappingMode.bbmapPacBio.id)

        let command = try ManagedMappingPipeline.buildCommand(for: request)

        XCTAssertEqual(command.executable, "mapPacBio.sh")
        XCTAssertEqual(command.nativeTool, .mapPacBio)
        XCTAssertNil(command.environment)
    }

    func testNormalizeAlignmentConvertsSAMToSortedIndexedBAM() async throws {
        let fixture = try SamtoolsFixture()
        defer { fixture.cleanup() }

        let rawSAM = fixture.tempRoot.appendingPathComponent("sample.sam")
        try Data("sam".utf8).write(to: rawSAM)

        let pipeline = ManagedMappingPipeline(
            condaManager: .shared,
            nativeToolRunner: fixture.runner
        )

        let result = try await pipeline.normalizeAlignment(
            rawAlignmentURL: rawSAM,
            outputDirectory: fixture.tempRoot
        )

        XCTAssertEqual(result.bamURL.lastPathComponent, "sample.sorted.bam")
        XCTAssertEqual(Array(try fixture.recordedSubcommands().prefix(3)), ["view", "sort", "index"])
    }

    func testNormalizeAlignmentSortsUnsortedBAM() async throws {
        let fixture = try SamtoolsFixture()
        defer { fixture.cleanup() }

        let rawBAM = fixture.tempRoot.appendingPathComponent("sample.unsorted.bam")
        try Data("bam".utf8).write(to: rawBAM)

        let pipeline = ManagedMappingPipeline(
            condaManager: .shared,
            nativeToolRunner: fixture.runner
        )

        let result = try await pipeline.normalizeAlignment(
            rawAlignmentURL: rawBAM,
            outputDirectory: fixture.tempRoot
        )

        XCTAssertEqual(result.bamURL.lastPathComponent, "sample.sorted.bam")
        XCTAssertEqual(Array(try fixture.recordedSubcommands().prefix(2)), ["sort", "index"])
    }

    func testNormalizeAlignmentIndexesAlreadySortedBAM() async throws {
        let fixture = try SamtoolsFixture()
        defer { fixture.cleanup() }

        let sortedBAM = fixture.tempRoot.appendingPathComponent("sample.sorted.bam")
        try Data("bam".utf8).write(to: sortedBAM)

        let pipeline = ManagedMappingPipeline(
            condaManager: .shared,
            nativeToolRunner: fixture.runner
        )

        let result = try await pipeline.normalizeAlignment(
            rawAlignmentURL: sortedBAM,
            outputDirectory: fixture.tempRoot
        )

        XCTAssertEqual(result.bamURL.lastPathComponent, "sample.sorted.bam")
        XCTAssertEqual(Array(try fixture.recordedSubcommands().prefix(1)), ["index"])
    }

    func testValidateCompatibilityRejectsMixedReadClasses() throws {
        let fixture = try MappingFASTQFixture()
        defer { fixture.cleanup() }

        let illuminaFASTQ = try fixture.writeFASTQ(
            name: "illumina.fastq",
            header: "@A00488:385:HKGCLDRXX:1:1101:1000:1000 1:N:0:1",
            sequenceLength: 151
        )
        let ontFASTQ = try fixture.writeFASTQ(
            name: "ont.fastq",
            header: "@0d4c6f0e-1234-5678-9abc-def012345678 runid=test flow_cell_id=FLO-MIN106 start_time=2026-04-19T00:00:00Z",
            sequenceLength: 1_200
        )

        let request = MappingRunRequest(
            tool: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            inputFASTQURLs: [illuminaFASTQ, ontFASTQ],
            referenceFASTAURL: fixture.referenceURL,
            outputDirectory: fixture.root.appendingPathComponent("out"),
            sampleName: "sample",
            pairedEnd: false,
            threads: 4
        )

        XCTAssertThrowsError(try ManagedMappingPipeline.validateCompatibility(for: request)) { error in
            guard case .incompatibleSelection(let message) = error as? ManagedMappingPipelineError else {
                return XCTFail("Expected incompatibleSelection error, got \(error)")
            }
            XCTAssertEqual(message, "Selected FASTQ inputs mix incompatible read classes. Select one read class per mapping run.")
        }
    }

    func testValidateCompatibilityRejectsBBMapStandardReadsLongerThan500Bases() throws {
        let fixture = try MappingFASTQFixture()
        defer { fixture.cleanup() }

        let ontFASTQ = try fixture.writeFASTQ(
            name: "ont.fastq",
            header: "@0d4c6f0e-1234-5678-9abc-def012345678 runid=test flow_cell_id=FLO-MIN106 start_time=2026-04-19T00:00:00Z",
            sequenceLength: 700
        )

        let request = MappingRunRequest(
            tool: .bbmap,
            modeID: MappingMode.bbmapStandard.id,
            inputFASTQURLs: [ontFASTQ],
            referenceFASTAURL: fixture.referenceURL,
            outputDirectory: fixture.root.appendingPathComponent("out"),
            sampleName: "sample",
            pairedEnd: false,
            threads: 4
        )

        XCTAssertThrowsError(try ManagedMappingPipeline.validateCompatibility(for: request)) { error in
            guard case .incompatibleSelection(let message) = error as? ManagedMappingPipelineError else {
                return XCTFail("Expected incompatibleSelection error, got \(error)")
            }
            XCTAssertEqual(message, "Standard BBMap mode supports reads up to 500 bases. Switch to PacBio mode or choose another mapper.")
        }
    }

    private func makeRequest(tool: MappingTool, modeID: String? = nil) -> MappingRunRequest {
        MappingRunRequest(
            tool: tool,
            modeID: modeID ?? (tool == .bbmap ? MappingMode.bbmapStandard.id : MappingMode.defaultShortRead.id),
            inputFASTQURLs: [
                URL(fileURLWithPath: "/tmp/R1.fastq.gz"),
                URL(fileURLWithPath: "/tmp/R2.fastq.gz"),
            ],
            referenceFASTAURL: URL(fileURLWithPath: "/tmp/reference.fa"),
            outputDirectory: URL(fileURLWithPath: "/tmp/mapping-output"),
            sampleName: "sample",
            pairedEnd: true,
            threads: 8
        )
    }
}

private struct SamtoolsFixture {
    let tempRoot: URL
    let runner: NativeToolRunner
    let logURL: URL

    init() throws {
        let fm = FileManager.default
        tempRoot = fm.temporaryDirectory.appendingPathComponent(
            "mapping-samtools-fixture-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let homeDirectory = tempRoot.appendingPathComponent("home", isDirectory: true)
        let samtoolsDir = homeDirectory
            .appendingPathComponent(".lungfish/conda/envs/samtools/bin", isDirectory: true)
        try fm.createDirectory(at: samtoolsDir, withIntermediateDirectories: true)

        logURL = tempRoot.appendingPathComponent("samtools.log")
        let scriptURL = samtoolsDir.appendingPathComponent("samtools")
        try Self.scriptBody(logURL: logURL).write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        runner = NativeToolRunner(toolsDirectory: nil, homeDirectory: homeDirectory)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func recordedSubcommands() throws -> [String] {
        guard FileManager.default.fileExists(atPath: logURL.path) else { return [] }
        return try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                String(line.split(separator: "\t", omittingEmptySubsequences: false).first ?? "")
            }
    }

    private static func scriptBody(logURL: URL) -> String {
        """
        #!/bin/sh
        subcommand="$1"
        printf '%s' "$subcommand" >> "\(logURL.path)"
        shift
        for arg in "$@"; do
            printf '\\t%s' "$arg" >> "\(logURL.path)"
        done
        printf '\\n' >> "\(logURL.path)"

        case "$subcommand" in
          sort)
            out=""
            while [ "$#" -gt 0 ]; do
              if [ "$1" = "-o" ]; then
                out="$2"
                shift 2
              else
                shift
              fi
            done
            : > "$out"
            ;;
          view)
            out=""
            while [ "$#" -gt 0 ]; do
              if [ "$1" = "-o" ]; then
                out="$2"
                shift 2
              else
                shift
              fi
            done
            if [ -n "$out" ]; then
              : > "$out"
            fi
            ;;
          index)
            bam="$1"
            : > "${bam}.bai"
            ;;
          flagstat)
            printf '%s\\n' '10 + 0 in total (QC-passed reads + QC-failed reads)'
            printf '%s\\n' '8 + 0 mapped (80.00% : N/A)'
            ;;
        esac

        exit 0
        """
    }
}

private struct MappingFASTQFixture {
    let root: URL
    let referenceURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mapping-validation-fixture-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        referenceURL = root.appendingPathComponent("reference.fa")
        try ">ref\nACGT\n".write(to: referenceURL, atomically: true, encoding: .utf8)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func writeFASTQ(name: String, header: String, sequenceLength: Int) throws -> URL {
        let url = root.appendingPathComponent(name)
        let sequence = String(repeating: "A", count: sequenceLength)
        let quality = String(repeating: "I", count: sequenceLength)
        let text = "\(header)\n\(sequence)\n+\n\(quality)\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
