// ExecutorAdoptParityTests.swift - The adopt of a Mac replay against a Mac import under the V15 list (CHTC C4 lane P, C4.12)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishIO
@testable import LungfishPortable
import LungfishTestSupport
@testable import LungfishWorkflow

/// TALLY C4.12 and C4-11. K4's 1,000,000-pair slice runs through the built `lungfish-executor run --plan` replay at one
/// thread, which the adopt takes through the `internal` replay policy (Q-C4-6), and through a Mac import of the same
/// sample that passes every setting the plan states (`bbtools`, the plan's heap, compression and binning). The two
/// bundles' records are walked key by key against `V15ParityList`, and every unlisted difference fails the test.
///
/// Runs only with `LUNGFISH_REQUIRE_TOOLS=1`, `LUNGFISH_PARITY_SLICE_DIR` and a scratch storage root holding the two
/// Deacon indexes. `LUNGFISH_PARITY_ARTIFACTS_DIR`, when set, receives both routes' records for the panel.
final class ExecutorAdoptParityTests: XCTestCase {
    static let importToolName = "lungfish import fastq"
    private var scratch: URL?

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: The three tests of C4.12

    /// BIO's test: the sidecar and the envelope, on both of K4's cases.
    func testAdoptedSidecarAndEnvelopeEqualInProcessImport() async throws {
        for parity in ExecutorPlanReplayParityTests.cases {
            let routes = try await routes(parity)
            let comparison = try compare(routes, envelope: true, sidecar: true)
            assertNoFinding(comparison, routes.name)
        }
    }

    /// UX's test: the sidecar the Inspector reads, on the wastewater case.
    func testAdoptedSidecarMatchesInProcessImportSidecar() async throws {
        let routes = try await routes(ExecutorPlanReplayParityTests.cases[1])
        let comparison = try compare(routes, envelope: false, sidecar: true)
        assertNoFinding(comparison, routes.name)
    }

    /// QA's test: the sidecar on the VSP2 case, and `provenance verify` passes on the adopted bundle.
    func testAdoptSidecarEqualsInProcessSidecar() async throws {
        let routes = try await routes(ExecutorPlanReplayParityTests.cases[0])
        let provenance = routes.adoptedBundle.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        XCTAssertNoThrow(try ProvenanceSignatureVerifier.verify(provenanceURL: provenance, signatureURL: nil, publicKeyURL: nil),
                         "provenance verify on the adopted bundle")
        let comparison = try compare(routes, envelope: false, sidecar: true)
        assertNoFinding(comparison, routes.name)
    }

    // MARK: The gate fails when it must

    /// C4-11 and S-4: a changed Q30 count in the adopted run record, and one key no record type declares in an adopted
    /// step, each fail the comparison with the key named.
    func testParityFailsOnUnlistedDifference() async throws {
        let routes = try await routes(ExecutorPlanReplayParityTests.cases[0])
        let unplanted = try compare(routes, envelope: true, sidecar: true).findings.map(\.key)

        var record = routes.record
        let counter = try XCTUnwrap(record.steps.firstIndex { $0.kind == .qualityCount }, "the counter step")
        let counts = try XCTUnwrap(record.steps[counter].qualityCounts)
        record.steps[counter].qualityCounts = ExecutorQualityCounts(
            baseCount: counts.baseCount, q20Count: counts.q20Count, q30Count: counts.q30Count - 1, recordCount: counts.recordCount,
            file: counts.file
        )
        try record.encoded().write(to: routes.returned.appendingPathComponent(ExecutorRunRecord.fileName))
        _ = try await ExecutorRunAdoption.adopt(resultFolder: routes.returned, projectDirectory: routes.project, force: true,
                                                policy: .macReplayForTests)
        var planted = routes
        planted.record = record
        let q30 = try compare(planted, envelope: true, sidecar: true).findings
        XCTAssertTrue(q30.contains { $0.key.hasSuffix("q30Percentage") && !unplanted.contains($0.key) },
                      "a planted Q30 count fails and names the key: \(q30.map(\.key))")

        let key = "plantedUndeclaredKey"
        let undeclared = try compare(routes, envelope: true, sidecar: false) { steps in
            guard let index = steps.firstIndex(where: { $0["toolName"] as? String == "fastp" }) else { return }
            steps[index][key] = "planted"
        }.findings
        XCTAssertTrue(undeclared.contains { $0.key.hasSuffix(".\(key)") }, "a planted undeclared key fails and is named: \(undeclared.map(\.key))")
    }

