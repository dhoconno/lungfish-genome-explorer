// LinuxRunScriptTests.swift - run-local.sh, jobs.tsv and README.txt of a batch (C5 lane LAUNCH M2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import LungfishCore
import LungfishPortable
import LungfishTestSupport
@testable import LungfishWorkflow

/// The batch writer's `run-local.sh` runs here with stand-in `docker` and `apptainer` at the front of `PATH`, which record
/// their arguments and run the container's command on this machine, and with a stand-in executor that writes its own
/// arguments, one a line, as the run record. So each test reads what a run leaves (the record's facts, the `result/`
/// and `logs/` listings, the refusals) and never the script's text (QA 2).
final class LinuxRunScriptTests: XCTestCase {
    private var root: URL!
    private var standIns: URL!
    private var marks: URL!

    /// A Docker image ID with a space, a command substitution and a glob, which reaches the record whole only when the
    /// script passes each fact as one argument and runs no value as shell text.
    private let imageID = "sha256:0123 $(touch INJECTED) *"
    private let sif = Data("stand-in SIF".utf8)
    private let layout = ExecutorPlanStagingLayout(folder: "/staging/groups/g/1/lge-test", batch: "batch")

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "LinuxRunScript")
        standIns = root.appendingPathComponent("stand-in-bin", isDirectory: true)
        marks = root.appendingPathComponent("marks", isDirectory: true)
        try FileManager.default.createDirectory(at: standIns, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: marks, withIntermediateDirectories: true)
        try writeStandIn("docker", """
            #!/bin/sh
            case $1 in
              version) echo 28.3.2; exit 0 ;;
              image) echo '\(imageID)'; exit 0 ;;
              run) shift ;;
              *) exit 64 ;;
            esac
            printf '%s\\n' "$@" > '\(marks.path)/docker-run.'$$
            dir=""
            while [ "$#" -gt 0 ]; do
              case $1 in
                --rm) shift ;;
                --workdir) dir=$2; shift 2 ;;
                --*) shift 2 ;;
                *) break ;;
              esac
            done
            shift
            cd "$dir" || exit 125
            exec "$@"
            """)
        try writeStandIn("apptainer", """
            #!/bin/sh
            case $1 in
              --version) echo 'apptainer version 1.3.4-1.el9'; exit 0 ;;
              exec) shift ;;
              *) exit 64 ;;
            esac
            printf '%s\\n' "$@" > '\(marks.path)/apptainer-exec.'$$
            dir=""
            while [ "$#" -gt 0 ]; do
              case $1 in
                --containall | --no-home) shift ;;
                --pwd) dir=$2; shift 2 ;;
                --*) shift 2 ;;
                *) break ;;
              esac
            done
            shift
            cd "$dir" || exit 255
            exec "$@"
            """)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func writeStandIn(_ name: String, _ text: String) throws {
        let script = standIns.appendingPathComponent(name)
        try (text + "\n").write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    private struct Written {
        var folder: URL
        var data: URL
        var batch: ExecutorPlanBatch
        var reports: [String]
    }

    /// A batch of BBTools plans and the data folder a lab makes from `staging-files.json`: each listed file at its path
    /// below the staging folder, with the stand-in executor in the executor's place.
    private func writeBatch(_ samples: [String]) throws -> Written {
        let request = try ExecutorPlanTestSupport.request(
            root: root, samples[0], inputs: ExecutorPlanTestSupport.writePair(root: root, samples[0]), clumping: .bbtools
        ).templateRequest
        let recipeTemplate = try ExecutorPlanEmitter.template(request, host: ExecutorPlanTestSupport.mac24)
        let rows = try samples.map { sample in
            let pair = try ExecutorPlanTestSupport.writePair(root: root, sample)
            return ExecutorPlanSampleRow(sampleName: sample, inputs: try pair.map { try ExecutorPlanSourceFile.measuring($0) },
                                         requestDiskGiB: nil)
        }
        let image = ExecutorPlanImageRecord(
            sif: ExecutorPlanImageFile(fileName: "lge-tools-test.sif", sha256: DeterministicTarWriter.sha256(sif),
                                       size: Int64(sif.count)),
            imageManifest: PlanImageManifestPin(sha256: ExecutorPlanTestSupport.digest, size: 4096)
        )
        let folder = root.appendingPathComponent("batch", isDirectory: true)
        let batch = try ExecutorPlanBatchWriter.write(recipeTemplate, request: request, rows: rows, image: image,
                                                      layout: layout, into: folder)
        let reports = HTCondorSubmitTemplate.reportRelativePaths(of: recipeTemplate.template.steps)
        let data = root.appendingPathComponent("data", isDirectory: true)
        let list = try JSONDecoder().decode(ExecutorPlanBatchFiles.self,
                                            from: Data(contentsOf: folder.appendingPathComponent("staging-files.json")))
        for file in list.files {
            let target = data.appendingPathComponent(layout.relativePath(file.stagingPath))
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            switch file.role {
            case "image": try sif.write(to: target)
            case "executor": try executorScript(reports: reports).write(to: target, atomically: true, encoding: .utf8)
            default: try FileManager.default.copyItem(atPath: try XCTUnwrap(file.source), toPath: target.path)
            }
        }
        return Written(folder: folder, data: data, batch: batch, reports: reports)
    }

    /// The executor's stand-in, started in the plan folder: it records its arguments as the run record and writes the
    /// payload, each report, a step log and a work file that no job returns, beside the plan.json the tar held.
    private func executorScript(reports: [String]) -> String {
        var lines = [
            "#!/bin/sh", "printf '%s\\n' \"$@\" > run-record.json", "mkdir -p out work logs",
            "echo reads > \(ExecutorPlanEmitter.payloadPath)", "echo intermediate > work/intermediate.fastq",
            "echo step > logs/step-1.log",
        ]
        for report in reports {
            lines += ["mkdir -p \((report as NSString).deletingLastPathComponent)", "echo report > \(report)"]
        }
        return (lines + ["exit 0"]).joined(separator: "\n") + "\n"
    }

    private func launch(_ written: Written, _ arguments: [String]) throws -> (status: Int, out: String, err: String) {
        let path = standIns.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        let result = try ToolProcess.start(ToolProcessSpec(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [written.folder.appendingPathComponent(LinuxRunScript.fileName).path] + arguments,
            environment: ProcessInfo.processInfo.environment.merging(["PATH": path]) { $1 },
            timeout: .seconds(120), label: "run-local"
        )).waitBlocking()
        return (Int(result.status), result.stdoutText, result.stderrText)
    }

    /// Every file below a folder, by its path in it.
    private func files(in folder: URL) throws -> [String] {
        try FileManager.default.subpathsOfDirectory(atPath: folder.path).filter { path in
            var isFolder: ObjCBool = false
            return FileManager.default.fileExists(atPath: folder.appendingPathComponent(path).path, isDirectory: &isFolder)
                && !isFolder.boolValue
        }.sorted()
    }

    /// The `--site-fact` values the executor stand-in recorded for a sample, in order.
    private func facts(_ written: Written, _ sample: String) throws -> [String] {
        let record = written.folder.appendingPathComponent("\(sample)/result/run-record.json")
        let lines = try String(contentsOf: record, encoding: .utf8).split(separator: "\n").map(String.init)
        return zip(lines, lines.dropFirst()).filter { $0.0 == "--site-fact" }.map(\.1)
    }

    /// The arguments each stand-in run recorded, one list a run.
    private func recordedRuns(_ prefix: String) throws -> [[String]] {
        try FileManager.default.contentsOfDirectory(atPath: marks.path).filter { $0.hasPrefix(prefix) }.map {
            try String(contentsOf: marks.appendingPathComponent($0), encoding: .utf8).split(separator: "\n").map(String.init)
        }
    }

    private func exists(_ written: Written, _ path: String) -> Bool {
        FileManager.default.fileExists(atPath: written.folder.appendingPathComponent(path).path)
    }

    /// ARCH-c5 point 1 and the BADOPT ruling: a plain run leaves in `<sample>/result/` only the run record, each report and
    /// the payload, never the plan.json or another work file, with `logs/` beside it. C5 D10: the facts arrive in D10's
    /// order, each one argument, with the Docker image ID and no SIF digest and no slot, cluster or HTCondor fact.
    func testDockerRunLeavesOnlyTheJobsFilesInResultAndPassesEachFactAsOneArgument() throws {
        let written = try writeBatch(["S1", "S2"])
        let run = try launch(written,["--runtime", "docker", "--image", "lge-test:1", "--data", written.data.path, "--jobs", "2"])
        XCTAssertEqual(run.status, 0, run.err)

        // The BBTools plan has no report, so work/intermediate.fastq is the work file that must stay behind.
        let expected = (["run-record.json", ExecutorPlanEmitter.payloadPath] + written.reports).sorted()
        for sample in ["S1", "S2"] {
            XCTAssertEqual(try files(in: written.folder.appendingPathComponent("\(sample)/result")), expected, sample)
            XCTAssertEqual(try files(in: written.folder.appendingPathComponent("\(sample)/logs")), ["step-1.log"], sample)
            XCTAssertTrue(exists(written, "logs/\(sample).out"), sample)
            XCTAssertTrue(run.out.contains("\(sample): finished. Its files are in \(sample)/result/."), run.out)

            let facts = try facts(written, sample)
            let keys = facts.map { String($0.prefix { $0 != "=" }) }
            XCTAssertEqual(keys.filter { $0 != "OpSysAndVer" },
                           ["Machine", "Arch", "ContainerRuntime", "ContainerRuntimeVersion", "ContainerImageID", "Launcher"])
            XCTAssertEqual(keys, HTCondorSubmitTemplate.PlainLauncherFact.allCases.map(\.rawValue).filter(keys.contains))
            for fact in ["ContainerRuntime=Docker", "ContainerRuntimeVersion=28.3.2", "ContainerImageID=\(imageID)",
                         "Launcher=run-local.sh/1"] {
                XCTAssertTrue(facts.contains(fact), "\(fact) in \(facts)")
            }
        }
        XCTAssertFalse(exists(written, "scratch"), "The scratch folder stays after the run")
        XCTAssertFalse(try FileManager.default.subpathsOfDirectory(atPath: root.path).contains { $0.hasSuffix("INJECTED") },
                       "A fact's value ran as shell text")

        // Each sample's container runs the batch's image for linux/amd64 and is removed when it ends.
        let runs = try recordedRuns("docker-run.")
        XCTAssertEqual(runs.count, 2)
        for argv in runs {
            XCTAssertEqual(Array(argv.prefix(3)), ["--rm", "--platform", "linux/amd64"], "\(argv)")
            XCTAssertTrue(argv.contains("lge-test:1"), "\(argv)")
        }

        // A second run skips both samples, since each has its result.
        let again = try launch(written,["--runtime", "docker", "--image", "lge-test:1", "--data", written.data.path])
        XCTAssertEqual(again.status, 0, again.err)
        XCTAssertTrue(again.out.contains("S1: skipped, since S1/result/ exists."), again.out)
        XCTAssertEqual(try recordedRuns("docker-run.").count, 2)
    }

    /// C5 D10: an Apptainer run hashes the SIF once, runs only the batch's image and records its SHA-256 and the bare
    /// Apptainer version, and no Docker image ID.
    func testApptainerRunChecksTheImageAndRecordsItsSHA256() throws {
        let written = try writeBatch(["S1"])
        let run = try launch(written,["--runtime", "apptainer", "--data", written.data.path])
        XCTAssertEqual(run.status, 0, run.err)
        let facts = try facts(written, "S1")
        for fact in ["ContainerRuntime=Apptainer", "ContainerRuntimeVersion=1.3.4", "ImageSHA256=\(DeterministicTarWriter.sha256(sif))"] {
            XCTAssertTrue(facts.contains(fact), "\(fact) in \(facts)")
        }
        XCTAssertFalse(facts.contains { $0.hasPrefix("ContainerImageID=") }, "\(facts)")
        let argv = try XCTUnwrap(try recordedRuns("apptainer-exec.").first)
        XCTAssertEqual(Array(argv.prefix(2)), ["--containall", "--no-home"], "\(argv)")
        XCTAssertTrue(argv.contains { $0.hasSuffix("/images/lge-tools-test.sif") }, "\(argv)")
    }

    func testApptainerRefusesAnImageThatIsNotTheBatchsImage() throws {
        let written = try writeBatch(["S1"])
        try Data("another image".utf8).write(to: written.data.appendingPathComponent("images/lge-tools-test.sif"))
        let run = try launch(written,["--runtime", "apptainer", "--data", written.data.path])
        XCTAssertEqual(run.status, 2, run.err)
        XCTAssertTrue(run.err.contains("not the batch's \(DeterministicTarWriter.sha256(sif)), so pass --image the batch's image lge-tools-test.sif. No sample ran."), run.err)
        XCTAssertFalse(exists(written, "S1/result"))
        XCTAssertEqual(try recordedRuns("apptainer-exec.").count, 0)
    }

    /// A plan tar that is not the bytes the writer pinned in `jobs.tsv` does not run, and the other samples do.
    func testRunRefusesAPlanTarThatIsNotThePlanLungfishWrote() throws {
        let written = try writeBatch(["S1", "S2"])
        let handle = try FileHandle(forWritingTo: written.folder.appendingPathComponent("S1/plan.tar"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        let run = try launch(written,["--runtime", "docker", "--image", "lge-test:1", "--data", written.data.path])
        XCTAssertEqual(run.status, 1, run.err)
        XCTAssertTrue(run.err.contains("S1: S1/plan.tar does not have the SHA-256 jobs.tsv gives, so it is not the plan Lungfish wrote. The sample did not run."), run.err)
        XCTAssertFalse(exists(written, "S1/result"))
        XCTAssertTrue(exists(written, "S2/result/run-record.json"))
        XCTAssertEqual(try recordedRuns("docker-run.").count, 1)
    }

    /// `jobs.tsv` names each sample's tar with its pinned SHA-256 and each file its job reads below the data folder,
    /// executor first and then the reads, at the plan paths the plan gives; `run-local.sh` is executable.
    func testJobsTableNamesEachFileBelowTheDataFolderInTheWrappersOrder() throws {
        let written = try writeBatch(["S1", "S2"])
        let lines = try String(contentsOf: written.folder.appendingPathComponent("jobs.tsv"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasPrefix("# sample\t"), lines[0])
        let list = try JSONDecoder().decode(ExecutorPlanBatchFiles.self,
                                            from: Data(contentsOf: written.folder.appendingPathComponent("staging-files.json")))
        let executor = try XCTUnwrap(list.files.first { $0.role == "executor" })
        for (index, sample) in ["S1", "S2"].enumerated() {
            let plan = try ExecutionPlan.decode(Data(contentsOf: written.folder.appendingPathComponent("\(sample)/plan.json")))
            let executorPath = try XCTUnwrap(plan.entries.first { $0.role == .executor }).relativePath
            let reads = plan.entries.filter { $0.role == .input }.map(\.relativePath)
            XCTAssertEqual(lines[index + 1].split(separator: "\t").map(String.init), [
                sample, "\(sample)/plan.tar", written.batch.planTars[index].sha256,
                "\(layout.relativePath(executor.stagingPath))=\(executorPath)",
                "batches/batch/\(sample)/R1.fastq=\(reads[0])", "batches/batch/\(sample)/R2.fastq=\(reads[1])",
            ])
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: written.folder.appendingPathComponent("run-local.sh").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
    }

    /// The BADOPT ruling's README order (one folder a sample, the one copy step, no logs or plan.json back, the whole-batch
    /// adopt with its three lines, the stopped adopt), D14's held-job steps, D13's two knobs, and no site's name (O41).
    func testReadmeGivesBothLaunchersOneCopyStepAndTheWholeBatchAdopt() throws {
        let written = try writeBatch(["S1"])
        let readme = try String(contentsOf: written.folder.appendingPathComponent("README.txt"), encoding: .utf8)
        let lines = [
            "condor_submit_dag run.dag",
            "condor_q -hold -af ClusterId ProcId DAGNodeName HoldReason",
            "To see every sample's state, read run.dag.status.",
            "Read its log, <sample>/logs/ in this folder, to see which step stopped.",
            "condor_rm <ClusterId>.<ProcId>",
            "MAXJOBS lge 10", "--jobs <n> changes it",
            "sh run-local.sh --runtime apptainer --data <data folder>",
            "sh run-local.sh --runtime docker --image <image> --data <data folder>",
            "The adopt reads one folder for each sample: the plan.json your Mac wrote, with the job's",
            "for sample in $(grep -v '^#' batch/jobs.tsv | cut -f 1); do rsync -a <source>/\"$sample\"/result/ batch/\"$sample\"/; done",
            "<source> is <host>:/staging/groups/g/1/lge-test/batches/batch after an HTCondor run",
            "Do not copy logs/, since the adopt reads no log. Do not copy a plan.json back from the Linux",
            "lungfish-cli import fastq batch --adopt --project <project>",
            "<sample>: its job returned nothing. The folder holds no run-record.json.",
            "<sample>: its job returned no reads. The payload <path> is missing from the folder.",
            "<sample>: The job's files are in the folder result. Copy everything inside result into the folder <sample>, next to plan.json.",
            "To adopt the rest, delete the imported bundles and adopt the batch again.",
        ]
        for line in lines {
            XCTAssertTrue(readme.contains(line), line)
        }
        let order = try ["The adopt reads one folder", "rsync -a", "Do not copy logs/", "--adopt --project", "To adopt the rest"]
            .map { try XCTUnwrap(readme.range(of: $0), $0).lowerBound }
        XCTAssertEqual(order, order.sorted())
        for name in ["README.txt", "run-local.sh", "jobs.tsv"] {
            let text = try String(contentsOf: written.folder.appendingPathComponent(name), encoding: .utf8)
            XCTAssertFalse(text.lowercased().contains("chtc"), "\(name) names a site")
        }
    }
}
