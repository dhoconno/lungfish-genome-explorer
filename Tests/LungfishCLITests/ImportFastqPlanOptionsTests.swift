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
        XCTAssertEqual(names, ["S1", "S2", "lge-job.sh", "logs", "run.dag", "sample.sub", "staging", "staging-files.json"])
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