    /// QA ruling 2: a plan step whose parent is the adopt step, and one whose parent is removed, each fail naming the step
    /// and `parentStepID`, and the unchanged record raises no parent finding.
    func testParityParentLinkComparesByRole() async throws {
        let routes = try await routes(ExecutorPlanReplayParityTests.cases[0])
        let unchanged = try compare(routes, envelope: true, sidecar: false).findings
        XCTAssertFalse(unchanged.contains { $0.key.hasSuffix("parentStepID") }, "\(unchanged.filter { $0.key.hasSuffix("parentStepID") })")
        let adoptStepID = try XCTUnwrap(try envelopeSteps(routes.adoptedBundle).last?["id"] as? String)
        let plants: [(String, ([[String: Any]], inout [String: Any]) -> Void)] = [
            ("parent set to the adopt step", { _, step in step["parentStepID"] = adoptStepID }),
            ("parent removed", { _, step in step.removeValue(forKey: "parentStepID") }),
        ]
        for (label, plant) in plants {
            let findings = try compare(routes, envelope: true, sidecar: false) { steps in
                guard let index = steps.firstIndex(where: { $0["toolName"] as? String == "fastp" }) else { return }
                var step = steps[index]
                plant(steps, &step)
                steps[index] = step
            }.findings
            XCTAssertTrue(findings.contains { $0.key == "envelope.steps[fastp#1].parentStepID" },
                          "\(label): \(findings.filter { $0.key.hasSuffix("parentStepID") })")
        }
    }

    /// QA ruling 3, condition 4: a changed `GC(%)` in the node's seqkit table, its digest and size updated, reaches the
    /// adopted sidecar and fails the comparison at `computedStatistics.gcContent`, so the sidecar carries the node's value.
    func testParityFailsOnPlantedSeqkitValue() async throws {
        let routes = try await routes(ExecutorPlanReplayParityTests.cases[0])
        var record = routes.record
        let index = try XCTUnwrap(record.steps.firstIndex { $0.kind == .statistics }, "the statistics step")
        let output = try XCTUnwrap(record.steps[index].standardOutput, "the node's seqkit table")
        var lines = output.text.components(separatedBy: "\n")
        let header = lines[0].components(separatedBy: "\t")
        var row = lines[1].components(separatedBy: "\t")
        let column = try XCTUnwrap(header.firstIndex(of: "GC(%)"))
        let planted = (Double(row[column]) ?? 0) + 1.25
        row[column] = String(planted)
        lines[1] = row.joined(separator: "\t")
        let text = lines.joined(separator: "\n")
        let bytes = Data(text.utf8)
        record.steps[index].standardOutput = ExecutorCapturedOutput(text: text, sha256: PortableDigest.sha256Hex(of: bytes), size: Int64(bytes.count))
        try record.encoded().write(to: routes.returned.appendingPathComponent(ExecutorRunRecord.fileName))
        _ = try await ExecutorRunAdoption.adopt(resultFolder: routes.returned, projectDirectory: routes.project, force: true,
                                                policy: .macReplayForTests)
        var plantedRoutes = routes
        plantedRoutes.record = record
        let findings = try compare(plantedRoutes, envelope: false, sidecar: true).findings
        let sidecar = findings.first { $0.key == "sidecar.computedStatistics.gcContent" }
        XCTAssertEqual(sidecar?.adopted, "\(planted / 100.0)", "the adopted sidecar carries the node's GC value: \(findings.map(\.key))")
    }

    /// QA ruling 1, condition 5: the class-4 lines cite the committed excerpt, whose first line names the C0 source.
    func testRunVaryingClassCitesCommittedDeterminismTable() throws {
        let classFour = V15ParityList.lines.filter { $0.n9Class == 4 }
        XCTAssertFalse(classFour.isEmpty)
        let name = (V15ParityList.determinismTablePath as NSString).lastPathComponent
        for line in classFour {
            XCTAssertTrue(line.reason.contains(name), "\(line.id) cites \(name)")
        }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let table = try String(contentsOf: repository.appendingPathComponent(V15ParityList.determinismTablePath), encoding: .utf8)
        let first = try XCTUnwrap(table.components(separatedBy: "\n").first)
        XCTAssertTrue(first.contains("chtc-program/c0/lanes/C0-DET/determinism.md"), first)
        XCTAssertTrue(first.contains("ab54dc0e0c7157974cb0716c1344c304ee591fb97765a09fd9f8a3da39683d0a"), first)
        for line in V15ParityList.lines {
            XCTAssertTrue((1...5).contains(line.n9Class), line.id)
            XCTAssertFalse(line.decision.isEmpty, line.id)
        }
        XCTAssertTrue(V15ParityList.routeOnlySteps.contains { $0.role == V15Roles.counter },
                      "The counter step stays listed until MO-B1's lane")
    }

