// ConvertCompressTests.swift - convert --compress and several inputs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A49 M3. `convert` writes its output as gzip or zstd with `--compress` and reads several
// inputs into one output. The compression runs on `SequenceExportCompressor`, which streams the compressor
// into a part file and names the result only when it is whole. gzip is /usr/bin/gzip on every Mac, zstd is
// looked for in /usr/bin and the two Homebrew prefixes, so the zstd test is a Conformance test.

import ArgumentParser
import XCTest
@testable import LungfishCLI
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

final class ConvertCompressTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConvertCompressTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCompressAndSeveralInputsParse() throws {
        let command = try ConvertCommand.parse(["a.fa", "b.fa", "--to", "out.fa.gz", "--compress", "gzip", "--force"])
        XCTAssertEqual(command.inputs, ["a.fa", "b.fa"])
        XCTAssertEqual(command.compress, .gzip)
        XCTAssertEqual(try ConvertCommand.parse(["a.fa", "--to", "o.zst", "--compress", "zstd"]).compress, .zstd)
        XCTAssertNil(try ConvertCommand.parse(["a.fa", "--to", "out.fa"]).compress)
        XCTAssertThrowsError(try ConvertCommand.parse(["a.fa", "--to", "out.fa", "--compress", "bzip2"]))
        XCTAssertThrowsError(try ConvertCommand.parse(["--to", "out.fa"]), "an input is required")
    }

    func testGzipOutputHoldsTheConvertedTextAndLeavesNoStage() async throws {
        let input = root.appendingPathComponent("first.fa")
        try ">a\nACGT\n>b\nTTGG\n".write(to: input, atomically: true, encoding: .utf8)
        let output = root.appendingPathComponent("out.fa.gz")

        let command = try ConvertCommand.parse([input.path, "--to", output.path, "--compress", "gzip", "--quiet"])
        try await command.run()

        let bytes = try Data(contentsOf: output)
        XCTAssertEqual(Array(bytes.prefix(2)), [0x1f, 0x8b], "a gzip container")
        XCTAssertEqual(try Self.decompress(output, with: "/usr/bin/gzip"), ">a\nACGT\n>b\nTTGG\n")
        XCTAssertEqual(Self.gzipHeaderName(bytes), "export.fa", "the header names the file the app's export gave it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: output).path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".") && $0.contains("convert") }
        XCTAssertEqual(leftovers, [], "no stage file or folder is left beside the output")
    }

    func testSeveralInputsAreWrittenToOneOutputInOrder() async throws {
        let first = root.appendingPathComponent("first.fa")
        let second = root.appendingPathComponent("second.fa")
        try ">a\nACGT\n".write(to: first, atomically: true, encoding: .utf8)
        try ">b\nTTGGCC\n>c\nGG\n".write(to: second, atomically: true, encoding: .utf8)
        let output = root.appendingPathComponent("both.fa.gz")

        let command = try ConvertCommand.parse([first.path, second.path, "--to", output.path, "--compress", "gzip", "--quiet"])
        try await command.run()

        XCTAssertEqual(try Self.decompress(output, with: "/usr/bin/gzip"), ">a\nACGT\n>b\nTTGGCC\n>c\nGG\n")
        let sidecar = try Data(contentsOf: ProvenanceRecorder.fileSidecarURL(for: output))
        let text = String(decoding: sidecar, as: UTF8.self)
        XCTAssertTrue(text.contains(first.lastPathComponent) && text.contains(second.lastPathComponent), "the record names both inputs")
        XCTAssertTrue(text.contains("--compress"), "the record keeps the option")
    }

    func testSeveralInputsWithoutCompressionKeepEachSourcesAnnotations() async throws {
        let first = root.appendingPathComponent("first.fa")
        let second = root.appendingPathComponent("second.fa")
        try ">a\nACGT\n".write(to: first, atomically: true, encoding: .utf8)
        try ">b\nTTGG\n".write(to: second, atomically: true, encoding: .utf8)
        let output = root.appendingPathComponent("both.gb")

        let command = try ConvertCommand.parse([first.path, second.path, "--to", output.path, "--to-format", "genbank", "--quiet"])
        try await command.run()

        let records = try GenBankReader(url: output).readAllRecoveringAnnotationsSync().records
        XCTAssertEqual(records.map { $0.sequence.name }, ["a", "b"])
    }

    func testAnExistingOutputStaysWhenCompressionFails() async throws {
        let input = root.appendingPathComponent("first.fa")
        try ">a\nACGT\n".write(to: input, atomically: true, encoding: .utf8)
        let output = root.appendingPathComponent("held.fa.gz")
        try "an earlier export".write(to: output, atomically: true, encoding: .utf8)

        // Without --force the existing output is refused before anything is staged.
        let command = try ConvertCommand.parse([input.path, "--to", output.path, "--compress", "gzip", "--quiet"])
        do {
            try await command.run()
            XCTFail("an existing output needs --force")
        } catch {
            XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "an earlier export")
        }
    }

    // MARK: - Helpers

    static func decompress(_ url: URL, with tool: String) throws -> String {
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

    /// The file name a gzip header records, or nil when it records none.
    static func gzipHeaderName(_ bytes: Data) -> String? {
        guard bytes.count > 10, bytes[bytes.startIndex + 3] & 0x08 != 0 else { return nil }
        let start = bytes.startIndex + 10
        guard let end = bytes[start...].firstIndex(of: 0) else { return nil }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }
}

/// zstd is not part of macOS, so this runs where a zstd sits in /usr/bin or a Homebrew prefix.
final class ConvertCompressZstdConformanceTests: XCTestCase {
    func testZstdOutputHoldsTheConvertedText() async throws {
        guard let zstd = SequenceExportCompressor.zstdExecutable() else {
            if ProcessInfo.processInfo.environment["LUNGFISH_REQUIRE_TOOLS"] == "1" {
                XCTFail("LUNGFISH_REQUIRE_TOOLS=1: no zstd in \(SequenceExportCompressor.zstdCandidates)")
                return
            }
            throw XCTSkip("no zstd in \(SequenceExportCompressor.zstdCandidates)")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConvertCompressZstd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("first.fa")
        try ">a\nACGT\n>b\nTTGG\n".write(to: input, atomically: true, encoding: .utf8)
        let output = root.appendingPathComponent("out.fa.zst")

        let command = try ConvertCommand.parse([input.path, "--to", output.path, "--compress", "zstd", "--quiet"])
        try await command.run()

        XCTAssertEqual(Array(try Data(contentsOf: output).prefix(4)), [0x28, 0xb5, 0x2f, 0xfd], "a zstd frame")
        XCTAssertEqual(try ConvertCompressTests.decompress(output, with: zstd.path), ">a\nACGT\n>b\nTTGG\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: output).path))
    }
}
