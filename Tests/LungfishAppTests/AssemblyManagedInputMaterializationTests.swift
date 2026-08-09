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
            reloaded.steps.first { $0.toolName == "lungfish-cli fastq materialize" }
        )
        let expectedCommand = CLISequenceInputMaterialization.materializationCommand(
            originalURL: derivedBundleURL,
            executionURL: materializedURL
        )

        XCTAssertEqual(reloadedStep.argv, expectedCommand)
        XCTAssertEqual(reloadedStep.durableReplayArgv, expectedCommand)
        XCTAssertEqual(reloadedStep.reproducibleCommand, expectedCommand.map(shellEscape).joined(separator: " "))
        XCTAssertEqual(reloadedStep.startedAt, materializationStartedAt)
        XCTAssertEqual(reloadedStep.completedAt, materializationEndedAt)
        XCTAssertEqual(reloadedStep.wallTimeSeconds, 2.0)
        XCTAssertTrue(reloadedStep.inputs.contains { $0.path == derivedBundleURL.path })
        XCTAssertTrue(reloadedStep.outputs.contains { $0.path == materializedURL.path })
    }

    // MARK: - MB-2 review round 1: per-bundle split operates on real bundle content

    /// Builds a real `.lungfishfastq` bundle backed by a `source-files.json`
    /// multi-file manifest listing two physical FASTQ files named with the
    /// R1/R2 convention -- the on-disk shape of a genuine paired-end sample
    /// imported as one bundle. This is the case
    /// `AppDelegate.resolvedAssemblyPairedEnd` must detect as truly paired.
    private func makeGenuinePairedBundle(
        named bundleName: String,
        in directory: URL
    ) throws -> URL {
        let bundleURL = directory.appendingPathComponent("\(bundleName).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let r1Name = "\(bundleName)_R1.fastq"
        let r2Name = "\(bundleName)_R2.fastq"
        let r1URL = bundleURL.appendingPathComponent(r1Name)
        let r2URL = bundleURL.appendingPathComponent(r2Name)
        let r1Data = "@r1\nACGT\n+\nIIII\n"
        let r2Data = "@r2\nTGCA\n+\nIIII\n"
        try r1Data.write(to: r1URL, atomically: true, encoding: .utf8)
        try r2Data.write(to: r2URL, atomically: true, encoding: .utf8)

        let manifest = FASTQSourceFileManifest(files: [
            .init(filename: r1Name, originalPath: r1URL.path, sizeBytes: Int64(r1Data.utf8.count), isSymlink: false),
            .init(filename: r2Name, originalPath: r2URL.path, sizeBytes: Int64(r2Data.utf8.count), isSymlink: false),
        ])
        try manifest.save(to: bundleURL)

        return bundleURL
    }

    /// Builds a real `.lungfishfastq` bundle containing exactly ONE physical
    /// FASTQ file, named to look like one half of an R1/R2 pair purely by
    /// bundle-directory naming convention. Two of these (named `X_R1` /
    /// `X_R2`) must NEVER be treated as mates -- there is no source manifest
    /// or derived-bundle payload connecting them; each is an independent
    /// single-end sample that happens to share a naming pattern with another
    /// bundle.
    private func makeSingleFileBundleNamedLikeAnRHalf(
        named bundleName: String,
        in directory: URL
    ) throws -> URL {
        let bundleURL = directory.appendingPathComponent("\(bundleName).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try "@single\nACGTACGT\n+\nIIIIIIII\n".write(
            to: bundleURL.appendingPathComponent("reads.fastq"),
            atomically: true,
            encoding: .utf8
        )
        return bundleURL
    }

    private func makePooledAssembleRequest(
        inputURLs: [URL],
        outputDirectory: URL,
        projectName: String = "pooled-run"
    ) -> FASTQOperationLaunchRequest {
        .assemble(
            request: AssemblyRunRequest(
                tool: .spades,
                readType: .illuminaShortReads,
                inputURLs: inputURLs,
                projectName: projectName,
                outputDirectory: outputDirectory,
                pairedEnd: false,
                threads: 4
            ),
            outputMode: .perInput
        )
    }

    func testIndependentAssembleLaunchRequestsSplitsGenuinePairedBundlesWithOwnR1R2Each() throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "AssemblyIndependentGenuinePairs")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleA = try makeGenuinePairedBundle(named: "SampleA", in: tempDir)
        let bundleB = try makeGenuinePairedBundle(named: "SampleB", in: tempDir)

        let pooledRequest = makePooledAssembleRequest(inputURLs: [bundleA, bundleB], outputDirectory: tempDir)

        let children = pooledRequest.independentAssembleLaunchRequests(outputDirectory: tempDir)

        XCTAssertEqual(children.count, 2)
        guard case .assemble(let firstRequest, let firstMode) = children[0],
              case .assemble(let secondRequest, let secondMode) = children[1] else {
            return XCTFail("Expected split .assemble requests")
        }

        XCTAssertEqual(firstMode, .perInput)
        XCTAssertEqual(secondMode, .perInput)

        XCTAssertTrue(firstRequest.pairedEnd, "SampleA's own R1/R2 manifest pair must be detected as paired")
        XCTAssertEqual(firstRequest.inputURLs.count, 2)
        XCTAssertEqual(Set(firstRequest.inputURLs.map(\.lastPathComponent)), ["SampleA_R1.fastq", "SampleA_R2.fastq"])

        XCTAssertTrue(secondRequest.pairedEnd, "SampleB's own R1/R2 manifest pair must be detected as paired")
        XCTAssertEqual(secondRequest.inputURLs.count, 2)
        XCTAssertEqual(Set(secondRequest.inputURLs.map(\.lastPathComponent)), ["SampleB_R1.fastq", "SampleB_R2.fastq"])
    }

    func testIndependentAssembleLaunchRequestsNeverMatesTwoUnrelatedBundlesNamedLikeAnRPair() throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "AssemblyIndependentNoFalseMating")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Two DISTINCT bundles whose directory names look like an R1/R2 pair,
        // but which are not: each is its own single-file bundle with no
        // manifest connecting it to the other. This is exactly the
        // regression the C2/MB-1 review caught: bundle-URL pattern matching
        // must never be used to infer pairing.
        let bundleR1 = try makeSingleFileBundleNamedLikeAnRHalf(named: "Run1_R1", in: tempDir)
        let bundleR2 = try makeSingleFileBundleNamedLikeAnRHalf(named: "Run1_R2", in: tempDir)

        let pooledRequest = makePooledAssembleRequest(inputURLs: [bundleR1, bundleR2], outputDirectory: tempDir)

        let children = pooledRequest.independentAssembleLaunchRequests(outputDirectory: tempDir)

        XCTAssertEqual(children.count, 2)
        guard case .assemble(let firstRequest, _) = children[0],
              case .assemble(let secondRequest, _) = children[1] else {
            return XCTFail("Expected split .assemble requests")
        }

        XCTAssertFalse(firstRequest.pairedEnd, "Run1_R1 and Run1_R2 are unrelated bundles, never mates")
        XCTAssertEqual(firstRequest.inputURLs.count, 1)
        XCTAssertEqual(firstRequest.inputURLs.first?.lastPathComponent, "reads.fastq")

        XCTAssertFalse(secondRequest.pairedEnd, "Run1_R1 and Run1_R2 are unrelated bundles, never mates")
        XCTAssertEqual(secondRequest.inputURLs.count, 1)
        XCTAssertEqual(secondRequest.inputURLs.first?.lastPathComponent, "reads.fastq")
    }

    func testIndependentAssembleLaunchRequestsAssignDistinctProjectNamesPerBundle() throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "AssemblyIndependentDistinctProjectNames")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleA = try makeGenuinePairedBundle(named: "SampleA", in: tempDir)
        let bundleB = try makeGenuinePairedBundle(named: "SampleB", in: tempDir)

        let pooledRequest = makePooledAssembleRequest(
            inputURLs: [bundleA, bundleB],
            outputDirectory: tempDir,
            projectName: "my-pooled-project"
        )

        let children = pooledRequest.independentAssembleLaunchRequests(outputDirectory: tempDir)

        let projectNames = children.compactMap { child -> String? in
            guard case .assemble(let request, _) = child else { return nil }
            return request.projectName
        }

        XCTAssertEqual(projectNames.count, 2)
        XCTAssertEqual(Set(projectNames).count, 2, "Each split child must have a distinct project name")
        XCTAssertFalse(projectNames.contains("my-pooled-project"), "Children must not repeat the pooled request's single name")
    }

    func testIndependentAssembleLaunchRequestsDeduplicatesProjectNamesForIdenticalBundleNames() throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "AssemblyIndependentDedupProjectNames")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Two different bundles that both happen to sanitize to the same
        // display/project name (distinct parent folders, identical leaf name).
        let subdirA = tempDir.appendingPathComponent("groupA", isDirectory: true)
        let subdirB = tempDir.appendingPathComponent("groupB", isDirectory: true)
        try FileManager.default.createDirectory(at: subdirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: subdirB, withIntermediateDirectories: true)
        let bundleA = try makeSingleFileBundleNamedLikeAnRHalf(named: "sample", in: subdirA)
        let bundleB = try makeSingleFileBundleNamedLikeAnRHalf(named: "sample", in: subdirB)

        let pooledRequest = makePooledAssembleRequest(inputURLs: [bundleA, bundleB], outputDirectory: tempDir)

        let children = pooledRequest.independentAssembleLaunchRequests(outputDirectory: tempDir)
        let projectNames = children.compactMap { child -> String? in
            guard case .assemble(let request, _) = child else { return nil }
            return request.projectName
        }

        XCTAssertEqual(projectNames, ["sample", "sample-2"])
    }

    func testIndependentAssembleLaunchRequestsSinglePairedEndInputIsUnaffected() throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "AssemblyIndependentSingleBundleUnaffected")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleA = try makeGenuinePairedBundle(named: "SampleA", in: tempDir)
        let pooledRequest = makePooledAssembleRequest(inputURLs: [bundleA], outputDirectory: tempDir)

        let children = pooledRequest.independentAssembleLaunchRequests(outputDirectory: tempDir)

        XCTAssertEqual(children.count, 1)
        guard case .assemble(let request, _) = children[0] else {
            return XCTFail("Expected the original single-bundle request unchanged")
        }
        XCTAssertEqual(request.inputURLs, [bundleA])
    }

    func testIndependentAssembleLaunchRequestsCombinedModeIsNotSplit() throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "AssemblyIndependentCombinedUnsplit")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleA = try makeGenuinePairedBundle(named: "SampleA", in: tempDir)
        let bundleB = try makeGenuinePairedBundle(named: "SampleB", in: tempDir)

        let pooledRequest = FASTQOperationLaunchRequest.assemble(
            request: AssemblyRunRequest(
                tool: .spades,
                readType: .illuminaShortReads,
                inputURLs: [bundleA, bundleB],
                projectName: "pooled-run",
                outputDirectory: tempDir,
                pairedEnd: false,
                threads: 4
            ),
            outputMode: .groupedResult
        )

        let children = pooledRequest.independentAssembleLaunchRequests(outputDirectory: tempDir)

        XCTAssertEqual(children.count, 1)
        guard case .assemble(let request, let mode) = children[0] else {
            return XCTFail("Expected the pooled request unchanged")
        }
        XCTAssertEqual(mode, .groupedResult)
        XCTAssertEqual(request.inputURLs, [bundleA, bundleB])
    }
}