    // MARK: The two routes

    struct Routes {
        let name: String
        let project: URL
        let macBundle: URL
        let adoptedBundle: URL
        let returned: URL
        let plan: ExecutionPlan
        var record: ExecutorRunRecord
        let e4Equal: Bool
    }

    private func routes(_ parity: ExecutorPlanReplayParityTests.ParityCase) async throws -> Routes {
        let shared = try await ExecutorPlanReplayParityTests.preparedShared()
        let root = try scratch ?? TestTempDirectory.make(prefix: "ExecutorAdoptParity")
        scratch = root
        let name = parity.recipeName
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let recipe = try XCTUnwrap(RecipeResolver.resolve(
            name, in: RecipeRegistryV2.builtinRecipes(),
            switchOptions: ["removeDuplicates": true, "removeRibosomalRNA": parity.removesRibosomalRNA]
        ), name)
        // BI:49-51, SW:25, AR:30: the Mac import passes bbtools and every setting the plan states.
        let project = folder.appendingPathComponent("Project.lungfish", isDirectory: true)
        let config = FASTQBatchImporter.ImportConfig(
            projectDirectory: project, platform: .illumina, newRecipe: recipe, qualityBinning: .illumina4, optimizeStorage: true,
            clumpingTool: .bbtools, compressionLevel: .balanced, threads: 1, pairing: .paired, threadsSource: .option,
            clumpifyHeapGB: 4
        )
        let manifestURL = folder.appendingPathComponent("image-manifest.json")
        try shared.manifestData.write(to: manifestURL)
        let request = ExecutorPlanRequest(
            sample: PlanSampleValues(sampleName: ExecutorPlanReplayParityTests.sampleName,
                                     originalFilenames: shared.inputs.map(\.url.lastPathComponent),
                                     originalSizeBytes: shared.inputs.reduce(0) { $0 + $1.size },
                                     // The Mac route is given `--platform illumina`, so the plan states the same request.
                                     platform: "illumina"),
            inputs: shared.inputs, inputFormat: .pairedR1R2, recipe: recipe, recipeFile: shared.recipeFile,
            storage: ExecutorPlanStorageRequest(
                requestedClumpingTool: config.clumpingTool, clumpifyHeapGB: config.clumpifyHeapGB ?? 0, threads: config.threads,
                compressor: .bgzip, qualityBinning: config.qualityBinning,
                compressionLevel: ExecutorPlanReplayParityTests.zlibLevel(config.compressionLevel),
                threadsSource: config.threadsSource, clumpifyHeapSource: .option, compressorSource: .default,
                qualityBinningSource: config.qualityBinningSource
            ),
            executorFile: shared.executor,
            executorBuild: PlanExecutorBuild(
                lgeVersion: "2026.10.22", lgeCommit: "efcdc7e1c877fb6ac1c78e14af6fd2367f38f171",
                targetTriple: "arm64-apple-macosx", toolchainID: "swift-6.2", toolchainSHA256: String(repeating: "b", count: 64),
                staticLinuxSDKID: "swift-6.2-static-linux", staticLinuxSDKSHA256: String(repeating: "b", count: 64)
            ),
            imageManifest: PlanImageManifestPin(sha256: ExecutorPlanReplayParityTests.sha256(shared.manifestData),
                                                size: Int64(shared.manifestData.count)),
            imageTools: shared.pins,
            deadlines: ExecutorPlanDeadlines(recipeStepSeconds: 7200, storageSeconds: 7200, statisticsSeconds: 3600, graceSeconds: 30),
            databases: shared.databases
        )
        let host = ExecutorPlanHostFacts(physicalMemoryBytes: Int64(ProcessInfo.processInfo.physicalMemory),
                                         processorCount: ProcessInfo.processInfo.activeProcessorCount)
        let emission = try ExecutorPlanEmitter.emission(request, host: host)
        // QA ruling 1, condition 4: one thread on both routes, the one condition under which the Mac equals itself.
        let threadsMessage = "\(name): both routes run at one thread, since mac-determinism-c0.md shows the Mac differing from itself at 8"
        XCTAssertEqual(emission.plan.storage.threads, 1, threadsMessage)
        XCTAssertEqual(config.threads, 1, threadsMessage)
        XCTAssertEqual(config.threadsSource, .option, threadsMessage)
        guard emission.plan.storage.threads == 1, config.threads == 1 else { throw XCTSkip(threadsMessage) }
        let work = folder.appendingPathComponent("plan", isDirectory: true)
        let planFile = try ExecutorPlanFolderWriter.write(emission, into: work)

        let process = Process()
        process.executableURL = work.appendingPathComponent(ExecutorPlanEmitter.executorPath)
        process.arguments = ["run", "--plan", planFile.path, "--image-manifest", manifestURL.path]
        process.currentDirectoryURL = work
        let stderrURL = folder.appendingPathComponent("executor.stderr")
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        FileManager.default.createFile(atPath: folder.appendingPathComponent("executor.stdout").path, contents: nil)
        process.standardError = try FileHandle(forWritingTo: stderrURL)
        process.standardOutput = try FileHandle(forWritingTo: folder.appendingPathComponent("executor.stdout"))
        let exited = AsyncStream<Int32> { continuation in
            process.terminationHandler = { continuation.yield($0.terminationStatus); continuation.finish() }
        }
        try process.run()
        let result = await FASTQBatchImporter.runBatchImport(
            pairs: [SamplePair(sampleName: ExecutorPlanReplayParityTests.sampleName, r1: shared.inputs[0].url, r2: shared.inputs[1].url)],
            config: config, log: nil
        )
        var status: Int32 = -1
        for await value in exited { status = value }
        XCTAssertEqual(result.completed, 1, "\(name) Mac import: \(result.errors)")
        let record = try ExecutorRunRecord.decode(Data(contentsOf: work.appendingPathComponent(ExecutorRunRecord.fileName)))
        XCTAssertEqual(status, 0, "\(name) replay: \(record.reason ?? "") at \(record.failedStepID ?? "")")
        guard result.completed == 1, status == 0 else { throw XCTSkip("\(name): a route failed") }

        // Both bundles sit at one project path, so a bundle path reads the same on both routes. The Mac project moves
        // aside and the adopt publishes into a new folder of the same name.
        let macProject = folder.appendingPathComponent("MacProject.lungfish", isDirectory: true)
        try FileManager.default.moveItem(at: project, to: macProject)
        // As A2's ARCH 5 test: the adopt signs with a throwaway key, as on a Mac that holds a signing key, so `provenance
        // verify` reads a signed record (SWIFT-ARCH fix 3). The test process holds no key of its own.
        let keyFile = folder.appendingPathComponent("signing-key.txt")
        try "adopt-parity-\(UUID().uuidString)\n".write(to: keyFile, atomically: true, encoding: .utf8)
        let adoptedBundle = try await ExecutorRunAdoption.adopt(
            resultFolder: work, projectDirectory: project, policy: .macReplayForTests,
            signingEnvironment: [ProvenanceSigningConfiguration.signingKeyFileEnvironmentKey: keyFile.path]
        )
        let macBundle = macProject.appendingPathComponent("Imports").appendingPathComponent(adoptedBundle.lastPathComponent)
        let payloadName = "\(ExecutorPlanReplayParityTests.sampleName).fastq.gz"
        let e4Equal = try PayloadLevels.measure(macBundle.appendingPathComponent(payloadName)).e4
            == PayloadLevels.measure(adoptedBundle.appendingPathComponent(payloadName)).e4
        return Routes(name: name, project: project, macBundle: macBundle, adoptedBundle: adoptedBundle, returned: work,
                      plan: emission.plan, record: record, e4Equal: e4Equal)
    }

