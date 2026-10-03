// MappingReadClassInferenceTests.swift - Read classes that mapping, assembly and Viral Recon take from the shared detector
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow
import LungfishIO
import LungfishTestSupport

/// Before platform inference, the dorado SAM-tag header read as Illumina
/// (seven or more colon fields), so mapping preselected minimap2 `sr`,
/// assembly offered SPAdes, MEGAHIT and SKESA, and Viral Recon ran the
/// Illumina pipeline on nanopore reads.
final class MappingReadClassInferenceTests: XCTestCase {

    func testDoradoSAMTagReadsMapAsNanopore() {
        let url = PlatformHeaderFixtures.url("ont-dorado-samtags-tab.fastq")
        let readClass = MappingReadClass.detect(fromInputURL: url)
        XCTAssertEqual(readClass, .ontReads)
        XCTAssertEqual(MappingMode.preferredMode(for: .minimap2, readClass: readClass), .minimap2MapONT)
    }

    func testSubreadsMapAsCLRAndCCSAsHiFi() {
        XCTAssertEqual(MappingReadClass.detect(fromInputURL: PlatformHeaderFixtures.url("pacbio-subreads.fastq")), .pacBioCLR)
        XCTAssertEqual(
            MappingMode.preferredMode(for: .minimap2, readClass: .pacBioCLR),
            .minimap2MapPB
        )
        XCTAssertEqual(MappingReadClass.detect(fromInputURL: PlatformHeaderFixtures.url("pacbio-revio-ccs.fastq")), .pacBioHiFi)
    }

    func testRevioAssemblesWithHifiasmOrFlye() {
        let readType = AssemblyReadType.detect(fromInputURL: PlatformHeaderFixtures.url("pacbio-revio-ccs.fastq"))
        XCTAssertEqual(readType, .pacBioHiFi)
        XCTAssertEqual(readType.map(AssemblyCompatibility.supportedTools(for:)), [.hifiasm, .flye])
        XCTAssertEqual(AssemblyCompatibility.defaultTool(for: readType), .hifiasm)
    }

    func testElementAndMGILabelsKeepTheShortReadClass() {
        XCTAssertEqual(MappingReadClass.detect(from: .element), .illuminaShortReads)
        XCTAssertEqual(MappingReadClass.detect(from: .mgi), .illuminaShortReads)
        XCTAssertEqual(AssemblyReadType.detect(from: .element), .illuminaShortReads)
        XCTAssertEqual(AssemblyReadType.detect(from: .mgi), .illuminaShortReads)
    }

    func testUnknownPlatformReadsDefaultFromReadLength() {
        XCTAssertNil(MappingReadClass.detect(fromInputURL: PlatformHeaderFixtures.url("sra-renamed-long.fastq")))
        XCTAssertEqual(MappingReadClass.lengthDefault(forInputURL: PlatformHeaderFixtures.url("sra-renamed-long.fastq")), .ontReads)
        XCTAssertEqual(MappingReadClass.lengthDefault(forInputURL: PlatformHeaderFixtures.url("sra-renamed-short.fastq")), .illuminaShortReads)
        XCTAssertEqual(AssemblyReadType.lengthDefault(forInputURL: PlatformHeaderFixtures.url("sra-renamed-long.fastq")), .ontReads)
    }

    func testAnUnknownBundleMapsWithTheLengthDefaultAndNoRefusal() throws {
        let fixture = try PlatformMappingFixture()
        defer { fixture.cleanup() }
        let reads = try PlatformHeaderFixtures.copy("sra-renamed-long.fastq", to: fixture.root)
        let bundle = try fixture.wrapInBundle(fastqURL: reads, bundleName: "unknown-long")
        let primary = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundle))
        FASTQMetadataStore.save(PersistedFASTQMetadata(sequencingPlatform: .unknown), for: primary)

        let readClass = MappingReadClass.detect(fromInputURL: bundle) ?? MappingReadClass.lengthDefault(forInputURL: bundle)
        XCTAssertEqual(MappingMode.preferredMode(for: .minimap2, readClass: readClass), .minimap2MapONT)

        for mode in [MappingMode.minimap2MapONT, .defaultShortRead] {
            let request = MappingRunRequest(
                tool: .minimap2, modeID: mode.id, inputFASTQURLs: [bundle],
                referenceFASTAURL: fixture.referenceURL, outputDirectory: fixture.root.appendingPathComponent("out"),
                sampleName: "sample", pairedEnd: false, threads: 1
            )
            let warnings = try ManagedMappingPipeline.validateCompatibility(for: request)
            XCTAssertTrue(warnings.contains(PlatformInference.untunedDefaultsNote), "\(mode): \(warnings)")
        }
    }

    func testAnExplicitShortReadPresetOnNanoporeReadsRunsWithAWarning() throws {
        let fixture = try PlatformMappingFixture()
        defer { fixture.cleanup() }
        let reads = try PlatformHeaderFixtures.copy("ont-dorado-samtags-tab.fastq", to: fixture.root)
        for (tool, mode) in [(MappingTool.minimap2, MappingMode.defaultShortRead), (.bowtie2, .defaultShortRead)] {
            let request = MappingRunRequest(
                tool: tool, modeID: mode.id, inputFASTQURLs: [reads],
                referenceFASTAURL: fixture.referenceURL, outputDirectory: fixture.root.appendingPathComponent("out"),
                sampleName: "sample", pairedEnd: false, threads: 1
            )
            let warnings = try ManagedMappingPipeline.validateCompatibility(for: request)
            XCTAssertEqual(warnings.count, 1, "\(tool)")
            XCTAssertTrue(warnings[0].contains("ONT reads"), warnings[0])
        }
    }

    func testViralReconRunsNanoporeForDoradoReadsAndDefaultsUnknownReadsByLength() throws {
        let temp = try TestTempDirectory.make(prefix: "viralrecon-platform")
        defer { TestTempDirectory.cleanup(temp) }
        let dorado = try ViralReconWorkflowTestFixtures.writeFastqBundle(
            named: "Dorado",
            in: temp,
            fastqText: try String(contentsOf: PlatformHeaderFixtures.url("ont-dorado-samtags-tab.fastq"), encoding: .utf8),
            metadataCSV: nil,
            sidecarJSON: nil
        )
        XCTAssertEqual(try ViralReconInputResolver.resolveInputs(from: [dorado]).first?.platform, .nanopore)

        let unknownLong = try ViralReconWorkflowTestFixtures.writeFastqBundle(
            named: "UnknownLong",
            in: temp,
            fastqText: try String(contentsOf: PlatformHeaderFixtures.url("sra-renamed-long.fastq"), encoding: .utf8),
            metadataCSV: nil,
            sidecarJSON: #"{"sequencingPlatform":"unknown"}"#
        )
        XCTAssertEqual(try ViralReconInputResolver.resolveInputs(from: [unknownLong]).first?.platform, .nanopore)
    }
}

private struct PlatformMappingFixture {
    let root: URL
    let referenceURL: URL

    init() throws {
        root = try TestTempDirectory.make(prefix: "platform-mapping")
        referenceURL = root.appendingPathComponent("reference.fasta")
        try ">ref\nACGTACGTACGTACGT\n".write(to: referenceURL, atomically: true, encoding: .utf8)
    }

    func cleanup() {
        TestTempDirectory.cleanup(root)
    }

    func wrapInBundle(fastqURL: URL, bundleName: String) throws -> URL {
        let bundleURL = root.appendingPathComponent("\(bundleName).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fastqURL, to: bundleURL.appendingPathComponent(fastqURL.lastPathComponent))
        return bundleURL
    }
}
