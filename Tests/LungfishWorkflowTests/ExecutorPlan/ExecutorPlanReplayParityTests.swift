// ExecutorPlanReplayParityTests.swift - The executor's replay of an emitted plan against the in-process import (CHTC lane K4, M5)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import XCTest
import LungfishIO
@testable import LungfishPortable
import LungfishTestSupport
@testable import LungfishWorkflow

/// BIO's parity ruling of tally-r3 (`BIO-r3.md` R1 to R9). The merged recipe runs on the 1,000,000-pair slice of sample
/// C079876_S1, once as VSP2 with rRNA removal off and once as wastewater with it on, through the in-process import and
/// through the built `lungfish-executor run --plan` replay of the plan the emitter writes for the same import, both on
/// this Mac. E0 to E3 must be equal, and E4 is printed as a `PARITY-E4` line and never fails the test.
///
/// The test runs only with `LUNGFISH_REQUIRE_TOOLS=1` and `LUNGFISH_PARITY_SLICE_DIR` naming the slice's folder, on a
/// scratch storage root that holds the two Deacon indexes (docs/development.md, "Running the recipe tests against a
/// scratch database root").
final class ExecutorPlanReplayParityTests: XCTestCase {
    static let sliceVariable = "LUNGFISH_PARITY_SLICE_DIR"
    static let sampleName = "C079876_S1"
    static let slice: [(name: String, sha256: String, size: Int64)] = [
        ("C079876_S1_1M_R1.fastq.gz", "581aa5a8cd55023e7030505479fee4e782f6a8f012ea91bebe8f525d202bd09c", 52_178_855),
        ("C079876_S1_1M_R2.fastq.gz", "a0b163cdf6d102ddd855d8bdbe51bc8c682fff99e2d5d707b5c61d7f4bc18ff9", 54_265_111),
    ]

    struct ParityCase: Sendable {
        let recipeName: String
        let removesRibosomalRNA: Bool
    }

    static let cases = [
        ParityCase(recipeName: "vsp2-target-enrichment", removesRibosomalRNA: false),
        ParityCase(recipeName: "wastewater-metagenomics", removesRibosomalRNA: true),
    ]

    /// R6. The in-process payload's E1 counts and E3 digest for each case, from this test's run at the lane's base
    /// `efcdc7e1c` (K4-M5a.md). A lane that changes a payload on purpose updates these with a prediction.
    static let frozen: [String: PayloadLevels.Anchor] = [
        "vsp2-target-enrichment": PayloadLevels.Anchor(
            e1: PayloadLevels.E1(records: 950_309, bases: 153_874_043, pairs: 100_191, singles: 749_927),
            e3: "f4d9a2ee74e8585c520907101952499327e34a8b83b0b36b7aa8596fc772b1f3"
        ),
        "wastewater-metagenomics": PayloadLevels.Anchor(
            e1: PayloadLevels.E1(records: 196_598, bases: 29_517_836, pairs: 11_227, singles: 174_144),
            e3: "418ed25cea1d29bbd2c35ea9ca410df5601b71046219ae686ad5b508ebcc0e66"
        ),
    ]

    /// The tools both routes run, read from the Mac's managed environments.
    static let tools: [NativeTool] = [.fastp, .deacon, .seqkit, .clumpify, .reformat, .bgzip, .pigz]
    static let databaseIDs = ["deacon-panhuman", "deacon-ribokmers"]

    private var scratch: URL?

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    func testVSP2PlanReplayMatchesInProcessImport() async throws {
        let root = try TestTempDirectory.make(prefix: "ExecutorPlanReplayParity")
        scratch = root
        let shared = try await Self.preparedShared()
        for parity in Self.cases {
            try await replay(parity, shared: shared, root: root)
        }
    }

