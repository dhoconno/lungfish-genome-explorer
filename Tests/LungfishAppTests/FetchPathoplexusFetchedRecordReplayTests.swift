// FetchPathoplexusFetchedRecordReplayTests.swift - The record of lungfish-cli fetch pathoplexus names the record it fetched
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A45 M2 (c), ruling K7 (`ruling-A45-M1.md` section 4) and BIO's brief for M2: the record
// names each accession with its version, the date of the fetch and the digest of what arrived, with the
// `liveSnapshot` status of 2.9 R3. The built CLI runs on the loopback Pathoplexus and NCBI stand-ins that
// the child's environment names, and each case is one of the row's four ways.
//
// - A record with an INSDC accession builds from its GenBank record. The record is the GenBank builder's,
//   with K7's `fetchedRecord` entry, the one sequence named by the accession with its version, the
//   Pathoplexus accession with its version in a `pathoplexusRecord` entry, and every output with the
//   digest it states, the manifest included, which the Pathoplexus metadata changes after the build.
// - A record with no INSDC accession, or one GenBank cannot serve, builds from the Pathoplexus FASTA.
//   The builder writes no record for it, so the CLI does. It keeps the FASTA the server sent as
//   `sources/record.fasta`, names it as the `fetchedRecord` listing and states its digest as the input.
// - A restricted record is refused and builds no bundle.
//
// They launch the built CLI and the managed bgzip and samtools, so the class name ends in ReplayTests,
// which sends it to the integration tier.

import Foundation
import XCTest
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishCore
@testable import LungfishWorkflow

