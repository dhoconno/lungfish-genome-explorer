// ExecutorAdoptParityTests.swift - The adopt of a Mac replay against a Mac import under the V15 list (CHTC C4 lane P, C4.12)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishIO
import LungfishCore
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

    /// QV-17 and XC-4 B (AMV1 QA fix 4): V15-02 sets the node tool's record aside only when its version is the step's own
    /// and the plan's pin. A fastp step whose tool record and step both say 0.0, which agree with each other and not with
    /// the plan, fails with `resolvedOptions.tool.version` named, and the unplanted run has no such finding.
    func testParityFailsOnPlantedToolVersionOffThePlanPin() async throws {
        let routes = try await routes(ExecutorPlanReplayParityTests.cases[0])
        let key = "envelope.steps[fastp#1].resolvedOptions.tool.version"
        let unplanted = try compare(routes, envelope: true, sidecar: false).findings.map(\.key)
        XCTAssertFalse(unplanted.contains(key), "the unplanted run names the tool version: \(unplanted)")
        let planted = try compare(routes, envelope: true, sidecar: false) { steps in
            guard let index = steps.firstIndex(where: { $0["toolName"] as? String == "fastp" }) else { return }
            var options = steps[index]["resolvedOptions"] as? [String: Any] ?? [:]
            // The envelope types the tool record as {"type": "dictionary", "value": {..., "version": {"type": "string", ...}}}.
            if var outer = options["tool"] as? [String: Any], var inner = outer["value"] as? [String: Any] {
                inner["version"] = ["type": "string", "value": "0.0"]
                outer["value"] = inner
                options["tool"] = outer
            }
            steps[index]["resolvedOptions"] = options
            steps[index]["toolVersion"] = "0.0"
        }.findings
        XCTAssertTrue(planted.contains { $0.key == key }, "a tool version off the plan's pin fails and is named: \(planted.map(\.key))")
    }

    /// AMV2 ARCH fix 3: the decompressor check names the decompressor the plan pins, not any tool the plan pins. With a plan
    /// that pins fastp, pigz 2.8 and bgzip 1.24 (gzip first when pinned), a step of `bgzip`, one of `fastp`, one of `pigz`
    /// 2.7 and one of `pigz` without `-dc` each give a finding, and `pigz` 2.8 with `-dc` gives none.
    func testDecompressorStepMustBeThePinnedDecompressor() {
        let pins: [(id: String, version: String)] = [("fastp", "1.0.1"), ("pigz", "2.8"), ("bgzip", "1.24")]
        func step(_ program: String, version: String, flag: String = "-dc") -> [String: Any] {
            ["argv": ["/opt/conda/envs/pigz/bin/\(program)", flag, "work/a.fq.gz"], "toolVersion": version]
        }
        func findings(_ step: [String: Any], _ pins: [(id: String, version: String)]) -> Int {
            Self.decompressorFindings([step], pins: pins).count
        }
        XCTAssertEqual(findings(step("pigz", version: "2.8"), pins), 0, "the pinned pigz at the pin's version")
        XCTAssertEqual(findings(step("bgzip", version: "1.24"), pins), 1, "bgzip is a plan pin, and the decompressor is pigz")
        XCTAssertEqual(findings(step("fastp", version: "1.0.1"), pins), 1, "fastp is a plan pin and no decompressor")
        XCTAssertEqual(findings(step("pigz", version: "2.7"), pins), 1, "pigz off the pin's version")
        XCTAssertEqual(findings(step("pigz", version: "2.8", flag: "-d"), pins), 1, "-dc byte for byte")
        XCTAssertEqual(findings(step("pigz", version: "2.8"), pins + [("gzip", "1.12")]), 1, "gzip, when pinned, is the decompressor")
        XCTAssertEqual(findings(step("bgzip", version: "1.24"), [("bgzip", "1.24")]), 0, "bgzip when the plan pins neither gzip nor pigz")
    }

    /// QA ruling 1 ("a test that cannot fail is not a gate"; AMV2 QA fix 5): a writer step whose `managedToolID` is not the
    /// envs folder of its own program fails V15-27, and a decompressor step at a version off the plan's pin or without `-dc`
    /// fails V15-S5, each with the step named and exactly one finding. The unplanted run has neither.
    func testParityFailsOnPlantedWriterEnvironmentAndDecompressorPin() async throws {
        let routes = try await routes(ExecutorPlanReplayParityTests.cases[0])
        let writerKey = "envelope.steps[bgzip#1].managedToolID"
        let pinKey = "envelope.steps[\(V15Roles.decompressor)]"
        let unplanted = try compare(routes, envelope: true, sidecar: false).findings
        XCTAssertFalse(unplanted.contains { $0.key == writerKey && $0.why.contains("V15-27") }, "\(unplanted.map(\.key))")
        XCTAssertFalse(unplanted.contains { $0.key == pinKey && $0.why.contains("V15-S5") }, "\(unplanted.map(\.key))")
        let plants: [(label: String, program: String, key: String, tag: String, edit: (inout [String: Any]) -> Void)] = [
            ("the writer's managedToolID", "bgzip", writerKey, "V15-27", { step in
                step["managedToolID"] = "\(step["managedToolID"] as? String ?? "none")-planted"
            }),
            ("a decompressor version of 0.0", "pigz", pinKey, "V15-S5", { step in step["toolVersion"] = "0.0" }),
            ("a decompressor without -dc", "pigz", pinKey, "V15-S5", { step in
                var argv = step["argv"] as? [String] ?? []
                if argv.count > 1 { argv[1] = "-d" }
                step["argv"] = argv
            }),
        ]
        for plant in plants {
            let findings = try compare(routes, envelope: true, sidecar: false) { steps in
                guard let index = steps.firstIndex(where: { $0["toolName"] as? String == plant.program }) else { return }
                plant.edit(&steps[index])
            }.findings.filter { $0.key == plant.key && $0.why.contains(plant.tag) }
            XCTAssertEqual(findings.count, 1, "\(plant.label) gives one \(plant.tag) finding at \(plant.key): \(findings)")
        }
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
        XCTAssertEqual(V15ParityList.routeOnlySteps.filter { $0.route == .adopted }.map(\.role),
                       [V15Roles.runner, V15Roles.counter, V15Roles.adoptStep, V15Roles.decompressor],
                       "C4-3 C-3: exactly four steps only the adopt route holds")
    }

    // MARK: Two bundles made outside the test (lane X, X3-6)

    /// Lane X's acceptance compare: the adopt of a plan folder a Linux run returned, against a Mac import of the same
    /// sample, both made before the test. `LUNGFISH_PARITY_ADOPTED_BUNDLE` and `LUNGFISH_PARITY_MAC_BUNDLE` name the two
    /// bundles and `LUNGFISH_PARITY_RETURNED_DIR` the returned folder the adopt read. The adopted bundle sits at the project
    /// path the Mac import wrote, with the Mac project moved aside, as `routes(_:)` arranges for its own runs. E0 to E3
    /// must be equal and every V15 finding fails, as for the test's own runs; E4 is reported.
    func testReturnedRunAdoptEqualsMacImportFromEnvironment() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let adopted = environment["LUNGFISH_PARITY_ADOPTED_BUNDLE"], !adopted.isEmpty,
              let mac = environment["LUNGFISH_PARITY_MAC_BUNDLE"], !mac.isEmpty,
              let returned = environment["LUNGFISH_PARITY_RETURNED_DIR"], !returned.isEmpty else {
            throw XCTSkip("Set LUNGFISH_PARITY_ADOPTED_BUNDLE, LUNGFISH_PARITY_MAC_BUNDLE and LUNGFISH_PARITY_RETURNED_DIR")
        }
        let (routes, levels) = try await Self.routes(
            adoptedBundle: URL(fileURLWithPath: adopted), macBundle: URL(fileURLWithPath: mac),
            returned: URL(fileURLWithPath: returned)
        )
        let name = routes.name
        // E0. The run succeeded on the plan the folder holds, and each plan step ran its plan argv.
        let planBytes = try Data(contentsOf: routes.returned.appendingPathComponent(ExecutorRunAdoption.planFileName))
        XCTAssertEqual(routes.record.exitCode, 0, "\(name) E0 exit")
        XCTAssertEqual(routes.record.plan?.sha256, ExecutorPlanReplayParityTests.sha256(planBytes), "\(name) E0 plan digest")
        XCTAssertEqual(routes.record.plan?.size, Int64(planBytes.count), "\(name) E0 plan size")
        for step in routes.plan.steps where !step.arguments.isEmpty {
            let ran = try XCTUnwrap(routes.record.steps.first { $0.id == step.id }, "\(name) \(step.id)")
            XCTAssertTrue(ran.argv == step.arguments || Array(ran.argv.dropFirst()) == step.arguments,
                          "\(name) E0 \(step.id): \(ran.argv) against \(step.arguments)")
        }
        // E1 to E3 on the two payloads, E4 reported.
        print("PARITY-LEVELS case=\(name) route=mac records=\(levels.mac.e1.records) bases=\(levels.mac.e1.bases) pairs=\(levels.mac.e1.pairs) singles=\(levels.mac.e1.singles) e2=\(levels.mac.e2) e3=\(levels.mac.e3) e4=\(levels.mac.e4)")
        print("PARITY-LEVELS case=\(name) route=adopted records=\(levels.adopted.e1.records) bases=\(levels.adopted.e1.bases) pairs=\(levels.adopted.e1.pairs) singles=\(levels.adopted.e1.singles) e2=\(levels.adopted.e2) e3=\(levels.adopted.e3) e4=\(levels.adopted.e4)")
        XCTAssertEqual(levels.adopted.e1, levels.mac.e1, "\(name) E1")
        XCTAssertEqual(levels.adopted.e2, levels.mac.e2, "\(name) E2")
        XCTAssertEqual(levels.adopted.e3, levels.mac.e3, "\(name) E3")
        let comparison = try compare(routes, envelope: true, sidecar: true)
        assertNoFinding(comparison, name)
    }

    /// The `Routes` of two bundles made outside the test, with each payload's levels.
    private static func routes(
        adoptedBundle: URL, macBundle: URL, returned: URL
    ) async throws -> (routes: Routes, levels: (mac: PayloadLevels, adopted: PayloadLevels)) {
        let plan = try ExecutionPlan.decode(Data(contentsOf: returned.appendingPathComponent(ExecutorRunAdoption.planFileName)))
        let record = try ExecutorRunRecord.decode(Data(contentsOf: returned.appendingPathComponent(ExecutorRunRecord.fileName)))
        let sampleName = plan.sample.sampleName
        let payloadName = "\(sampleName).fastq.gz"
        let mac = try PayloadLevels.measure(macBundle.appendingPathComponent(payloadName))
        let adopted = try PayloadLevels.measure(adoptedBundle.appendingPathComponent(payloadName))
        let macRow = try await NativeToolRunner.shared.run(
            .seqkit, arguments: ["stats", "-a", "-T", macBundle.appendingPathComponent(payloadName).path], timeout: 900
        )
        guard macRow.isSuccess else {
            try ToolAvailability.skipOrFail("seqkit stats of the Mac bundle's payload exited \(macRow.exitCode): \(macRow.stderr)")
        }
        var routes = Routes(name: sampleName, project: adoptedBundle.deletingLastPathComponent().deletingLastPathComponent(),
                            macBundle: macBundle, adoptedBundle: adoptedBundle, returned: returned, plan: plan, record: record,
                            e4Equal: mac.e4 == adopted.e4, macStatisticsTable: macRow.stdout, sampleName: sampleName)
        // BIOQA-X1 R2, S1: V15-30 may pass the lines that follow the stored order only when E2 and E3 are equal and E4 differs.
        routes.storedOrderDiffers = mac.e2 == adopted.e2 && mac.e3 == adopted.e3 && mac.e4 != adopted.e4
        return (routes, (mac, adopted))
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
        /// A seqkit stats table of the Mac bundle's payload, for the value columns no sidecar key holds (AMV1 BIO fix 3).
        let macStatisticsTable: String
        /// The sample, which names the payload and its sidecar in both bundles (lane X3-6: a bundle made outside the test).
        var sampleName = ExecutorPlanReplayParityTests.sampleName
        /// BIOQA-X1 R2, S1: the hook found E2 and E3 equal and E4 different. False for the test's own runs.
        var storedOrderDiffers = false
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
        // AMV1 BIO fix 3: a seqkit row of the Mac's payload from the runner the Mac import uses, for the columns it keeps no value for.
        let macRow = try await NativeToolRunner.shared.run(
            .seqkit, arguments: ["stats", "-a", "-T", macBundle.appendingPathComponent(payloadName).path], timeout: 900
        )
        guard macRow.isSuccess else {
            try ToolAvailability.skipOrFail("seqkit stats of the Mac bundle's payload exited \(macRow.exitCode): \(macRow.stderr)")
        }
        return Routes(name: name, project: project, macBundle: macBundle, adoptedBundle: adoptedBundle, returned: work,
                      plan: emission.plan, record: record, e4Equal: e4Equal, macStatisticsTable: macRow.stdout)
    }

    // MARK: The comparison

    private func envelopeSteps(_ bundle: URL) throws -> [[String: Any]] {
        let envelope = try V15Comparison.jsonObject(bundle.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
        return envelope["steps"] as? [[String: Any]] ?? []
    }

    /// C4-3 C-2's names, each read from that route's own records (ARCH A-C2-1, QA Q-2b, Q-2e): the node's stem from its
    /// one payload and its work folder from the emitter, the Mac's stem from its one published FASTQ, and each route's
    /// input paths with the digests its records give them, against the plan's digest for each mate. The Mac names an
    /// input outside the project `<external>/<name>`; its sidecar's absolute form resolves that against the slice folder.
    /// Returns the problems, a route with no one stem among them.
    private static func routeNames(
        _ routes: Routes, adoptedEnvelope: [String: Any], macEnvelope: [String: Any], into comparison: inout V15Comparison
    ) -> [String] {
        func inputDigests(_ envelope: [String: Any]) -> [String: String] {
            var digests: [String: String] = [:]
            for file in envelope["files"] as? [[String: Any]] ?? [] where file["role"] as? String == "input" {
                if let path = file["path"] as? String, let digest = file["checksumSHA256"] as? String { digests[path] = digest }
            }
            return digests
        }
        let mates = routes.plan.entries.filter { $0.role == .input }.map(\.sha256)
        var adoptedDigests = inputDigests(adoptedEnvelope)
        for entry in routes.record.inputs where entry.role == .input { adoptedDigests[entry.relativePath] = entry.sha256 }
        var macDigests = inputDigests(macEnvelope)
        let external = PortablePath.externalPlaceholder + "/"
        if let slice = ProcessInfo.processInfo.environment["LUNGFISH_PARITY_SLICE_DIR"], !slice.isEmpty {
            for (path, digest) in macDigests where path.hasPrefix(external) {
                macDigests[URL(fileURLWithPath: slice).appendingPathComponent(String(path.dropFirst(external.count))).path] = digest
            }
        }
        var problems: [String] = []
        let nodeStems = routes.record.payloads.compactMap { V15RouteNames.stem(ofPayload: $0.relativePath) }
        let macStem = ((macEnvelope["output"] as? [String: Any])?["path"] as? String).flatMap(V15RouteNames.stem(ofPayload:))
        if nodeStems.count != 1 { problems.append("the run record names \(nodeStems.count) payload stems, and must name one (Q-2b)") }
        if macStem == nil { problems.append("the Mac envelope names no one published FASTQ stem (Q-2b)") }
        comparison.names = [
            .adopted: V15RouteNames(stem: nodeStems.count == 1 ? nodeStems[0] : nil,
                                    workFolder: ExecutorPlanEmitter.workspace.lastPathComponent,
                                    inputs: V15RouteNames.mates(adoptedDigests, plan: mates),
                                    // C4-4 D-5: the plan's payload path and the paths the record's own steps name.
                                    payloadPaths: Set(routes.record.payloads.map(\.relativePath))
                                        .union(V15RouteNames.namedPayloadPaths(in: adoptedEnvelope))),
            .mac: V15RouteNames(stem: macStem, reportUUID: true, inputs: V15RouteNames.mates(macDigests, plan: mates),
                                payloadPaths: V15RouteNames.namedPayloadPaths(in: macEnvelope)),
        ]
        return problems
    }

    /// V15-S5 (C4-3 C-3, XC-4 B; AMV2 ARCH fix 3, QA fix 5): each decompressor step runs the one decompressor the plan pins,
    /// taken in the executor's order (`gzip`, else `pigz`, else `bgzip`; `RunCommand.swift:274`), at the pin's version, and
    /// its first argument is `-dc`. A pin the plan holds for another tool (`fastp`, or `bgzip` when the plan pins `pigz`) is
    /// not the decompressor. One finding for each step that is not.
    static func decompressorFindings(_ steps: [[String: Any]], pins: [(id: String, version: String)]) -> [V15Finding] {
        let pinned = ["gzip", "pigz", "bgzip"].first { id in pins.contains { $0.id == id } }
        return steps.compactMap { step in
            let argv = step["argv"] as? [String] ?? []
            let program = argv.first.map { ($0 as NSString).lastPathComponent } ?? ""
            let pin = pins.first { $0.id == program && program == pinned }
            guard pin == nil || step["toolVersion"] as? String != pin?.version || argv.dropFirst().first != "-dc" else { return nil }
            return V15Finding(
                key: "envelope.steps[\(V15Roles.decompressor)]",
                adopted: "\(program) \(step["toolVersion"] ?? "absent") \(argv.dropFirst().first ?? "-")", mac: "-",
                why: "V15-S5: the decompressor step's program is not the plan's pinned decompressor (gzip, else pigz, else bgzip) "
                    + "at the pin's version with -dc (XC-4 B)")
        }
    }

    private func compare(
        _ routes: Routes, envelope: Bool, sidecar: Bool, editAdoptedSteps: ((inout [[String: Any]]) -> Void)? = nil
    ) throws -> V15Comparison {
        let payloadName = "\(routes.sampleName).fastq.gz"
        let macFASTQ = routes.macBundle.appendingPathComponent(payloadName)
        let adoptedFASTQ = routes.adoptedBundle.appendingPathComponent(payloadName)
        let sidecarName = FASTQMetadataStore.metadataURL(for: macFASTQ).lastPathComponent
        let provenance = ProvenanceRecorder.provenanceFilename
        var adoptedEnvelope = try V15Comparison.jsonObject(routes.adoptedBundle.appendingPathComponent(provenance))
        let macEnvelope = try V15Comparison.jsonObject(routes.macBundle.appendingPathComponent(provenance))
        let adoptedSidecar = try V15Comparison.jsonObject(FASTQMetadataStore.metadataURL(for: adoptedFASTQ))
        let macSidecarObject = try V15Comparison.jsonObject(FASTQMetadataStore.metadataURL(for: macFASTQ))
        // QV-10: each route's roots, the Mac's scratch and storage folders read from its own records.
        let macStrings = V15Comparison.strings(in: macEnvelope) + V15Comparison.strings(in: macSidecarObject)
        let adoptedRecordStrings = V15Comparison.strings(in: adoptedEnvelope) + V15Comparison.strings(in: adoptedSidecar)
        let found = V15Comparison.routeRoots(
            project: routes.project.path, returned: routes.returned.path,
            storageRoot: ProcessInfo.processInfo.environment["LUNGFISH_STORAGE_ROOT"],
            macStrings: macStrings,
            adoptedStrings: adoptedRecordStrings
                + routes.record.steps.flatMap { $0.argv + ($0.storage?.launches ?? []).flatMap(\.argv) }
        )
        var comparison = V15Comparison(roots: found.roots, payloadFileNames: [payloadName, sidecarName])
        for problem in found.problems {
            comparison.findings.append(V15Finding(key: "roots", adopted: "-", mac: "-", why: problem))
        }
        for problem in Self.routeNames(routes, adoptedEnvelope: adoptedEnvelope, macEnvelope: macEnvelope, into: &comparison) {
            comparison.findings.append(V15Finding(key: "names", adopted: "-", mac: "-", why: problem))
        }
        // BIOQA-X1 R2, S1: set before `compareEnvelopes` reads S2 and S3 from the paired steps.
        comparison.storedOrder.e4Differs = routes.storedOrderDiffers
        // QA Q4-13 (XC-1, integrity inside one route): every entry at a payload path carries that route's own payload digest.
        for (route, envelope) in [(V15Route.adopted, adoptedEnvelope), (.mac, macEnvelope)] {
            comparison.findings += V15Comparison.payloadIntegrityFindings(
                envelope: envelope, route: route, paths: comparison.names[route]?.payloadPaths ?? [])
        }
        // UX U-3: the harness's placeholders never reach a record of either bundle.
        for (route, strings) in [("adopted", adoptedRecordStrings), ("mac", macStrings)]
        where strings.contains(where: {
            $0.contains(V15RouteNames.stemPlaceholder) || $0.contains(V15RouteNames.matePlaceholderPrefix)
                || $0.contains(V15RouteNames.payloadPlaceholder)
        }) {
            comparison.findings.append(V15Finding(key: "names", adopted: "-", mac: "-", why: "the \(route) records hold a harness placeholder (UX U-3)"))
        }
        if envelope {
            var adoptedSteps = adoptedEnvelope["steps"] as? [[String: Any]] ?? []
            editAdoptedSteps?(&adoptedSteps)
            adoptedEnvelope["steps"] = adoptedSteps
            let adoptedRoles = V15StepRoles.adopted(
                adoptedSteps, executorToolName: ExecutorRunAdoption.executorToolName, adoptToolName: Self.importToolName,
                // The adopt writes a storage step's launches as steps, the writer probe left out (QV-15).
                nodeKinds: routes.record.steps.flatMap { step -> [String] in
                    let launches = (step.storage?.launches ?? []).filter { Array($0.argv.dropFirst()) != ["-h"] }
                    guard !launches.isEmpty else { return ["\(step.kind)"] }
                    if step.kind == .storage { return Array(repeating: "\(step.kind)", count: launches.count) }
                    // C4-3 C-3: the interleave step's decompressor launches, each its own step.
                    return step.kind == .interleave ? Array(repeating: V15Roles.decompressor, count: launches.count) : ["\(step.kind)"]
                }
            )
            // C4-3 C-3 (XC-4 B): each decompressor step's program is the decompressor the plan pins, at the pin's version.
            comparison.findings += Self.decompressorFindings(
                adoptedSteps.filter { ($0["id"] as? String).map(adoptedRoles.role(ofID:)) == V15Roles.decompressor },
                pins: routes.plan.tools.map { ($0.id, $0.version) }
            )
            let macRoles = V15StepRoles.mac(macEnvelope["steps"] as? [[String: Any]] ?? [], importToolName: Self.importToolName)
            for problem in adoptedRoles.problems + macRoles.problems {
                comparison.findings.append(V15Finding(key: "envelope.steps", adopted: "-", mac: "-", why: problem))
            }
            comparison.compareEnvelopes(adopted: adoptedEnvelope, mac: macEnvelope, adoptedRoles: adoptedRoles, macRoles: macRoles,
                                        artifact: "adopted-envelope.json, mac-envelope.json",
                                        adoptedBundle: routes.adoptedBundle, macBundle: routes.macBundle)
            // QV-17, XC-4 B (AMV1 QA fix 4): V15-02 sets the node tool's record aside only when its version is the step's own
            // (`compareStep`) and the plan's pin, which this loop checks for every node step. The executor's own steps are
            // pinned by the plan's executor build.
            for step in adoptedSteps {
                guard let tool = V15Comparison.untyped((step["resolvedOptions"] as? [String: Any])?["tool"]) as? [String: Any],
                      let id = V15Comparison.untyped(tool["id"]) as? String else { continue }
                let held = V15Comparison.untyped(tool["version"]) as? String
                let pinned = id == ExecutorRunAdoption.executorBinaryName
                    ? routes.plan.executor.lgeVersion : routes.plan.tools.first { $0.id == id }?.version
                if pinned == nil || held != pinned {
                    let role = (step["id"] as? String).map(adoptedRoles.role(ofID:)) ?? "unnamed"
                    comparison.findings.append(V15Finding(
                        key: "envelope.steps[\(role)].resolvedOptions.tool.version", adopted: V15Comparison.render(held),
                        mac: "plan pin \(pinned ?? "absent")",
                        why: "V15-02 sets the node tool aside only when its version is the plan's pin for \(id) (QV-17, XC-4 B)"))
                }
            }
        }
        if sidecar {
            comparison.compareSidecars(adopted: adoptedSidecar, mac: macSidecarObject, artifact: "adopted-sidecar.json, mac-sidecar.json")
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
        // AMV1 BIO fix 3: the columns no sidecar key holds, against a seqkit row of the Mac's own payload.
        comparison.findings += V15Statistics.compareTables(standardOutput: statistics, macTable: routes.macStatisticsTable)
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
        let payloadName = "\(routes.sampleName).fastq.gz"
        for (route, bundle) in [("adopted", routes.adoptedBundle), ("mac", routes.macBundle)] {
            try FileManager.default.copyItem(at: bundle.appendingPathComponent(ProvenanceRecorder.provenanceFilename),
                                             to: target.appendingPathComponent("\(route)-envelope.json"))
            try FileManager.default.copyItem(at: FASTQMetadataStore.metadataURL(for: bundle.appendingPathComponent(payloadName)),
                                             to: target.appendingPathComponent("\(route)-sidecar.json"))
            // C4-4 D-4: the report copies the harness parsed, for the panel.
            let reports = bundle.appendingPathComponent("metadata/recipe-step-artifacts", isDirectory: true)
            if FileManager.default.fileExists(atPath: reports.path) {
                try FileManager.default.copyItem(at: reports, to: target.appendingPathComponent("\(route)-recipe-step-artifacts", isDirectory: true))
            }
        }
        try routes.record.encoded().write(to: target.appendingPathComponent("run-record.json"))
    }
}
