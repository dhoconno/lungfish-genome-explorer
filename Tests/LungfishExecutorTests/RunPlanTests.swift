import Foundation
import LungfishPortable
import XCTest
@testable import LungfishExecutor
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A plan folder with one input, `/bin/sh` script tools listed in a test tool manifest, and the built executor, which
/// each test runs as `run --plan <plan> --image-manifest <manifest>` (lane K4, milestone M3).
struct RunPlanFixture {
    static let zeros = String(repeating: "0", count: 64)
    let root: String
    let planFolder: String
    let toolsFolder: String
    let binary: String
    let executorEntry: PlanEntry
    private(set) var tools: [ImageTool] = []

    struct Run {
        var exit: ChildExit
        var record: ExecutorRunRecord?
        var stderr: String
        var status: Int32? {
            if case .exited(let code) = exit.termination { return code }
            return nil
        }
    }

    init() throws {
        root = try ExecutorTestSupport.scratchFolder()
        planFolder = root + "/plan"
        toolsFolder = root + "/tools"
        binary = try ExecutorTestSupport.executorBinary()
        for folder in [planFolder + "/inputs", toolsFolder] {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
        try Self.write("@r1\nACGT\n+\nIIII\n", to: planFolder + "/inputs/R1.fastq")
        let size = try FileManager.default.attributesOfItem(atPath: binary)[.size] as? Int ?? 0
        executorEntry = PlanEntry(
            role: .executor, relativePath: "lungfish-executor",
            sha256: try PortableDigest.sha256Hex(ofFileAt: URL(fileURLWithPath: binary)), size: Int64(size)
        )
    }

    static func write(_ text: String, to path: String) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: planFolder + "/" + relativePath)
    }

    func text(_ relativePath: String) -> String {
        ExecutorTestSupport.text(planFolder + "/" + relativePath)
    }

    /// Writes an executable `/bin/sh` script under tools/ and lists it at version 1.0, build t0.
    mutating func addTool(_ id: String, _ body: String) throws -> PlanToolPin {
        let path = toolsFolder + "/" + id
        try Self.write("#!/bin/sh\nPATH=/usr/bin:/bin\nexport PATH\n\(body)\n", to: path)
        guard chmod(path, 0o755) == 0 else { throw ExecutorTestSupport.Failure(description: "cannot chmod \(path)") }
        tools.append(ImageTool(id: id, version: "1.0", build: "t0", path: path, condaPackage: "test-\(id)"))
        return PlanToolPin(id: id, version: "1.0", build: "t0")
    }

    /// Writes the tool manifest and returns its path and the pin a plan names it by. A manifest that lists a BBTools
    /// wrapper (an id ending in `.sh`) also lists a `java` in tools/, as the image does, since `run --plan` refuses a
    /// wrapper plan whose manifest names no Java (SWIFT ruling Q-K4-3). `tools` keeps its order.
    func writeManifest() throws -> (path: String, pin: PlanImageManifestPin) {
        var listed = tools
        if listed.contains(where: { $0.id.hasSuffix(".sh") }), !listed.contains(where: { $0.id == "java" }) {
            let java = toolsFolder + "/java"
            try Self.write("#!/bin/sh\necho 'openjdk 25.0.2'\n", to: java)
            guard chmod(java, 0o755) == 0 else { throw ExecutorTestSupport.Failure(description: "cannot chmod \(java)") }
            listed.append(ImageTool(id: "java", version: "25.0.2", build: "t0", path: java, condaPackage: "test-openjdk"))
        }
        let data = try ImageToolManifest(platform: ImageToolPlatform.current ?? .linux64, tools: listed).encoded()
        let path = toolsFolder + "/image-manifest.json"
        try data.write(to: URL(fileURLWithPath: path))
        return (path, PlanImageManifestPin(sha256: PortableDigest.sha256Hex(of: data), size: Int64(data.count)))
    }

    static func step(_ id: String, _ tool: PlanToolPin, _ arguments: [String] = [], outputs: [String] = []) -> PlanStep {
        PlanStep(
            id: id, title: "Run \(id)", kind: .recipe, tool: tool, arguments: arguments, deadlineSeconds: 60,
            inputs: ["inputs/R1.fastq"], outputs: outputs
        )
    }

    /// A `gzip` that appends each argv to `logs/gzip.used` in the work root and runs the host's gzip with it, for a plan
    /// that pins the program that reads its gzip files (SWIFT fix 2 of the K4 part B review).
    mutating func addLoggingGzip() throws -> PlanToolPin {
        try addTool("gzip", "printf '%s\\n' \"$*\" >> '\(planFolder)/logs/gzip.used'\nexec /usr/bin/gzip \"$@\"")
    }

    /// Writes plan.json for `steps`, pinning the running executor unless `executor` is given, and returns its path.
    /// `pins` names the tools the plan pins beside its steps' own, such as the program that reads a gzip payload.
    func writePlan(
        _ steps: [PlanStep], manifestPin: PlanImageManifestPin, executor: PlanEntry? = nil,
        storage: PlanStorageSettings? = nil, clumping: PlanClumpingChoice? = nil, pins: [PlanToolPin] = []
    ) throws -> String {
        let input = try Data(contentsOf: URL(fileURLWithPath: planFolder + "/inputs/R1.fastq"))
        let plan = ExecutionPlan(
            entries: [
                executor ?? executorEntry,
                PlanEntry(role: .input, relativePath: "inputs/R1.fastq", sha256: PortableDigest.sha256Hex(of: input), size: Int64(input.count)),
            ],
            executor: PlanExecutorBuild(
                lgeVersion: "test", lgeCommit: Self.zeros, targetTriple: "test", toolchainID: "test",
                toolchainSHA256: Self.zeros, staticLinuxSDKID: "test", staticLinuxSDKSHA256: Self.zeros
            ),
            imageManifest: manifestPin,
            tools: Array(Set(steps.compactMap(\.tool) + pins)).sorted { $0.id < $1.id },
            recipe: nil,
            sample: PlanSampleValues(sampleName: "sample", originalFilenames: ["R1.fastq"], originalSizeBytes: Int64(input.count)),
            storage: storage ?? PlanStorageSettings(
                clumpingTool: .none, compressor: .bgzip, qualityBinning: .illumina4, threads: 1, clumpifyHeapGB: 1,
                compressionLevel: 4, threadsSource: .option, clumpifyHeapSource: .option, clumpingToolSource: .option,
                compressorSource: .option, qualityBinningSource: .option
            ),
            clumping: clumping ?? PlanClumpingChoice(
                requested: .none, resolved: .none, resolvedSource: .option, heapBytes: 1_073_741_824,
                reason: "explicit clumping tool selection"
            ),
            graceSeconds: 5,
            steps: steps
        )
        let path = planFolder + "/plan.json"
        try plan.encoded().write(to: URL(fileURLWithPath: path))
        return path
    }

    /// Runs `lungfish-executor run --plan <plan>` with `arguments` after it and `environment` plus a PATH, and reads the
    /// run record it left.
    func run(_ plan: String, _ arguments: [String], environment: [String: String] = [:]) throws -> Run {
        try? FileManager.default.removeItem(atPath: planFolder + "/" + ExecutorRunRecord.fileName)
        let stdin = try ExecutorSpawn.openNullForReading()
        let stdout = try ExecutorSpawn.openForWriting(root + "/executor.out")
        let stderr = try ExecutorSpawn.openForWriting(root + "/executor.err")
        let pid: pid_t
        do {
            defer {
                close(stdin)
                close(stdout)
                close(stderr)
            }
            pid = try ExecutorSpawn.spawn(
                executable: binary, arguments: ["run", "--plan", plan] + arguments,
                environment: environment.merging(["PATH": "/usr/bin:/bin"]) { current, _ in current },
                stdin: stdin, stdout: stdout, stderr: stderr
            )
        }
        guard let exit = ExecutorTestSupport.waitForExit(pid, timeout: 120) else {
            throw ExecutorTestSupport.Failure(description: "the executor did not end within 120 s")
        }
        let recordPath = planFolder + "/" + ExecutorRunRecord.fileName
        let record = FileManager.default.fileExists(atPath: recordPath)
            ? try ExecutorRunRecord.decode(Data(contentsOf: URL(fileURLWithPath: recordPath))) : nil
        return Run(exit: exit, record: record, stderr: ExecutorTestSupport.text(root + "/executor.err"))
    }

    /// The record with every time, PID and peak memory cleared, the fields two runs of one plan may differ in.
    static func timeless(_ record: ExecutorRunRecord?) -> ExecutorRunRecord? {
        guard var copy = record else { return nil }
        copy.startedAt = ""
        copy.endedAt = ""
        copy.wallSeconds = 0
        copy.steps = copy.steps.map { step in
            var step = step
            step.startedAt = ""
            step.endedAt = ""
            step.wallSeconds = 0
            step.toolPID = nil
            step.peakResidentBytes = nil
            return step
        }
        return copy
    }
}

