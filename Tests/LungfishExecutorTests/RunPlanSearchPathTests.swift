// RunPlanSearchPathTests.swift - The child PATH of run --plan and the Java a BBTools wrapper finds (CHTC lane K4)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable
import XCTest
@testable import LungfishExecutor
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// SWIFT ruling Q-K4-3. Each child's `PATH` is the manifest's tool folders in manifest order, then `/usr/bin` and `/bin`,
/// with nothing inherited, and a BBTools wrapper takes its Java from the manifest alone. These tests sit in
/// `RunPlanTests`, so the Linux tier runs them against the static binary too.
extension RunPlanTests {
    /// Writes `text` at `path` as an executable file, making its folder.
    static func writeExecutable(_ text: String, at path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        try RunPlanFixture.write(text, to: path)
        guard chmod(path, 0o755) == 0 else { throw ExecutorTestSupport.Failure(description: "cannot chmod \(path)") }
    }

    /// A tool listed at version 1.0, build t0, at `path`.
    static func listed(_ id: String, at path: String) -> ImageTool {
        ImageTool(id: id, version: "1.0", build: "t0", path: path, condaPackage: "test-\(id)")
    }

    /// Writes a tool manifest that lists exactly `tools` and returns its path and pin.
    static func writeManifest(_ tools: [ImageTool], in fixture: RunPlanFixture) throws -> (path: String, pin: PlanImageManifestPin) {
        let data = try ImageToolManifest(platform: ImageToolPlatform.current ?? .linux64, tools: tools).encoded()
        let path = fixture.toolsFolder + "/image-manifest.json"
        try data.write(to: URL(fileURLWithPath: path))
        return (path, PlanImageManifestPin(sha256: PortableDigest.sha256Hex(of: data), size: Int64(data.count)))
    }

