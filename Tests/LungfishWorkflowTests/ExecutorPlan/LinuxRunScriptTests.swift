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
    /// below the staging folder, with the stand-in executor (and its `gate`) in the executor's place.
    private func writeBatch(_ samples: [String], gate: Gate = .open) throws -> Written {
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
            let target = data.appendingPathComponent(layout.pathBelowFolder(file.stagingPath))
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            switch file.role {
            case "image": try sif.write(to: target)
            case "executor": try executorScript(reports: reports, gate: gate).write(to: target, atomically: true, encoding: .utf8)
            default: try FileManager.default.copyItem(atPath: try XCTUnwrap(file.source), toPath: target.path)
            }
        }
        return Written(folder: folder, data: data, batch: batch, reports: reports)
    }

    /// What the executor stand-in does around its work, so a test can see how many samples run together (QA 2, C5 D13).
    /// `exclusive` takes `<marks>/busy` before it writes the record and exits 9 at once when another executor holds it,
    /// so a sample that ran beside another has no record and no `result/`. `meeting` writes `<marks>/in.<pid>` and waits
    /// up to 30 seconds for a second `in.*` file, so it finishes only when two samples run together.
    private enum Gate {
        case open, exclusive, meeting
    }

    /// The executor's stand-in, started in the plan folder: it records its arguments as the run record and writes the
    /// payload, each report, a step log and a work file that no job returns, beside the plan.json the tar held.
    private func executorScript(reports: [String], gate: Gate = .open) -> String {
        var lines = ["#!/bin/sh"]
        switch gate {
        case .open:
            break
        case .exclusive:
            lines += ["mkdir '\(marks.path)/busy' || exit 9", "sleep 1"]
        case .meeting:
            lines += [
                ": > '\(marks.path)/in.'$$", "tries=0", "while true; do", "  n=0",
                "  for f in '\(marks.path)'/in.*; do [ -e \"$f\" ] && n=$((n + 1)); done",
                "  [ \"$n\" -ge 2 ] && break", "  tries=$((tries + 1))", "  [ \"$tries\" -le 300 ] || exit 9",
                "  sleep 0.1", "done",
            ]
        }
        lines += [
            "printf '%s\\n' \"$@\" > run-record.json", "mkdir -p out work logs",
            "echo reads > \(ExecutorPlanEmitter.payloadPath)", "echo intermediate > work/intermediate.fastq",
            "echo step > logs/step-1.log",
        ]
        for report in reports {
            lines += ["mkdir -p \((report as NSString).deletingLastPathComponent)", "echo report > \(report)"]
        }
        if gate == .exclusive { lines.append("rmdir '\(marks.path)/busy'") }
        return (lines + ["exit 0"]).joined(separator: "\n") + "\n"
    }

    private func launch(_ written: Written, _ arguments: [String]) throws -> (status: Int, out: String, err: String) {
        let path = standIns.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        let result = try ToolProcess.start(ToolProcessSpec(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [written.folder.appendingPathComponent(LinuxRunScript.fileName).path] + arguments,
            environment: ProcessInfo.processInfo.environment.merging(["PATH": path]) { $1 },
            timeout: .seconds(30), label: "run-local"
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

    /// C5 ruling 6: a Docker run with no `--image` is refused in the README's words for the image, a Docker image for
    /// linux/amd64 made from the batch's file, and names the lab's command that makes one. No sample runs.
    func testDockerRefusesARunWithNoImageAndNamesHowToMakeOne() throws {
        let written = try writeBatch(["S1"])
        let run = try launch(written, ["--runtime", "docker", "--data", written.data.path])
        XCTAssertEqual(run.status, 2, run.err)
        XCTAssertTrue(run.err.contains("A Docker run needs --image, a Docker image for linux/amd64 made from the batch's image lge-tools-test.sif. The lab's launcher-tier.sh image command makes one. No sample ran."), run.err)
        XCTAssertFalse(run.err.contains("unpacked"), run.err)
        XCTAssertFalse(exists(written, "S1/result"))
        XCTAssertEqual(try recordedRuns("docker-run.").count, 0)
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
                "\(layout.pathBelowFolder(executor.stagingPath))=\(executorPath)",
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
            "condor_q -hold -af ClusterId ProcId DAGNodeName ExitCode HoldReason",
            "To see every sample's state, read run.dag.status.",
            "<sample>/logs/ in this folder, to see which step",
            "condor_rm <ClusterId>.<ProcId>",
            "MAXJOBS lge 10", "--jobs <n> changes it",
            "sh run-local.sh --runtime apptainer --data <data folder>",
            "sh run-local.sh --runtime docker --image <image> --data <data folder>",
            "Docker runs <image>, a Docker image for linux/amd64 made from that same file.",
            "A Docker run reads no images/ folder.", "a Linux machine or a Mac with Docker",
            "is that folder alone, with no <host>:.",
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
        XCTAssertFalse(readme.contains("Run on one Linux machine"), "a Mac with Docker runs the script too")
        let order = try ["The adopt reads one folder", "rsync -a", "Do not copy logs/", "--adopt --project", "To adopt the rest"]
            .map { try XCTUnwrap(readme.range(of: $0), $0).lowerBound }
        XCTAssertEqual(order, order.sorted())
        for name in ["README.txt", "run-local.sh", "jobs.tsv"] {
            let text = try String(contentsOf: written.folder.appendingPathComponent(name), encoding: .utf8)
            XCTAssertFalse(text.lowercased().contains("chtc"), "\(name) names a site")
        }
    }

    /// ARCH-c5 point 8: the README's `samples.csv` example is a sheet Lungfish reads, with a `request_disk` cell and an
    /// empty one, so the example and `FASTQSampleSheet` cannot drift apart.
    func testReadmeSampleSheetExampleIsASheetLungfishReads() throws {
        let written = try writeBatch(["S1"])
        let readme = try String(contentsOf: written.folder.appendingPathComponent("README.txt"), encoding: .utf8)
        let lines = readme.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        let header = try XCTUnwrap(lines.firstIndex(of: "sample,r1,r2,request_disk"), "The README has no samples.csv example")
        let csv = Array(lines.dropFirst(header).prefix(3)).joined(separator: "\n") + "\n"
        let sheet = try FASTQSampleSheet.parse(csv: csv, sourceURL: root.appendingPathComponent("samples.csv"))
        XCTAssertEqual(sheet.entries.map(\.sampleName), ["S1", "S2"])
        XCTAssertEqual(sheet.entries.first?.metadata["request_disk"], "40")
        XCTAssertNil(sheet.entries.last?.metadata["request_disk"])
        // A relative path is read from the folder that holds the sheet, as the README says.
        XCTAssertEqual(sheet.entries.first?.r1.path, root.appendingPathComponent("S1_R1.fastq.gz").path)
    }

    /// Ruling X6 (R-README), the finding of the CASPER batch's lab run. Step 1 copies the files of `staging-files.json` that
    /// have a `source`, and leaves a file in `shared/` that is already there, since the jobs of other batches read it. The
    /// list is what the step reads: every file in `shared/` is named by its SHA-256, so one with the listed size is the same
    /// file, and the image is the one file with no `source`. The text is read with its hard line breaks joined.
    func testReadmeSaysWhichFilesToCopyAndLeavesSharedFilesInPlace() throws {
        let written = try writeBatch(["S1"])
        let readme = try String(contentsOf: written.folder.appendingPathComponent("README.txt"), encoding: .utf8)
        let flat = readme.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let staging = "/staging/groups/g/1/lge-test"
        for sentence in [
            "For each file in staging-files.json that has a source, copy or link that source to the file's stagingPath, below \(staging).",
            "The name of a file in shared/ starts with its SHA-256, so a file already there with the listed size is the same file. Leave it, and never copy over it, since the jobs of other batches may be reading it.",
        ] {
            XCTAssertTrue(flat.contains(sentence), "\(sentence) is missing: \(flat)")
        }
        let files = try JSONDecoder().decode(
            ExecutorPlanBatchFiles.self, from: Data(contentsOf: written.folder.appendingPathComponent("staging-files.json"))
        ).files
        let shared = files.filter { $0.stagingPath.contains("/shared/") }
        XCTAssertFalse(shared.isEmpty, "the batch lists files in shared/")
        for file in shared {
            XCTAssertTrue((file.stagingPath as NSString).lastPathComponent.hasPrefix("\(file.sha256)-"),
                          "\(file.stagingPath) is named by its SHA-256 and a dash")
        }
        XCTAssertEqual(files.filter { $0.source == nil }.map(\.role), ["image"], "the image is the one file with no source")
    }

    /// Lane X's findings from the first run on a lab machine: the README says "copy or link" for each listed file, names
    /// `--samplesheet samples.csv` and that the Mac reads the sheet when the batch is written, says the staging folder
    /// can be the data folder, says what `run-local.sh` prints and where the job's logs are, says the copy loop's
    /// `rsync` uses the ssh setup for the host, and says the project must not hold a bundle of a sample's name and how to
    /// start over. The text is read with its hard line breaks joined, so a new wrap does not move a pin.
    func testReadmeAnswersTheFindingsOfALabMembersFirstRun() throws {
        let written = try writeBatch(["S1"])
        let readme = try String(contentsOf: written.folder.appendingPathComponent("README.txt"), encoding: .utf8)
        let flat = readme.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let staging = "/staging/groups/g/1/lge-test"
        let sentences = [
            "For each file in staging-files.json that has a source, copy or link that source to the file's stagingPath, below \(staging).",
            "the file on the Mac to copy or link.",
            "Make a data folder there and copy or link into it each file staging-files.json lists",
            "Lungfish reads it on the Mac, when it writes the batch with --samplesheet samples.csv.",
            "On a machine that reaches the staging folder, \(staging) can be the data folder.",
            "logs/<sample>.err hold the run's output. Those are the logs of the job.",
            "run-local.sh prints its progress to its own output, a line when a sample starts and a line when it finishes. It prints none of the job's output.",
            "The rsync command reaches <host> through your ssh setup, so a name from your ssh config works.",
            "The project must not already hold a bundle with the name of a sample of the batch",
            "To start over, delete those bundles from the project and adopt the batch again.",
            "<sample>: The project already holds the bundle <bundle>.",
        ]
        for sentence in sentences {
            XCTAssertTrue(flat.contains(sentence), sentence)
        }
        XCTAssertFalse(flat.contains("Copy each file"), "a file may be linked as well as copied")
        XCTAssertFalse(readme.lowercased().contains("chtc"), "the README names no site (O41)")
    }

    /// The fact-check of lane CMD's strings (FC-CMD) found three README sentences false. A job that the executor
    /// refuses leaves its record and one that `lge-job.sh` refuses leaves none, so that message is in
    /// `logs/<sample>.err`. `staging-files.json` gives the image no file on the Mac, since the image is staged already.
    /// The adopt can print more lines than the four the README lists. The text is read with its hard line breaks joined.
    func testReadmeWordsThatTheFactCheckFoundFalseSayWhatTheCodeDoes() throws {
        let written = try writeBatch(["S1"])
        let readme = try String(contentsOf: written.folder.appendingPathComponent("README.txt"), encoding: .utf8)
        let flat = readme.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for sentence in [
            "A job the executor refuses before its first step leaves only the record. A job that lge-job.sh refuses leaves no record, so read logs/<sample>.err.",
            "each with its size and its SHA-256. Each file other than the image also has a source, the file on the Mac to copy or link. The image is staged already.",
            "These are four of the lines you may meet:",
        ] {
            XCTAssertTrue(flat.contains(sentence), "\(sentence) is missing: \(flat)")
        }
        for stale in [
            "A job refused before its first step",
            "each with its size, its SHA-256 and the file on the Mac",
            "each file except the image with the file on the Mac to copy or link",
            "Copy or link each file staging-files.json lists",
            "These are the four lines you may meet:",
        ] {
            XCTAssertFalse(flat.contains(stale), "\(stale) is false: \(flat)")
        }
        // The list gives the image no file on the Mac and gives each read one, as the README now says.
        let files = try JSONDecoder().decode(
            ExecutorPlanBatchFiles.self, from: Data(contentsOf: written.folder.appendingPathComponent("staging-files.json"))
        ).files
        XCTAssertNil(try XCTUnwrap(files.first { $0.role == "image" }).source, "the image is staged already")
        XCTAssertTrue(files.filter { $0.role == "input" }.allSatisfy { $0.source != nil }, "each read has its file on the Mac")
    }

    /// UX-c5 section 4: the held-job steps come in order, the removal before the run again, each step is numbered, and the
    /// last one brings the results home and not the batch folder. A swap of two steps fails here.
    func testReadmeHeldJobStepsNameTheSample() throws {
        let written = try writeBatch(["S1"])
        let readme = try String(contentsOf: written.folder.appendingPathComponent("README.txt"), encoding: .utf8)
        let start = try XCTUnwrap(readme.range(of: "If a sample's job is held"))
        let end = try XCTUnwrap(readme.range(of: "Run on one machine with Apptainer or Docker", range: start.upperBound..<readme.endIndex))
        let held = String(readme[start.upperBound..<end.lowerBound])
        let record = "/staging/groups/g/1/lge-test/batches/batch/<sample>/result/run-record.json"
        let commands = ["condor_q -hold -af ClusterId ProcId DAGNodeName ExitCode HoldReason",
                        "cp \(record) <sample>/run-record-<ClusterId>.json", "condor_rm <ClusterId>.<ProcId>",
                        "condor_submit_dag run.dag"]
        let places = try commands.map { try XCTUnwrap(held.range(of: $0), $0).lowerBound }
        XCTAssertEqual(places, places.sorted())
        let steps = try (1...5).map { try XCTUnwrap(held.range(of: "\n\($0). "), "step \($0)").lowerBound }
        XCTAssertEqual(steps, steps.sorted())
        // CHTC-3d R1 to R3. Step 1 says a hold shows as an eviction and then a hold, which is one hold, and step 2 says
        // HTCondor starts a job again by itself, at most twice, when the exit code is 0.
        let step1 = held[steps[0]..<steps[1]], step2 = held[steps[1]..<steps[2]]
        XCTAssertTrue(step2.contains("at most twice"), String(step2))
        let evicted = try XCTUnwrap(step1.range(of: "Job was evicted"), String(step1)).lowerBound
        let heldLine = try XCTUnwrap(step1.range(of: "Job was held"), String(step1)).lowerBound
        XCTAssertLessThan(evicted, heldLine)
        XCTAssertTrue(held.contains("copy the results back to the Mac and adopt the batch"), held)
        XCTAssertFalse(held.contains("copy the batch folder back"), held)
        XCTAssertFalse(readme.lowercased().contains("chtc"))
    }

    /// QA 2 and C5 D13: `--jobs` is the most samples running together, and the script runs that many at once. The
    /// `exclusive` executor fails a sample that overlaps another, so `--jobs 1` finishing all three samples shows they
    /// ran one at a time; the `meeting` executor finishes only when a second sample runs beside it, so `--jobs 2`
    /// finishing both shows two ran together.
    func testJobsCapsTheSamplesRunningAtOnce() throws {
        let serial = try writeBatch(["S1", "S2", "S3"], gate: .exclusive)
        let one = try launch(serial, ["--runtime", "docker", "--image", "lge-test:1", "--data", serial.data.path, "--jobs", "1"])
        XCTAssertEqual(one.status, 0, one.err)
        for sample in ["S1", "S2", "S3"] {
            XCTAssertTrue(exists(serial, "\(sample)/result/run-record.json"), "\(sample) ran beside another sample: \(one.err)")
        }

        // The second batch takes the first one's place.
        try FileManager.default.removeItem(at: serial.folder)
        try FileManager.default.removeItem(at: serial.data)
        let pair = try writeBatch(["S1", "S2"], gate: .meeting)
        let two = try launch(pair, ["--runtime", "docker", "--image", "lge-test:1", "--data", pair.data.path, "--jobs", "2"])
        XCTAssertEqual(two.status, 0, two.err)
        for sample in ["S1", "S2"] {
            XCTAssertTrue(exists(pair, "\(sample)/result/run-record.json"), "\(sample) did not run beside the other sample: \(two.err)")
        }
    }
}