final class RunPlanTests: XCTestCase {
    /// One step that copies the input by its work-root path, which works only when the child starts in the work root,
    /// writes its environment's names and says so on stderr.
    private func copyPlan() throws -> (fixture: RunPlanFixture, plan: String, manifest: String) {
        var fixture = try RunPlanFixture()
        let copy = try fixture.addTool("copy-reads", "cat \"$1\" > \"$2\"\nenv | cut -d= -f1 | sort > out/env.txt\necho \"copied $1\" >&2")
        let manifest = try fixture.writeManifest()
        let plan = try fixture.writePlan(
            [RunPlanFixture.step("copy", copy, ["inputs/R1.fastq", "out/R1.fastq"], outputs: ["out/R1.fastq", "out/env.txt"])],
            manifestPin: manifest.pin
        )
        return (fixture, plan, manifest.path)
    }

    func testRunRecordIgnoresCondorEnvironment() throws {
        let (fixture, plan, manifest) = try copyPlan()
        let plain = try fixture.run(plan, ["--image-manifest", manifest])
        XCTAssertEqual(plain.status, ExecutorExitCode.succeeded, plain.stderr)
        let record = try XCTUnwrap(plain.record)
        XCTAssertEqual(record.outcome, .succeeded)
        XCTAssertEqual(record.imageManifest?.source, .argument)
        XCTAssertEqual(record.executor.sha256, fixture.executorEntry.sha256)
        XCTAssertEqual(record.inputs.map(\.relativePath), ["inputs/R1.fastq"])
        let step = try XCTUnwrap(record.steps.first)
        XCTAssertEqual(step.argv, [fixture.tools[0].path, "inputs/R1.fastq", "out/R1.fastq"])
        XCTAssertEqual(step.environmentNames, ["HOME", "PATH", "TMPDIR"])
        XCTAssertEqual(step.outputs.map(\.path), ["out/R1.fastq", "out/env.txt"])
        XCTAssertEqual(step.stderrTail, "copied inputs/R1.fastq\n")
        XCTAssertEqual(fixture.text("out/R1.fastq"), "@r1\nACGT\n+\nIIII\n")

        try FileManager.default.createDirectory(atPath: fixture.root + "/condor", withIntermediateDirectories: true)
        try RunPlanFixture.write("Cpus = 512\nMemory = 1\nnonsense ][\n", to: fixture.root + "/machine.ad")
        try RunPlanFixture.write("GlobalJobId = \"x#1.0#0\"\n{{{\n", to: fixture.root + "/job.ad")
        let condor = try fixture.run(plan, ["--image-manifest", manifest], environment: [
            "_CONDOR_SCRATCH_DIR": fixture.root + "/condor",
            "_CONDOR_MACHINE_AD": fixture.root + "/machine.ad",
            "_CONDOR_JOB_AD": fixture.root + "/job.ad",
        ])
        XCTAssertEqual(condor.status, ExecutorExitCode.succeeded, condor.stderr)
        XCTAssertEqual(RunPlanFixture.timeless(condor.record), RunPlanFixture.timeless(plain.record))
        XCTAssertFalse(fixture.text("out/env.txt").contains("_CONDOR"))
    }