    /// The run record as JSON, so a test reads each key by the name the record writes.
    static func recordObject(in fixture: RunPlanFixture) throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: fixture.planFolder + "/" + ExecutorRunRecord.fileName))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testChildPathIsManifestFoldersThenUsrBinAndBin() throws {
        let fixture = try RunPlanFixture()
        let folderA = fixture.root + "/a/bin"
        let folderB = fixture.root + "/b/bin"
        // The probe keeps the PATH it was given, as a BBTools wrapper does.
        let probe = Self.listed("a-path-probe", at: folderA + "/a-path-probe")
        try Self.writeExecutable("""
        #!/bin/sh
        printf '%s' "$PATH" > out/path.txt
        printf '%s' "${JAVA_HOME-unset},${BBMAP_JAVA-unset}" > out/java.txt
        """, at: probe.path)
        let other = Self.listed("b-tool", at: folderB + "/b-tool")
        try Self.writeExecutable("#!/bin/sh\nexit 0\n", at: other.path)
        let manifest = try Self.writeManifest([probe, other], in: fixture)
        let plan = try fixture.writePlan(
            [RunPlanFixture.step("probe", PlanToolPin(id: probe.id, version: "1.0", build: "t0"), outputs: ["out/path.txt", "out/java.txt"])],
            manifestPin: manifest.pin
        )
        let run = try fixture.run(plan, ["--image-manifest", manifest.path], environment: [
            "PATH": "/tmp/inherited-bin:/usr/local/bin", "JAVA_HOME": "/tmp/jh", "BBMAP_JAVA": "/tmp/bj",
        ])
        XCTAssertEqual(run.status, ExecutorExitCode.succeeded, run.stderr)
        XCTAssertEqual(fixture.text("out/path.txt"), "\(folderA):\(folderB):/usr/bin:/bin")
        XCTAssertEqual(fixture.text("out/java.txt"), "unset,unset")
        XCTAssertEqual(run.record?.steps.first?.environmentNames, ["HOME", "PATH", "TMPDIR"])
        let object = try Self.recordObject(in: fixture)
        XCTAssertEqual(object["searchPath"] as? [String], [folderA, folderB, "/usr/bin", "/bin"])
        XCTAssertEqual((object["runtimes"] as? [Any])?.count, 0, "a plan with no BBTools wrapper states no runtime")
    }

    /// The wrapper resolves its own symlink with basename, readlink and dirname from the fixed folders and calls java by
    /// its bare name. On macOS the manifest's Java beats `/usr/bin/java`, and on the Linux tier Java comes from the
    /// manifest alone.
    func testBBToolsStyleWrapperFindsDirnameBasenameReadlinkAndTheManifestJava() throws {
        let fixture = try RunPlanFixture()
        try Self.writeExecutable("""
        #!/bin/sh
        set -e
        name=$(basename "$0")
        link=$(readlink "$0")
        folder=$(dirname "$0")
        version=$(java)
        printf '%s|%s\\n%s\\n' "$name" "$link" "$version" > out/wrapper.txt
        printf '%s\\n' "$folder" > out/folder.txt
        """, at: fixture.root + "/env/opt/clumpify.sh")
        try FileManager.default.createDirectory(atPath: fixture.root + "/env/bin", withIntermediateDirectories: true)
        let wrapper = Self.listed("clumpify.sh", at: fixture.root + "/env/bin/clumpify.sh")
        try FileManager.default.createSymbolicLink(atPath: wrapper.path, withDestinationPath: "../opt/clumpify.sh")
        let java = Self.listed("java", at: fixture.root + "/jdk/lib/jvm/bin/java")
        try Self.writeExecutable("#!/bin/sh\necho fake-java-99\n", at: java.path)
        let manifest = try Self.writeManifest([wrapper, java], in: fixture)
        let plan = try fixture.writePlan(
            [RunPlanFixture.step("wrap", PlanToolPin(id: "clumpify.sh", version: "1.0", build: "t0"), outputs: ["out/wrapper.txt", "out/folder.txt"])],
            manifestPin: manifest.pin
        )
        let run = try fixture.run(plan, ["--image-manifest", manifest.path])
        XCTAssertEqual(run.status, ExecutorExitCode.succeeded, run.stderr)
        XCTAssertEqual(run.record?.steps.first?.outcome, .succeeded, run.record?.steps.first?.stderrTail ?? "")
        XCTAssertEqual(fixture.text("out/wrapper.txt"), "clumpify.sh|../opt/clumpify.sh\nfake-java-99\n")
        XCTAssertEqual(fixture.text("out/folder.txt"), fixture.root + "/env/bin\n")
        let object = try Self.recordObject(in: fixture)
        XCTAssertEqual(object["runtimes"] as? [[String: String]], [[
            "id": "java", "version": "1.0", "build": "t0", "path": java.path, "versionSource": "imageManifest",
        ]])
    }

    func testWrapperPlanWithoutManifestJavaIsRefusedBeforeAnyTool() throws {
        let fixture = try RunPlanFixture()
        let wrapper = Self.listed("clumpify.sh", at: fixture.toolsFolder + "/clumpify.sh")
        try Self.writeExecutable("#!/bin/sh\necho ran > out/ran.txt\n", at: wrapper.path)
        let manifest = try Self.writeManifest([wrapper], in: fixture)
        let plan = try fixture.writePlan(
            [RunPlanFixture.step("wrap", PlanToolPin(id: "clumpify.sh", version: "1.0", build: "t0"), outputs: ["out/ran.txt"])],
            manifestPin: manifest.pin
        )
        let run = try fixture.run(plan, ["--image-manifest", manifest.path])
        XCTAssertEqual(run.status, ExecutorExitCode.refused, run.stderr)
        let record = try XCTUnwrap(run.record)
        XCTAssertEqual(record.outcome, .refused)
        XCTAssertEqual(record.refusedField, "tools")
        XCTAssertEqual(record.reason, "The image's tool manifest lists no java, which clumpify.sh needs. No tool ran.")
        XCTAssertEqual(record.steps, [])
        let object = try Self.recordObject(in: fixture)
        XCTAssertNil(object["searchPath"])
        XCTAssertNil(object["runtimes"])
        for folder in ["tmp", "home", "logs", "out"] {
            XCTAssertFalse(fixture.exists(folder), folder)
        }
    }
}
