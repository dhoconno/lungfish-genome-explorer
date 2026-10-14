// AssemblyRouteConformanceTests.swift - What the Reassemble route shows and writes on a fixture
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A46 M2 (BIO 1, UX 3). Reassemble runs ManagedAssemblyPipeline in the app today
// (census row p32) and builds a `.lungfishref` bundle from the contigs. This class runs that route
// the way `AssemblyRunner.runValidated` starts it once its checks pass, MEGAHIT on the paired reads
// of Tests/Fixtures/sarscov2 with one thread and 4 GB, and freezes its row (each detail and bar
// position in order, each line it logs and its end) and its result (each file it wrote, the
// SHA-256 of the sequence files, and each value of its JSON records). The scratch folder reads
// `/work`. MEGAHIT's own lines hold times and memory, so each run of them reads
// `info <assembler output>`, and dates and timings read as placeholders. M3's parity class holds the
// CLI route to these files. Set LUNGFISH_RECAPTURE_ASSEMBLY_ROUTE=1 to write the files instead of
// comparing, and review the diff.
//
// The real assembler runs, so the name holds Conformance and the class never runs in the unit tier.
// The locked golden storage holds no assembler (Tests/Fixtures/cli-events/README.md), so run it
// against a storage root whose `conda/envs/megahit` holds MEGAHIT 1.2.9:
//
//     LUNGFISH_STORAGE_ROOT=<root> LUNGFISH_REQUIRE_TOOLS=1 \
//         swift test --skip-update --filter AssemblyRouteConformanceTests

import Combine
import CryptoKit
import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishKit
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class AssemblyRouteConformanceTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "assembly-route")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    func testTheInProcessRouteOnTheSarscov2Reads() async throws {
        _ = try await ToolAvailability.require("megahit", environment: "megahit")
        _ = try await ToolAvailability.require("bgzip", environment: "htslib")
        let fixture = try AssemblyRoute.Fixture(in: scratch)
        let row = try await AssemblyRoute.record(fixture.request) { AssemblyRoute.startInProcess($0) }
        try AssemblyRoute.assertFrozen(AssemblyRoute.rowText(row), name: "megahit-row", scratch: scratch)
        let result = try AssemblyRoute.resultText(in: fixture.outputFolder, scratch: scratch)
        try AssemblyRoute.assertFrozen(result, name: "megahit-result", scratch: scratch)
    }
}

/// The Reassemble route's fixture, its row and its result, shared by lane A46's assembly classes.
enum AssemblyRoute {
    static let projectName = "sarscov2-test"

