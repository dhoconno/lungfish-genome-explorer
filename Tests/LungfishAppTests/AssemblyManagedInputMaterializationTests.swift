// AssemblyManagedInputMaterializationTests.swift - managed assembly input materialization regressions
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishApp
import LungfishIO
import LungfishWorkflow

@MainActor
final class AssemblyManagedInputMaterializationTests: XCTestCase {

    func testManagedAssemblyRequestMaterializesVirtualDerivedFASTQBeforePipeline() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-managed-assembly-materialization-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let rootBundleURL = tempDir.appendingPathComponent("root.lungfishfastq", isDirectory: true)
        let rootFASTQURL = rootBundleURL.appendingPathComponent("root.fastq")
        let derivedBundleURL = tempDir.appendingPathComponent("derived.lungfishfastq", isDirectory: true)
        let materializedURL = tempDir.appendingPathComponent("materialized.fastq")
        try FileManager.default.createDirectory(at: rootBundleURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: derivedBundleURL, withIntermediateDirectories: true)
        try "@root\nACGT\n+\nIIII\n".write(to: rootFASTQURL, atomically: true, encoding: .utf8)
        try "root\n".write(
            to: derivedBundleURL.appendingPathComponent("read-ids.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "@root\nACGT\n+\nIIII\n".write(to: materializedURL, atomically: true, encoding: .utf8)

        let manifest = FASTQDerivedBundleManifest(
            name: "derived",
            parentBundleRelativePath: "../root.lungfishfastq",
            rootBundleRelativePath: "../root.lungfishfastq",
            rootFASTQFilename: "root.fastq",
            payload: .subset(readIDListFilename: "read-ids.txt"),
            lineage: [],
            operation: FASTQDerivativeOperation(kind: .searchText, query: "root"),
            cachedStatistics: .placeholder(readCount: 1, baseCount: 4),
            pairingMode: nil,
            sequenceFormat: .fastq
        )
        try FASTQBundle.saveDerivedManifest(manifest, in: derivedBundleURL)

        let request = AssemblyRunRequest(
            tool: .megahit,
            readType: .illuminaShortReads,
            inputURLs: [derivedBundleURL],
            projectName: "demo",
            outputDirectory: tempDir.appendingPathComponent("out", isDirectory: true),
            threads: 2
        )

        var materializedBundles: [URL] = []
        let resolved = try await AssemblyRunner.materializedManagedAssemblyRequest(
            from: request,
            tempDirectory: tempDir,
            materialize: { bundleURL, _, _ in
                materializedBundles.append(bundleURL.standardizedFileURL)
                return materializedURL
            }
        )

        XCTAssertEqual(resolved.inputURLs.map(\.standardizedFileURL), [materializedURL.standardizedFileURL])
        XCTAssertEqual(materializedBundles, [derivedBundleURL.standardizedFileURL])
        XCTAssertFalse(resolved.inputURLs.map(\.standardizedFileURL).contains(rootFASTQURL.standardizedFileURL))
    }

    func testManagedAssemblyRejectsLongReadTopologyBeforeMaterializingVirtualInput() async throws {
        let cases = [
            (tool: AssemblyTool.flye, readType: AssemblyReadType.ontReads),
            (tool: AssemblyTool.hifiasm, readType: AssemblyReadType.pacBioHiFi),
        ]

        for testCase in cases {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("app-managed-\(testCase.tool.rawValue)-topology-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let rootBundleURL = tempDir.appendingPathComponent("root.lungfishfastq", isDirectory: true)
            let rootFASTAURL = rootBundleURL.appendingPathComponent("root.fasta")
            let derivedBundleURL = tempDir.appendingPathComponent("derived.lungfishfastq", isDirectory: true)
            let secondInputURL = tempDir.appendingPathComponent("second.fasta")
            try FileManager.default.createDirectory(at: rootBundleURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: derivedBundleURL, withIntermediateDirectories: true)
            try ">read1\nACGT\n".write(to: rootFASTAURL, atomically: true, encoding: .utf8)
            try ">read2\nTGCA\n".write(to: secondInputURL, atomically: true, encoding: .utf8)
            try "read1\n".write(
                to: derivedBundleURL.appendingPathComponent("read-ids.txt"),
                atomically: true,
                encoding: .utf8
            )
            let manifest = FASTQDerivedBundleManifest(
                name: "derived",
                parentBundleRelativePath: "../root.lungfishfastq",
                rootBundleRelativePath: "../root.lungfishfastq",
                rootFASTQFilename: "root.fasta",
                payload: .subset(readIDListFilename: "read-ids.txt"),
                lineage: [],
                operation: FASTQDerivativeOperation(kind: .searchText, query: "read1"),
                cachedStatistics: .placeholder(readCount: 1, baseCount: 4),
                pairingMode: nil,
                sequenceFormat: .fasta
            )
            try FASTQBundle.saveDerivedManifest(manifest, in: derivedBundleURL)

            let outputDir = tempDir.appendingPathComponent("out", isDirectory: true)
            let request = AssemblyRunRequest(
                tool: testCase.tool,
                readType: testCase.readType,
                inputURLs: [derivedBundleURL, secondInputURL],
                projectName: "demo",
                outputDirectory: outputDir,
                threads: 2
            )
            var materializeCalled = false

            do {
                _ = try await AssemblyRunner.materializedManagedAssemblyRequest(
                    from: request,
                    tempDirectory: outputDir.appendingPathComponent(".lungfish-assembly-inputs", isDirectory: true),
                    materialize: { _, _, _ in
                        materializeCalled = true
                        return tempDir.appendingPathComponent("materialized.fasta")
                    }
                )
                XCTFail("Expected \(testCase.tool.rawValue) topology validation to fail before materialization")
            } catch {
                XCTAssertFalse(materializeCalled, "\(testCase.tool.rawValue) materializer should not be invoked")
                XCTAssertFalse(
                    FileManager.default.fileExists(
                        atPath: outputDir.appendingPathComponent(".lungfish-assembly-inputs", isDirectory: true).path
                    ),
                    "\(testCase.tool.rawValue) should not create assembly materialization directory"
                )
            }
        }
    }

    func testManagedAssemblyRejectsDemuxGroupBeforeResolvingRootPayload() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-managed-demux-group-no-materialize-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let rootBundleURL = tempDir.appendingPathComponent("root.lungfishfastq", isDirectory: true)
        let rootFASTQURL = rootBundleURL.appendingPathComponent("root.fastq")
        let groupBundleURL = tempDir.appendingPathComponent("group.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: rootBundleURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: groupBundleURL, withIntermediateDirectories: true)
        try "@root\nACGT\n+\nIIII\n".write(to: rootFASTQURL, atomically: true, encoding: .utf8)

        let manifest = FASTQDerivedBundleManifest(
            name: "group",
            parentBundleRelativePath: "../root.lungfishfastq",
            rootBundleRelativePath: "../root.lungfishfastq",
            rootFASTQFilename: "root.fastq",
            payload: .demuxGroup(barcodeCount: 2),
            lineage: [],
            operation: FASTQDerivativeOperation(kind: .demultiplex),
            cachedStatistics: .placeholder(readCount: 1, baseCount: 4),
            pairingMode: nil,
            sequenceFormat: .fastq
        )
        try FASTQBundle.saveDerivedManifest(manifest, in: groupBundleURL)

        let outputDir = tempDir.appendingPathComponent("out", isDirectory: true)
        let request = AssemblyRunRequest(
            tool: .megahit,
            readType: .illuminaShortReads,
            inputURLs: [groupBundleURL],
            projectName: "demo",
            outputDirectory: outputDir,
            threads: 2
        )
        var materializeCalled = false

        do {
            let result = try await AssemblyRunner.materializedManagedAssemblyRequest(
                from: request,
                tempDirectory: outputDir.appendingPathComponent(".lungfish-assembly-inputs", isDirectory: true),
                materialize: { _, _, _ in
                    materializeCalled = true
                    return tempDir.appendingPathComponent("materialized.fastq")
                }
            )
            XCTFail("Expected demux-group input to fail before resolving \(result.inputURLs)")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Demultiplexed group bundles are container-only"))
        }

        XCTAssertFalse(materializeCalled)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outputDir.appendingPathComponent(".lungfish-assembly-inputs", isDirectory: true).path
            )
        )
    }

