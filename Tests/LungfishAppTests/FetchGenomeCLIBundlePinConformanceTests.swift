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

    /// `--into-bundle` adds the assembly's genome and annotations to a bundle imported from a VCF
    /// with no reference (census g17). The bundle keeps its variant track and file, gains the
    /// genome, the annotation database and the record of what was fetched in `genome/`, and no
    /// staging folder is left beside it.
    func testAssemblyIntoAVariantOnlyBundleAddsTheGenomeAndKeepsTheVariants() async throws {
        try await assertCLIBundle(
            pin: "cli-fetch-genome-into-bundle", accession: NCBIGenomeStandIn.assemblyAccession, intoVariantOnlyBundle: true)
    }

    // MARK: - Helpers

    private func assertCLIBundle(
        pin: String, accession: String, intoVariantOnlyBundle: Bool = false,
        file: StaticString = #filePath, line: UInt = #line
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
        let server = try await NCBIGenomeStandIn.start(servingIn: served)
        defer { server.stop() }

        let saved = ProcessEnvironmentOverride(
            set: [NCBIServiceEndpoints.standInOriginVariable: server.baseURL.absoluteString],
            unset: ["NCBI_API_KEY"])
        defer { saved.restore() }
        var arguments = [accession, "--output-dir", output.path, "--quiet"]
        if intoVariantOnlyBundle {
            arguments = [accession, "--into-bundle", try Self.makeVariantOnlyBundle(in: output).path, "--quiet"]
        }
        var command = try GenomeSubcommand.parse(arguments)
        try await command.run()

        let bundles = try FileManager.default.contentsOfDirectory(atPath: output.path).sorted()
        XCTAssertEqual(bundles.count, 1, "\(bundles)", file: file, line: line)
        let bundle = output.appendingPathComponent(try XCTUnwrap(bundles.first))
        // Since lane A44 M2 the leaf builds through the download builders, so the assembly bundle
        // is named `<organism> - <assembly name>` and carries the record of what was fetched, and
        // the nucleotide bundle is the GenBank download's, with its record. No record names a
        // scratch folder now. The temporary folder and UUIDs stay masked for the builders' own
        // scratch names. A merge's record names its outputs as the file system lists them, with
        // `/private` before a temporary path.
        var snapshot = try await DownloadedBundleSnapshot.text(
            of: bundle,
            replacing: [(server.baseURL.absoluteString, "<STAND-IN>"), ("/private" + output.standardizedFileURL.path, "<OUT>")]
                + DownloadedBundleSnapshot.directoryReplacements(output, as: "<OUT>")
                + DownloadedBundleSnapshot.directoryReplacements(FileManager.default.temporaryDirectory, as: "<TMP>"))
        snapshot = snapshot.replacingOccurrences(
            of: #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#,
            with: "<UUID>", options: .regularExpression)
        snapshot += server.requests.map { "\nrequest \($0.method) \($0.target)" }.joined()
        DownloadedBundleSnapshot.recordIfAsked(snapshot, name: pin)
        XCTAssertEqual(snapshot, try DownloadBundlePins.expected(pin), file: file, line: line)
    }

    /// A bundle as a VCF import with no reference leaves it, a manifest with one variant track and
    /// no genome, and the track's file.
    static func makeVariantOnlyBundle(in folder: URL) throws -> URL {
        let bundle = folder.appendingPathComponent("Cohort calls.lungfishref", isDirectory: true)
        let variants = bundle.appendingPathComponent("variants", isDirectory: true)
        try FileManager.default.createDirectory(at: variants, withIntermediateDirectories: true)
        try "##fileformat=VCFv4.2\n#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\nNC_000001.1\t5\t.\tA\tG\t50\tPASS\t.\n"
            .write(to: variants.appendingPathComponent("calls.vcf"), atomically: true, encoding: .utf8)
        let manifest = BundleManifest(
            name: "Cohort calls",
            identifier: "org.lungfish.test.cohort-calls",
            source: SourceInfo(organism: "Unknown", assembly: "Unknown"),
            variants: [VariantTrackInfo(
                id: "calls", name: "Cohort calls", path: "variants/calls.vcf", indexPath: "variants/calls.vcf.idx")],
            recordStore: nil
        )
        try manifest.save(to: bundle)
        return bundle
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
