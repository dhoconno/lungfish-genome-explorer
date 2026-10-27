// FastqImportONTChunkBinningTests.swift - An ONT run folder import that names a scheme bins every stored chunk
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane C2-ONTBIN (owner answer OQ1, 2026-10-22, "Bin chunked ONT payloads"). The ONT run folder import stores
// chunked payloads by default. Before this lane they kept every quality score whatever `--quality-binning` said,
// because only Optimize Storage binned and it needs flattened storage. An import that names a scheme now bins each
// chunk with the same `quantize=` argument the Illumina route's clumpify takes, and `none`, the ONT default since
// BIO-BIN (Phase 3.0 lane BIN), keeps every chunk as the run wrote it.
// The assertions read the stored chunks and the provenance records. Binning needs the managed BBTools, so the
// binning tests skip without it unless LUNGFISH_REQUIRE_TOOLS is set.

import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow

final class FastqImportONTChunkBinningTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ont-chunk-binning-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = root.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The Phred+33 characters `quantize=0,2,7,12,17,22,27,32,37` writes, Q2 to Q37 in steps of five, and Q0 for an N.
    private static let fiveStepLevels = Set("!#(-27<AF")

    func testAnImportNamingFiveStepBinsEveryStoredChunkAndRecordsEachBinningStep() async throws {
        try await Self.requireReformat()
        let source = try makeSource()
        let output = root.appendingPathComponent("project", isDirectory: true)

        try await FastqImportONTSubcommand.parse([source.path, "--output", output.path, "--concurrency", "1", "--quality-binning", "fiveStep"]).run()

        let bundle = output.appendingPathComponent("barcode01.lungfishfastq", isDirectory: true)
        for chunk in Self.chunks {
            let stored = try Self.records(in: bundle.appendingPathComponent("chunks").appendingPathComponent(chunk.name))
            XCTAssertEqual(stored.map(\.header), chunk.reads.map(\.header), "\(chunk.name) keeps every read, its whole name and its order")
            XCTAssertEqual(stored.map(\.sequence), chunk.reads.map(\.sequence), "\(chunk.name) keeps every sequence")
            for record in stored {
                XCTAssertEqual(record.quality.count, record.sequence.count, record.header)
                XCTAssertTrue(Set(record.quality).isSubset(of: Self.fiveStepLevels),
                              "\(chunk.name) \(record.header) holds only fiveStep levels: \(record.quality)")
            }
        }
        let preview = try Self.records(in: bundle.appendingPathComponent("preview.fastq"))
        XCTAssertEqual(preview.map(\.header), Self.chunks.flatMap(\.reads).map(\.header), "the preview lists the stored reads")
        XCTAssertTrue(preview.allSatisfy { Set($0.quality).isSubset(of: Self.fiveStepLevels) }, "the preview shows the binned scores")

        let bundleEnvelope = try readEnvelope(bundle.appendingPathComponent(ProvenanceWriter.provenanceFilename))
        let binningSteps = bundleEnvelope.steps.filter { $0.toolName == "reformat.sh" }
        XCTAssertEqual(binningSteps.count, Self.chunks.count, "one binning step for each chunk")
        for step in binningSteps {
            XCTAssertTrue(step.argv.contains("quantize=0,2,7,12,17,22,27,32,37"), "\(step.argv)")
            XCTAssertEqual(step.exitStatus, 0)
            XCTAssertFalse(step.toolVersion.isEmpty)
            // C4-10 (BIO 4): BBTools writes a plain chunk as plain text through no bgzip, so only the step of a `.gz`
            // chunk names a writer and a level, and the level is the `zl=` of the argv that ran.
            let chunkName = step.outputs.first.map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? ""
            let gzip = step.outputs.contains { $0.path.hasSuffix(".gz") }
            XCTAssertEqual(step.resolvedOptions["writer"] != nil, gzip, "\(chunkName): a writer is recorded for a gzip output only")
            XCTAssertEqual(
                step.resolvedOptions["effectiveCompressionLevel"] != nil, gzip,
                "\(chunkName): a level is recorded for a gzip output only"
            )
            if gzip {
                guard case .dictionary(let writer)? = step.resolvedOptions["writer"] else {
                    XCTFail("\(chunkName) names no writer: \(step.resolvedOptions)")
                    continue
                }
                XCTAssertEqual(writer["name"], .string("bgzip"), chunkName)
                let level = step.argv.first { $0.hasPrefix("zl=") }.flatMap { Int($0.dropFirst(3)) }
                XCTAssertNotNil(level, "\(chunkName): no zl= in \(step.argv)")
                XCTAssertEqual(step.resolvedOptions["effectiveCompressionLevel"], level.map(ParameterValue.integer), chunkName)
            }
        }
        XCTAssertEqual(
            // The record names the run's chunk by its real path, /private/var on macOS, so both sides resolve links.
            Set(binningSteps.flatMap(\.inputs).map { canonicalPath(URL(fileURLWithPath: $0.path)) }),
            Set(Self.chunks.map { canonicalPath(source.appendingPathComponent("barcode01").appendingPathComponent($0.name)) }),
            "each step reads the run's own chunk"
        )
        XCTAssertEqual(
            Set(binningSteps.flatMap(\.outputs).map { canonicalPath(URL(fileURLWithPath: $0.path)) }),
            Set(Self.chunks.map { canonicalPath(bundle.appendingPathComponent("chunks").appendingPathComponent($0.name)) }),
            "each step writes the bundle's stored chunk"
        )
        XCTAssertEqual(bundleEnvelope.options.resolvedDefaults["qualityBinning"], .string("fiveStep"))
        XCTAssertEqual(bundleEnvelope.options.resolvedDefaults["qualityBinningApplied"], .boolean(true))
        let runEnvelope = try readEnvelope(output.appendingPathComponent(ProvenanceWriter.provenanceFilename))
        XCTAssertEqual(runEnvelope.options.resolvedDefaults["qualityBinningApplied"], .boolean(true))
    }

    /// The Illumina route bins with clumpify's `quantize=` and the ONT chunks with reformat.sh's. Both are the one
    /// BBTools mapping, so one read imported each way stores the same scores.
    func testAnONTChunkAndAClumpifiedIlluminaImportBinOneScoreToTheSameValue() async throws {
        try await Self.requireReformat()
        let source = try makeSource()
        let output = root.appendingPathComponent("project", isDirectory: true)
        try await FastqImportONTSubcommand.parse([source.path, "--output", output.path, "--concurrency", "1", "--quality-binning", "fiveStep"]).run()
        let ontChunk = output.appendingPathComponent("barcode01.lungfishfastq/chunks/\(Self.chunks[0].name)")

        let illuminaInput = root.appendingPathComponent("illumina-input.fastq")
        try Self.fastq(Self.chunks[0].reads).write(to: illuminaInput, atomically: true, encoding: .utf8)
        let illuminaOutput = root.appendingPathComponent("illumina-output", isDirectory: true)
        let result = try await FASTQIngestionPipeline().run(
            config: FASTQIngestionConfig(
                inputFiles: [illuminaInput],
                pairingMode: .singleEnd,
                outputDirectory: illuminaOutput,
                threads: 1,
                deleteOriginals: false,
                qualityBinning: .fiveStep,
                clumpingTool: .bbtools
            ),
            progress: { _, _ in }
        )
        XCTAssertTrue(result.wasClumpified, "the Illumina route clumpifies")

        let ont = Dictionary(uniqueKeysWithValues: try Self.records(in: ontChunk).map { ($0.header, $0.quality) })
        let illumina = Dictionary(uniqueKeysWithValues: try Self.records(in: result.outputFile).map { ($0.header, $0.quality) })
        XCTAssertEqual(ont, illumina)
        XCTAssertNotEqual(ont[Self.chunks[0].reads[0].header], Self.chunks[0].reads[0].quality, "the scores were binned")
    }

    func testQualityBinningNoneStoresEveryChunkAsTheRunWroteIt() async throws {
        let source = try makeSource()
        let output = root.appendingPathComponent("project", isDirectory: true)

        try await FastqImportONTSubcommand.parse([
            source.path, "--output", output.path, "--concurrency", "1", "--quality-binning", "none",
        ]).run()

        let bundle = output.appendingPathComponent("barcode01.lungfishfastq", isDirectory: true)
        for chunk in Self.chunks {
            XCTAssertEqual(
                try Data(contentsOf: bundle.appendingPathComponent("chunks").appendingPathComponent(chunk.name)),
                try Data(contentsOf: source.appendingPathComponent("barcode01").appendingPathComponent(chunk.name)),
                "\(chunk.name) is stored byte for byte"
            )
        }
        let bundleEnvelope = try readEnvelope(bundle.appendingPathComponent(ProvenanceWriter.provenanceFilename))
        XCTAssertFalse(bundleEnvelope.steps.contains { $0.toolName == "reformat.sh" }, "no binning step")
        XCTAssertEqual(bundleEnvelope.options.resolvedDefaults["qualityBinning"], .string("none"))
        XCTAssertEqual(bundleEnvelope.options.resolvedDefaults["qualityBinningApplied"], .boolean(false))
    }

    // MARK: - Fixture

    private struct Read {
        let header: String
        let sequence: String
        let quality: String
    }

    /// Every Phred score from Q0 to Q50, the range a Dorado basecaller writes.
    private static let allScores = String((33...83).map { Character(UnicodeScalar(UInt8($0))) })

    private static func read(_ id: String, _ seed: Int) -> Read {
        let bases = Array("ACGT")
        let sequence = String((0..<allScores.count).map { bases[($0 + seed) % 4] })
        let rotation = seed % allScores.count
        let quality = String(allScores.dropFirst(rotation) + allScores.prefix(rotation))
        return Read(header: "@\(id) runid=f00d ch=\(seed) start_time=2026-10-22T08:00:00Z", sequence: sequence, quality: quality)
    }

    /// A plain chunk and a gzip chunk, the two shapes the importer lists.
    private static let chunks: [(name: String, reads: [Read])] = [
        ("chunk_0.fastq", [read("read-1", 1), read("read-2", 2), read("read-3", 3)]),
        ("chunk_1.fastq.gz", [read("read-4", 4), read("read-5", 5)]),
    ]

    private static func fastq(_ reads: [Read]) -> String {
        reads.map { "\($0.header)\n\($0.sequence)\n+\n\($0.quality)\n" }.joined()
    }

    private func makeSource() throws -> URL {
        let source = root.appendingPathComponent("fastq_pass", isDirectory: true)
        let barcode = source.appendingPathComponent("barcode01", isDirectory: true)
        try FileManager.default.createDirectory(at: barcode, withIntermediateDirectories: true)
        for chunk in Self.chunks {
            let gzip = chunk.name.hasSuffix(".gz")
            let plainName = gzip ? String(chunk.name.dropLast(3)) : chunk.name
            let file = barcode.appendingPathComponent(plainName)
            try Self.fastq(chunk.reads).write(to: file, atomically: true, encoding: .utf8)
            if gzip {
                let result = try ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/gzip"), ["-f", file.path])
                XCTAssertEqual(result.status, 0, "gzip failed: \(result.stderr)")
            }
        }
        return source
    }

    private static func records(in url: URL) throws -> [Read] {
        let text: String
        if url.pathExtension == "gz" {
            let result = try ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/gzip"), ["-dc", url.path])
            XCTAssertEqual(result.status, 0, "gzip -dc failed: \(result.stderr)")
            text = result.stdout
        } else {
            text = try String(contentsOf: url, encoding: .utf8)
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return stride(from: 0, to: lines.count - 3, by: 4).map {
            Read(header: lines[$0], sequence: lines[$0 + 1], quality: lines[$0 + 3])
        }
    }

    private static func requireReformat() async throws {
        do {
            _ = try await NativeToolRunner.shared.toolPath(for: .reformat)
        } catch {
            if ProcessInfo.processInfo.environment["LUNGFISH_REQUIRE_TOOLS"] == "1" { throw error }
            throw XCTSkip("Binning needs the managed BBTools reformat.sh: \(error)")
        }
    }

    private func readEnvelope(_ url: URL) throws -> ProvenanceEnvelope {
        try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: Data(contentsOf: url))
    }

    private func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