    func testManagedAssemblyRejectsIncompatibleReadTypeBeforeMaterializingVirtualInput() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-managed-incompatible-no-materialize-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let rootBundleURL = tempDir.appendingPathComponent("root.lungfishfastq", isDirectory: true)
        let rootFASTQURL = rootBundleURL.appendingPathComponent("root.fastq")
        let derivedBundleURL = tempDir.appendingPathComponent("derived.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: rootBundleURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: derivedBundleURL, withIntermediateDirectories: true)
        try "@root\nACGT\n+\nIIII\n".write(to: rootFASTQURL, atomically: true, encoding: .utf8)
        try "root\t0\t4\n".write(
            to: derivedBundleURL.appendingPathComponent("trim-positions.tsv"),
            atomically: true,
            encoding: .utf8
        )
        let manifest = FASTQDerivedBundleManifest(
            name: "derived",
            parentBundleRelativePath: "../root.lungfishfastq",
            rootBundleRelativePath: "../root.lungfishfastq",
            rootFASTQFilename: "root.fastq",
            payload: .trim(trimPositionFilename: "trim-positions.tsv"),
            lineage: [],
            operation: FASTQDerivativeOperation(kind: .qualityTrim, qualityThreshold: 20),
            cachedStatistics: .placeholder(readCount: 1, baseCount: 4),
            pairingMode: nil,
            sequenceFormat: .fastq
        )
        try FASTQBundle.saveDerivedManifest(manifest, in: derivedBundleURL)

        let outputDir = tempDir.appendingPathComponent("out", isDirectory: true)
        let request = AssemblyRunRequest(
            tool: .flye,
            readType: .illuminaShortReads,
            inputURLs: [derivedBundleURL],
            projectName: "demo",
            outputDirectory: outputDir,
            threads: 2
        )
        var materializeCalled = false

        do {
            _ = try await AssemblyRunner.materializedManagedAssemblyRequest(
                from: request,
                tempDirectory: outputDir.appendingPathComponent(".lungfish-assembly-inputs", isDirectory: true),
                materialize: { _, _, _ in
                    materializeCalled = true
                    return tempDir.appendingPathComponent("materialized.fastq")
                }
            )
            XCTFail("Expected incompatible assembly selection to fail before materialization")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Flye is not available for Illumina short reads"))
        }

        XCTAssertFalse(materializeCalled)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outputDir.appendingPathComponent(".lungfish-assembly-inputs", isDirectory: true).path
            )
        )
    }

    func testManagedAssemblyInputRecordsPreserveOriginalVirtualBundleLineage() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-managed-assembly-provenance-lineage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let rootBundleURL = tempDir.appendingPathComponent("root.lungfishfastq", isDirectory: true)
        let rootFASTQURL = rootBundleURL.appendingPathComponent("root.fastq")
        let derivedBundleURL = tempDir.appendingPathComponent("derived.lungfishfastq", isDirectory: true)
        let materializedURL = tempDir
            .appendingPathComponent("out", isDirectory: true)
            .appendingPathComponent(".lungfish-assembly-inputs", isDirectory: true)
            .appendingPathComponent("materialized.fastq")
        try FileManager.default.createDirectory(at: rootBundleURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: derivedBundleURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: materializedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "@root\nACGT\n+\nIIII\n".write(to: rootFASTQURL, atomically: true, encoding: .utf8)
        try "root\n".write(
            to: derivedBundleURL.appendingPathComponent("read-ids.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "@root\nACGT\n+\nIIII\n".write(to: materializedURL, atomically: true, encoding: .utf8)

        let manifest = FASTQDerivedBundleManifest(
            name: "derived",
            parentBundleRelativePath: "../root.lungfishfastq",
            rootBundleRelativePath: "../root.lungfishfastq",
            rootFASTQFilename: "root.fastq",
            payload: .subset(readIDListFilename: "read-ids.txt"),
            lineage: [],
            operation: FASTQDerivativeOperation(kind: .searchText, query: "root"),
            cachedStatistics: .placeholder(readCount: 1, baseCount: 4),
            pairingMode: nil,
            sequenceFormat: .fastq
        )
        try FASTQBundle.saveDerivedManifest(manifest, in: derivedBundleURL)

        let originalRequest = AssemblyRunRequest(
            tool: .megahit,
            readType: .illuminaShortReads,
            inputURLs: [derivedBundleURL],
            projectName: "demo",
            outputDirectory: tempDir.appendingPathComponent("out", isDirectory: true),
            threads: 2
        )
        let executionRequest = AssemblyRunRequest(
            tool: originalRequest.tool,
            readType: originalRequest.readType,
            inputURLs: [materializedURL],
            projectName: originalRequest.projectName,
            outputDirectory: originalRequest.outputDirectory,
            threads: originalRequest.threads
        )

        let records = AssemblyRunner.managedAssemblyInputRecords(
            originalRequest: originalRequest,
            executionRequest: executionRequest
        )

        XCTAssertTrue(records.contains {
            $0.originalPath == derivedBundleURL.path && $0.sha256 != nil && $0.sizeBytes > 0
        })
        XCTAssertTrue(records.contains {
            $0.originalPath == rootFASTQURL.path && $0.sha256 != nil && $0.sizeBytes > 0
        })
        XCTAssertTrue(records.contains {
            $0.originalPath == materializedURL.path && $0.sha256 != nil && $0.sizeBytes > 0
        })
    }

    func testManagedAssemblyProvenanceRecordsMaterializationStepTiming() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-managed-assembly-provenance-step-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let rootBundleURL = tempDir.appendingPathComponent("root.lungfishfastq", isDirectory: true)
        let rootFASTQURL = rootBundleURL.appendingPathComponent("root.fastq")
        let derivedBundleURL = tempDir.appendingPathComponent("derived.lungfishfastq", isDirectory: true)
        let outputDir = tempDir.appendingPathComponent("out", isDirectory: true)
        let materializedURL = outputDir
            .appendingPathComponent(".lungfish-assembly-inputs", isDirectory: true)
            .appendingPathComponent("materialized.fastq")
        try FileManager.default.createDirectory(at: rootBundleURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: derivedBundleURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: materializedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "@root\nACGT\n+\nIIII\n".write(to: rootFASTQURL, atomically: true, encoding: .utf8)
        try "root\n".write(
            to: derivedBundleURL.appendingPathComponent("read-ids.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "@root\nACGT\n+\nIIII\n".write(to: materializedURL, atomically: true, encoding: .utf8)
        let manifest = FASTQDerivedBundleManifest(
            name: "derived",
            parentBundleRelativePath: "../root.lungfishfastq",
            rootBundleRelativePath: "../root.lungfishfastq",
            rootFASTQFilename: "root.fastq",
            payload: .subset(readIDListFilename: "read-ids.txt"),
            lineage: [],
            operation: FASTQDerivativeOperation(kind: .searchText, query: "root"),
            cachedStatistics: .placeholder(readCount: 1, baseCount: 4),
            pairingMode: nil,
            sequenceFormat: .fastq
        )
        try FASTQBundle.saveDerivedManifest(manifest, in: derivedBundleURL)

        let originalRequest = AssemblyRunRequest(
            tool: .megahit,
            readType: .illuminaShortReads,
            inputURLs: [derivedBundleURL],
            projectName: "demo",
            outputDirectory: outputDir,
            threads: 2
        )
        let executionRequest = AssemblyRunRequest(
            tool: originalRequest.tool,
            readType: originalRequest.readType,
            inputURLs: [materializedURL],
            projectName: originalRequest.projectName,
            outputDirectory: originalRequest.outputDirectory,
            threads: originalRequest.threads
        )
        let contigsURL = outputDir.appendingPathComponent("contigs.fasta")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        try ">contig1\nACGT\n".write(to: contigsURL, atomically: true, encoding: .utf8)
        let result = AssemblyResult(
            tool: .megahit,
            readType: .illuminaShortReads,
            contigsPath: contigsURL,
            graphPath: nil,
            logPath: nil,
            assemblerVersion: "1.2.9",
            commandLine: "megahit -r \(materializedURL.path) -o \(outputDir.path)",
            outputDirectory: outputDir,
            statistics: try AssemblyStatisticsCalculator.compute(from: contigsURL),
            wallTimeSeconds: 3.0
        )
        let materializationStartedAt = Date(timeIntervalSince1970: 100)
        let materializationEndedAt = Date(timeIntervalSince1970: 102)
        let materializationStep = try XCTUnwrap(
            AssemblyRunner.managedAssemblyMaterializationStep(
                originalRequest: originalRequest,
                executionRequest: executionRequest,
                startedAt: materializationStartedAt,
                endedAt: materializationEndedAt
            )
        )

        let provenance = ProvenanceBuilder.build(
            request: executionRequest,
            result: result,
            inputRecords: AssemblyRunner.managedAssemblyInputRecords(
                originalRequest: originalRequest,
                executionRequest: executionRequest
            ),
            steps: [materializationStep],
            lungfishVersion: "test"
        )
        try provenance.save(to: outputDir)
        let reloaded = try AssemblyProvenance.load(from: outputDir)
        let reloadedStep = try XCTUnwrap(
            reloaded.steps.first { $0.toolName == "lungfish.assemble.input-materialization" }
        )

        XCTAssertEqual(reloadedStep.startedAt, materializationStartedAt)
        XCTAssertEqual(reloadedStep.completedAt, materializationEndedAt)
        XCTAssertEqual(reloadedStep.wallTimeSeconds, 2.0)
        XCTAssertTrue(reloadedStep.inputs.contains { $0.path == derivedBundleURL.path })
        XCTAssertTrue(reloadedStep.outputs.contains { $0.path == materializedURL.path })
    }
}