    static var frozenFolder: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/AssemblyRoute", isDirectory: true)
    }

    /// A project with the paired reads of Tests/Fixtures/sarscov2 and the folder Reassemble names,
    /// the one that holds the bundle it was opened on.
    struct Fixture {
        let outputFolder: URL
        let request: AssemblyRunRequest

        init(in root: URL) throws {
            let fileManager = FileManager.default
            let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
            let inputs = project.appendingPathComponent("inputs", isDirectory: true)
            outputFolder = project.appendingPathComponent("Assemblies", isDirectory: true)
            try fileManager.createDirectory(at: inputs, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: outputFolder, withIntermediateDirectories: true)
            let source = MappingRouteGolden.repositoryRoot.appendingPathComponent("Tests/Fixtures/sarscov2", isDirectory: true)
            for name in ["test_1.fastq.gz", "test_2.fastq.gz"] {
                try fileManager.copyItem(at: source.appendingPathComponent(name), to: inputs.appendingPathComponent(name))
            }
            request = AssemblyRunRequest(
                tool: .megahit,
                readType: .illuminaShortReads,
                inputURLs: ["test_1.fastq.gz", "test_2.fastq.gz"].map { inputs.appendingPathComponent($0) },
                projectName: AssemblyRoute.projectName,
                outputDirectory: outputFolder,
                pairedEnd: true,
                threads: 1,
                memoryGB: 4
            )
        }
    }

    /// Starts `request` on today's in-process route, as `runValidated` does once its checks pass.
    @MainActor
    static func startInProcess(_ request: AssemblyRunRequest) {
        let request = request.normalizedForExecution()
        let executionRequest = AssemblyRunner.executionRequest(for: request)
        AssemblyRunner.beginAssemblyOperation(
            request: request,
            outputDirectory: executionRequest.outputDirectory,
            routeContext: nil
        ) { opID in
            Task.detached {
                await AssemblyRunner.runManagedAssemblyOperation(
                    request: executionRequest,
                    baseOutputDirectory: request.outputDirectory,
                    projectName: request.projectName,
                    operationID: opID
                )
            }
        }
    }

    /// Runs `start` with `request` and records its row until the row ends.
    @MainActor
    static func record(_ request: AssemblyRunRequest, start: (AssemblyRunRequest) -> Void) async throws -> MappingRouteRow {
        let recorder = MappingRouteRow.Recorder(title: "\(request.tool.displayName) Assembly: \(request.projectName)")
        let subscription = OperationCenter.shared.$items.sink { items in recorder.take(items) }
        defer { subscription.cancel() }
        start(request)
        // A real assembly and bundle, so the wait is long, and it returns once the row ends.
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline, recorder.ended == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        let item = try XCTUnwrap(recorder.ended, "the row never ended:\n\(recorder.row.text)")
        var row = recorder.row
        row.logged = item.logEntries.map { "\($0.level) \($0.message)" }
        row.end = "\(item.state) \(item.detail)"
        return row
    }

    /// The frozen form of `row`, with each run of MEGAHIT's own lines read as one entry.
    static func rowText(_ row: MappingRouteRow) -> String {
        var row = row
        var logged: [String] = []
        for line in row.logged {
            let isAssemblerLine = line.range(of: #"^info \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} - "#, options: .regularExpression) != nil
            let entry = isAssemblerLine ? "info <assembler output>" : line
            if isAssemblerLine, logged.last == entry { continue }
            logged.append(entry)
        }
        row.logged = logged
        return row.text
    }

    /// Each file under `folder` in path order. A sequence file adds its SHA-256 and a JSON record adds
    /// each value as `<key path> = <value>`. The record the bundle keeps beside each of its files
    /// repeats the bundle's record, so one digest of its values stands for it.
    static func resultText(in folder: URL, scratch: URL) throws -> String {
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys))
        var files: [String: URL] = [:]
        while let url = walker?.nextObject() as? URL {
            guard try url.resourceValues(forKeys: keys).isRegularFile == true else { continue }
            files[String(url.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count + 1))] = url
        }
        var lines: [String] = []
        for (relative, url) in files.sorted(by: { $0.key < $1.key }) {
            let data = try Data(contentsOf: url)
            if url.pathExtension == "json", let object = try? JSONSerialization.jsonObject(with: data) {
                let values = flattened(object, path: "", scratch: scratch)
                if relative.contains("provenance/"), relative.hasSuffix(".lungfish-provenance.json") {
                    lines.append("\(relative) values-sha256=\(digest(Data(values.joined(separator: "\n").utf8)))")
                } else {
                    lines.append(relative)
                    lines += values.map { "  \($0)" }
                }
            } else if sequenceExtensions.contains(where: { relative.hasSuffix($0) }) {
                lines.append("\(relative) sha256=\(digest(data))")
            } else {
                lines.append(relative)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static let sequenceExtensions = [".fa", ".fasta", ".fa.gz", ".fai", ".gzi", ".gfa", ".fastg"]

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The values of a JSON record. A record of a log, another record or the bundle itself keeps a
    /// digest and a size that change with each run's times, and the manifest's wall time changes too.
    private static func flattened(_ value: Any, path: String, scratch: URL) -> [String] {
        if let dictionary = value as? [String: Any] {
            var varying: Set<String> = []
            if let recorded = dictionary["path"] as? String, [".json", ".log", ".lungfishref"].contains(where: { recorded.hasSuffix($0) }) {
                varying = ["checksumSHA256", "fileSize"]
            }
            if dictionary["label"] as? String == "Wall Time" { varying.insert("value") }
            return dictionary.keys.sorted().flatMap { key -> [String] in
                let child = path.isEmpty ? key : "\(path).\(key)"
                return varying.contains(key) ? ["\(child) = <varies>"] : flattened(dictionary[key]!, path: child, scratch: scratch)
            }
        }
        if let array = value as? [Any] {
            return array.enumerated().flatMap { flattened($1, path: "\(path)[\($0)]", scratch: scratch) }
        }
        let key = path.split(separator: ".").last.map(String.init) ?? path
        return ["\(path) = \(masked(value, key: key, scratch: scratch))"]
    }

    /// Dates, timings, identifiers, the host and the build read as placeholders, the scratch folder
    /// reads `/work`, and another temporary folder reads `<tmp>`.
    private static func masked(_ value: Any, key: String, scratch: URL) -> String {
        let name = key.replacingOccurrences(of: #"\[\d+\]$"#, with: "", options: .regularExpression)
            .lowercased().replacingOccurrences(of: "_", with: "")
        if ["date", "time", "seconds", "startedat", "endedat", "completedat", "createdat"].contains(where: { name.hasSuffix($0) }) {
            return "<time>"
        }
        if ["hostos", "hostarchitecture", "appversion", "executablepath", "operatingsystemversion"].contains(name) {
            return "<host>"
        }
        return normalizedText("\(value)", scratch: scratch)
            .replacingOccurrences(of: #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#, with: "<uuid>", options: .regularExpression)
            .replacingOccurrences(of: #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})?"#, with: "<date>", options: .regularExpression)
    }

    /// `text` with the scratch folder read as `/work` and any other temporary folder as `<tmp>`.
    static func normalizedText(_ text: String, scratch: URL) -> String {
        var text = text
        for root in [scratch.resolvingSymlinksInPath().path, scratch.path] {
            text = text.replacingOccurrences(of: root, with: "/work")
        }
        return text.replacingOccurrences(of: #"(/private)?/var/folders/[^ '"]+"#, with: "<tmp>", options: .regularExpression)
    }

    /// Holds `text` to its frozen file, with `scratch` read as `/work`.
    static func assertFrozen(_ text: String, name: String, scratch: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let text = normalizedText(text, scratch: scratch)
        let url = frozenFolder.appendingPathComponent("\(name).txt")
        if ProcessInfo.processInfo.environment["LUNGFISH_RECAPTURE_ASSEMBLY_ROUTE"] == "1" {
            try FileManager.default.createDirectory(at: frozenFolder, withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        XCTAssertEqual(text, try String(contentsOf: url, encoding: .utf8), "\(name) differs from its frozen file", file: file, line: line)
    }
}
