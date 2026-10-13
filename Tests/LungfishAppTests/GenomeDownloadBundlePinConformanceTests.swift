// GenomeDownloadBundlePinConformanceTests.swift - Pins the bundles the genome download builds
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishWorkflow
import LungfishTestSupport

/// Pins the bundle `GenomeDownloadViewModel` builds from a recorded NCBI assembly folder. The
/// model downloads through its own `URLSession`, so the recorded files come from a loopback
/// stand-in that the summary's FTP path names (decision G5). The snapshots were recorded at the
/// base of Phase 2.10 lane A44 (c68381a62), before the bundle building moved into
/// LungfishWorkflow. Each case runs the managed bgzip and samtools faidx, so the class sits in the
/// conformance tier and skips without them unless `LUNGFISH_REQUIRE_TOOLS=1`.
final class GenomeDownloadBundlePinConformanceTests: XCTestCase {

    /// FASTA, GFF3 and the assembly report, so chromosomes gain aliases and the report is kept.
    func testAssemblyWithAnnotationsAndReportBuildsTodaysBundle() async throws {
        try await assertBundle(pin: "genome-assembly-full", servesGFF3: true, servesReport: true)
    }

    /// Only the FASTA, so the bundle has no annotation track, no aliases and no report.
    func testAssemblyWithFASTAOnlyBuildsTodaysBundle() async throws {
        try await assertBundle(pin: "genome-assembly-fasta-only", servesGFF3: false, servesReport: false)
    }

    // MARK: - Helpers

    private func assertBundle(
        pin: String, servesGFF3: Bool, servesReport: Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        do {
            try await GenomeDownloadViewModel().validateTools()
        } catch {
            try ToolAvailability.skipOrFail("Managed bgzip and samtools are required: \(error)", file: file, line: line)
        }
        let root = try TestTempDirectory.make(prefix: "genome-download-pin")
        defer { TestTempDirectory.cleanup(root) }
        let served = root.appendingPathComponent("served", isDirectory: true)
        let output = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: served, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let folder = NCBIDownloadPinFixtures.assemblyFTPPath + "/" + NCBIDownloadPinFixtures.assemblyDirectory
        let fasta = try await gzipped(NCBIDownloadPinFixtures.assemblyFASTA, as: "genomic.fna", in: served)
        var routes: [String: LoopbackHTTPResponse] = [folder + "_genomic.fna.gz": fasta]
        if servesGFF3 {
            let gff3 = try await gzipped(NCBIDownloadPinFixtures.assemblyGFF3, as: "genomic.gff", in: served)
            routes[folder + "_genomic.gff.gz"] = gff3
        }
        if servesReport {
            routes[folder + "_assembly_report.txt"] = .text(NCBIDownloadPinFixtures.assemblyReport)
        }
        let server = try LoopbackHTTPStandIn.start(routes: routes)
        defer { server.stop() }

        let summary = try NCBIDownloadPinFixtures.assemblySummary(ftpBase: server.baseURL.absoluteString)
        let model = GenomeDownloadViewModel(ncbiService: NCBIService(apiKey: nil, environment: [:]))
        let bundle = try await model.downloadAndBuild(assembly: summary, outputDirectory: output)

        var snapshot = try await DownloadedBundleSnapshot.text(
            of: bundle,
            replacing: [(server.baseURL.absoluteString, "<STAND-IN>")]
                + DownloadedBundleSnapshot.directoryReplacements(output, as: "<OUT>"))
        snapshot += server.requests.map { "\nrequest \($0.method) \($0.target)" }.joined()
        DownloadedBundleSnapshot.recordIfAsked(snapshot, name: pin)
        XCTAssertEqual(snapshot, try DownloadBundlePins.expected(pin), file: file, line: line)
    }

    /// The gzip bytes NCBI's FTP folder serves for `text`. bgzip writes a gzip stream that any
    /// gzip reader opens, as NCBI's files are.
    private func gzipped(_ text: String, as name: String, in directory: URL) async throws -> LoopbackHTTPResponse {
        let plain = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: plain)
        let result = try await NativeToolRunner.shared.bgzipCompress(inputPath: plain, keepOriginal: false)
        XCTAssertTrue(result.isSuccess, result.combinedOutput)
        let compressed = try Data(contentsOf: plain.appendingPathExtension("gz"))
        return LoopbackHTTPResponse(contentType: "application/x-gzip", body: compressed)
    }
}