    func testSiteFactsAreRecordedVerbatimAndChangeNothingElse() throws {
        let (fixture, plan, manifest) = try copyPlan()
        let none = try fixture.run(plan, ["--image-manifest", manifest])
        let facts = [
            PlanKeyValue(key: "Machine", value: "slot1@e2001.chtc.wisc.edu"),
            PlanKeyValue(key: "OpSysAndVer", value: "AlmaLinux9"),
            PlanKeyValue(key: "Cpus", value: "4"),
            PlanKeyValue(key: "Note_1", value: "two words, a comma and é"),
            PlanKeyValue(key: "Empty", value: ""),
        ]
        let five = try fixture.run(plan, ["--image-manifest", manifest] + facts.flatMap { ["--site-fact", "\($0.key)=\($0.value)"] })
        XCTAssertEqual(none.status, ExecutorExitCode.succeeded, none.stderr)
        XCTAssertEqual(five.status, ExecutorExitCode.succeeded, five.stderr)
        XCTAssertEqual(none.record?.siteFacts, [])
        XCTAssertEqual(five.record?.siteFacts, facts)
        var withFacts = try XCTUnwrap(RunPlanFixture.timeless(five.record))
        var withoutFacts = try XCTUnwrap(RunPlanFixture.timeless(none.record))
        XCTAssertEqual(Array(withFacts.executorArguments.suffix(10)), facts.flatMap { ["--site-fact", "\($0.key)=\($0.value)"] })
        withFacts.siteFacts = []
        withFacts.executorArguments = []
        withoutFacts.executorArguments = []
        XCTAssertEqual(withFacts, withoutFacts)
        XCTAssertFalse(fixture.text("out/env.txt").contains("Machine"))
    }