final class FetchPathoplexusFetchedRecordReplayTests: XCTestCase {
    func testARecordWithAnINSDCAccessionNamesTheGenBankRecordAndThePathoplexusVersion() async throws {
        let result = try await fetch(PathoplexusLAPISStandIn.openWithINSDC)
        XCTAssertEqual(result.status, 0, result.detail)
        let bundle = try result.onlyBundle()
        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: bundle), "the run wrote no record")

        let manifest = try BundleManifest.load(from: bundle)
        XCTAssertEqual(
            manifest.genome?.chromosomes.map(\.name), [NCBIDownloadPinFixtures.genBankAccession],
            "the one sequence is named by the INSDC accession with its version")
        XCTAssertNotNil(manifest.metadata?.first { $0.name == "Pathoplexus Record" }, "the Pathoplexus metadata is in the manifest")

        let entry = try Self.dictionary("fetchedRecord", in: envelope)
        XCTAssertEqual(DatabaseIdentityStatus(recordedWord: entry["status"]?.stringValue ?? ""), .liveSnapshot)
        let fetch = try XCTUnwrap(envelope.steps.first { $0.toolName == "NCBI EFetch (URLSession)" }, "the record lists no fetch step")
        XCTAssertEqual(entry["fetchedAt"]?.stringValue, try XCTUnwrap(fetch.completedAt).formatted(.iso8601))
        let listing = try Self.listing(of: entry)
        XCTAssertEqual(
            listing.resolvingSymlinksInPath().path,
            bundle.appendingPathComponent("sources/record.gb").resolvingSymlinksInPath().path,
            "the listing is the kept GenBank record, in the bundle's final place")
        XCTAssertEqual(try ProvenanceFileHasher.sha256(of: listing), fetch.outputs.first?.checksumSHA256)

        try Self.assertPathoplexusRecord(in: envelope, entry: PathoplexusLAPISStandIn.openWithINSDC)
        XCTAssertEqual(
            Self.dictionaryEntry("pathoplexusRecord", "insdcAccession", in: envelope), NCBIDownloadPinFixtures.genBankAccession)
        try Self.assertEachOutputHasItsDigest(envelope)
    }

    func testARecordWithNoINSDCAccessionNamesTheKeptFASTAAsALiveSnapshot() async throws {
        let before = Date().addingTimeInterval(-1)
        let result = try await fetch(PathoplexusLAPISStandIn.openNoINSDC)
        XCTAssertEqual(result.status, 0, result.detail)
        try assertFASTABundle(
            try result.onlyBundle(), accession: PathoplexusLAPISStandIn.openNoINSDC, notes: "Generated from Pathoplexus sequence (no INSDC accession available)",
            fetchedAfter: before)
    }

    func testAnINSDCAccessionGenBankCannotServeFallsBackToTheFASTAWithItsRecord() async throws {
        let before = Date().addingTimeInterval(-1)
        let result = try await fetch(PathoplexusLAPISStandIn.openINSDCUnavailable)
        XCTAssertEqual(result.status, 0, result.detail)
        try assertFASTABundle(
            try result.onlyBundle(), accession: PathoplexusLAPISStandIn.openINSDCUnavailable,
            notes: "Generated from Pathoplexus FASTA fallback after INSDC lookup failed", fetchedAfter: before)
    }

    func testARestrictedRecordIsRefusedAndBuildsNoBundle() async throws {
        let result = try await fetch(PathoplexusLAPISStandIn.restricted)
        XCTAssertEqual(result.status, 1, result.detail)
        let events = result.stdout.split(separator: "\n").compactMap { try? CLIEventLineDecoder().decode(line: String($0)) }
        guard case let .failed(message, _)? = events.last else { return XCTFail("The run ends with no failed event: \(result.stdout)") }
        XCTAssertTrue(
            message.hasSuffix("Record PP_000003 is restricted and cannot be downloaded"), "the refusal keeps the row's words: \(message)")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: result.work.path)) ?? []
        XCTAssertEqual(left.filter { $0.hasSuffix(".lungfishref") || $0.hasPrefix(".fetch-pathoplexus-") }, [], "a refusal leaves nothing")
    }

    // MARK: - Assertions

    private func assertFASTABundle(_ bundle: URL, accession: String, notes: String, fetchedAfter before: Date) throws {
        let after = Date().addingTimeInterval(1)
        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: bundle), "the run wrote no record")
        let manifest = try BundleManifest.load(from: bundle)
        XCTAssertEqual(manifest.genome?.chromosomes.map(\.name), [accession])
        XCTAssertEqual(manifest.source.database, "Pathoplexus")
        XCTAssertEqual(manifest.source.notes, notes)

        let entry = try Self.dictionary("fetchedRecord", in: envelope)
        XCTAssertEqual(DatabaseIdentityStatus(recordedWord: entry["status"]?.stringValue ?? ""), .liveSnapshot)
        let fetchedAt = try Date(try XCTUnwrap(entry["fetchedAt"]?.stringValue), strategy: .iso8601)
        XCTAssertTrue((before...after).contains(fetchedAt), "the date is the date of the fetch: \(fetchedAt)")

        let kept = bundle.appendingPathComponent("sources/record.fasta")
        let listing = try Self.listing(of: entry)
        XCTAssertEqual(listing.resolvingSymlinksInPath().path, kept.resolvingSymlinksInPath().path)
        let held = try XCTUnwrap(PathoplexusLAPISStandIn.entries.first { $0.accession == accession })
        XCTAssertEqual(try String(contentsOf: kept, encoding: .utf8), PathoplexusLAPISStandIn.fasta(of: held), "the kept file is what the server sent")

        // The input is the server's FASTA under Pathoplexus's own address, not the origin that answered.
        let input = try XCTUnwrap(
            envelope.steps.flatMap(\.inputs).first { $0.path.contains("unalignedNucleotideSequences") }, "the record lists no fetched input")
        XCTAssertTrue(input.path.hasPrefix("https://lapis.pathoplexus.org/"), input.path)
        XCTAssertEqual(input.checksumSHA256, try ProvenanceFileHasher.sha256(of: kept))

        try Self.assertPathoplexusRecord(in: envelope, entry: held.accession)
        try Self.assertEachOutputHasItsDigest(envelope)
        XCTAssertTrue(envelope.outputs.contains { $0.path.hasSuffix("sources/record.fasta") }, "the kept FASTA is an output")
    }

    /// The `pathoplexusRecord` entry names the accession as Pathoplexus resolved it, with its version.
    private static func assertPathoplexusRecord(in envelope: ProvenanceEnvelope, entry accession: String) throws {
        XCTAssertEqual(dictionaryEntry("pathoplexusRecord", "accession", in: envelope), accession)
        XCTAssertEqual(dictionaryEntry("pathoplexusRecord", "accessionVersion", in: envelope), accession + ".1")
        XCTAssertEqual(dictionaryEntry("pathoplexusRecord", "organism", in: envelope), PathoplexusLAPISStandIn.organism)
        XCTAssertEqual(dictionaryEntry("pathoplexusRecord", "dataUseTerms", in: envelope), "OPEN")
    }

    /// B-5. The record lists outputs, each of which exists with the digest it states.
    private static func assertEachOutputHasItsDigest(_ envelope: ProvenanceEnvelope) throws {
        XCTAssertFalse(envelope.outputs.isEmpty)
        for output in envelope.outputs {
            let url = URL(fileURLWithPath: output.path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), output.path)
            let stated = try XCTUnwrap(output.checksumSHA256, output.path)
            XCTAssertEqual(try ProvenanceFileHasher.sha256(of: url), stated, output.path)
        }
    }

    private static func dictionary(_ key: String, in envelope: ProvenanceEnvelope) throws -> [String: ParameterValue] {
        guard case let .dictionary(entry)? = envelope.options.resolvedDefaults[key] else {
            XCTFail("The record names no \(key): \(envelope.options.resolvedDefaults.keys.sorted())")
            throw CocoaError(.fileReadCorruptFile)
        }
        return entry
    }

    private static func dictionaryEntry(_ key: String, _ field: String, in envelope: ProvenanceEnvelope) -> String? {
        guard case let .dictionary(entry)? = envelope.options.resolvedDefaults[key] else { return nil }
        return entry[field]?.stringValue
    }

    private static func listing(of entry: [String: ParameterValue]) throws -> URL {
        guard case let .array(listings)? = entry["listingFiles"], listings.count == 1, case let .file(listing)? = listings.first else {
            XCTFail("The entry lists one kept file: \(String(describing: entry["listingFiles"]))")
            throw CocoaError(.fileReadCorruptFile)
        }
        return listing
    }

    // MARK: - The run

    private struct CLIRun {
        let status: Int32?
        let detail: String
        let stdout: String
        let work: URL

        func onlyBundle() throws -> URL {
            let names = try FileManager.default.contentsOfDirectory(atPath: work.path).filter { $0.hasSuffix(".lungfishref") }
            XCTAssertEqual(names.count, 1, "\(names)")
            return work.appendingPathComponent(try XCTUnwrap(names.first), isDirectory: true)
        }
    }

    /// Runs the built CLI on `fetch pathoplexus <accession> --organism <stand-in organism> --output-dir <folder>
    /// --format json`, with both stand-ins named in its environment and no NCBI key.
    private func fetch(_ accession: String) async throws -> CLIRun {
        do {
            try await GenBankDownloadBundleBuilder(ncbiService: NCBIService(apiKey: nil, environment: [:])).validateTools()
        } catch {
            try ToolAvailability.skipOrFail("Managed bgzip and samtools are required: \(error)")
        }
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH")
        let root = try TestTempDirectory.make(prefix: "fetch-pathoplexus-fetched-record")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let ncbi = try await NCBIGenomeStandIn.start(servingIn: root.appendingPathComponent("served", isDirectory: true))
        defer { ncbi.stop() }
        let lapis = try PathoplexusLAPISStandIn.start()
        defer { lapis.stop() }
        let work = root.appendingPathComponent("work", isDirectory: true)
        let run = await RouteParityHarness.runCLI(
            cli,
            arguments: [
                "fetch", "pathoplexus", accession, "--organism", PathoplexusLAPISStandIn.organism,
                "--output-dir", work.path, "--format", "json",
            ],
            timeout: .seconds(120),
            environment: [
                NCBIServiceEndpoints.standInOriginVariable: ncbi.baseURL.absoluteString,
                PathoplexusServiceEndpoints.standInOriginVariable: lapis.baseURL.absoluteString,
                "NCBI_API_KEY": "",
            ])
        return CLIRun(status: run.status, detail: run.detail, stdout: run.stdout, work: work)
    }
}
