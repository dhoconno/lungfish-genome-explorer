// NaoMgsNvdImportLocaleTests.swift - A completed NAO-MGS or NVD import under a non-English locale
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.05, finding 3 of its review (BIO 5, X12). The cancelled runs of NaoMgsNvdImportSIGTERMTests are
// the only ones that ran under de_DE. Each leaf runs here to the end under de_DE with `--format json`, and the test
// reads the words, the sample names and the source digest the record holds, which must equal the English words, the
// ids as the result spells them and a digest the test computes. The fixture totals stay below 1,000, so the comma
// grouping of a count is not seen here, and 12.04 pins it with 2,504,263 reads. No real tool and no network are
// needed, since the managed storage under the scratch folder holds a fixture taxonomy.

import CryptoKit
import Foundation
import XCTest
import LungfishCore
import LungfishTestSupport
import LungfishWorkflow

final class NaoMgsNvdImportLocaleTests: XCTestCase {
    private var root: URL!
    private var storage: URL!

    override func setUp() async throws {
        root = try TestTempDirectory.make(prefix: "naomgs-nvd-import-locale")
        storage = try await NaoMgsNvdImportFixtures.installFixtureTaxonomy(in: root)
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    func testImportNaoMgsUnderAGermanLocaleKeepsItsWordsNamesAndDigest() throws {
        let input = try NaoMgsNvdImportFixtures.naoMgsResult(in: root)
        let done = try runImport(kind: "nao-mgs", input: input, extra: ["--no-fetch-references"])
        XCTAssertEqual(done.message, "Imported NAO-MGS result: 5 reads, 1 taxa")
        XCTAssertEqual(done.sampleNames, ["S1.2024", "S2.2024"])
        XCTAssertEqual(done.sourceDigest, try Self.folderDigest(of: input))
    }

    func testImportNvdUnderAGermanLocaleKeepsItsWordsNamesAndDigest() throws {
        let input = try NaoMgsNvdImportFixtures.nvdRun(in: root)
        let done = try runImport(kind: "nvd", input: input, extra: [])
        XCTAssertEqual(done.message, "Imported NVD result: 3 hits, 2 samples")
        XCTAssertEqual(done.sampleNames, ["S1.2024", "S2.2024"])
        XCTAssertEqual(done.sourceDigest, try Self.folderDigest(of: input))
    }

    // MARK: - Running one import

    private struct Done {
        let message: String?
        let sampleNames: [String]
        let sourceDigest: String?
    }

    /// Runs `import <kind>` on the built CLI under de_DE to its end, waits for exit 0 inside 30 seconds, and reads the
    /// `complete` words and the record of the one folder it made.
    private func runImport(kind: String, input: URL, extra: [String]) throws -> Done {
        let cli = try XCTUnwrap(CLISIGTERMHarness.cliBinaryURL(for: Self.self), "Inject LUNGFISH_CLI or build it beside the tests")
        let imports = root.appendingPathComponent("Project.lungfish/Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        let standardOutput = root.appendingPathComponent("\(kind).stdout.ndjson")
        FileManager.default.createFile(atPath: standardOutput.path, contents: nil)
        let output = try FileHandle(forWritingTo: standardOutput)
        defer { try? output.close() }

        let process = Process()
        process.executableURL = cli
        process.arguments = ["import", kind, input.path] + extra + ["--output-dir", imports.path, "--format", "json"]
        process.environment = CLISIGTERMHarness.childEnvironment(
            overriding: NaoMgsNvdImportFixtures.nonEnglishLocale.merging(NaoMgsNvdImportFixtures.storageEnvironment(storage)) { $1 }
        )
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
        let folders = NaoMgsNvdImportFixtures.entries(in: imports)
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

    // MARK: - The digest the record states, computed here

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