    func testSiteFactOutsideBoundsRefusesBeforeAnyTool() throws {
        let (fixture, plan, manifest) = try copyPlan()
        let cases: [(arguments: [String], field: String)] = [
            ((1...65).flatMap { ["--site-fact", "K\($0)=MARK\($0)"] }, "--site-fact 65"),
            (["--site-fact", "9lives=MARKKEY"], "--site-fact 1"),
            (["--site-fact", "A=MARKA", "--site-fact", "B=MARK" + String(repeating: "v", count: 1021)], "--site-fact 2"),
            (["--site-fact", "C=MARK\u{01}C"], "--site-fact 1"),
            (["--site-fact", "D=MARK1", "--site-fact", "D=MARK2"], "--site-fact 2"),
            (["--site-fact", "NOEQUALSMARK"], "--site-fact 1"),
        ]
        for (arguments, field) in cases {
            let run = try fixture.run(plan, ["--image-manifest", manifest] + arguments)
            XCTAssertEqual(run.status, ExecutorExitCode.refused, field)
            let record = try XCTUnwrap(run.record, field)
            XCTAssertEqual(record.outcome, .refused, field)
            XCTAssertEqual(record.refusedField, field)
            XCTAssertFalse(record.reason?.contains("MARK") ?? true, field)
            XCTAssertEqual(record.steps, [], field)
            XCTAssertEqual(record.siteFacts, [], field)
            XCTAssertFalse(fixture.exists("out/R1.fastq"), field)
            XCTAssertFalse(fixture.exists("logs"), field)
        }
        // At the bounds: 64 facts and a 1,024-byte value run.
        let full = (1...63).flatMap { ["--site-fact", "K\($0)=v"] } + ["--site-fact", "Long=" + String(repeating: "v", count: 1024)]
        XCTAssertEqual(try fixture.run(plan, ["--image-manifest", manifest] + full).record?.siteFacts.count, 64)
    }

    func testSelfCheckMismatchRefusesBeforeAnyTool() throws {
        var fixture = try RunPlanFixture()
        let copy = try fixture.addTool("copy-reads", "cat \"$1\" > \"$2\"")
        let manifest = try fixture.writeManifest()
        try RunPlanFixture.write("not the executor\n", to: fixture.planFolder + "/lungfish-executor")
        let other = PlanEntry(
            role: .executor, relativePath: "lungfish-executor",
            sha256: PortableDigest.sha256Hex(of: Data("not the executor\n".utf8)), size: 17
        )
        let plan = try fixture.writePlan(
            [RunPlanFixture.step("copy", copy, ["inputs/R1.fastq", "out/R1.fastq"])], manifestPin: manifest.pin, executor: other
        )
        let run = try fixture.run(plan, ["--image-manifest", manifest.path])
        XCTAssertEqual(run.status, ExecutorExitCode.refused, run.stderr)
        let record = try XCTUnwrap(run.record)
        XCTAssertEqual(record.outcome, .refused)
        XCTAssertEqual(record.refusedField, "entries[0]")
        XCTAssertEqual(record.executor.sha256, fixture.executorEntry.sha256)
        XCTAssertEqual(record.executor.size, fixture.executorEntry.size)
        XCTAssertTrue(record.reason?.contains(other.sha256) ?? false)
        XCTAssertTrue(record.reason?.contains(fixture.executorEntry.sha256) ?? false)
        XCTAssertNil(record.imageManifest, "the manifest is read only after the self-check")
        XCTAssertEqual(record.inputs, [])
        XCTAssertEqual(record.steps, [])
        XCTAssertFalse(fixture.exists("out/R1.fastq"))
    }