    /// R1, the slice's bytes checked before either route runs, then the tools, the indexes and the Mac replay's
    /// manifest both routes run. The adopt parity tests (C4 lane P) share it.
    static func preparedShared() async throws -> Shared {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LUNGFISH_REQUIRE_TOOLS"] == "1", let sliceFolder = environment[Self.sliceVariable],
              !sliceFolder.isEmpty else {
            throw XCTSkip("The replay parity test runs with LUNGFISH_REQUIRE_TOOLS=1 and \(Self.sliceVariable) naming the slice's folder.")
        }
        var inputs: [ExecutorPlanSourceFile] = []
        for file in Self.slice {
            let measured = try ExecutorPlanSourceFile.measuring(URL(fileURLWithPath: sliceFolder).appendingPathComponent(file.name))
            guard measured.sha256 == file.sha256, measured.size == file.size else {
                XCTFail("\(file.name) has SHA-256 \(measured.sha256) and \(measured.size) bytes, not the slice's")
                throw XCTSkip("The slice does not match")
            }
            inputs.append(measured)
        }
        var toolPaths: [NativeTool: URL] = [:]
        for tool in Self.tools {
            guard let path = try? await NativeToolRunner.shared.toolPath(for: tool) else {
                try ToolAvailability.skipOrFail("Managed \(tool.rawValue) is not available")
            }
            toolPaths[tool] = path
        }
        var databases: [String: ExecutorPlanDatabaseFile] = [:]
        for id in Self.databaseIDs {
            guard let path = await DatabaseRegistry.shared.effectiveDatabasePath(for: id) else {
                try ToolAvailability.skipOrFail("The Deacon index \(id) is not installed")
            }
            let index = try ConformanceFixtures.installedManagedDatabaseFile(id: id, path: path)
            let database = ExecutorPlanDatabaseFile(record: try await RecipeDatabaseIdentity().record(databaseID: id, at: index))
            XCTAssertEqual(database.identity.lockPinned, true, "\(id) is installed at the lock's digest")
            databases[id] = database
        }

        // SWIFT's Q-K4-1 ruling: the Mac replay's manifest comes from the managed environments the in-process import
        // runs, so the two routes run the same executables. ARCH-r3 ruling 3: the plan writer gets the builder's manifest
        // as it is. The interleave step reads each merged-step output through the manifest's pigz, as the node does, so
        // no host program reads it and /usr/bin stays after the managed Java on PATH (ARCH fix 1 of the K4 part C review).
        let prefixes = Set(toolPaths.values.map { $0.deletingLastPathComponent().deletingLastPathComponent().path })
        let manifest = try ImageToolManifest.build(condaPrefixes: prefixes.sorted().map { URL(fileURLWithPath: $0) })
        let manifestData = try manifest.encoded()
        var pins: [PlanToolPin] = []
        for (tool, path) in toolPaths {
            let entry = try XCTUnwrap(manifest.tools.first {
                $0.path == path.path || URL(fileURLWithPath: $0.path).resolvingSymlinksInPath() == path.resolvingSymlinksInPath()
            }, "\(tool.rawValue) at \(path.path) is in the manifest")
            pins.append(PlanToolPin(id: entry.id, version: entry.version, build: entry.build))
        }
        // SWIFT's Q-K4-3 ruling: clumpify's Java comes from the manifest, here the bbtools environment's own openjdk.
        let java = try XCTUnwrap(manifest.tools.first { $0.id == "java" }, "The managed bbtools environment's Java is in the manifest")
        pins.append(PlanToolPin(id: java.id, version: java.version, build: java.build))
        pins.sort { $0.id < $1.id }
        return Shared(
            inputs: inputs, databases: databases, manifestData: manifestData, pins: pins,
            executor: try ExecutorPlanSourceFile.measuring(Self.builtExecutor()),
            recipeFile: try ExecutorPlanSourceFile.measuring(Self.recipeSourceURL())
        )
    }

    struct Shared {
        let inputs: [ExecutorPlanSourceFile]
        let databases: [String: ExecutorPlanDatabaseFile]
        let manifestData: Data
        let pins: [PlanToolPin]
        let executor: ExecutorPlanSourceFile
        let recipeFile: ExecutorPlanSourceFile
    }

