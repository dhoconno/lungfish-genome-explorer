// SequenceExportPinConformanceTests.swift - What the sequence export writes today, pinned after decompression
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A49 M3 (BIO 1, QA 3). The Import Center compresses a sequence export with /usr/bin/gzip or
// /usr/bin/zstd. Lane A49 M3 moves that compression into `convert --compress` and runs the exports through
// lungfish-cli. This pin exports four fixtures once for each compressor the export offers, a FASTA file, an
// annotated reference bundle to GenBank, two FASTA files and a captured snapshot, and keeps each export as
// text after decompression, with the GenBank date taken out. The route must leave those texts as they are.
// It also checks the container of each output by its first bytes and that its record sits beside it. A gzip
// header holds the name and the time of the file it compressed, so the bytes of a `.gz` differ from run to
// run and only the text after decompression is pinned.
//
// macOS ships no /usr/bin/zstd, which was the only path the export launched, so at the base the zstd export
// failed and published nothing on a Mac without one, and the pin said so. The route looks in /usr/bin and in
// Homebrew's two prefixes, so with a zstd there the pin holds the same text, and without one the export still
// fails and publishes nothing. The test at the end replays the row's recorded command on a copy of the folder.
//
// It runs the system gzip, so its name ends in Conformance, which keeps it out of the unit tier, and it
// skips without gzip unless `LUNGFISH_REQUIRE_TOOLS=1`. It points `LUNGFISH_CLI_PATH` at the built
// lungfish-cli, which the base never starts for these cases and the route does. To capture the texts again set
// `LUNGFISH_RECAPTURE_SEQUENCE_EXPORT=1`, which rewrites `SequenceExportPinExpected.swift`.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class SequenceExportPinConformanceTests: XCTestCase {
    private var root: URL!
    private var priorCLIPath: String?

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "sequence-export-pin")
        priorCLIPath = ProcessInfo.processInfo.environment["LUNGFISH_CLI_PATH"]
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        if let cli = CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products) {
            setenv("LUNGFISH_CLI_PATH", cli.path, 1)
        }
    }

    override func tearDownWithError() throws {
        if let priorCLIPath { setenv("LUNGFISH_CLI_PATH", priorCLIPath, 1) } else { unsetenv("LUNGFISH_CLI_PATH") }
        if let root { TestTempDirectory.cleanup(root) }
    }

    func testEachExportPinsItsTextAfterDecompression() async throws {
        try requireTools()
        let inputs = root.appendingPathComponent("inputs", isDirectory: true)
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let first = inputs.appendingPathComponent("first.fa")
        let second = inputs.appendingPathComponent("second.fa")
        try ">alpha first record\nACGTACGTAC\n>beta\nTTGGCCAATT\n".write(to: first, atomically: true, encoding: .utf8)
        try ">gamma\nGGGGCCCCAAAATTTT\n".write(to: second, atomically: true, encoding: .utf8)
        let bundle = try ReferenceMergeFixture.writeSource(
            named: "Alpha", sequence: "chrA", bases: "ACGTACGTACGTACGTACGT", gene: "geneA", in: project, inputs: inputs
        )
        let snapshotURL = project.appendingPathComponent("snapshot")
        let snapshot = SequenceExportSourceResolver.Source(
            metadata: .init(
                kind: .nativeProjectSequence, url: snapshotURL, documentID: UUID(), nativeSequenceID: UUID(),
                projectURL: project
            ),
            document: .init(
                name: "snapshot", url: snapshotURL,
                sequences: [try LungfishCore.Sequence(name: "native", alphabet: .dna, bases: "ACGTTGCA")],
                annotations: []
            )
        )

        let cases: [(name: String, sources: [SequenceExportSourceResolver.Source], format: SequenceExportFormat)] = [
            ("file", [Self.fileSource(first)], .fasta),
            ("bundle", [Self.fileSource(bundle)], .genbank),
            ("two", [Self.fileSource(first), Self.fileSource(second)], .fasta),
            ("captured", [snapshot], .fasta),
        ]
        var actual: [String: String] = [:]
        for item in cases {
            actual[item.name] = try await export(item.sources, to: "\(item.name).gz", format: item.format, compression: .gzip)
        }
        if ProcessInfo.processInfo.environment["LUNGFISH_RECAPTURE_SEQUENCE_EXPORT"] == "1" {
            try Self.writeExpected(actual)
            return
        }
        XCTAssertEqual(Set(actual.keys), Set(SequenceExportPinExpected.cases.keys))
        for (name, text) in actual.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(text, SequenceExportPinExpected.cases[name], "\(name) with gzip")
        }

        // The same four exports with zstd. At the base the export launched only /usr/bin/zstd, which macOS does
        // not ship, so on a Mac without one it failed and published nothing. The route looks in /usr/bin and in
        // Homebrew's two prefixes, so with a zstd in one of them the text is the same, and without one the export
        // still fails and publishes nothing.
        let hasZstd = SequenceExportCompressor.zstdExecutable() != nil
        for item in cases {
            if hasZstd {
                let text = try await export(item.sources, to: "\(item.name).zst", format: item.format, compression: .zstd)
                XCTAssertEqual(text, SequenceExportPinExpected.cases[item.name], "\(item.name) with zstd")
            } else {
                let output = root.appendingPathComponent("out/\(item.name).zst")
                do {
                    _ = try await makeAppDelegateWithTemporaryState().performSequenceExport(
                        sources: item.sources, outputURL: output, format: item.format, compression: .zstd
                    )
                    XCTFail("\(item.name) with zstd should fail without /usr/bin/zstd")
                } catch {
                    XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "\(item.name) publishes nothing")
                    XCTAssertFalse(
                        FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: output).path),
                        "\(item.name) leaves no record"
                    )
                }
            }
        }
    }

    /// The row's recorded command, moved onto a copy of the folder and run there, writes the text the run wrote
    /// (C against C'). Each compressor available here runs once.
    func testTheRecordedCommandReproducesTheRun() async throws {
        try requireTools()
        let inputs = root.appendingPathComponent("inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let first = inputs.appendingPathComponent("first.fa")
        let second = inputs.appendingPathComponent("second.fa")
        try ">alpha first record\nACGTACGTAC\n>beta\nTTGGCCAATT\n".write(to: first, atomically: true, encoding: .utf8)
        try ">gamma\nGGGGCCCCAAAATTTT\n".write(to: second, atomically: true, encoding: .utf8)
        let replayRoot = try TestTempDirectory.make(prefix: "sequence-export-replay")
        defer { TestTempDirectory.cleanup(replayRoot) }
        try FileManager.default.copyItem(at: inputs, to: replayRoot.appendingPathComponent("inputs"))
        try FileManager.default.createDirectory(at: replayRoot.appendingPathComponent("out"), withIntermediateDirectories: true)

        var compressions: [SequenceExportCompression] = [.gzip]
        if SequenceExportCompressor.zstdExecutable() != nil { compressions.append(.zstd) }
        for compression in compressions {
            let name = compression == .gzip ? "run.fa.gz" : "run.fa.zst"
            let text = try await export(
                [Self.fileSource(first), Self.fileSource(second)], to: name, format: .fasta, compression: compression
            )
            let output = root.appendingPathComponent("out").appendingPathComponent(name)
            let recorded = try XCTUnwrap(AppDelegate.sequenceExportCLICommand(
                inputURLs: [first, second], outputURL: output, format: .fasta, compression: compression
            ))
            let rebased = try RecordedCLICommand.rebased(recorded, from: root, to: replayRoot)
            let replayOutput = replayRoot.appendingPathComponent("out").appendingPathComponent(name)
            let count = try await SequenceExportRoute.run(
                arguments: RecordedCLICommand.arguments(of: rebased), outputURL: replayOutput
            )
            XCTAssertEqual(count, 3, "\(name) replay count")
            let replayed = try Self.decompress(
                replayOutput, with: compression == .gzip ? "/usr/bin/gzip" : (SequenceExportCompressor.zstdExecutable()?.path ?? "zstd")
            )
            XCTAssertEqual(replayed, text, "\(name) replay text")
            XCTAssertEqual(text, SequenceExportPinExpected.cases["two"], "\(name) against the pinned text")
        }
    }

    // MARK: - Helpers

    private static func fileSource(_ url: URL) -> SequenceExportSourceResolver.Source {
        .init(
            metadata: .init(kind: .filesystem, url: url, documentID: nil, nativeSequenceID: nil, projectURL: nil),
            document: nil
        )
    }

    /// Runs the export and returns its text after decompression, the date of a GenBank LOCUS line taken out.
    private func export(
        _ sources: [SequenceExportSourceResolver.Source],
        to name: String,
        format: SequenceExportFormat,
        compression: SequenceExportCompression
    ) async throws -> String {
        let folder = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let output = folder.appendingPathComponent(name)
        _ = try await makeAppDelegateWithTemporaryState().performSequenceExport(
            sources: sources, outputURL: output, format: format, compression: compression
        )
        let magic: [UInt8] = compression == .gzip ? [0x1f, 0x8b] : [0x28, 0xb5, 0x2f, 0xfd]
        XCTAssertEqual(Array(try Data(contentsOf: output).prefix(magic.count)), magic, "\(name) holds a \(compression) container")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: output).path),
            "\(name) has its record beside it"
        )
        let text = try Self.decompress(
            output, with: compression == .gzip ? "/usr/bin/gzip" : (SequenceExportCompressor.zstdExecutable()?.path ?? "zstd")
        )
        return text.replacingOccurrences(of: "[0-9]{2}-[A-Z]{3}-[0-9]{4}", with: "<DATE>", options: .regularExpression)
    }

    private static func decompress(_ url: URL, with tool: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["-dc", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(tool) -dc \(url.lastPathComponent)")
        return String(decoding: data, as: UTF8.self)
    }

    private static func writeExpected(_ cases: [String: String]) throws {
        var lines = [
            "// SequenceExportPinExpected.swift - The text of each pinned sequence export after decompression",
            "// Copyright (c) 2026 Lungfish Contributors",
            "// SPDX-License-Identifier: MIT",
            "//",
            "// Written by `SequenceExportPinConformanceTests` when `LUNGFISH_RECAPTURE_SEQUENCE_EXPORT=1`.",
            "",
            "enum SequenceExportPinExpected {",
            "    static let cases: [String: String] = [",
        ]
        for (name, text) in cases.sorted(by: { $0.key < $1.key }) {
            lines.append("        \"\(name)\": #\"\"\"")
            lines.append(text)
            lines.append("\"\"\"#,")
        }
        lines.append(contentsOf: ["    ]", "}", ""])
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("SequenceExportPinExpected.swift")
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    private func requireTools(file: StaticString = #filePath, line: UInt = #line) throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/gzip") else {
            try ToolAvailability.skipOrFail("/usr/bin/gzip is required", file: file, line: line)
            return
        }
    }
}
