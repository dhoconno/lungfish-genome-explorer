import XCTest
import ArgumentParser
import Foundation
import LungfishWorkflow
@testable import LungfishCLI
@testable import LungfishCore
@testable import LungfishIO

final class ExtractContigsCommandTests: XCTestCase {
    private var cliBinaryPath: URL? {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let candidates = [
            repoRoot.appendingPathComponent(".build/debug/lungfish-cli"),
            repoRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/lungfish-cli"),
            repoRoot.appendingPathComponent(".build/x86_64-apple-macosx/debug/lungfish-cli"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func testParseBundleModeRequiresProjectRoot() throws {
        XCTAssertThrowsError(
            try ExtractContigsSubcommand.parse([
                "--assembly", "/tmp/assembly",
                "--bundle",
                "--contig", "contig_b",
            ])
        ) { error in
            XCTAssertTrue("\(error)".contains("--project-root"))
        }
    }

    func testParseBundleModeRequiresContigSelection() throws {
        XCTAssertThrowsError(
            try ExtractContigsSubcommand.parse([
                "--assembly", "/tmp/assembly",
                "--bundle",
                "--project-root", "/tmp/project.lungfish",
            ])
        ) { error in
            XCTAssertTrue("\(error)".contains("--contig"))
        }
    }

    func testRunWritesSelectedContigsInRequestedOrder() async throws {
        let fixture = try makeAssemblyFixture()
        let outputURL = fixture.root.appendingPathComponent("subset.fa")

        let command = try ExtractContigsSubcommand.parse([
            "--assembly", fixture.root.path,
            "--contig", "beta",
            "--contig", "alpha",
            "--output", outputURL.path,
            "--line-width", "4",
        ])

        try await command.run()

        let output = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertEqual(
            output,
            """
            >beta secondary contig
            ACGT
            AC
            >alpha primary contig
            AAAA
            CCCC

            """
        )
    }

    func testRunCombinesRepeatedContigFilesInDeclaredOrder() async throws {
        let fixture = try makeAssemblyFixture()
        let firstListURL = fixture.root.appendingPathComponent("first.txt")
        let secondListURL = fixture.root.appendingPathComponent("second.txt")
        let outputURL = fixture.root.appendingPathComponent("subset-from-files.fa")

        try "gamma\n".write(to: firstListURL, atomically: true, encoding: .utf8)
        try "alpha\nbeta\n".write(to: secondListURL, atomically: true, encoding: .utf8)

        let command = try ExtractContigsSubcommand.parse([
            "--assembly", fixture.root.path,
            "--contig-file", firstListURL.path,
            "--contig-file", secondListURL.path,
            "--output", outputURL.path,
            "--line-width", "8",
        ])

        try await command.run()

        let output = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertEqual(
            output,
            """
            >gamma tertiary contig
            TTAA
            >alpha primary contig
            AAAACCCC
            >beta secondary contig
            ACGTAC

            """
        )
    }

    func testRunPreservesMixedInlineAndFileSelectionOrder() async throws {
        let fixture = try makeAssemblyFixture()
        let listURL = fixture.root.appendingPathComponent("mixed.txt")
        let outputURL = fixture.root.appendingPathComponent("subset-mixed-order.fa")

        try "gamma\n".write(to: listURL, atomically: true, encoding: .utf8)

        var command = try ExtractContigsSubcommand.parse([
            "--assembly", fixture.root.path,
            "--contig", "beta",
            "--contig-file", listURL.path,
            "--contig", "alpha",
            "--output", outputURL.path,
            "--line-width", "8",
        ])
        command.rawSelectionArguments = [
            "--assembly", fixture.root.path,
            "--contig", "beta",
            "--contig-file", listURL.path,
            "--contig", "alpha",
            "--output", outputURL.path,
            "--line-width", "8",
        ]

        try await command.run()

        let output = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertEqual(
            output,
            """
            >beta secondary contig
            ACGTAC
            >gamma tertiary contig
            TTAA
            >alpha primary contig
            AAAACCCC

            """
        )
    }

    func testRunWritesSelectedContigsToStdoutWhenOutputIsOmitted() throws {
        let fixture = try makeAssemblyFixture()
        let result = try runCLI([
            "extract", "contigs",
            "--assembly", fixture.root.path,
            "--contig", "beta",
            "--line-width", "4",
            "--quiet",
        ])

        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")

        XCTAssertEqual(
            result.stdout,
            """
            >beta secondary contig
            ACGT
            AC

            """
        )
    }

    private func makeAssemblyFixture() throws -> (root: URL, result: AssemblyResult) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExtractContigsCommandTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }

        let contigsURL = root.appendingPathComponent("contigs.fasta")
        try """
        >alpha primary contig
        AAAACCCC
        >beta secondary contig
        ACGTAC
        >gamma tertiary contig
        TTAA
        """.write(to: contigsURL, atomically: true, encoding: .utf8)
        try FASTAIndexBuilder.buildAndWrite(for: contigsURL)

        let statistics = try AssemblyStatisticsCalculator.compute(from: contigsURL)
        let result = AssemblyResult(
            tool: .spades,
            readType: .illuminaShortReads,
            contigsPath: contigsURL,
            graphPath: nil,
            logPath: nil,
            assemblerVersion: "4.2.0",
            commandLine: "spades.py --isolate",
            outputDirectory: root,
            statistics: statistics,
            wallTimeSeconds: 12
        )
        try result.save(to: root)
        return (root, result)
    }

    private func runCLI(_ arguments: [String]) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        guard let binary = cliBinaryPath else {
            throw XCTSkip("CLI binary not built at expected path")
        }

        let process = Process()
        process.executableURL = binary
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }
}
