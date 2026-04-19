import XCTest
@testable import LungfishWorkflow

final class ManagedAssemblyPipelineTests: XCTestCase {
    func testBuildsSpadesCommandForIlluminaReads() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("managed-assembly-spades-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let request = AssemblyRunRequest(
            tool: .spades,
            readType: .illuminaShortReads,
            inputURLs: [
                URL(fileURLWithPath: "/tmp/R1.fastq.gz"),
                URL(fileURLWithPath: "/tmp/R2.fastq.gz"),
            ],
            projectName: "ecoli",
            outputDirectory: tempDir,
            pairedEnd: true,
            threads: 8,
            memoryGB: 16,
            minContigLength: 500,
            selectedProfileID: "isolate",
            extraArguments: []
        )

        let command = try ManagedAssemblyPipeline.buildCommand(for: request)

        XCTAssertEqual(command.executable, "spades.py")
        XCTAssertEqual(command.environment, "spades")
        XCTAssertEqual(command.workingDirectory, tempDir.deletingLastPathComponent())
        XCTAssertTrue(command.arguments.contains("--threads"))
        XCTAssertTrue(command.arguments.contains("--memory"))
        XCTAssertTrue(command.arguments.contains("-1"))
        XCTAssertTrue(command.arguments.contains("-2"))
    }

    func testBuildsFlyeCommandForOntReads() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("managed-assembly-flye-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let request = AssemblyRunRequest(
            tool: .flye,
            readType: .ontReads,
            inputURLs: [URL(fileURLWithPath: "/tmp/ont.fastq.gz")],
            projectName: "ont-demo",
            outputDirectory: tempDir,
            threads: 16,
            memoryGB: nil,
            minContigLength: nil,
            selectedProfileID: "nano-hq",
            extraArguments: []
        )

        let command = try ManagedAssemblyPipeline.buildCommand(for: request)

        XCTAssertEqual(command.executable, "flye")
        XCTAssertEqual(command.workingDirectory, tempDir.deletingLastPathComponent())
        XCTAssertTrue(command.arguments.contains("--nano-hq"))
        XCTAssertTrue(command.arguments.contains("--out-dir"))
    }

    func testBuildsMegahitCommandForShortReads() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("managed-assembly-megahit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let request = AssemblyRunRequest(
            tool: .megahit,
            readType: .illuminaShortReads,
            inputURLs: [
                URL(fileURLWithPath: "/tmp/R1.fastq.gz"),
                URL(fileURLWithPath: "/tmp/R2.fastq.gz"),
            ],
            projectName: "meta-demo",
            outputDirectory: tempDir,
            pairedEnd: true,
            threads: 12,
            memoryGB: nil,
            minContigLength: 1000,
            selectedProfileID: "meta-sensitive",
            extraArguments: []
        )

        let command = try ManagedAssemblyPipeline.buildCommand(for: request)

        XCTAssertEqual(command.executable, "megahit")
        XCTAssertEqual(command.workingDirectory, tempDir.deletingLastPathComponent())
        XCTAssertTrue(command.arguments.contains("--num-cpu-threads"))
        XCTAssertTrue(command.arguments.contains("--presets"))
        XCTAssertTrue(command.arguments.contains("--min-contig-len"))
    }

    func testRejectsIncompatibleToolReadType() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("managed-assembly-invalid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let request = AssemblyRunRequest(
            tool: .flye,
            readType: .illuminaShortReads,
            inputURLs: [URL(fileURLWithPath: "/tmp/sample.fastq.gz")],
            projectName: "bad-demo",
            outputDirectory: tempDir,
            threads: 8
        )

        XCTAssertThrowsError(try ManagedAssemblyPipeline.buildCommand(for: request)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Flye is not available for Illumina short reads in v1."
            )
        }
    }
}
