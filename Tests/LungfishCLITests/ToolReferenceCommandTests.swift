import ArgumentParser
import Darwin
import Foundation
import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

final class ToolReferenceCommandTests: XCTestCase {
    func testVersionToolsPrintsBundledAndManagedToolTable() async throws {
        let command = try VersionCommand.parse(["--tools"])

        let output = try await captureStandardOutput {
            try await command.run()
        }

        XCTAssertTrue(output.contains("Bundled and Managed Tools"), output)
        XCTAssertTrue(output.contains("Tool"), output)
        XCTAssertTrue(output.contains("Version"), output)
        XCTAssertTrue(output.contains("micromamba"), output)
        XCTAssertTrue(output.contains("2.0.5-0"), output)
        XCTAssertTrue(output.contains("Nextflow"), output)
        XCTAssertTrue(output.contains("25.10.4"), output)
        XCTAssertTrue(output.contains("Samtools"), output)
        XCTAssertTrue(output.contains("1.23.1"), output)
    }

    func testVersionToolsParsesThroughTopLevelCLI() throws {
        let command = try LungfishCLI.parseAsRoot(["version", "--tools"])
        XCTAssertTrue(command is VersionCommand)
    }

    func testProvenanceBibliographyPrintsKnownCitationsAndUnmatchedTools() async throws {
        let bundle = try makeBundleWithProvenance(
            steps: [
                StepExecution(
                    toolName: "samtools sort",
                    toolVersion: "1.23.1",
                    command: ["samtools", "sort", "reads.bam"],
                    inputs: []
                ),
                StepExecution(
                    toolName: "fastp adapter trimming",
                    toolVersion: "1.3.2",
                    command: ["fastp", "--in1", "reads.fastq"],
                    inputs: []
                ),
                StepExecution(
                    toolName: "custom laboratory script",
                    toolVersion: "2026.05",
                    command: ["./custom-qc"],
                    inputs: []
                ),
            ]
        )

        let command = try ProvenanceCommand.BibliographySubcommand.parse([bundle.path])
        let output = try await captureStandardOutput {
            try await command.run()
        }

        XCTAssertTrue(output.contains("Bibliography for bundle"), output)
        XCTAssertTrue(output.contains("fastp"), output)
        XCTAssertTrue(output.contains("10.1093/bioinformatics/bty560"), output)
        XCTAssertTrue(output.contains("SAMtools"), output)
        XCTAssertTrue(output.contains("10.1093/gigascience/giab008"), output)
        XCTAssertTrue(output.contains("Tools without known citations"), output)
        XCTAssertTrue(output.contains("custom laboratory script 2026.05"), output)

        let fastpRange = try XCTUnwrap(output.range(of: "fastp"))
        let samtoolsRange = try XCTUnwrap(output.range(of: "SAMtools"))
        XCTAssertLessThan(fastpRange.lowerBound, samtoolsRange.lowerBound, output)
    }

    func testProvenanceBibliographyReadsBundleProvenanceFolderRollup() async throws {
        let bundle = try makeBundleWithProvenance(
            steps: [
                StepExecution(
                    toolName: "fastp",
                    toolVersion: "1.3.2",
                    command: ["fastp", "--in1", "reads.fastq"],
                    inputs: []
                ),
            ],
            provenanceRelativePath: "provenance/bundle.lungfish-provenance.json"
        )

        let command = try ProvenanceCommand.BibliographySubcommand.parse([bundle.path])
        let output = try await captureStandardOutput {
            try await command.run()
        }

        XCTAssertTrue(output.contains("fastp"), output)
        XCTAssertTrue(output.contains("10.1093/bioinformatics/bty560"), output)
    }

    private func makeBundleWithProvenance(
        steps: [StepExecution],
        provenanceRelativePath: String = ProvenanceRecorder.provenanceFilename
    ) throws -> URL {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-tool-reference-\(UUID().uuidString)", isDirectory: true)
        let bundle = tempRoot.appendingPathComponent("sample.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

        let run = WorkflowRun(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000016")!,
            name: "Synthetic citation test",
            startTime: Date(timeIntervalSince1970: 0),
            endTime: Date(timeIntervalSince1970: 1),
            status: .completed,
            appVersion: "Lungfish test",
            hostOS: "macOS test",
            runtime: WorkflowRuntime(appVersion: "Lungfish test", hostOS: "macOS test", user: "tester"),
            steps: steps
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(run)
        let provenanceURL = bundle.appendingPathComponent(provenanceRelativePath)
        try FileManager.default.createDirectory(
            at: provenanceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: provenanceURL, options: .atomic)
        return bundle
    }

    private func captureStandardOutput(_ operation: () async throws -> Void) async throws -> String {
        let pipe = Pipe()
        let originalStdout = dup(STDOUT_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)

        do {
            try await operation()
            fflush(stdout)
        } catch {
            fflush(stdout)
            dup2(originalStdout, STDOUT_FILENO)
            close(originalStdout)
            pipe.fileHandleForWriting.closeFile()
            throw error
        }

        dup2(originalStdout, STDOUT_FILENO)
        close(originalStdout)
        pipe.fileHandleForWriting.closeFile()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
