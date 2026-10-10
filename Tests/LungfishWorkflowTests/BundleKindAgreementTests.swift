// BundleKindAgreementTests.swift - The bundle kind registry against what LungfishWorkflow declares
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The registry lives in LungfishIO, which cannot see LungfishWorkflow. A run bundle, a workflow
// package and a CZ ID import are named by constants and writers on this side, so this suite checks
// that the registry agrees with them, and that every analysis the registry names as a producer is
// one the AnalysisToolRegistry knows.

import Foundation
import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow

final class BundleKindAgreementTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("bundle-kind-agreement-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch {
            try? FileManager.default.removeItem(at: scratch)
        }
        try super.tearDownWithError()
    }

    private func descriptor(_ id: BundleKindID, file: StaticString = #filePath, line: UInt = #line) throws -> BundleKindDescriptor {
        try XCTUnwrap(BundleKindRegistry.descriptor(for: id), "No descriptor for \(id)", file: file, line: line)
    }

    // MARK: - Analyses

    func testEveryProducerNamedByTheRegistryIsAKnownAnalysis() throws {
        let producers = BundleKindRegistry.all.compactMap { descriptor in descriptor.producedBy.map { (descriptor.id, $0) } }
        XCTAssertEqual(producers.map(\.0), [.multipleSequenceAlignment, .genotypeResult, .czIdResult])
        for (kind, analysis) in producers {
            XCTAssertNotNil(AnalysisToolRegistry.descriptor(for: analysis), "\(kind) names the unknown analysis \(analysis)")
        }
    }

    func testAnalysisAndKindShareTheSidebarSymbolWhereOneKindIsTheWholeResult() throws {
        // MAFFT writes only alignments, ONT genotyping only genotype results and CZ ID only CZ ID imports.
        // The analysis row and the bundle row use one symbol today, so a change to one is a change to both.
        for descriptor in BundleKindRegistry.all {
            guard let analysis = descriptor.producedBy else { continue }
            XCTAssertEqual(
                AnalysisToolRegistry.descriptor(for: analysis)?.sidebarSymbolName,
                descriptor.sidebarSymbolName,
                "\(descriptor.id) and \(analysis)"
            )
        }
    }

    // MARK: - Constants and writers on the Workflow side

    func testRunBundleAndWorkflowPackageConstantsEqualTheRegistry() throws {
        let run = try descriptor(.workflowRun)
        XCTAssertEqual(run.folderExtensions, [NFCoreRunBundleStore.directoryExtension])
        XCTAssertEqual(run.folderExtensions, [LocalWorkflowRunBundleStore.directoryExtension])
        let package = try descriptor(.workflowPackage)
        XCTAssertEqual(package.folderExtensions, [WorkflowPackageValidator.packageExtension])
        XCTAssertEqual(package.manifestFileName, WorkflowPackageValidator.manifestFilename)
    }

    func testTheRunBundleStoreWritesTheRegistryManifestName() throws {
        let workflow = try XCTUnwrap(NFCoreSupportedWorkflowCatalog.workflow(named: "viralrecon"))
        let manifest = NFCoreRunBundleManifest(
            workflow: workflow,
            version: "2.7.0",
            executor: .docker,
            params: ["input": "samplesheet.csv"],
            outputDirectoryName: "results"
        )
        let run = try descriptor(.workflowRun)
        let bundle = scratch.appendingPathComponent("probe.\(try XCTUnwrap(run.folderExtensions.first))", isDirectory: true)
        try NFCoreRunBundleStore.write(manifest, to: bundle)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appendingPathComponent(try XCTUnwrap(run.manifestFileName)).path))
    }

    func testTheCzIdConverterWritesTheRegistryManifestName() throws {
        let columns = ["tax_id", "taxon_name", "rank", "nt_read_count", "nt_rpm", "sample_name"]
        let rows: [[String]] = [
            ["1", "root", "root", "1200", "1000000", "Sample-CZ-001"],
            ["9606", "Homo sapiens", "species", "100", "83333.33", "Sample-CZ-001"],
        ]
        let report = scratch.appendingPathComponent("taxon_report.tsv")
        let text = ([columns] + rows).map { $0.joined(separator: "\t") }.joined(separator: "\n") + "\n"
        try text.write(to: report, atomically: true, encoding: .utf8)

        let tax = try descriptor(.czIdResult)
        let output = scratch.appendingPathComponent("probe.\(try XCTUnwrap(tax.folderExtensions.first))", isDirectory: true)
        _ = try CzIdDataConverter.convertTaxonReport(at: report, outputDirectory: output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent(try XCTUnwrap(tax.manifestFileName)).path))
    }

    func testSidecarNamesEqualTheProvenanceWriterConstants() {
        XCTAssertEqual(BundleKindDescriptor.SidecarNaming.rootRecordFileName, ProvenanceWriter.provenanceFilename)
        XCTAssertEqual(BundleKindDescriptor.SidecarNaming.layoutFolderName, ProvenanceWriter.bundleProvenanceDirectoryName)
    }

    func testTheProvenanceWriterTreatsEveryRegistryExtensionAsABundleFolder() {
        // ProvenanceWriter.isBundleDirectory accepts any lungfish prefix, so the layout folder is written
        // for every kind, the project and the frozen exceptions included.
        for descriptor in BundleKindRegistry.all {
            for ext in descriptor.folderExtensions {
                XCTAssertTrue(ProvenanceWriter.isBundleDirectory(scratch.appendingPathComponent("probe.\(ext)")), ext)
                XCTAssertTrue(ProvenanceWriter.isBundleDirectory(scratch.appendingPathComponent("probe.\(ext.uppercased())")), ext)
            }
        }
        XCTAssertFalse(ProvenanceWriter.isBundleDirectory(scratch.appendingPathComponent("probe.zlungfishref")))
    }

    func testWorkflowPackageInputTypesNameThreeKindsNothingCreates() {
        // WorkflowPackageBundleType is persisted in package manifests, so its raw values stay as they are.
        // Four of its seven values are registry extensions. The other three name kinds that do not exist.
        let unknown = WorkflowPackageBundleType.allCases.filter {
            BundleKindRegistry.descriptor(forExactExtension: $0.rawValue) == nil
        }
        XCTAssertEqual(unknown, [.lungfishbam, .lungfishvcf, .lungfishproject])
        XCTAssertEqual(WorkflowPackageBundleType.allCases.count - unknown.count, 4)
    }
}