    private func replay(_ parity: ParityCase, shared: Shared, root: URL) async throws {
        let name = parity.recipeName
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // R2 and R3. Each switch and setting is passed as an option, so both routes hold the same values and sources.
        let recipe = try XCTUnwrap(RecipeResolver.resolve(
            name, in: RecipeRegistryV2.builtinRecipes(),
            switchOptions: ["removeDuplicates": true, "removeRibosomalRNA": parity.removesRibosomalRNA]
        ), name)
        let config = FASTQBatchImporter.ImportConfig(
            projectDirectory: folder.appendingPathComponent("InProcess.lungfish", isDirectory: true), platform: .illumina,
            newRecipe: recipe, qualityBinning: .illumina4, optimizeStorage: true, clumpingTool: .bbtools, threads: 1,
            pairing: .paired, threadsSource: .option, clumpifyHeapGB: 4
        )
        let manifestURL = folder.appendingPathComponent("image-manifest.json")
        try shared.manifestData.write(to: manifestURL)
        let request = ExecutorPlanRequest(
            sample: PlanSampleValues(sampleName: Self.sampleName, originalFilenames: shared.inputs.map(\.url.lastPathComponent),
                                     originalSizeBytes: shared.inputs.reduce(0) { $0 + $1.size }),
            inputs: shared.inputs, inputFormat: .pairedR1R2, recipe: recipe, recipeFile: shared.recipeFile,
            storage: ExecutorPlanStorageRequest(
                requestedClumpingTool: config.clumpingTool, clumpifyHeapGB: config.clumpifyHeapGB ?? 0, threads: config.threads,
                compressor: .bgzip, qualityBinning: config.qualityBinning, compressionLevel: Self.zlibLevel(config.compressionLevel),
                threadsSource: config.threadsSource, clumpifyHeapSource: .option, compressorSource: .default,
                qualityBinningSource: config.qualityBinningSource
            ),
            executorFile: shared.executor,
            executorBuild: PlanExecutorBuild(
                lgeVersion: "2026.10.22", lgeCommit: "efcdc7e1c877fb6ac1c78e14af6fd2367f38f171",
                targetTriple: "arm64-apple-macosx", toolchainID: "swift-6.2", toolchainSHA256: String(repeating: "b", count: 64),
                staticLinuxSDKID: "swift-6.2-static-linux", staticLinuxSDKSHA256: String(repeating: "b", count: 64)
            ),
            imageManifest: PlanImageManifestPin(sha256: Self.sha256(shared.manifestData), size: Int64(shared.manifestData.count)),
            imageTools: shared.pins,
            deadlines: ExecutorPlanDeadlines(recipeStepSeconds: 7200, storageSeconds: 7200, statisticsSeconds: 3600, graceSeconds: 30),
            databases: shared.databases
        )
        let host = ExecutorPlanHostFacts(physicalMemoryBytes: Int64(ProcessInfo.processInfo.physicalMemory),
                                         processorCount: ProcessInfo.processInfo.activeProcessorCount)
        let emission = try ExecutorPlanEmitter.emission(request, host: host)
        let work = folder.appendingPathComponent("plan", isDirectory: true)
        let planFile = try ExecutorPlanFolderWriter.write(emission, into: work)

        // The replay starts first and runs beside the in-process import, each at one thread.
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
        let started = Date()
        let result = await FASTQBatchImporter.runBatchImport(
            pairs: [SamplePair(sampleName: Self.sampleName, r1: shared.inputs[0].url, r2: shared.inputs[1].url)],
            config: config, log: nil
        )
        let inProcessWall = Date().timeIntervalSince(started)
        var status: Int32 = -1
        for await value in exited { status = value }
        XCTAssertEqual(result.completed, 1, "\(name) in process: \(result.errors)")
        let record = try JSONDecoder().decode(
            ExecutorRunRecord.self, from: Data(contentsOf: work.appendingPathComponent("run-record.json"))
        )
        XCTAssertEqual(status, 0, "\(name) replay: \(record.reason ?? "") at \(record.failedStepID ?? "") \(record.refusedField ?? ""): \(String(decoding: (try? Data(contentsOf: stderrURL)) ?? Data(), as: UTF8.self))")
        guard result.completed == 1, status == 0 else {
            if result.completed == 1 {
                // R6 needs the in-process values even while the replay fails, so they are measured and printed here.
                let levels = try PayloadLevels.measure(config.projectDirectory.appendingPathComponent(
                    "Imports/\(Self.sampleName).lungfishfastq/\(Self.sampleName).fastq.gz"
                ))
                print("PARITY-FREEZE case=\(name) records=\(levels.e1.records) bases=\(levels.e1.bases) pairs=\(levels.e1.pairs) singles=\(levels.e1.singles) e2=\(levels.e2) e3=\(levels.e3) inProcessWallSeconds=\(String(format: "%.1f", inProcessWall))")
            }
            return
        }

        // E0. The plan the executor ran is the emitter's, each step ran its plan argv, and the plan's settings are the
        // in-process import's.
        let planBytes = try Data(contentsOf: planFile)
        XCTAssertEqual(planBytes, try emission.plan.encoded(), "\(name) E0 plan bytes")
        XCTAssertEqual(record.plan?.sha256, Self.sha256(planBytes), name)
        XCTAssertEqual(record.plan?.size, Int64(planBytes.count), name)
        for step in emission.plan.steps where !step.arguments.isEmpty {
            let ran = try XCTUnwrap(record.steps.first { $0.id == step.id }, "\(name) \(step.id)")
            XCTAssertTrue(ran.argv == step.arguments || Array(ran.argv.dropFirst()) == step.arguments,
                          "\(name) E0 \(step.id): \(ran.argv) against \(step.arguments)")
        }
        let storage = emission.plan.storage
        XCTAssertEqual(storage.threads, config.threads, name)
        XCTAssertEqual(storage.clumpifyHeapGB, config.clumpifyHeapGB, name)
        XCTAssertEqual(storage.clumpingTool.rawValue, config.clumpingTool.rawValue, name)
        XCTAssertEqual(storage.clumpingToolSource, config.clumpingToolSource, name)
        XCTAssertEqual(storage.qualityBinning, config.qualityBinning, name)
        XCTAssertEqual(storage.qualityBinningSource, config.qualityBinningSource, name)
        XCTAssertEqual(storage.threadsSource, config.threadsSource, name)
        XCTAssertEqual(storage.compressor, .bgzip, name)
        XCTAssertEqual(emission.plan.recipe?.sourceSHA256, shared.recipeFile.sha256, name)
        XCTAssertEqual(emission.plan.recipe?.switches.map { "\($0.id)=\($0.value) \($0.source)" },
                       recipe.switchSettings.map { "\($0.id)=\($0.value) \($0.source)" }, name)
        XCTAssertEqual(record.recipe, emission.plan.recipe, name)
        XCTAssertEqual(record.imageManifest?.source, .argument, name)
        XCTAssertEqual(record.imageManifest?.sha256, Self.sha256(shared.manifestData), name)
        // ARCH fix 1 of the K4 part C review. The fixed folders come once and last, after the folder of the manifest's
        // Java that clumpify finds through PATH.
        let searchPath = try XCTUnwrap(record.searchPath, name)
        XCTAssertEqual(Array(searchPath.suffix(2)), ["/usr/bin", "/bin"], name)
        XCTAssertEqual(searchPath.filter { $0 == "/usr/bin" }.count, 1, name)
        let java = try XCTUnwrap(record.runtimes?.first { $0.id == "java" }, "\(name) states the manifest's Java")
        let javaFolder = try XCTUnwrap(
            searchPath.firstIndex(of: (java.path as NSString).deletingLastPathComponent), "\(name) \(java.path)"
        )
        XCTAssertLessThan(javaFolder, searchPath.count - 2, name)
        // The in-process import has no compressor option, so it must have resolved bgzip and never pigz.
        let bundle = config.projectDirectory.appendingPathComponent("Imports/\(Self.sampleName).lungfishfastq", isDirectory: true)
        let provenanceURL = bundle.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(fromSidecar: provenanceURL), name)
        let toolNames = envelope.steps.map(\.toolName)
        XCTAssertTrue(toolNames.contains { $0.contains("bgzip") }, "\(name) in process resolved bgzip: \(toolNames)")
        XCTAssertFalse(toolNames.contains { $0.contains("pigz") }, "\(name) in process resolved pigz: \(toolNames)")