    func testPlanStepFailureWritesFailedRecord() throws {
        var fixture = try RunPlanFixture()
        let first = try fixture.addTool("first", "echo one > out/a.txt")
        let failing = try fixture.addTool("failing", "echo 'bad input at record 7' >&2\nexit 3")
        let never = try fixture.addTool("never", "echo three > out/c.txt")
        let manifest = try fixture.writeManifest()
        let plan = try fixture.writePlan([
            RunPlanFixture.step("first", first, outputs: ["out/a.txt"]),
            RunPlanFixture.step("failing", failing),
            RunPlanFixture.step("never", never, outputs: ["out/c.txt"]),
        ], manifestPin: manifest.pin)
        let run = try fixture.run(plan, ["--image-manifest", manifest.path])
        XCTAssertEqual(run.status, ExecutorExitCode.failed, run.stderr)
        let record = try XCTUnwrap(run.record)
        XCTAssertEqual(record.outcome, .failed)
        XCTAssertEqual(record.exitCode, ExecutorExitCode.failed)
        XCTAssertEqual(record.failedStepID, "failing")
        XCTAssertNil(record.refusedField)
        XCTAssertEqual(record.steps.map(\.id), ["first", "failing"])
        XCTAssertEqual(record.steps.map(\.outcome), [.succeeded, .failed])
        XCTAssertEqual(record.steps[1].toolExitCode, 3)
        XCTAssertEqual(record.steps[1].stderrTail, "bad input at record 7\n")
        XCTAssertEqual(record.steps[1].outputs, [])
        XCTAssertTrue(record.reason?.contains("failing") ?? false)
        XCTAssertFalse(fixture.exists("out/c.txt"))
    }

    func testStderrKeepsItsLastFourMegabytes() throws {
        var fixture = try RunPlanFixture()
        let loud = try fixture.addTool("loud", "head -c 5242880 /dev/zero | tr '\\000' 'a' >&2\nprintf 'TAIL-END' >&2")
        let quiet = try fixture.addTool("quiet", "printf 'short' >&2")
        let manifest = try fixture.writeManifest()
        let plan = try fixture.writePlan([RunPlanFixture.step("loud", loud), RunPlanFixture.step("quiet", quiet)], manifestPin: manifest.pin)
        let run = try fixture.run(plan, ["--image-manifest", manifest.path])
        XCTAssertEqual(run.status, ExecutorExitCode.succeeded, run.stderr)
        let record = try XCTUnwrap(run.record)
        XCTAssertEqual(record.steps.count, 2)
        let cut = record.steps[0]
        XCTAssertEqual(cut.stderrBytes, 5_242_880 + 8)
        XCTAssertTrue(cut.stderrTruncated)
        XCTAssertEqual(cut.stderrTail.utf8.count, ExecutorStepRecord.stderrTailLimit)
        XCTAssertTrue(cut.stderrTail.hasSuffix("aaaaTAIL-END"))
        XCTAssertEqual(fixture.text("logs/loud.stderr").utf8.count, 5_242_880 + 8, "the log file keeps every byte")
        let whole = record.steps[1]
        XCTAssertEqual(whole.stderrTail, "short")
        XCTAssertEqual(whole.stderrBytes, 5)
        XCTAssertFalse(whole.stderrTruncated)
    }