    // MARK: The comparison

    private func envelopeSteps(_ bundle: URL) throws -> [[String: Any]] {
        let envelope = try V15Comparison.jsonObject(bundle.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
        return envelope["steps"] as? [[String: Any]] ?? []
    }

    private func compare(
        _ routes: Routes, envelope: Bool, sidecar: Bool, editAdoptedSteps: ((inout [[String: Any]]) -> Void)? = nil
    ) throws -> V15Comparison {
        let payloadName = "\(ExecutorPlanReplayParityTests.sampleName).fastq.gz"
        let macFASTQ = routes.macBundle.appendingPathComponent(payloadName)
        let adoptedFASTQ = routes.adoptedBundle.appendingPathComponent(payloadName)
        let sidecarName = FASTQMetadataStore.metadataURL(for: macFASTQ).lastPathComponent
        var comparison = V15Comparison(
            roots: [.mac: [routes.project.path], .adopted: [routes.returned.path, routes.project.path]],
            payloadFileNames: [payloadName, sidecarName]
        )
        if envelope {
            let provenance = ProvenanceRecorder.provenanceFilename
            var adoptedEnvelope = try V15Comparison.jsonObject(routes.adoptedBundle.appendingPathComponent(provenance))
            let macEnvelope = try V15Comparison.jsonObject(routes.macBundle.appendingPathComponent(provenance))
            var adoptedSteps = adoptedEnvelope["steps"] as? [[String: Any]] ?? []
            editAdoptedSteps?(&adoptedSteps)
            adoptedEnvelope["steps"] = adoptedSteps
            let adoptedRoles = V15StepRoles.adopted(
                adoptedSteps, executorToolName: ExecutorRunAdoption.executorToolName, adoptToolName: Self.importToolName,
                nodeKinds: routes.record.steps.map { "\($0.kind)" }
            )
            let macRoles = V15StepRoles.mac(macEnvelope["steps"] as? [[String: Any]] ?? [], importToolName: Self.importToolName)
            for problem in adoptedRoles.problems + macRoles.problems {
                comparison.findings.append(V15Finding(key: "envelope.steps", adopted: "-", mac: "-", why: problem))
            }
            comparison.compareEnvelopes(adopted: adoptedEnvelope, mac: macEnvelope, adoptedRoles: adoptedRoles, macRoles: macRoles)
        }
        if sidecar {
            comparison.compareSidecars(
                adopted: try V15Comparison.jsonObject(FASTQMetadataStore.metadataURL(for: adoptedFASTQ)),
                mac: try V15Comparison.jsonObject(FASTQMetadataStore.metadataURL(for: macFASTQ))
            )
        }
        // QA ruling 3: the node's printed and counted values against the Mac sidecar, by the test's own parse.
        let statistics = routes.record.steps.first { $0.kind == .statistics }?.standardOutput?.text ?? ""
        let counts = routes.record.steps.first { $0.kind == .qualityCount }?.qualityCounts
        let macSidecar = try XCTUnwrap(FASTQMetadataStore.load(for: macFASTQ), "the Mac sidecar")
        comparison.findings += V15Statistics.compare(
            standardOutput: statistics,
            counts: FASTQQualityFractions(baseCount: counts?.baseCount ?? 0, q20Count: counts?.q20Count ?? 0, q30Count: counts?.q30Count ?? 0),
            macSidecar: macSidecar
        ).map { V15Finding(key: "statistics." + $0.key, adopted: $0.adopted, mac: $0.mac, why: $0.why) }
        comparison.reported.append("PARITY-REPORTED line=V15-22 key=payload.e4 case=\(routes.name) equalInStoredOrder=\(routes.e4Equal)")
        try keepArtifacts(routes)
        return comparison
    }

    private func assertNoFinding(_ comparison: V15Comparison, _ name: String) {
        for line in comparison.reported { print(line) }
        for finding in comparison.findings { print("\(finding) case=\(name)") }
        XCTAssertTrue(comparison.findings.isEmpty,
                      "\(name): \(comparison.findings.count) lines outside the V15 list differ (XC-11 C, never widen the list): "
                        + comparison.findings.prefix(40).map(\.description).joined(separator: "\n"))
    }

    /// Both routes' records for the panel, when `LUNGFISH_PARITY_ARTIFACTS_DIR` names a folder.
    private func keepArtifacts(_ routes: Routes) throws {
        guard let folder = ProcessInfo.processInfo.environment["LUNGFISH_PARITY_ARTIFACTS_DIR"], !folder.isEmpty else { return }
        let target = URL(fileURLWithPath: folder).appendingPathComponent("\(name)-\(routes.name)", isDirectory: true)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let payloadName = "\(ExecutorPlanReplayParityTests.sampleName).fastq.gz"
        for (route, bundle) in [("adopted", routes.adoptedBundle), ("mac", routes.macBundle)] {
            try FileManager.default.copyItem(at: bundle.appendingPathComponent(ProvenanceRecorder.provenanceFilename),
                                             to: target.appendingPathComponent("\(route)-envelope.json"))
            try FileManager.default.copyItem(at: FASTQMetadataStore.metadataURL(for: bundle.appendingPathComponent(payloadName)),
                                             to: target.appendingPathComponent("\(route)-sidecar.json"))
        }
        try routes.record.encoded().write(to: target.appendingPathComponent("run-record.json"))
    }
}
