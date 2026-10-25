// ImportFastqPlanOptionsTests.swift - `import fastq --write-plan` needs no project and starts no ssh (CHTC C4 lane F M2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import XCTest
import Foundation
import LungfishCore
import LungfishPortable
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow

final class ImportFastqPlanOptionsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "ImportFastqPlanOptions")
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// A planning step writes nothing into a project (ARCH 3), so `--write-plan` parses with no `--project`.
    func testParseWritePlanNeedsNoProject() throws {
        let command = try ImportCommand.FastqSubcommand.parse([
            "/data/S1_R1.fastq", "/data/S1_R2.fastq", "--write-plan", "/plans/batch",
            "--executor-manifest", "/x/manifest.json", "--image", "/x/image.json",
            "--image-tool-manifest", "/x/image-manifest.json", "--staging-folder", "/staging/groups/g/1/lge",
            "--plan-database", "deacon-panhuman=/db/panhuman.idx", "--threads", "4", "--clumpify-heap-gb", "8",
        ])
        XCTAssertNil(command.project)
        XCTAssertTrue(command.planOptions.isOn)
        XCTAssertEqual(command.planOptions.writePlan, "/plans/batch")
        XCTAssertEqual(command.planOptions.executorManifest, "/x/manifest.json")
        XCTAssertEqual(command.planOptions.image, "/x/image.json")
        XCTAssertEqual(command.planOptions.imageToolManifest, "/x/image-manifest.json")
        XCTAssertEqual(command.planOptions.stagingFolder, "/staging/groups/g/1/lge")
        XCTAssertEqual(command.planOptions.planDatabases, ["deacon-panhuman=/db/panhuman.idx"])
        XCTAssertEqual(command.threads, 4)
    }

    /// An import still needs its project: only `--write-plan` runs without one.
    func testImportWithoutProjectOrWritePlanIsRefused() {
        XCTAssertThrowsError(try ImportCommand.FastqSubcommand.parse(["/data/fastq_dir", "--dry-run"])) { error in
            let message = ImportCommand.FastqSubcommand.message(for: error)
            XCTAssertTrue(message.contains("--project <project>"), message)
        }
    }

    /// A plan fixes its thread count, so `--write-plan` with no `--threads` ends with the input error exit code and
    /// writes no folder.
    func testWritePlanWithoutThreadsEndsWithExitCode3() async throws {
        let fixture = try writeFixture()
        let folder = root.appendingPathComponent("no-threads", isDirectory: true)
        let command = try ImportCommand.FastqSubcommand.parse(
            fixture.reads.map(\.path) + fixture.planArguments(folder: folder) + ["--clumpify-heap-gb", "4"]
        )
        do {
            try await command.run()
            XCTFail("--write-plan with no --threads must be refused")
        } catch let error as ExitCode {
            XCTAssertEqual(error.rawValue, 3)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    /// The plan has its own detection, so `--pairing`, `--recursive` and `--name` are refused with the input error exit
    /// code and no folder, never ignored.
    func testWritePlanRefusesPairingRecursiveAndName() async throws {
        let fixture = try writeFixture()
        for (index, option) in [["--pairing", "single"], ["--recursive"], ["--name", "X"]].enumerated() {
            let folder = root.appendingPathComponent("refused-\(index)", isDirectory: true)
            let command = try ImportCommand.FastqSubcommand.parse(
                fixture.reads.map(\.path) + fixture.planArguments(folder: folder)
                    + ["--threads", "1", "--clumpify-heap-gb", "4"] + option
            )
            do {
                try await command.run()
                XCTFail("\(option) with --write-plan must be refused")
            } catch let error as ExitCode {
                XCTAssertEqual(error.rawValue, 3, "\(option)")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "\(option)")
        }
    }

    /// An R1 and an R2 file for `sample` in a folder of their own.
    private func writeReadPair(_ sample: String) throws -> [URL] {
        let folder = root.appendingPathComponent("reads-\(sample)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try [1, 2].map { mate in
            let url = folder.appendingPathComponent("\(sample)_R\(mate).fastq")
            try "@\(sample)a/\(mate)\nACGTACGTAC\n+\nIIIIIIIIII\n".write(to: url, atomically: true, encoding: .utf8)
            return url
        }
    }

    /// `--dry-run` with `--write-plan` makes the refusals the real run makes for a fixed reason, so a dry run that passes
    /// is a run that can pass. It writes nothing in either case.
    func testWritePlanDryRunReportsTheRefusalsOfTheRealRun() async throws {
        let fixture = try writeFixture()
        let dotted = try writeReadPair("S1.2")
        let cases: [(name: String, reads: [URL], staging: String, extra: [String], refused: Bool)] = [
            ("no clumping and no binning", fixture.reads, Fixture.stagingFolder,
             ["--clumping-tool", "none", "--quality-binning", "none"], true),
            ("a sample name the DAG cannot name", dotted, Fixture.stagingFolder, ["--clumping-tool", "bbtools"], true),
            ("a staging folder with a space", fixture.reads, "/staging/groups/our lab/x", ["--clumping-tool", "bbtools"], true),
            ("the plain fixture", fixture.reads, Fixture.stagingFolder, ["--clumping-tool", "bbtools"], false),
        ]
        for (index, item) in cases.enumerated() {
            let folder = root.appendingPathComponent("dry-run-\(index)", isDirectory: true)
            let command = try ImportCommand.FastqSubcommand.parse(
                item.reads.map(\.path) + fixture.planArguments(folder: folder, staging: item.staging)
                    + ["--threads", "1", "--clumpify-heap-gb", "4", "--dry-run"] + item.extra
            )
            do {
                try await command.run()
                XCTAssertFalse(item.refused, "\(item.name): the dry run passed where the real run is refused")
            } catch let error as ExitCode {
                XCTAssertTrue(item.refused, "\(item.name): the dry run was refused")
                XCTAssertEqual(error.rawValue, 3, item.name)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "\(item.name): a dry run writes nothing")
        }
    }

    /// The built CLI writes the submit folder with `ssh`, `scp`, `rsync` and the HTCondor submit commands replaced by
    /// stand-ins at the front of `PATH`, and no stand-in ran: the planning step opens no connection and submits nothing.
    func testWritePlanOpensNoSSH() throws {
        guard let cli = CLISIGTERMHarness.cliBinaryURL(for: Self.self) else {
            throw XCTSkip("Inject LUNGFISH_CLI with the resolved swiftbuild product or build it beside the test bundle")
        }
        let fixture = try writeFixture()
        let standIns = root.appendingPathComponent("stand-in-bin", isDirectory: true)
        let markers = root.appendingPathComponent("markers", isDirectory: true)
        try FileManager.default.createDirectory(at: standIns, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
        for name in ["ssh", "scp", "sftp", "rsync", "condor_submit", "condor_submit_dag"] {
            let script = standIns.appendingPathComponent(name)
            try "#!/bin/sh\necho \"$*\" > '\(markers.path)/\(name)'\nexit 0\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }
        let path = standIns.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
        let folder = root.appendingPathComponent("batch-1", isDirectory: true)
        let arguments = ["import", "fastq"] + fixture.reads.map(\.path) + fixture.planArguments(folder: folder)
            + ["--threads", "1", "--clumpify-heap-gb", "4", "--clumping-tool", "bbtools", "--format", "json"]
        let result = try ToolProcess.start(ToolProcessSpec(
            executableURL: cli, arguments: arguments,
            environment: CLISIGTERMHarness.childEnvironment(overriding: ["PATH": path]),
            timeout: .seconds(120), label: "write-plan-opens-no-ssh"
        )).waitBlocking()
        XCTAssertEqual(result.status, 0, result.stderrText)

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: markers.path), [],
                       "The planning step started a connection or submit command")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(names, ["S1", "S2", "lge-job.sh", "logs", "run.dag", "sample.sub", "staging-files.json"])
        for sample in ["S1", "S2"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(sample)/plan.json").path), sample)
        }

        // --format json prints the submit folder's and each plan folder's path.
        let events = result.stdoutText.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        let complete = try XCTUnwrap(events.first { $0["event"] as? String == "complete" }, result.stdoutText)
        XCTAssertEqual(complete["outputs"] as? [String],
                       [folder.path, folder.appendingPathComponent("S1").path, folder.appendingPathComponent("S2").path])
    }

    /// The built CLI's run of the fixture plan into a batch folder named `batch-1`, in the output format given. The tests
    /// below read what a person or a script reads: the output of the run.
    private func runWritePlan(cli: URL, format: String) throws -> (succeeded: Bool, stdout: String, stderr: String) {
        let fixture = try writeFixture()
        let folder = root.appendingPathComponent("batch-1", isDirectory: true)
        let arguments = ["import", "fastq"] + fixture.reads.map(\.path) + fixture.planArguments(folder: folder)
            + ["--threads", "1", "--clumpify-heap-gb", "4", "--clumping-tool", "bbtools", "--format", format]
        let result = try ToolProcess.start(ToolProcessSpec(
            executableURL: cli, arguments: arguments, environment: CLISIGTERMHarness.childEnvironment(overriding: [:]),
            timeout: .seconds(120), label: "write-plan-\(format)"
        )).waitBlocking()
        return (result.status == 0, result.stdoutText, result.stderrText)
    }

    /// Review of fix G3, fix 1. A GUI or a script that reads the events never sees the human text, so the `complete`
    /// event names each of a sample's result folders as an artifact of kind `staging-result-folder`, with the sample as
    /// its role and the folder on the staging area as its path (C5 D1).
    func testWritePlanCompleteEventNamesEachResultFolderToMake() throws {
        guard let cli = CLISIGTERMHarness.cliBinaryURL(for: Self.self) else {
            throw XCTSkip("Inject LUNGFISH_CLI with the resolved swiftbuild product or build it beside the test bundle")
        }
        let run = try runWritePlan(cli: cli, format: "json")
        XCTAssertTrue(run.succeeded, run.stderr)
        let events = run.stdout.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        let complete = try XCTUnwrap(events.first { $0["event"] as? String == "complete" }, run.stdout)
        let artifacts = try XCTUnwrap(complete["artifacts"] as? [[String: Any]], run.stdout)
        let folders = artifacts.filter { $0["kind"] as? String == "staging-result-folder" }
        XCTAssertEqual(folders.map { $0["role"] as? String }, ["S1", "S1", "S2", "S2"], "two folders a sample: \(artifacts)")
        XCTAssertEqual(folders.map { $0["path"] as? String },
                       ["S1/result", "S1/result/out", "S2/result", "S2/result/out"]
                           .map { "\(Fixture.stagingFolder)/batches/batch-1/\($0)" })
        XCTAssertFalse(artifacts.contains { $0["kind"] as? String == "staging-plan-tar" }, "the tars stay in the submit folder")
    }

    /// Review of fix G3, fix 1 and the wrapper question. The human text of the same run names each result folder once and
    /// says that run.dag makes it, so a person has no step to take, and says each plan tar stays in the submit folder.
    func testWritePlanTextNamesEachResultFolderToMake() throws {
        guard let cli = CLISIGTERMHarness.cliBinaryURL(for: Self.self) else {
            throw XCTSkip("Inject LUNGFISH_CLI with the resolved swiftbuild product or build it beside the test bundle")
        }
        let run = try runWritePlan(cli: cli, format: "text")
        XCTAssertTrue(run.succeeded, run.stderr)
        for sample in ["S1", "S2"] {
            for made in ["result", "result/out"] {
                let line = "run.dag makes the folder \(Fixture.stagingFolder)/batches/batch-1/\(sample)/\(made) before it submits the job of \(sample)"
                XCTAssertEqual(run.stdout.components(separatedBy: line).count - 1, 1, "\(line) once in: \(run.stdout)")
            }
            XCTAssertTrue(run.stdout.contains("\(sample)/plan.tar stays in the submit folder"), run.stdout)
        }
        XCTAssertFalse(run.stdout.contains("before you submit"), "no folder is left to a person: \(run.stdout)")
    }

    /// A file that `--executor-manifest`, `--image` or `--image-tool-manifest` names and that is missing or holds `{}`
    /// ends the command with exit code 3 and a failed line that names the option, not a Foundation or decoder message.
    func testWritePlanNamesTheOptionOfAnUnreadableFile() throws {
        guard let cli = CLISIGTERMHarness.cliBinaryURL(for: Self.self) else {
            throw XCTSkip("Inject LUNGFISH_CLI with the resolved swiftbuild product or build it beside the test bundle")
        }
        let fixture = try writeFixture()
        let empty = root.appendingPathComponent("empty.json")
        try Data("{}".utf8).write(to: empty)
        let missing = root.appendingPathComponent("missing.json")
        let folder = root.appendingPathComponent("unreadable", isDirectory: true)
        for option in ["--executor-manifest", "--image", "--image-tool-manifest"] {
            for unreadable in [missing, empty] {
                let label = "\(option) \(unreadable.lastPathComponent)"
                var plan = fixture.planArguments(folder: folder)
                plan[try XCTUnwrap(plan.firstIndex(of: option)) + 1] = unreadable.path
                let result = try ToolProcess.start(ToolProcessSpec(
                    executableURL: cli,
                    arguments: ["import", "fastq"] + fixture.reads.map(\.path) + plan
                        + ["--threads", "1", "--clumpify-heap-gb", "4", "--clumping-tool", "bbtools", "--format", "json"],
                    environment: CLISIGTERMHarness.childEnvironment(overriding: [:]),
                    timeout: .seconds(120), label: "write-plan-unreadable-file"
                )).waitBlocking()
                XCTAssertEqual(result.status, 3, "\(label): \(result.stderrText)")
                let events = result.stdoutText.split(separator: "\n").compactMap {
                    try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
                }
                let failed = try XCTUnwrap(events.first { $0["event"] as? String == "failed" }, "\(label): \(result.stdoutText)")
                // The failed line of a version 2 event holds its sentence under `error`.
                let message = try XCTUnwrap(failed["error"] as? String, "\(label): \(failed)")
                XCTAssertTrue(message.contains("given to \(option) is not"), "\(label): \(message)")
                XCTAssertFalse(message.contains("Error Domain") || message.contains("keyNotFound"), "\(label): \(message)")
                XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), label)
            }
        }
    }

    /// The `request_disk` column is a whole number of GB, with or without a `GB` ending. Any other value is refused with
    /// the sample and the column named.
    func testRequestDiskColumnReadsWholeGB() throws {
        for text in ["40", "40GB", "40 gb"] {
            XCTAssertEqual(try ImportCommand.FastqSubcommand.requestDiskGiB(text, sample: "S1"), 40, text)
        }
        for text in ["0", "1.5", "forty"] {
            XCTAssertThrowsError(try ImportCommand.FastqSubcommand.requestDiskGiB(text, sample: "S1"), text) { error in
                let refusal = error as? ImportFastqPlanRefusal
                XCTAssertTrue(refusal?.message.contains("S1") == true && refusal?.message.contains("request_disk") == true,
                              "\(text): \(error)")
            }
        }
    }

    /// ARCH-c5 point 8. The batch's sheet is comma-separated, `samples.csv`, and its `request_disk` column gives one
    /// sample's disk: S1 asks 40 GB in `run.dag`, and S2, whose cell is empty, asks what the writer's rule gives.
    func testPlanReadsCommaSampleSheetRequestDisk() async throws {
        let fixture = try writeFixture()
        let sheet = root.appendingPathComponent("samples.csv")
        let lines = ["sample,r1,r2,request_disk",
                     "S1,\(fixture.reads[0].path),\(fixture.reads[1].path),40",
                     "S2,\(fixture.reads[2].path),\(fixture.reads[3].path),"]
        try (lines.joined(separator: "\n") + "\n").write(to: sheet, atomically: true, encoding: .utf8)
        let folder = root.appendingPathComponent("sheet-batch", isDirectory: true)
        let command = try ImportCommand.FastqSubcommand.parse(
            ["--samplesheet", sheet.path] + fixture.planArguments(folder: folder)
                + ["--threads", "1", "--clumpify-heap-gb", "4", "--clumping-tool", "bbtools"]
        )
        try await command.run()
        let dag = try String(contentsOf: folder.appendingPathComponent("run.dag"), encoding: .utf8)
        let vars = dag.split(separator: "\n").filter { $0.hasPrefix("VARS ") }
        XCTAssertEqual(vars.count, 2, dag)
        XCTAssertTrue(vars[0].hasPrefix("VARS S1 ") && vars[0].contains("request_disk=\"40GB\""), String(vars[0]))
        // S2's reads are far under a GiB, so the rule gives the default: one GiB for the reads plus 8.
        XCTAssertTrue(vars[1].hasPrefix("VARS S2 ") && vars[1].contains("request_disk=\"9GB\""), String(vars[1]))
    }

    // MARK: Fixture

    /// Two samples' reads, an executor stand-in with its `manifest.json`, a tool manifest and the `image.json` that pins it.
    private struct Fixture {
        var reads: [URL]
        var executorManifest: URL
        var image: URL
        var toolManifest: URL

        static let stagingFolder = "/staging/groups/g/1/lge-chtc-test"

        func planArguments(folder: URL, staging: String = Fixture.stagingFolder) -> [String] {
            ["--write-plan", folder.path, "--executor-manifest", executorManifest.path, "--image", image.path,
             "--image-tool-manifest", toolManifest.path, "--staging-folder", staging]
        }
    }

    private func writeFixture() throws -> Fixture {
        let reads = root.appendingPathComponent("reads", isDirectory: true)
        try FileManager.default.createDirectory(at: reads, withIntermediateDirectories: true)
        var urls: [URL] = []
        for sample in ["S1", "S2"] {
            for mate in [1, 2] {
                let url = reads.appendingPathComponent("\(sample)_R\(mate).fastq")
                try "@\(sample)a/\(mate)\nACGTACGTAC\n+\nIIIIIIIIII\n@\(sample)b/\(mate)\nTTGGCCAATT\n+\nIIIIIIIIII\n"
                    .write(to: url, atomically: true, encoding: .utf8)
                urls.append(url)
            }
        }
        let executorFolder = root.appendingPathComponent("executor", isDirectory: true)
        try FileManager.default.createDirectory(at: executorFolder, withIntermediateDirectories: true)
        let executor = Data("executor stand-in".utf8)
        try executor.write(to: executorFolder.appendingPathComponent("lungfish-executor"))
        let digest = String(repeating: "b", count: 64)
        let manifest: [String: Any] = [
            "sha256": PortableDigest.sha256Hex(of: executor), "size": executor.count,
            "lgeVersion": "2026.10.22", "lgeCommit": "74ae0db3400d6b7519550e33dafc369e081fa114",
            "targetTriple": "x86_64-swift-linux-musl", "toolchainID": "swift-6.2", "toolchainSHA256": digest,
            "staticLinuxSDKID": "swift-6.2-static-linux", "staticLinuxSDKSHA256": digest,
        ]
        let manifestURL = executorFolder.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestURL)

        let tools = [("clumpify.sh", "39.13", "he5f24ec_0", "bbmap"), ("reformat.sh", "39.13", "he5f24ec_0", "bbmap"),
                     ("java", "25.0.2", "h1602c4f_26", "openjdk"), ("bgzip", "1.21", "h3ff9d97_0", "htslib"),
                     ("pigz", "2.8", "h421ea60_1", "pigz"), ("seqkit", "2.10.0", "h9ee0642_0", "seqkit"),
                     ("gzip", "1.13", "h8359307_0", "gzip"), ("fastp", "1.0.1", "h43da1c4_0", "fastp")]
        let toolManifest = try ImageToolManifest(platform: .linux64, tools: tools.map {
            ImageTool(id: $0.0, version: $0.1, build: $0.2, path: "/opt/conda/bin/\($0.0)", condaPackage: $0.3)
        }).encoded()
        let toolManifestURL = root.appendingPathComponent("image-manifest.json")
        try toolManifest.write(to: toolManifestURL)
        let image: [String: Any] = [
            "schemaVersion": 1,
            "sif": ["fileName": "lge-tools-test.sif", "sha256": String(repeating: "e", count: 64), "size": 396_402_688],
            "imageManifest": ["sha256": PortableDigest.sha256Hex(of: toolManifest), "size": toolManifest.count],
        ]
        let imageURL = root.appendingPathComponent("image.json")
        try JSONSerialization.data(withJSONObject: image, options: [.sortedKeys]).write(to: imageURL)
        return Fixture(reads: urls, executorManifest: manifestURL, image: imageURL, toolManifest: toolManifestURL)
    }
}