    func testImageManifestAndToolPinRefusalsNameTheField() throws {
        let (fixture, plan, manifest) = try copyPlan()
        let missing = try fixture.run(plan, [])
        XCTAssertEqual(missing.status, ExecutorExitCode.refused, missing.stderr)
        XCTAssertEqual(missing.record?.refusedField, "imageManifest")
        XCTAssertEqual(missing.record?.reason, "The tool manifest is missing at /opt/lungfish/image-manifest.json. Outside a Lungfish tool image, pass --image-manifest with the absolute path of the manifest the plan pins. No tool ran.")
        let relative = try fixture.run(plan, ["--image-manifest", "tools/image-manifest.json"])
        XCTAssertEqual(relative.record?.refusedField, "imageManifest")
        let absent = try fixture.run(plan, ["--image-manifest", fixture.root + "/absent.json"])
        XCTAssertEqual(absent.record?.refusedField, "imageManifest")
        XCTAssertFalse(absent.record?.reason?.contains(fixture.root) ?? true, "the record never states the option's path")
        XCTAssertEqual(absent.record?.reason, "The file that --image-manifest names is missing. Name the tool manifest the plan pins. No tool ran.")

        let wrongPin = PlanImageManifestPin(sha256: RunPlanFixture.zeros, size: 5)
        let copyStep = RunPlanFixture.step("copy", PlanToolPin(id: "copy-reads", version: "1.0", build: "t0"))
        let mismatched = try fixture.run(try fixture.writePlan([copyStep], manifestPin: wrongPin), ["--image-manifest", manifest])
        let record = try XCTUnwrap(mismatched.record)
        XCTAssertEqual(record.refusedField, "imageManifest")
        XCTAssertEqual(record.imageManifest?.source, .argument)
        XCTAssertTrue(record.reason?.contains(RunPlanFixture.zeros) ?? false)
        XCTAssertTrue(record.reason?.contains(record.imageManifest?.sha256 ?? "-") ?? false)

        let pin = try RunPlanFixture.timeless(fixture.run(fixture.writePlan([copyStep], manifestPin: try fixture.writeManifest().pin), ["--image-manifest", manifest]).record)
        XCTAssertEqual(pin?.outcome, .succeeded)
        let unlisted = RunPlanFixture.step("copy", PlanToolPin(id: "copy-reads", version: "2.0", build: "t0"))
        let refused = try fixture.run(try fixture.writePlan([unlisted], manifestPin: try fixture.writeManifest().pin), ["--image-manifest", manifest])
        XCTAssertEqual(refused.record?.refusedField, "steps[0].tool")
        XCTAssertEqual(refused.record?.steps, [])
    }

    func testPreflightRefusesHeapAtOrAboveObservedLimit() throws {
        let root = try ExecutorTestSupport.scratchFolder()
        for folder in ["/proc/self", "/sys/fs/cgroup/job"] {
            try FileManager.default.createDirectory(atPath: root + folder, withIntermediateDirectories: true)
        }
        try RunPlanFixture.write("MemTotal:        8388608 kB\nMemFree: 1 kB\n", to: root + "/proc/meminfo")
        try RunPlanFixture.write("Name:\tx\nCpus_allowed_list:\t0-3\nNSpid:\t42\t1\n", to: root + "/proc/self/status")
        try RunPlanFixture.write("0::/job\n", to: root + "/proc/self/cgroup")
        try RunPlanFixture.write("1073741824\n", to: root + "/sys/fs/cgroup/job/memory.max")
        let report = ChildSubreaper.Report(setterResult: 0, getterResult: 0, getterValue: 1)
        let limited = RuntimeObservation.identity(subreaper: report, root: root)
        XCTAssertEqual(limited.cgroupVersion, 2)
        XCTAssertEqual(limited.pidNamespaceDepth, 2)
        XCTAssertEqual(limited.observedLimits.map(\.value), ["8589934592", "0-3", "1073741824"])
        XCTAssertEqual(limited.orphanSweep, .subreaper)
        let refusal = RuntimeObservation.preflightRefusal(heapGB: 1, limits: limited.observedLimits)
        XCTAssertEqual(refusal?.field, "storage.clumpifyHeapGB")
        XCTAssertTrue(refusal?.reason.contains("/sys/fs/cgroup/job/memory.max") ?? false)

        try RunPlanFixture.write("max\n", to: root + "/sys/fs/cgroup/job/memory.max")
        let unlimited = RuntimeObservation.identity(subreaper: report, root: root)
        XCTAssertNil(unlimited.observedLimits[2].value)
        XCTAssertNil(RuntimeObservation.preflightRefusal(heapGB: 1, limits: unlimited.observedLimits))
        XCTAssertEqual(RuntimeObservation.preflightRefusal(heapGB: 8, limits: unlimited.observedLimits)?.field, "storage.clumpifyHeapGB")

        try FileManager.default.removeItem(atPath: root + "/proc/self/cgroup")
        let noCgroup = RuntimeObservation.identity(subreaper: report, root: root)
        XCTAssertNil(noCgroup.cgroupVersion)
        XCTAssertNil(RuntimeObservation.preflightRefusal(heapGB: 7, limits: noCgroup.observedLimits))
    }
}
