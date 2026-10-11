// AnalysisToolRunsToolsTests.swift - The managed tools each analysis kind runs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.7, lane B5. A descriptor lists the managed tools its kind's pipeline launches and records as steps.
// The table below is the list of every kind, pinned in one place so a change to it is a decision. Workflow
// holds the ids to the managed tool lock and the version probe table (AnalysisRunsToolsAgreementTests).

import XCTest
@testable import LungfishIO

final class AnalysisToolRunsToolsTests: XCTestCase {
    /// Lock ids by analysis id. The evidence for each row is the step the kind's pipeline records.
    private static let expectedRunsTools: [String: [String]] = [
        // Classification. The Kraken2 pipeline records kraken2 and bracken steps. EsViritu records its own.
        "esviritu": ["esviritu"],
        "kraken2": ["kraken2", "bracken"],
        "taxtriage": ["nextflow"],
        // Mapping. The mapping pipeline records the mapper and the samtools view, sort, index and flagstat steps.
        "minimap2": ["minimap2", "samtools"],
        "bwa-mem2": ["bwa-mem2", "samtools"],
        "bowtie2": ["bowtie2", "samtools"],
        "bbmap": ["bbtools", "samtools"],
        // Assembly. The assembly pipeline records the assembler only.
        "spades": ["spades"],
        "megahit": ["megahit"],
        "skesa": ["skesa"],
        "flye": ["flye"],
        "hifiasm": ["hifiasm"],
        // Imported results run nothing.
        "naomgs": [],
        "nvd": [],
        "cz-id": [],
        "mafft": ["mafft"],
        // ONT genotyping runs four tools. The Illumina mode adds bbmerge from bbtools.
        "ont-genotyping": ["minimap2", "samtools", "pysam", "openpyxl"],
        "illumina-amplicon-genotyping": ["bbtools", "minimap2", "samtools", "pysam", "openpyxl"],
        "ont-sample-bundle-genotyping": ["minimap2", "samtools", "pysam", "openpyxl"],
        "viralrecon": ["nextflow"],
        // Primer order is built-in code, and pbAA runs in a container.
        "primer-order": [],
        "pbaa": [],
        // The full-length MHC pipeline records savont, blastn, the cohort minimap2 and samtools, and the workbook.
        "savont": ["savont", "blast", "minimap2", "samtools", "openpyxl"],
    ]

    private func runsTools(_ raw: String) throws -> [String] {
        try XCTUnwrap(AnalysisToolRegistry.descriptor(forRawID: raw), raw).runsTools.map(\.rawValue)
    }

    func testEveryKindHasARowInThePinnedTable() {
        XCTAssertEqual(
            Set(AnalysisToolRegistry.all.map { $0.id.rawValue }), Set(Self.expectedRunsTools.keys),
            "a new analysis kind needs a row, even an empty one")
    }

    func testEachKindListsTheToolsOfThePinnedTable() throws {
        for (raw, expected) in Self.expectedRunsTools {
            XCTAssertEqual(try runsTools(raw), expected, raw)
        }
    }

    func testOntGenotypingRunsItsFourTools() throws {
        XCTAssertEqual(try runsTools("ont-genotyping"), ["minimap2", "samtools", "pysam", "openpyxl"])
        XCTAssertEqual(AnalysisToolRegistry.descriptor(for: .ontGenotyping)?.runsTools.count, 4)
    }

    func testPrimerOrderAndTheKindsThatRunNothingListNoTool() throws {
        for raw in ["primer-order", "pbaa", "naomgs", "nvd", "cz-id"] {
            XCTAssertEqual(try runsTools(raw), [], raw)
        }
    }

    func testAKindProvisionedWithAManagedToolListsIt() {
        for descriptor in AnalysisToolRegistry.all {
            if case .managedTool(let tool) = descriptor.provisioning {
                XCTAssertTrue(descriptor.runsTools.contains(tool), descriptor.id.rawValue)
            }
        }
    }

    func testNoKindListsAToolTwice() {
        for descriptor in AnalysisToolRegistry.all {
            XCTAssertEqual(
                descriptor.runsTools.count, Set(descriptor.runsTools).count, descriptor.id.rawValue)
        }
    }

    // MARK: - The default

    func testTheListDefaultsToTheProvisionedTool() {
        let managed = AnalysisToolDescriptor(
            id: AnalysisToolID(rawValue: "demo"), displayName: "Demo", sidebarSymbolName: nil,
            provisioning: .managedTool(ManagedToolID(rawValue: "demo-tool")))
        XCTAssertEqual(managed.runsTools, [ManagedToolID(rawValue: "demo-tool")])

        for provisioning: AnalysisToolProvisioning in [.lockedPipeline("demo"), .container, .importedResult, .builtIn] {
            let descriptor = AnalysisToolDescriptor(
                id: AnalysisToolID(rawValue: "demo"), displayName: "Demo", sidebarSymbolName: nil,
                provisioning: provisioning)
            XCTAssertEqual(descriptor.runsTools, [], "\(provisioning)")
        }
    }

    func testAGivenListWinsOverTheProvisionedTool() {
        let tools = [ManagedToolID(rawValue: "a"), ManagedToolID(rawValue: "b")]
        let listed = AnalysisToolDescriptor(
            id: AnalysisToolID(rawValue: "demo"), displayName: "Demo", sidebarSymbolName: nil,
            runsTools: tools, provisioning: .managedTool(ManagedToolID(rawValue: "demo-tool")))
        XCTAssertEqual(listed.runsTools, tools)

        let none = AnalysisToolDescriptor(
            id: AnalysisToolID(rawValue: "demo"), displayName: "Demo", sidebarSymbolName: nil,
            runsTools: [], provisioning: .managedTool(ManagedToolID(rawValue: "demo-tool")))
        XCTAssertEqual(none.runsTools, [])
    }
}
