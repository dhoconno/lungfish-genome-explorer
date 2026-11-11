// FASTQOperationOutputImporterTests.swift - An operation's output bundle keeps the platform its source records
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 4 close, lane DERIVED-PLATFORM, BIO ruling DEMUX-C-BIO (S2). The importer that makes the bundle of each
// operation (subsample, trim, filter, any derivative) wrote a sidecar with no sequencing platform and no assembly
// read type, although its source records both. The Demultiplex dialog then defaulted to TruSeq Single Index Set A on
// ONT reads, and an ONT subset of reads 600 bases or shorter got the Illumina mapping preset and assembly. These
// tests import a subsample of an ONT bundle whose read names match no platform, so only the record can say ONT.

import Darwin
import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class FASTQOperationOutputImporterTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        // The physical path (/private/var, not /var), which the input resolvers hand the CLI.
        let made = try TestTempDirectory.make(prefix: "fastq-importer-platform")
        let physical = try XCTUnwrap(realpath(made.path, nil))
        defer { free(physical) }
        root = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - Fixtures

    /// Eight reads of 300 to 550 bases whose names match no platform. By length alone they read as Illumina.
    private static let records: [(id: String, sequence: String)] = [300, 340, 380, 420, 460, 500, 520, 550]
        .enumerated().map { index, length in
            (id: "read_\(index)", sequence: String(String(repeating: "ACGTTGCA", count: length / 8 + 1).prefix(length)))
        }

    private var project: URL { root.appendingPathComponent("Project.lungfish", isDirectory: true) }

    /// An ONT bundle under the project's Imports. `recorded` false leaves its sidecar without a platform.
    private func makeSource(recorded: Bool) throws -> URL {
        let bundle = project.appendingPathComponent("Imports/ont-run.\(FASTQBundle.directoryExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let reads = bundle.appendingPathComponent("reads.fastq")
        try FASTQOperationTestHelper.writeFASTQ(records: Self.records, to: reads)
        if recorded {
            FASTQMetadataStore.save(
                PersistedFASTQMetadata(sequencingPlatform: .oxfordNanopore, assemblyReadType: .ontReads),
                for: reads
            )
        }
        return bundle
    }

    /// Imports the first `count` reads as the dialog imports the output of Subsample by Count on `source`, and
    /// returns the new bundle and its one file. Static, so a main-actor test can call it.
    private static func importSubsample(
        of source: URL,
        named name: String,
        count: Int,
        project: URL,
        work: URL
    ) async throws -> (bundle: URL, payload: URL) {
        let input = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: source))
        let staging = work.appendingPathComponent("work-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let staged = staging.appendingPathComponent("\(name).fastq")
        try FASTQOperationTestHelper.writeFASTQ(records: Array(records.prefix(count)), to: staged)
        try DialogRowStagedProvenance.write(
            argv: ["fixture-tool", input.path, "-o", staged.path],
            inputURL: input,
            outputURL: staged,
            in: staging
        )
        let writer = AppFASTQOutputBundleWriter(
            ingestor: DialogRowCopyingIngestor(),
            statisticsCalculator: AppFASTQOutputBundleWriter.swiftReaderStatisticsCalculator
        )
        let bundle = try await writer.importFASTQOutput(
            sourceURL: staged,
            bundleURL: project.appendingPathComponent("Analyses/\(name).\(FASTQBundle.directoryExtension)"),
            originalRequest: .derivative(request: .subsampleCount(count), inputURLs: [source], outputMode: .perInput),
            sourceInputURL: source
        )
        return (bundle, try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundle)))
    }

    // MARK: - Tests

    /// BIO's test. The subsample holds both fields, so Map, Assemble and Demultiplex read ONT. From the read
    /// lengths alone the same reads read as Illumina, and with no detected read type the dialog starts on the
    /// registry's first kit, TruSeq Single Index Set A.
    @MainActor
    func testDerivativeKeepsSourcePlatform() async throws {
        let source = try makeSource(recorded: true)
        let output = try await Self.importSubsample(
            of: source, named: "ont-run-subsampleCount", count: 4, project: project, work: root
        )

        let sidecar = try XCTUnwrap(FASTQMetadataStore.load(for: output.payload))
        XCTAssertEqual(sidecar.sequencingPlatform, .oxfordNanopore)
        XCTAssertEqual(sidecar.assemblyReadType, .ontReads)

        XCTAssertEqual(AssemblyReadType.lengthDefault(forInputURL: output.bundle), .illuminaShortReads)
        XCTAssertEqual(MappingReadClass.lengthDefault(forInputURL: output.bundle), .illuminaShortReads)
        XCTAssertEqual(AssemblyReadType.detect(fromInputURL: output.bundle), .ontReads)
        XCTAssertEqual(MappingReadClass.detect(fromInputURL: output.bundle), .ontReads)

        let detected = [AssemblyReadType.detect(fromInputURL: output.bundle)].compactMap { $0 }
        let defaultKit = try XCTUnwrap(BarcodeKitRegistry.kit(
            byID: FASTQOperationDialogState.defaultDemultiplexKitID(detectedReadTypes: detected)
        ))
        XCTAssertEqual(defaultKit.platform, .oxfordNanopore, "The Demultiplex dialog starts on \(defaultKit.displayName)")
        let ontKit = try XCTUnwrap(BarcodeKitRegistry.kit(
            byID: FASTQOperationDialogState.defaultDemultiplexKitID(detectedReadTypes: [.ontReads])
        ))
        XCTAssertEqual(ontKit.platform, .oxfordNanopore)
    }

    /// A bundle made by a build up to 12859 records no platform. A new operation on it reaches the record of the
    /// bundle it derives from, so the grandchild is recorded as ONT too.
    func testADerivativeOfABundleThatLostItsRecordKeepsTheRootsPlatform() async throws {
        let source = try makeSource(recorded: true)
        let child = try await Self.importSubsample(
            of: source, named: "ont-run-subsampleCount", count: 6, project: project, work: root
        )
        var stripped = try XCTUnwrap(FASTQMetadataStore.load(for: child.payload))
        stripped.sequencingPlatform = nil
        stripped.assemblyReadType = nil
        FASTQMetadataStore.save(stripped, for: child.payload)
        XCTAssertNil(FASTQMetadataStore.load(for: child.payload)?.sequencingPlatform)

        let grandchild = try await Self.importSubsample(
            of: child.bundle, named: "ont-run-subsampleCount-again", count: 3, project: project, work: root
        )

        let sidecar = try XCTUnwrap(FASTQMetadataStore.load(for: grandchild.payload))
        XCTAssertEqual(sidecar.sequencingPlatform, .oxfordNanopore)
        XCTAssertEqual(sidecar.assemblyReadType, .ontReads)
    }

    /// Nothing is invented. A source that records no platform anywhere leaves the output's record empty.
    func testAnOutputOfASourceWithoutAPlatformRecordsNone() async throws {
        let source = try makeSource(recorded: false)
        let output = try await Self.importSubsample(
            of: source, named: "ont-run-subsampleCount", count: 4, project: project, work: root
        )

        let sidecar = try XCTUnwrap(FASTQMetadataStore.load(for: output.payload))
        XCTAssertNil(sidecar.sequencingPlatform)
        XCTAssertNil(sidecar.assemblyReadType)
    }
}
