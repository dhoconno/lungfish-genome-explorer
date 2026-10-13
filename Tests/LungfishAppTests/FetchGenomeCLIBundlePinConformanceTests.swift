// FetchGenomeCLIBundlePinConformanceTests.swift - Pins the bundles lungfish-cli fetch genome builds today
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import XCTest
@testable import LungfishCLI
@testable import LungfishCore
@testable import LungfishWorkflow
import LungfishTestSupport

/// Pins the bundle `fetch genome` builds for an assembly and for a nucleotide record, its name
/// included, before Phase 2.10 lane A44 moves the leaf onto the download builders (review ruling
/// Q2c item 1). The leaf builds through `NativeBundleBuilder` with names and a layout of its own
/// (`bundleDirectoryName`), so the commit that moves it changes these snapshots and names each
/// changed default against them.
///
/// The leaf runs in this process against a loopback stand-in. Its `NCBIService` reads the
/// process environment, so each case sets the stand-in origin there (ruling Q2a) and clears
/// `NCBI_API_KEY` for the run, then puts both back. Each case runs the managed bgzip and samtools
/// faidx, so the class sits in the conformance tier and skips without them unless
/// `LUNGFISH_REQUIRE_TOOLS=1`.
final class FetchGenomeCLIBundlePinConformanceTests: XCTestCase {

    func testAssemblyAccessionBuildsTodaysCLIBundle() async throws {
        try await assertCLIBundle(pin: "cli-fetch-genome-assembly", accession: "GCF_000000001.1")
    }

    func testNucleotideAccessionBuildsTodaysCLIBundle() async throws {
        try await assertCLIBundle(pin: "cli-fetch-genome-nucleotide", accession: NCBIDownloadPinFixtures.genBankAccession)
    }

    // MARK: - Helpers

    private func assertCLIBundle(
        pin: String, accession: String, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        do {
            try await GenomeDownloadBundleBuilder(ncbiService: NCBIService(apiKey: nil, environment: [:])).validateTools()
        } catch {
            try ToolAvailability.skipOrFail("Managed bgzip and samtools are required: \(error)", file: file, line: line)
        }
        let root = try TestTempDirectory.make(prefix: "fetch-genome-cli-pin")
        defer { TestTempDirectory.cleanup(root) }
        let served = root.appendingPathComponent("served", isDirectory: true)
        let output = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: served, withIntermediateDirectories: true)

        let folder = NCBIDownloadPinFixtures.assemblyFTPPath + "/" + NCBIDownloadPinFixtures.assemblyDirectory
        let routes: [String: LoopbackHTTPResponse] = [
            folder + "_genomic.fna.gz": try await gzipped(NCBIDownloadPinFixtures.assemblyFASTA, as: "genomic.fna", in: served),
            folder + "_genomic.gff.gz": try await gzipped(NCBIDownloadPinFixtures.assemblyGFF3, as: "genomic.gff", in: served),
            "/entrez/eutils/esearch.fcgi": .text(NCBIDownloadPinFixtures.assemblyESearchJSON),
        ]
        let summaryHolder = SummaryHolder()
        let server = try LoopbackHTTPStandIn.start { request in
            switch request.path {
            case "/entrez/eutils/esummary.fcgi":
                return .text(summaryHolder.json)
            case "/entrez/eutils/efetch.fcgi":
                switch request.queryItems.first(where: { $0.name == "rettype" })?.value {
                case "fasta": return .text(NCBIDownloadPinFixtures.genBankFASTA)
                case "gff3": return .text(NCBIDownloadPinFixtures.genBankGFF3)
                default: return .notFound
                }
            default:
                return routes[request.path] ?? .notFound
            }
        }
        defer { server.stop() }
        summaryHolder.json = try NCBIDownloadPinFixtures.assemblyESummaryJSON(ftpBase: server.baseURL.absoluteString)

        let saved = ProcessEnvironmentOverride(
            set: [NCBIServiceEndpoints.standInOriginVariable: server.baseURL.absoluteString],
            unset: ["NCBI_API_KEY"])
        defer { saved.restore() }
        var command = try GenomeSubcommand.parse([accession, "--output-dir", output.path, "--quiet"])
        try await command.run()

        let bundles = try FileManager.default.contentsOfDirectory(atPath: output.path).sorted()
        XCTAssertEqual(bundles.count, 1, "\(bundles)", file: file, line: line)
        let bundle = output.appendingPathComponent(try XCTUnwrap(bundles.first))
        // Today's nucleotide record names the leaf's scratch folders in the system temporary folder
        // (`.lungfish-temp-<UUID>` and NativeBundleBuilder's `.<name>.building-<UUID>`), which the
        // run deletes, so the temporary folder and every UUID are masked here. The move onto the
        // download builders drops that false fact.
        var snapshot = try await DownloadedBundleSnapshot.text(
            of: bundle,
            replacing: [(server.baseURL.absoluteString, "<STAND-IN>")]
                + DownloadedBundleSnapshot.directoryReplacements(output, as: "<OUT>")
                + DownloadedBundleSnapshot.directoryReplacements(FileManager.default.temporaryDirectory, as: "<TMP>"))
        snapshot = snapshot.replacingOccurrences(
            of: #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#,
            with: "<UUID>", options: .regularExpression)
        snapshot += server.requests.map { "\nrequest \($0.method) \($0.target)" }.joined()
        DownloadedBundleSnapshot.recordIfAsked(snapshot, name: pin)
        XCTAssertEqual(snapshot, try DownloadBundlePins.expected(pin), file: file, line: line)
    }

    /// The gzip bytes NCBI's FTP folder serves for `text`, as the genome pins make them.
    private func gzipped(_ text: String, as name: String, in directory: URL) async throws -> LoopbackHTTPResponse {
        let plain = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: plain)
        let result = try await NativeToolRunner.shared.bgzipCompress(inputPath: plain, keepOriginal: false)
        XCTAssertTrue(result.isSuccess, result.combinedOutput)
        let compressed = try Data(contentsOf: plain.appendingPathExtension("gz"))
        return LoopbackHTTPResponse(contentType: "application/x-gzip", body: compressed)
    }
}

/// The esummary answer, which names the stand-in's own port and so is set once it started.
private final class SummaryHolder: Sendable {
    private let value = Mutex("")

    var json: String {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
}

/// Sets and clears process environment variables for one in-process CLI run and puts back what
/// was there. Only a conformance or replay class uses it, never the parallel unit tier.
struct ProcessEnvironmentOverride {
    private let previous: [String: String?]

    init(set: [String: String], unset: [String]) {
        var previous: [String: String?] = [:]
        for name in Array(set.keys) + unset {
            previous[name] = ProcessInfo.processInfo.environment[name]
        }
        self.previous = previous
        for (name, value) in set { setenv(name, value, 1) }
        for name in unset { unsetenv(name) }
    }

    func restore() {
        for (name, value) in previous {
            if let value { setenv(name, value, 1) } else { unsetenv(name) }
        }
    }
}
