// ImportOutputSpellingProvenanceTests.swift - An import records the same steps whatever spelling its output folder has
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane C2-PROVPATH. macOS reaches many real folders through a link, `/tmp` and `/var` among them, so one folder has
// several spellings. Landing 5 of the CHTC program found that `fastq import-ont --output /private/tmp/...` binned every
// chunk and recorded no `reformat.sh` step, and that Optimize Storage lost its `clumpify.sh` step the same way, while
// `/tmp/...` kept both. Each test here imports one source three times, into a folder spelled as the system temp folder
// gives it, spelled with its real `/private` path, and reached through a link the test makes, and reads each bundle's
// record. Every spelling must record the same steps, the route's tool among them, with paths that exist and none in the
// staging folder the run published from. The routes run the managed tools, so the tests skip without them unless
// LUNGFISH_REQUIRE_TOOLS=1 is set.

import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishCLI

final class ImportOutputSpellingProvenanceTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "import-output-spelling")
    }

    override func tearDown() async throws {
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    /// One folder for the outputs of one import, in each of the three spellings.
    private struct Spelling {
        let label: String
        let folder: URL
    }

    /// The system temp spelling (`/var/folders/...`), the real path (`/private/var/folders/...`) and a link the test
    /// makes to a real folder. Each spelling gets its own folder, so the three imports never meet.
    private func spellings() throws -> [Spelling] {
        let fm = FileManager.default
        let plain = root.appendingPathComponent("plain", isDirectory: true)
        let realPath = URL(fileURLWithPath: root.canonicalFilePath, isDirectory: true)
            .appendingPathComponent("private", isDirectory: true)
        let target = root.appendingPathComponent("link-target", isDirectory: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        for folder in [plain, realPath, target] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertTrue(realPath.path.hasPrefix("/private/"), "the real path of the temp folder is under /private: \(realPath.path)")
        return [
            Spelling(label: "system temp spelling", folder: plain),
            Spelling(label: "/private spelling", folder: realPath),
            Spelling(label: "linked folder spelling", folder: link),
        ]
    }

    // MARK: - Routes

    func testTheChunkedONTImportRecordsEachBinningStepForEverySpelling() async throws {
        _ = try await ToolAvailability.require("reformat.sh", environment: "bbtools")
        let source = try makeONTSource(chunks: 2)
        try await assertEverySpellingRecordsTheSameSteps(route: "chunked ONT import", tool: "reformat.sh", count: 2) { folder in
            let output = folder.appendingPathComponent("project", isDirectory: true)
            try await FastqImportONTSubcommand.parse([source.path, "--output", output.path, "--concurrency", "1"]).run()
            return output.appendingPathComponent("barcode01.lungfishfastq", isDirectory: true)
        }
    }

    func testTheOptimizeStorageONTImportRecordsTheClumpifyStepForEverySpelling() async throws {
        _ = try await ToolAvailability.require("clumpify.sh", environment: "bbtools")
        let source = try makeONTSource(chunks: 1)
        try await assertEverySpellingRecordsTheSameSteps(
            route: "Optimize Storage ONT import", tool: "clumpify", count: 1,
            // clumpify replaces the flattened payload it reads, so its input is gone by design.
            inputsRemain: false
        ) { folder in
            let output = folder.appendingPathComponent("project", isDirectory: true)
            try await FastqImportONTSubcommand.parse([
                source.path, "--output", output.path, "--concurrency", "1",
                "--storage-mode", "flattened", "--optimize-storage",
            ]).run()
            return output.appendingPathComponent("barcode01.lungfishfastq", isDirectory: true)
        }
    }

    func testTheIlluminaImportRecordsTheClumpifyStepForEverySpelling() async throws {
        _ = try await ToolAvailability.require("clumpify.sh", environment: "bbtools")
        _ = try await ToolAvailability.require("seqkit", environment: "seqkit")
        let input = try makeIlluminaPair()
        try await assertEverySpellingRecordsTheSameSteps(route: "Illumina import fastq", tool: "clumpify", count: 1) { folder in
            let project = folder.appendingPathComponent("study.lungfish", isDirectory: true)
            try await ImportCommand.FastqSubcommand.parse([input.path, "--project", project.path]).run()
            return try XCTUnwrap(Self.bundles(in: project).first, "the import writes a bundle in \(project.path)")
        }
    }

    /// Review fix 2 of C2-PROVPATH. `fastq ingest` builds its output in a hidden `lungfish-ingest-...` folder and moves the
    /// pipeline's steps to the published file with `StepExecution.relocated`, which replaced one spelling of the hidden
    /// file's path. The record sits in the input's folder.
    func testTheFastqIngestRecordsItsStepsForEverySpelling() async throws {
        _ = try await ToolAvailability.require("clumpify.sh", environment: "bbtools")
        try await assertEverySpellingRecordsTheSameSteps(
            route: "fastq ingest", tool: "clumpify", count: 1,
            // The run reads its input from the hidden folder, so only the outputs are read back.
            inputsRemain: false,
            // The durable publish refuses a folder with a link in it (`DurableReplace.ReplaceError.unsafeDirectory`), so
            // the route has the system temp and the real spelling.
            linkedFolder: false
        ) { folder in
            let input = folder.appendingPathComponent("SRR9_1.fastq")
            try Self.ingestReads.write(to: input, atomically: true, encoding: .utf8)
            try await FastqIngestSubcommand.parse([input.path, "--binning", "none", "--quiet"]).execute(emit: { _ in })
            return folder
        }
    }

    /// Four single-end reads, none a duplicate, so clumpify drops none (the fixture of `FastqIngestLiveConformanceTests`).
    private static let ingestReads = [
        "@SRR9.1 a/1\nACGTACGTACGTAAAC\n+\nIIIIIIIIIIIIIIII\n",
        "@SRR9.2 b/1\nTTGGCCAATTGGCCAA\n+\nIIIIIIIIIIIIIIII\n",
        "@SRR9.3 c/1\nGGGGCCCCAAAATTTT\n+\nIIIIIIIIIIIIIIII\n",
        "@SRR9.4 d/1\nCATGCATGCATGCATG\n+\nIIIIIIIIIIIIIIII\n",
    ].joined()

    // MARK: - Assertions

    /// Runs `importInto` once for each spelling and checks each bundle record it returns. `tool` names the step the
    /// route runs `count` times, matched as part of the step's tool name.
    private func assertEverySpellingRecordsTheSameSteps(
        route: String,
        tool: String,
        count: Int,
        inputsRemain: Bool = true,
        linkedFolder: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line,
        importInto: (URL) async throws -> URL
    ) async throws {
        var stepNamesBySpelling: [(label: String, names: [String])] = []
        for spelling in try spellings() where linkedFolder || !spelling.label.hasPrefix("linked") {
            let bundle = try await importInto(spelling.folder)
            let recordURL = bundle.appendingPathComponent(ProvenanceWriter.provenanceFilename)
            let envelope = try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: Data(contentsOf: recordURL))
            let names = envelope.steps.map(\.toolName).sorted()
            stepNamesBySpelling.append((spelling.label, names))
            let context = "\(route), output in the \(spelling.label) \(spelling.folder.path)"
            // A record inside a project names its files as `@/...` and scratch files as `<workspace>/...`, which a
            // reader resolves for the file it reads.
            let portable = PortablePath.Context.forFile(at: recordURL)

            let toolSteps = envelope.steps.filter { $0.toolName.lowercased().contains(tool) }
            XCTAssertEqual(toolSteps.count, count, "\(context) records each \(tool) step, it records \(names)", file: file, line: line)
            XCTAssertTrue(
                toolSteps.allSatisfy { $0.outputs.contains { $0.checksumSHA256 != nil } },
                "\(context): each \(tool) step records the digest of an output, so the digest check below compares one",
                file: file, line: line
            )
            for step in envelope.steps {
                for descriptor in step.outputs + (inputsRemain ? step.inputs : []) {
                    let path = PortablePath.resolve(path: descriptor.path, context: portable)
                    XCTAssertTrue(
                        FileManager.default.fileExists(atPath: path),
                        "\(context): the \(step.toolName) step names \(descriptor.path), which does not exist",
                        file: file, line: line
                    )
                }
                // BIO 6. An output that records a digest or a size describes the file that is there. Inputs are left
                // out, since a step such as clumpify replaces the file it reads.
                for descriptor in step.outputs {
                    let path = PortablePath.resolve(path: descriptor.path, context: portable)
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
                    let recordedFile = URL(fileURLWithPath: path)
                    if let recorded = descriptor.checksumSHA256 {
                        XCTAssertEqual(
                            try ProvenanceFileHasher.sha256(of: recordedFile, cancellationCheck: { try Task.checkCancellation() }), recorded,
                            "\(context): the \(step.toolName) step records a digest the file does not have",
                            file: file, line: line
                        )
                    }
                    if let recorded = descriptor.fileSize {
                        XCTAssertEqual(
                            try ProvenanceFileHasher.fileSize(of: recordedFile), recorded,
                            "\(context): the \(step.toolName) step records a size the file does not have",
                            file: file, line: line
                        )
                    }
                }
                // The replayed command and the named files leave the staging folder. A step's own argv keeps the
                // command as it ran, which may name the staging folder.
                for path in step.inputs.map(\.path) + step.outputs.map(\.path) + (step.durableReplayArgv ?? step.argv)
                    where path.contains(".ont-import-staging-") || path.contains(".building-") || path.contains("lungfish-ingest-") {
                    XCTFail("\(context): the \(step.toolName) step names the staging folder in \(path)", file: file, line: line)
                }
            }
        }
        if let control = stepNamesBySpelling.first {
            for other in stepNamesBySpelling.dropFirst() {
                XCTAssertEqual(
                    other.names, control.names,
                    "\(route): the \(other.label) records the steps the \(control.label) records", file: file, line: line
                )
            }
        }
    }

    // MARK: - Sources

    /// An ONT run folder with `chunks` chunks in barcode01, each eight reads of 60 bases with every score at Q40.
    private func makeONTSource(chunks: Int) throws -> URL {
        let barcode = root.appendingPathComponent("run/fastq_pass/barcode01", isDirectory: true)
        try FileManager.default.createDirectory(at: barcode, withIntermediateDirectories: true)
        for chunk in 0..<chunks {
            var text = ""
            for index in 0..<8 {
                text += "@chunk\(chunk)-r\(index) runid=test flow_cell_id=FLO-MIN sample_id=S1 barcode=barcode01\n"
                text += "\(Self.sequence(chunk * 8 + index))\n+\n\(String(repeating: "I", count: 60))\n"
            }
            try text.write(to: barcode.appendingPathComponent("chunk_\(chunk).fastq"), atomically: true, encoding: .utf8)
        }
        return barcode.deletingLastPathComponent()
    }

    /// A folder with one Illumina pair, twelve read pairs of 60 bases.
    private func makeIlluminaPair() throws -> URL {
        let folder = root.appendingPathComponent("illumina-input", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var r1 = ""
        var r2 = ""
        let quality = String(repeating: "I", count: 60)
        for index in 0..<12 {
            r1 += "@pair\(index) 1:N:0:1\n\(Self.sequence(index))\n+\n\(quality)\n"
            r2 += "@pair\(index) 2:N:0:1\n\(Self.sequence(index + 40))\n+\n\(quality)\n"
        }
        try r1.write(to: folder.appendingPathComponent("sample_R1.fastq"), atomically: true, encoding: .utf8)
        try r2.write(to: folder.appendingPathComponent("sample_R2.fastq"), atomically: true, encoding: .utf8)
        return folder
    }

    private static func sequence(_ seed: Int) -> String {
        let bases = Array("ACGT")
        return String((0..<60).map { bases[($0 * 7 + seed * 3 + $0 / 5) % 4] })
    }

    /// The `.lungfishfastq` bundles under `project`.
    private static func bundles(in project: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: project, includingPropertiesForKeys: nil) else { return [] }
        var found: [URL] = []
        for case let url as URL in walker where url.pathExtension == FASTQBundle.directoryExtension {
            found.append(url)
            walker.skipDescendants()
        }
        return found.sorted { $0.path < $1.path }
    }
}
