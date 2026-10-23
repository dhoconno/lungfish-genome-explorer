// ExecutorPlanEmitterTests.swift - The plan emitter's clumping entry, Mac invariance and argv (CHTC lane K4, M2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import LungfishPortable
import LungfishTestSupport
@testable import LungfishWorkflow

final class ExecutorPlanEmitterTests: XCTestCase {
    private static let gib: Int64 = 1_073_741_824
    private static let mac24 = ExecutorPlanHostFacts(physicalMemoryBytes: 24 * gib, processorCount: 4)
    private static let mac192 = ExecutorPlanHostFacts(physicalMemoryBytes: 192 * gib, processorCount: 28)
    private static let digest = String(repeating: "b", count: 64)
    private static let pins = [
        PlanToolPin(id: "fastp", version: "1.0.1", build: "h43da1c4_0"),
        PlanToolPin(id: "clumpify.sh", version: "39.13", build: "he5f24ec_0"),
        PlanToolPin(id: "reformat.sh", version: "39.13", build: "he5f24ec_0"),
        PlanToolPin(id: "seqkit", version: "2.10.0", build: "h9ee0642_0"),
        PlanToolPin(id: "gzip", version: "1.13", build: "h8359307_0"),
        PlanToolPin(id: "bgzip", version: "1.21", build: "h3ff9d97_0"),
        PlanToolPin(id: "deacon", version: "0.13.2", build: "h4349ce8_0"),
        PlanToolPin(id: "trim_galore", version: "2.3.0", build: "h48b4a6d_0"),
    ]

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "ExecutorPlanEmitter")
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func recipe() -> Recipe {
        Recipe(formatVersion: 1, id: "plan-test", name: "Plan Test", platforms: [.illumina], requiredInput: .paired,
               steps: [RecipeStep(type: "fastp-dedup"), RecipeStep(type: "fastp-trim"), RecipeStep(type: "fastp-merge")])
    }

    /// A small R1/R2 pair named for `sample` in its own folder.
    private func writePair(_ sample: String) throws -> [URL] {
        let folder = root.appendingPathComponent(sample, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let r1 = folder.appendingPathComponent("\(sample)_R1.fastq")
        let r2 = folder.appendingPathComponent("\(sample)_R2.fastq")
        try "@pair1/1\nACGTACGTAC\n+\nIIIIIIIIII\n@pair2/1\nTTGGCCAATT\n+\nIIIIIIIIII\n".write(to: r1, atomically: true, encoding: .utf8)
        try "@pair1/2\nGTACGTACGT\n+\nIIIIIIIIII\n@pair2/2\nAATTGGCCAA\n+\nIIIIIIIIII\n".write(to: r2, atomically: true, encoding: .utf8)
        return [r1, r2]
    }

    private func request(
        _ sample: String, inputs: [URL], clumping: ClumpingTool, heapGB: Int = 4, recipe chosen: Recipe? = nil,
        databases: [String: ExecutorPlanDatabaseFile] = [:]
    ) throws -> ExecutorPlanRequest {
        let executor = root.appendingPathComponent("lungfish-executor")
        if !FileManager.default.fileExists(atPath: executor.path) {
            try Data("executor stand-in".utf8).write(to: executor)
        }
        let files = try inputs.map { try ExecutorPlanSourceFile.measuring($0) }
        return ExecutorPlanRequest(
            sample: PlanSampleValues(sampleName: sample, originalFilenames: inputs.map(\.lastPathComponent),
                                     originalSizeBytes: files.reduce(0) { $0 + $1.size }),
            inputs: files, inputFormat: .pairedR1R2, recipe: nil, recipeFile: nil,
            plannedSteps: try RecipeEngine().plan(recipe: chosen ?? recipe(), inputFormat: .pairedR1R2),
            storage: ExecutorPlanStorageRequest(
                requestedClumpingTool: clumping, clumpifyHeapGB: heapGB, threads: 1, statisticsThreads: 1,
                compressor: .bgzip, qualityBinning: .illumina4, compressionLevel: 4, threadsSource: .option,
                clumpifyHeapSource: .option, compressorSource: .default, qualityBinningSource: .default
            ),
            executorFile: try ExecutorPlanSourceFile.measuring(executor),
            executorBuild: PlanExecutorBuild(
                lgeVersion: "2026.10.22", lgeCommit: "74ae0db3400d6b7519550e33dafc369e081fa114",
                targetTriple: "x86_64-swift-linux-musl", toolchainID: "swift-6.2", toolchainSHA256: Self.digest,
                staticLinuxSDKID: "swift-6.2-static-linux", staticLinuxSDKSHA256: Self.digest
            ),
            imageManifest: PlanImageManifestPin(sha256: Self.digest, size: 4096), imageTools: Self.pins,
            deadlines: ExecutorPlanDeadlines(recipeStepSeconds: 3600, storageSeconds: 7200, statisticsSeconds: 1800, graceSeconds: 30),
            databases: databases
        )
    }

    private func keyPaths(_ value: Any, _ path: String = "") -> [String: String] {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [:]) { $0.merge(keyPaths($1.value, path + "." + $1.key)) { a, _ in a } }
        }
        if let array = value as? [Any] {
            return array.enumerated().reduce(into: [:]) { $0.merge(keyPaths($1.element, path + "[\($1.offset)]")) { a, _ in a } }
        }
        return [path: "\(value)"]
    }

    func testPlanClumpingRawValuesMatchClumpingTool() {
        XCTAssertEqual(PlanClumpingRequest.allCases.map(\.rawValue), ClumpingTool.allCases.map(\.rawValue))
        XCTAssertEqual(PlanClumpingTool.allCases.map(\.rawValue), ClumpingTool.allCases.filter { $0 != .auto }.map(\.rawValue))
    }

    /// N2-T1 with UX's two reason tests folded in.
    func testPlanForAutoClumpingNamesBBToolsWithNoEstimate() throws {
        let pair = try writePair("S")
        let plan = try ExecutorPlanEmitter.emit(request("S", inputs: pair, clumping: .auto), host: Self.mac24)
        XCTAssertEqual(plan.clumping.requested, .auto)
        XCTAssertEqual(plan.clumping.resolved, .bbtools)
        XCTAssertEqual(plan.clumping.heapBytes, 4_294_967_296)
        XCTAssertEqual(plan.clumping.reason, "The automatic clumping choice names BBTools clumpify for every sample, at the plan's heap and with no size estimate, because clumpify's groups=auto compares its memory estimate for each input with the memory available in that heap and splits a large input into more groups.")
        XCTAssertEqual(plan.clumping.resolvedSource, .default)
        XCTAssertEqual(plan.storage.clumpingToolSource, .default)
        let paths = keyPaths(try JSONSerialization.jsonObject(with: plan.encoded())).keys
        for banned in ["estimatedInputBytes", "physicalMemoryBytes", "thresholdBytes"] {
            XCTAssertFalse(paths.contains { $0.hasSuffix("." + banned) || $0.contains("." + banned + ".") }, banned)
        }
        let storage = try XCTUnwrap(plan.steps.first { $0.kind == .storage })
        XCTAssertEqual(storage.tool?.id, "clumpify.sh")
        XCTAssertEqual(storage.environment, [PlanEnvironmentVariable(name: "_JAVA_OPTIONS", value: "-Xmx4g")])

        for named in [ClumpingTool.bbtools, .none] {
            let namedPlan = try ExecutorPlanEmitter.emit(request("S", inputs: pair, clumping: named), host: Self.mac24)
            XCTAssertEqual(namedPlan.clumping.requested.rawValue, named.rawValue)
            XCTAssertEqual(namedPlan.clumping.resolved.rawValue, named.rawValue)
            XCTAssertEqual(namedPlan.clumping.resolvedSource, .option)
            XCTAssertEqual(namedPlan.clumping.reason, "explicit clumping tool selection")
            XCTAssertNil(namedPlan.clumping.operationNotice)
        }
    }

    /// ARCH A5 withdrew K4.9's refusal: a named Trim Galore is planned as the Mac resolves it, with its notice.
    func testPlanNamesTrimGaloreWithItsOperationNotice() throws {
        let pair = try writePair("S")
        let emission = try ExecutorPlanEmitter.emission(request("S", inputs: pair, clumping: .trimGalore), host: Self.mac24)
        let plan = emission.plan
        XCTAssertEqual(plan.clumping.requested, .trimGalore)
        XCTAssertEqual(plan.clumping.resolved, .trimGalore)
        XCTAssertEqual(plan.storage.clumpingTool, .trimGalore)
        XCTAssertEqual(plan.clumping.resolvedSource, .option)
        XCTAssertEqual(plan.storage.clumpingToolSource, .option)
        XCTAssertEqual(plan.clumping.reason, "explicit clumping tool selection")
        XCTAssertEqual(plan.clumping.heapBytes, 4_294_967_296)
        XCTAssertEqual(plan.clumping.operationNotice, ClumpingTool.trimGalore.operationNotice)
        XCTAssertEqual(plan.clumping.operationNotice, "Trim Galore --clumpify also performs adapter/quality filtering and may remove short reads.")
        let storage = try XCTUnwrap(plan.steps.first { $0.kind == .storage })
        XCTAssertEqual(storage.tool?.id, "trim_galore")
        XCTAssertEqual(storage.arguments, [])
        XCTAssertEqual(storage.environment, [])
        XCTAssertTrue(plan.tools.contains { $0.id == "reformat.sh" }, "the Trim Galore route interleaves pairs with reformat.sh")

        let file = try ExecutorPlanFolderWriter.write(emission, into: root.appendingPathComponent("trim-galore-plan", isDirectory: true))
        let decoded = try ExecutionPlan.decode(Data(contentsOf: file))
        XCTAssertEqual(decoded.clumping.operationNotice, ClumpingTool.trimGalore.operationNotice)
        XCTAssertEqual(decoded.storage.clumpingTool, .trimGalore)
    }

    /// N2-T2.
    func testPlanTemplateForAutoIsEqualOnEveryMac() throws {
        let pair = try writePair("S")
        let small = try ExecutorPlanFolderWriter.write(
            ExecutorPlanEmitter.emission(request("S", inputs: pair, clumping: .auto), host: Self.mac24),
            into: root.appendingPathComponent("plan-24", isDirectory: true)
        )
        let large = try ExecutorPlanFolderWriter.write(
            ExecutorPlanEmitter.emission(request("S", inputs: pair, clumping: .auto), host: Self.mac192),
            into: root.appendingPathComponent("plan-192", isDirectory: true)
        )
        XCTAssertEqual(try Data(contentsOf: small), try Data(contentsOf: large))
        XCTAssertEqual(try ExecutionPlan.decode(Data(contentsOf: small)).clumping.resolved, .bbtools)
    }

    /// N2-T3. Sample L is S's pair extended to 600 MiB each, stored sparse.
    func testPlanNamesBBToolsWhereMacAutoSkipsClumping() throws {
        let small = try writePair("S")
        let large = try writePair("L")
        for url in large {
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 600 * 1_048_576)
            try handle.close()
        }
        let macLarge = ClumpingTool.auto.resolve(
            estimatedInputBytes: FASTQIngestionPipeline.estimatedUncompressedInputBytes(for: large),
            physicalMemoryBytes: 25_769_803_776, pinnedHeapGB: 1
        )
        XCTAssertEqual(macLarge.resolved, .none)
        XCTAssertEqual(macLarge.reason, "skipped clumping: estimated input exceeds the BBTools clumpify memory budget")
        let macSmall = ClumpingTool.auto.resolve(
            estimatedInputBytes: FASTQIngestionPipeline.estimatedUncompressedInputBytes(for: small),
            physicalMemoryBytes: 25_769_803_776, pinnedHeapGB: 1
        )
        XCTAssertEqual(macSmall.resolved, .bbtools)

        let planS = try ExecutorPlanEmitter.emit(request("S", inputs: small, clumping: .auto, heapGB: 1), host: Self.mac24)
        let planL = try ExecutorPlanEmitter.emit(request("L", inputs: large, clumping: .auto, heapGB: 1), host: Self.mac24)
        XCTAssertEqual(planS.clumping, planL.clumping)
        XCTAssertEqual(planS.clumping.resolved, .bbtools)
        XCTAssertEqual(planS.clumping.heapBytes, 1_073_741_824)
        XCTAssertEqual(planS.clumping.reason, ExecutorPlanEmitter.automaticClumpingReason)
        XCTAssertEqual(planS.clumping.resolvedSource, .default)

        let pathsS = keyPaths(try JSONSerialization.jsonObject(with: planS.encoded()))
        let pathsL = keyPaths(try JSONSerialization.jsonObject(with: planL.encoded()))
        XCTAssertEqual(Set(pathsS.keys), Set(pathsL.keys))
        let differing = Set(pathsS.keys.filter { pathsS[$0] != pathsL[$0] })
        let allowed = differing.filter { path in
            path == ".sample.sampleName" || path == ".sample.originalSizeBytes" || path.hasPrefix(".sample.originalFilenames[")
                || (path.hasPrefix(".entries[") && [".relativePath", ".sha256", ".size"].contains { path.hasSuffix($0) })
        }
        XCTAssertEqual(differing, allowed, "Plans differ outside QA's list: \(differing.subtracting(allowed).sorted())")
        let inputEntries = planL.entries.filter { $0.role == .input }
        XCTAssertEqual(inputEntries.map(\.size), [629_145_600, 629_145_600])
    }

    /// Stand-ins for fastp, deacon and seqkit that copy each input to its output (gzipping a plain one) and write the
    /// reports. deacon and seqkit take their inputs as the arguments just before `-o`.
    private func fakeRunner() throws -> NativeToolRunner {
        let put = #"put() { if /usr/bin/gzip -t "$1" 2>/dev/null; then /bin/cp "$1" "$2"; else /usr/bin/gzip -c "$1" > "$2"; fi; }"#
        let scripts: [(env: String, name: String, body: String)] = [
            ("fastp", "fastp", """
            if [ "${1:-}" = "--version" ]; then echo "fastp 1.0.1"; exit 0; fi
            in1=""; in2=""; o1=""; o2=""; m=""; report=""
            while [ "$#" -gt 0 ]; do
              case "$1" in
                -i) in1="$2"; shift 2 ;; -I) in2="$2"; shift 2 ;;
                -o|--out1) o1="$2"; shift 2 ;; -O|--out2) o2="$2"; shift 2 ;;
                --merged_out) m="$2"; shift 2 ;; -j) report="$2"; shift 2 ;;
                *) shift ;;
              esac
            done
            [ -n "$o1" ] && put "$in1" "$o1"
            [ -n "$o2" ] && put "$in2" "$o2"
            [ -n "$m" ] && put "$in1" "$m"
            printf '%s\\n' '{"summary":{"before_filtering":{"total_reads":4}}}' > "$report"
            """),
            ("deacon", "deacon", """
            case "${1:-}" in --version|-V) echo "deacon 0.13.2"; exit 0 ;; esac
            p2=""; p1=""; in1=""; in2=""; o1=""; o2=""; summary=""
            while [ "$#" -gt 0 ]; do
              case "$1" in
                -o) in1="$p2"; in2="$p1"; o1="$2"; shift 2 ;; -O) o2="$2"; shift 2 ;;
                --summary) summary="$2"; shift 2 ;;
                *) p2="$p1"; p1="$1"; shift ;;
              esac
            done
            put "$in1" "$o1"; put "$in2" "$o2"; printf '{}\\n' > "$summary"
            """),
            ("seqkit", "seqkit", """
            case "${1:-}" in version|--version) echo "seqkit v2.10.0"; exit 0 ;; esac
            p1=""; src=""; out=""
            while [ "$#" -gt 0 ]; do
              case "$1" in
                -o) src="$p1"; out="$2"; shift 2 ;;
                *) p1="$1"; shift ;;
              esac
            done
            put "$src" "$out"
            """),
        ]
        for script in scripts {
            let bin = root.appendingPathComponent(".lungfish/conda/envs/\(script.env)/bin", isDirectory: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let executable = bin.appendingPathComponent(script.name)
            try "#!/bin/sh\nset -eu\n\(put)\n\(script.body)\n".write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        return NativeToolRunner(toolsDirectory: nil, homeDirectory: root, appIdentity: .preview)
    }

    /// `root/inputs/R1.fastq` and `R2.fastq`, copies of S's pair, and an empty `root/work`.
    private func layOutWorkRoot(_ pair: [URL]) throws -> (input: StepInput, work: URL) {
        let inputs = root.appendingPathComponent("inputs", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let r1 = inputs.appendingPathComponent("R1.fastq")
        let r2 = inputs.appendingPathComponent("R2.fastq")
        if !FileManager.default.fileExists(atPath: r1.path) {
            try FileManager.default.copyItem(at: pair[0], to: r1)
            try FileManager.default.copyItem(at: pair[1], to: r2)
        }
        return (StepInput(r1: r1, r2: r2, format: .pairedR1R2), work)
    }

    /// Each recorded tool run's argv with the tool's path dropped, the root removed and the fused report's
    /// per-run UUID taken out, after asserting its pattern.
    private func recordedArguments(_ result: RecipeExecutionResult) -> [[String]] {
        result.stepRecords.compactMap(\.commandArguments).map { recorded in
            var argv = recorded
            if argv.first?.hasPrefix("/") == true { argv.removeFirst() }
            return argv.map { argument in
                let relative = argument.replacingOccurrences(of: root.path + "/", with: "")
                guard relative.hasPrefix("work/sample_fused_fastp_report_") else { return relative }
                XCTAssertNotNil(relative.range(of: #"^work/sample_fused_fastp_report_[0-9A-F-]{36}\.json$"#, options: .regularExpression))
                return "work/sample_fused_fastp_report.json"
            }
        }
    }

    func testEmittedPlanMatchesRecordedArgvOfInProcessRun() async throws {
        let pair = try writePair("S")
        let (input, work) = try layOutWorkRoot(pair)
        let result = try await RecipeEngine().execute(
            recipe: recipe(), input: input,
            context: StepContext(workspace: work, threads: 1, sampleName: ExecutorPlanEmitter.workStem,
                                 runner: try fakeRunner(), progress: { _, _ in })
        )
        let recorded = recordedArguments(result)
        XCTAssertEqual(recorded.count, 2, "the fused fastp run and the merge run")

        let plan = try ExecutorPlanEmitter.emit(request("S", inputs: pair, clumping: .auto), host: Self.mac24)
        XCTAssertEqual(plan.steps.filter { $0.kind == .recipe }.map(\.arguments), recorded)
        XCTAssertEqual(plan.steps.map(\.kind), [.recipe, .recipe, .interleave, .storage, .statistics, .qualityCount])
    }

    /// BIO's two parity cases of tally-r3: the merged recipe as VSP2 (rRNA removal off) and as wastewater (on), at
    /// threads 1, bbtools, a 4 GB heap, illumina4 and bgzip. Every recipe step's argv equals the in-process run's.
    func testMergedRecipeEmitsCompletePlanForBothRRNASettings() async throws {
        let pair = try writePair("S")
        var indexes: [String: URL] = [:]
        var databases: [String: ExecutorPlanDatabaseFile] = [:]
        for (id, name) in [("test-panhuman", "panhuman-1.k31w15.idx"), ("deacon-ribokmers", "ribokmers.k31w15.idx")] {
            let folder = root.appendingPathComponent("databases/\(id)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let index = folder.appendingPathComponent(name)
            try Data("deacon index \(id)".utf8).write(to: index)
            indexes[id] = index
            databases[id] = ExecutorPlanDatabaseFile(
                file: try ExecutorPlanSourceFile.measuring(index),
                identity: PlanDatabaseIdentity(id: id, version: "test", format: "deacon-index")
            )
        }
        let runner = try fakeRunner()
        let builtin = RecipeRegistryV2.builtinRecipes()
        for (name, removesRibosomalRNA) in [("vsp2-target-enrichment", false), ("wastewater-metagenomics", true)] {
            var merged = try XCTUnwrap(RecipeResolver.resolve(name, in: builtin), name)
            // The bundled lock pins the 3.3 GB panhuman index by size and SHA-256, and the in-process run checks the
            // index against it, so the scrub reads a stand-in under an id the lock does not hold. Its argv is unchanged.
            for index in merged.steps.indices where merged.steps[index].type == "deacon-scrub" {
                merged.steps[index].params?["database"] = .string("test-panhuman")
            }
            XCTAssertEqual(merged.id, "illumina-paired-cleanup")
            XCTAssertEqual(merged.switchSettings.first { $0.id == "removeRibosomalRNA" }?.value, removesRibosomalRNA)
            let (input, work) = try layOutWorkRoot(pair)
            let result = try await RecipeEngine().execute(
                recipe: merged, input: input,
                context: StepContext(workspace: work, threads: 1, sampleName: ExecutorPlanEmitter.workStem,
                                     runner: runner, databasePaths: indexes, progress: { _, _ in })
            )
            let recorded = recordedArguments(result)

            let emission = try ExecutorPlanEmitter.emission(
                request("S", inputs: pair, clumping: .bbtools, recipe: merged, databases: databases), host: Self.mac24
            )
            let plan = emission.plan
            let recipeSteps = plan.steps.filter { $0.kind == .recipe }
            XCTAssertEqual(recipeSteps.map(\.arguments), recorded, name)
            XCTAssertEqual(recipeSteps.map { $0.tool?.id }, ["fastp", "deacon"] + (removesRibosomalRNA ? ["deacon"] : []) + ["fastp", "seqkit", "fastp"], name)
            XCTAssertEqual(Array(plan.steps.map(\.kind).suffix(4)), [.interleave, .storage, .statistics, .qualityCount], name)
            let ids = ["test-panhuman"] + (removesRibosomalRNA ? ["deacon-ribokmers"] : [])
            let entries = plan.entries.filter { $0.role == .database }
            XCTAssertEqual(entries.map(\.relativePath), ids.map { "databases/\($0)/\(indexes[$0]!.lastPathComponent)" }, name)
            XCTAssertEqual(entries.map(\.sha256), ids.map { databases[$0]!.file.sha256 }, name)
            XCTAssertEqual(entries.compactMap(\.database?.id), ids, name)
            XCTAssertTrue(recipeSteps[1].inputs.contains(entries[0].relativePath), "the scrub step reads its index")
            XCTAssertEqual(plan.storage.clumpingTool, .bbtools)
            XCTAssertEqual(plan.storage.clumpifyHeapGB, 4)
            XCTAssertEqual(plan.storage.compressor, .bgzip)
            XCTAssertEqual(plan.storage.qualityBinning, .illumina4)
            XCTAssertEqual(plan.storage.threads, 1)
            XCTAssertEqual(plan.steps.first { $0.kind == .statistics }?.arguments, ["stats", "-a", "-T", "out/sample.fastq.gz"])

            let file = try ExecutorPlanFolderWriter.write(emission, into: root.appendingPathComponent("plan-\(name)", isDirectory: true))
            XCTAssertEqual(try ExecutionPlan.decode(Data(contentsOf: file)), plan, name)
        }
    }

    func testEmittedPlanCarriesNoSigningKey() throws {
        let pair = try writePair("S")
        let emission = try ExecutorPlanEmitter.emission(request("S", inputs: pair, clumping: .auto), host: Self.mac24)
        let text = String(decoding: try emission.plan.encoded(), as: UTF8.self)
        XCTAssertFalse(text.contains("LUNGFISH_PROVENANCE_SIGNING"))
        for step in emission.plan.steps {
            XCTAssertFalse(step.environment.contains { $0.name.hasPrefix("LUNGFISH_PROVENANCE_SIGNING") }, step.id)
        }

        var keyed = emission.plan
        keyed.steps[0].environment.append(PlanEnvironmentVariable(
            name: "LUNGFISH_PROVENANCE_SIGNING_KEY_FILE", value: "/Users/someone/.lungfish/signing.key"
        ))
        let folder = root.appendingPathComponent("keyed-plan", isDirectory: true)
        XCTAssertThrowsError(try ExecutorPlanFolderWriter.write(
            ExecutorPlanEmission(plan: keyed, sources: emission.sources), into: folder
        )) { error in
            XCTAssertEqual((error as? ExecutorPlanError)?.reason, ExecutorPlanFolderWriter.signingKeyRefusal)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }
}