        // E1 to E3, with R6's anchor on the in-process payload.
        let inProcessPayload = bundle.appendingPathComponent("\(Self.sampleName).fastq.gz")
        let replayPayload = work.appendingPathComponent(ExecutorPlanEmitter.payloadPath)
        let inProcess = try PayloadLevels.measure(inProcessPayload)
        let replayed = try PayloadLevels.measure(replayPayload)
        print("PARITY-FREEZE case=\(name) records=\(inProcess.e1.records) bases=\(inProcess.e1.bases) pairs=\(inProcess.e1.pairs) singles=\(inProcess.e1.singles) e2=\(inProcess.e2) e3=\(inProcess.e3)")
        XCTAssertEqual(inProcess.anchor, Self.frozen[name], "\(name) R6 frozen in-process E1 and E3")
        XCTAssertEqual(replayed.e1, inProcess.e1, "\(name) E1")
        XCTAssertEqual(replayed.e2, inProcess.e2, "\(name) E2")
        XCTAssertEqual(replayed.e3, inProcess.e3, "\(name) E3")

        // R8 and the XC-14 condition. The run record is true to its own payload, and the sidecar to the in-process one.
        let payload = try XCTUnwrap(record.payloads.first, name)
        let replayFile = try ExecutorPlanSourceFile.measuring(replayPayload)
        XCTAssertEqual(payload.relativePath, ExecutorPlanEmitter.payloadPath, name)
        XCTAssertEqual(payload.sha256, replayFile.sha256, name)
        XCTAssertEqual(payload.size, replayFile.size, name)
        XCTAssertEqual(payload.recordCount, Int64(replayed.e1.records), name)
        let counts = try XCTUnwrap(record.steps.first { $0.kind == .qualityCount }?.qualityCounts, name)
        XCTAssertEqual(counts.recordCount, Int64(replayed.e1.records), name)
        XCTAssertEqual(counts.baseCount, Int64(replayed.e1.bases), name)
        XCTAssertEqual(counts.q20Count, Int64(replayed.q20), name)
        XCTAssertEqual(counts.q30Count, Int64(replayed.q30), name)
        let statistics = try XCTUnwrap(FASTQMetadataStore.load(for: inProcessPayload)?.computedStatistics, name)
        XCTAssertEqual(statistics.readCount, inProcess.e1.records, name)
        XCTAssertEqual(statistics.baseCount, Int64(inProcess.e1.bases), name)
        XCTAssertEqual(statistics.q20Percentage, Double(inProcess.q20) / Double(inProcess.e1.bases) * 100, accuracy: 0.01, name)
        XCTAssertEqual(statistics.q30Percentage, Double(inProcess.q30) / Double(inProcess.e1.bases) * 100, accuracy: 0.01, name)
        let recipeSteps = record.steps.filter { $0.kind == .recipe }
        for step in recipeSteps {
            XCTAssertNotNil(step.inputReadCount, "\(name) \(step.id) input reads")
            XCTAssertNotNil(step.outputReadCount, "\(name) \(step.id) output reads")
        }
        XCTAssertEqual(recipeSteps.compactMap { $0.tool?.id },
                       ["fastp", "deacon"] + (parity.removesRibosomalRNA ? ["deacon"] : []) + ["fastp", "seqkit", "fastp"], name)
        XCTAssertEqual(record.recipe?.turnedOffSteps.map(\.switchID), parity.removesRibosomalRNA ? [] : ["removeRibosomalRNA"], name)

