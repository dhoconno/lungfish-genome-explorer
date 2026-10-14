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

    /// A44 M2 review, F9 (B-3, B-5). A nucleotide bundle's record names each output it lists in
    /// the bundle, with the digest the file has, and names no scratch folder of the run, and a
    /// signed record passes `provenance verify`.
    func testNucleotideBundlesRecordNamesEachOutputItHoldsAndVerifies() async throws {
        do {
            try await GenomeDownloadBundleBuilder(ncbiService: NCBIService(apiKey: nil, environment: [:])).validateTools()
        } catch {
            try ToolAvailability.skipOrFail("Managed bgzip and samtools are required: \(error)")
        }
        let root = try TestTempDirectory.make(prefix: "nucleotide-record")
        defer { TestTempDirectory.cleanup(root) }
        let output = root.appendingPathComponent("out", isDirectory: true)
        let server = try await NCBIGenomeStandIn.start(servingIn: root.appendingPathComponent("served", isDirectory: true))
        defer { server.stop() }
        let saved = ProcessEnvironmentOverride(
            set: [
                NCBIServiceEndpoints.standInOriginVariable: server.baseURL.absoluteString,
                ProvenanceSigningConfiguration.signingKeyEnvironmentKey: "lane-a44-f9-signing-key",
            ],
            unset: ["NCBI_API_KEY", ProvenanceSigningConfiguration.signingKeyFileEnvironmentKey])
        defer { saved.restore() }
        var command = try GenomeSubcommand.parse([NCBIDownloadPinFixtures.genBankAccession, "--output-dir", output.path, "--quiet"])
        try await command.run()

        let bundle = output.appendingPathComponent("ZZ000001.1.lungfishref", isDirectory: true)
        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: bundle))
        XCTAssertFalse(envelope.outputs.isEmpty)
        for file in envelope.outputs {
            XCTAssertTrue(file.path.contains("/out/ZZ000001.1.lungfishref/"), file.path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), file.path)
            XCTAssertEqual(try ProvenanceFileHasher.sha256(of: URL(fileURLWithPath: file.path)), file.checksumSHA256, file.path)
        }
        let record = try String(
            contentsOf: bundle.appendingPathComponent(ProvenanceRecorder.provenanceFilename), encoding: .utf8)
        XCTAssertFalse(record.contains(".lungfish-temp-"), "the record names the run's scratch folder")
        XCTAssertFalse(record.contains(".fetch-genome-"), "the record names the run's staging folder")
        var verify = try ProvenanceCommand.VerifySubcommand.parse([bundle.path])
        try await verify.run()
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
        // Since lane A44 M2 the leaf builds an assembly through the genome download builder, so the
        // assembly bundle is named `<organism> - <assembly name>` and carries the record of what was
        // fetched. A nucleotide bundle still builds through NativeBundleBuilder (A44 M2 review,
        // ruling 2), and gets the same record in its final place (F9).
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

    /// A bundle as a VCF import with no reference leaves it, a manifest with one variant track and
    /// no genome, and the track's file, whose one variant sits on `chromosome`.
    static func makeVariantOnlyBundle(in folder: URL, chromosome: String = "NC_000001.1") throws -> URL {
        let bundle = folder.appendingPathComponent("Cohort calls.lungfishref", isDirectory: true)
        let variants = bundle.appendingPathComponent("variants", isDirectory: true)
        try FileManager.default.createDirectory(at: variants, withIntermediateDirectories: true)
        try "##fileformat=VCFv4.2\n#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\n\(chromosome)\t5\t.\tA\tG\t50\tPASS\t.\n"
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
