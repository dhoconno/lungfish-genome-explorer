// ImportVCFSIGTERMTests.swift - What SIGTERM does to import vcf while it attaches to a bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.07 (A64) M1, QA 1. The app's Cancel sends SIGTERM to the command it runs and gives it
// `operationGrace`. This is the pin at the base, where `import vcf` has no handler: the signal ends the command
// at once, the private staging folder under `variants/` stays, no track is added and no cancelled record is
// written. The command is held at work by a VCF of 400,000 records on the fixture's one chromosome.

import Darwin
import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

final class ImportVCFSIGTERMTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "import-vcf-sigterm")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    func testSIGTERMWhileAttachingEndsTheCommandBySignalAndLeavesItsStaging() async throws {
        let (project, bundle) = try Self.makeProject(in: root)
        let vcf = try Self.largeVCF(in: root, records: 400_000)
        let run = try CLISIGTERMHarness.launchCLI(
            ["import", "vcf", vcf.path, "--output-dir", bundle.path, "--format", "json"],
            workingDirectory: root,
            testClass: Self.self
        )
        defer { run.stop() }
        let variants = bundle.appendingPathComponent("variants", isDirectory: true)
        let started = await waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(10)) {
            !Self.stagingFolders(in: variants).isEmpty
        }
        XCTAssertTrue(started, "the command never began its staging folder")
        let stop = await CLISIGTERMHarness.cancel(run)
        XCTAssertEqual(stop.termination, .signaled(signal: SIGTERM), stop.diagnostics)
        XCTAssertEqual(Self.stagingFolders(in: variants).count, 1, "the staging folder stays at the base")
        XCTAssertEqual(try BundleManifest.load(from: bundle).variants, [], "no track is added")
        XCTAssertNil(ProvenanceRecorder.loadEnvelope(from: project), "no cancelled record at the base")
    }

    // MARK: - Fixture

    /// A project with a manifest-only reference bundle named for the fixture's chromosome.
    static func makeProject(in root: URL) throws -> (project: URL, bundle: URL) {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let bundle = project.appendingPathComponent("Reference.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try BundleManifest(
            name: "Reference",
            identifier: "bundle.reference",
            source: SourceInfo(organism: "Virus", assembly: "MT192765.1", database: "Test")
        ).save(to: bundle)
        return (project, bundle)
    }

    /// A VCF of `records` single-base variants on MT192765.1, each with INFO fields, so the import runs for seconds.
    static func largeVCF(in root: URL, records: Int) throws -> URL {
        let url = root.appendingPathComponent("large.vcf")
        var text = """
        ##fileformat=VCFv4.2
        ##contig=<ID=MT192765.1,length=29829>
        ##INFO=<ID=DP,Number=1,Type=Integer,Description="Depth">
        ##INFO=<ID=AF,Number=A,Type=Float,Description="Allele frequency">
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO

        """
        text.reserveCapacity(records * 48)
        let bases = ["A", "C", "G", "T"]
        for index in 0..<records {
            let position = index * 29_000 / records + 1
            let ref = bases[index % 4], alt = bases[(index + 1) % 4]
            text += "MT192765.1\t\(position)\t.\t\(ref)\t\(alt)\t60\tPASS\tDP=\(index % 500);AF=0.5\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func stagingFolders(in variants: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: variants.path)) ?? []).filter { $0.hasPrefix(".import-") }
    }
}