        // R7. E4 is reported and never fails the test.
        let firstDifference = zip(inProcess.recordDigests, replayed.recordDigests).enumerated().first { $0.element.0 != $0.element.1 }?.offset
            ?? (inProcess.recordDigests.count == replayed.recordDigests.count ? nil : min(inProcess.recordDigests.count, replayed.recordDigests.count))
        let provenanceText = String(decoding: (try? Data(contentsOf: provenanceURL)) ?? Data(), as: UTF8.self)
        let inProcessGroups = provenanceText.components(separatedBy: "Set groups to ").dropFirst().compactMap { Int($0.prefix { $0.isNumber }) }
        let storageStep = record.steps.first { $0.kind == .storage }
        // The real probe found the managed bgzip, so the record names it as the writer (BIO fix 1 of the K4 part C review).
        XCTAssertEqual(storageStep?.storage?.writer?.name, "bgzip", name)
        let stepWalls = record.steps.map { "\($0.id)=\(String(format: "%.1f", $0.wallSeconds))" }.joined(separator: ",")
        print("PARITY-E4 case=\(name) equalInStoredOrder=\(inProcess.e4 == replayed.e4) firstDifferingRecord=\(firstDifference.map(String.init) ?? "none") groupsInProcess=\(inProcessGroups) groupsReplay=\(storageStep?.storage?.clumpifyGroups.map(String.init) ?? "none") inProcessWallSeconds=\(String(format: "%.1f", inProcessWall)) replayWallSeconds=\(String(format: "%.1f", record.wallSeconds)) replaySteps=\(stepWalls)")
    }

    static func zlibLevel(_ level: CompressionLevel) -> Int {
        switch level {
        case .fast: return 1
        case .balanced: return 4
        case .maximum: return 9
        }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The recipe file the bundled registry loads, found the way the registry finds it.
    static func recipeSourceURL() throws -> URL {
        let folder = try XCTUnwrap(RecipeBundleAccessor.recipesDirectoryURL(), "The bundled recipes folder was not found")
        return folder.appendingPathComponent("illumina-paired-cleanup.recipe.json")
    }

    /// The `lungfish-executor` built beside the test bundle, or the one `LUNGFISH_EXECUTOR_BINARY` names.
    static func builtExecutor() throws -> URL {
        if let path = ProcessInfo.processInfo.environment["LUNGFISH_EXECUTOR_BINARY"], FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let candidate = Bundle(for: ExecutorPlanReplayParityTests.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("lungfish-executor")
        return try XCTUnwrap(FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil,
                             "lungfish-executor was not built beside the tests at \(candidate.path)")
    }
}

/// The levels of BIO's R5 for one stored payload, as `c0/scripts/fastq_levels.py` defines them. A record followed by its
/// mate (equal names once `@`, the text after the first blank and a `/1` or `/2` are dropped) is one pair unit, and any
/// other record is one single unit. E2 sums the SHA-256 of each unit's sequences (a pair as R1, NUL, R2) modulo 2^256,
/// E3 the SHA-256 of each unit's header, sequence and quality lines joined by newlines. E4 is the SHA-256 of the
/// decompressed stream in stored order, with each record's digest kept to find the first record that differs.
struct PayloadLevels {
    struct E1: Equatable, Sendable {
        var records: Int
        var bases: Int
        var pairs: Int
        var singles: Int
    }

    struct Anchor: Equatable, Sendable {
        var e1: E1
        var e3: String
    }

    var e1 = E1(records: 0, bases: 0, pairs: 0, singles: 0)
    var q20 = 0
    var q30 = 0
    var e2 = ""
    var e3 = ""
    var e4 = ""
    var recordDigests: [UInt64] = []

    var anchor: Anchor { Anchor(e1: e1, e3: e3) }

    private struct Record {
        let header: [UInt8]
        let sequence: [UInt8]
        let quality: [UInt8]

        var key: ArraySlice<UInt8> {
            var name = header.dropFirst().prefix { $0 != 0x20 && $0 != 0x09 }
            if name.count > 2, name[name.endIndex - 2] == 0x2F, name.last == 0x31 || name.last == 0x32 {
                name = name.dropLast(2)
            }
            return name
        }
    }

    static func measure(_ url: URL) throws -> PayloadLevels {
        var levels = PayloadLevels()
        var e2 = ModularSum()
        var e3 = ModularSum()
        var stream = SHA256()
        var lines: [[UInt8]] = []
        var pending: Record?
        func single(_ record: Record) {
            levels.e1.singles += 1
            e2.add(record.sequence)
            e3.add(record.header + [0x0A] + record.sequence + [0x0A] + record.quality)
        }
        try url.forEachLineAutoDecompressing { line in
            lines.append(Array(line.utf8))
            guard lines.count == 4 else { return }
            let record = Record(header: lines[0], sequence: lines[1], quality: lines[3])
            let bytes = lines[0] + [0x0A] + lines[1] + [0x0A] + lines[2] + [0x0A] + lines[3] + [0x0A]
            lines.removeAll(keepingCapacity: true)
            stream.update(data: bytes)
            levels.recordDigests.append(SHA256.hash(data: bytes).prefix(8).reduce(0) { $0 << 8 | UInt64($1) })
            levels.e1.records += 1
            levels.e1.bases += record.sequence.count
            for byte in record.quality {
                if byte >= 33 + 20 { levels.q20 += 1 }
                if byte >= 33 + 30 { levels.q30 += 1 }
            }
            if let first = pending {
                if first.key == record.key {
                    levels.e1.pairs += 1
                    e2.add(first.sequence + [0x00] + record.sequence)
                    e3.add(first.header + [0x0A] + first.sequence + [0x0A] + first.quality + [0x0A]
                           + record.header + [0x0A] + record.sequence + [0x0A] + record.quality)
                    pending = nil
                    return
                }
                single(first)
            }
            pending = record
        }
        if let last = pending { single(last) }
        levels.e2 = e2.hex
        levels.e3 = e3.hex
        levels.e4 = stream.finalize().map { String(format: "%02x", $0) }.joined()
        return levels
    }
}

/// The sum of SHA-256 digests modulo 2^256, in four 64-bit limbs, most significant first.
struct ModularSum {
    private var limbs: [UInt64] = [0, 0, 0, 0]

    mutating func add(_ bytes: [UInt8]) {
        let digest = Array(SHA256.hash(data: bytes))
        var carry: UInt64 = 0
        for index in stride(from: 3, through: 0, by: -1) {
            let limb = digest[(index * 8)..<(index * 8 + 8)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            let (partial, first) = limbs[index].addingReportingOverflow(limb)
            let (sum, second) = partial.addingReportingOverflow(carry)
            limbs[index] = sum
            carry = (first ? 1 : 0) + (second ? 1 : 0)
        }
    }

    var hex: String { limbs.map { String(format: "%016llx", $0) }.joined() }
}
