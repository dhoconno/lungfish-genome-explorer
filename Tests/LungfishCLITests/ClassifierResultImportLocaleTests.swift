// ClassifierResultImportLocaleTests.swift - A completed Kraken2, EsViritu or TaxTriage import under a non-English locale
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.04, finding 5 of its review (BIO 5, X12). The cancelled runs of ClassifierResultImportSIGTERMTests
// are the only ones that ran under de_DE. Two places could let a locale change a completed run. The grouped count in
// the words of the `complete` event reads a NumberFormatter, and the sample names of the record are sorted. Each leaf
// runs here to the end under de_DE with `--format json`, and the test reads the words, the sample names and the source
// digest the record holds, which must equal the English transcripts, the ids as read and a digest the test computes.
// No real tool and no network are needed.

import CryptoKit
import Foundation
import XCTest
import LungfishCore
import LungfishTestSupport
import LungfishWorkflow

final class ClassifierResultImportLocaleTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "classifier-import-locale")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    func testImportKraken2UnderAGermanLocaleKeepsItsWordsNamesAndDigest() throws {
        let input = try ClassifierResultImportFixtures.kraken2Report(in: root)
        let done = try runImport(kind: "kraken2", input: input)
        XCTAssertEqual(done.message, "Imported Kraken2 result: 2,504,263 reads, 738 species")
        XCTAssertEqual(done.sampleNames, ["S1.2024"])
        XCTAssertEqual(done.sourceDigest, try Self.sha256(of: input))
    }

    func testImportEsVirituUnderAGermanLocaleKeepsItsWordsNamesAndDigest() throws {
        let input = try ClassifierResultImportFixtures.esVirituResult(in: root)
        let done = try runImport(kind: "esviritu", input: input)
        XCTAssertEqual(done.message, "Imported EsViritu result: 3 files, 3 detections")
        XCTAssertEqual(done.sampleNames, ["S1.2024"])
        XCTAssertEqual(done.sourceDigest, try Self.folderDigest(of: input))
    }

    func testImportTaxTriageUnderAGermanLocaleKeepsItsWordsNamesAndDigest() throws {
        let input = try ClassifierResultImportFixtures.taxTriageResult(in: root)
        let done = try runImport(kind: "taxtriage", input: input)
        XCTAssertEqual(done.message, "Imported TaxTriage result: 6 files")
        XCTAssertEqual(done.sampleNames, ["S1.2024", "SRR35517702", "SRR35517703", "SRR35517705"])
        XCTAssertEqual(done.sourceDigest, try Self.folderDigest(of: input))
    }

    // MARK: - Running one import

    private struct Done {
        let message: String?
        let sampleNames: [String]
        let sourceDigest: String?
    }

    /// Runs `import <kind>` on the built CLI under de_DE to its end, waits for exit 0 inside 30 seconds, and reads the
    /// `complete` words and the record of the one result folder it made.
    private func runImport(kind: String, input: URL) throws -> Done {
        let cli = try XCTUnwrap(CLISIGTERMHarness.cliBinaryURL(for: Self.self), "Inject LUNGFISH_CLI or build it beside the tests")
        let imports = root.appendingPathComponent("Project.lungfish/Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        let standardOutput = root.appendingPathComponent("\(kind).stdout.ndjson")
        FileManager.default.createFile(atPath: standardOutput.path, contents: nil)
        let output = try FileHandle(forWritingTo: standardOutput)
        defer { try? output.close() }

        let process = Process()
        process.executableURL = cli
        process.arguments = ["import", kind, input.path, "--output-dir", imports.path, "--format", "json"]
        process.environment = CLISIGTERMHarness.childEnvironment(overriding: ClassifierResultImportFixtures.nonEnglishLocale)
        process.currentDirectoryURL = root
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            XCTFail("import \(kind) did not end inside 30 seconds")
        }
        process.waitUntilExit()
        let lines = ((try? String(contentsOf: standardOutput, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        XCTAssertEqual(process.terminationStatus, 0, lines.joined(separator: "\n"))

        let message = lines.compactMap { line -> String? in
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  object["event"] as? String == "complete" else { return nil }
            return object["message"] as? String
        }.last
        let folders = ClassifierResultImportFixtures.resultFolders(in: imports)
        XCTAssertEqual(folders.count, 1, "\(folders)")
        let folder = imports.appendingPathComponent(folders.first ?? "", isDirectory: true)
        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: folder), "the result folder holds its record")
        let defaults = envelope.options.resolvedDefaults
        var names: [String] = []
        if case .array(let values)? = defaults["sampleNames"] {
            names = values.compactMap { value in
                if case .string(let text) = value { return text }
                return nil
            }
        }
        var digest: String?
        if case .string(let text)? = defaults["sourceDigest"] { digest = text }
        return Done(message: message, sampleNames: names, sourceDigest: digest)
    }

    // MARK: - The digests the record states, computed here

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(of file: URL) throws -> String {
        hex(SHA256.hash(data: try Data(contentsOf: file)))
    }

    /// The SHA-256 of one `<relative path>\t<SHA-256>` line for each regular file of `folder`, in path order.
    private static func folderDigest(of folder: URL) throws -> String {
        let top = folder.resolvingSymlinksInPath().path
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])?
            .compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true } ?? []
        let lines = try files.map { url in
            "\(url.resolvingSymlinksInPath().path.dropFirst(top.count + 1))\t\(try sha256(of: url))\n"
        }.sorted()
        return hex(SHA256.hash(data: Data(lines.joined().utf8)))
    }
}
