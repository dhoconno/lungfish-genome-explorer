// MappingToolVersionProbeTests.swift - The BBMap version comes from the tool, never a path or an option
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.5 decision S10. The captures are real BBTools 40.02 output from
// ~/.lungfish on 2026-10-10, with the home folder written as <root>.

import Foundation
import LungfishTestSupport
import XCTest
@testable import LungfishWorkflow

final class MappingToolVersionProbeTests: XCTestCase {
    private static let root = "/Users/someone/.lungfish/conda"
    private static let helpLine = "For help, please run the shellscript with no parameters, or look in /docs/."

    func testReadsTheVersionLineOfEachBBToolsWrapper() {
        let reformat = "java -ea   -Xmx300m -Xms300m -cp \(Self.root)/envs/bbtools/opt/bbmap-40.02-0/current/ jgi.ReformatReads --version\n"
            + "BBTools version 40.02\n\(Self.helpLine)\n"
        let mapPacBio = "Detected 67108864KB total memory on macOS, estimating 43620761KB available\n"
            + "Detected 34546384KB free memory on macOS (vm_stat)\n"
            + "java -ea   -Xmx27928m -Xms27928m -cp \(Self.root)/envs/bbtools/opt/bbmap-40.02-0/current/ align2.BBMapPacBio "
            + "build=1 overwrite=true minratio=0.40 fastareadlen=6000 ambiguous=best minscaf=100 startpad=10000 "
            + "stoppad=10000 midpad=6000 --version\nBBTools version 40.02\n\(Self.helpLine)\n"
        let olderBanner = "java -ea   -Xmx29890m -Xms29890m -cp \(Self.root)/envs/bbtools/opt/bbmap-40.02-0/current/ "
            + "align2.BBMapPacBio build=1 overwrite=true minratio=0.40 fastareadlen=6000 --version\nBBMap version 40.02\n"
        for (name, stderr) in [("reformat.sh", reformat), ("mapPacBio.sh", mapPacBio), ("BBMap banner", olderBanner)] {
            XCTAssertEqual(MappingToolVersionProbe.parseBBToolsVersion(stdout: "", stderr: stderr), "40.02", name)
        }
    }

    /// A version inside the install path, a volume name or an echoed option
    /// is never read. Without the version line there is no version.
    func testIgnoresVersionsOutsideTheVersionLine() {
        let underVolume = "java -ea   -Xmx300m -Xms300m -cp /Volumes/LGE 2.0/conda/envs/bbtools/opt/bbmap-40.02-0/current/ "
            + "jgi.ReformatReads --version\nBBTools version 40.02\n\(Self.helpLine)\n"
        XCTAssertEqual(MappingToolVersionProbe.parseBBToolsVersion(stdout: "", stderr: underVolume), "40.02")

        let cases: [(String, String, String)] = [
            ("java line only", "", "java -ea   -Xmx300m -cp /Volumes/LGE 2.0/conda/envs/bbtools/opt/bbmap-40.02-0/current/ minratio=0.40 --version\n"),
            ("micromamba error", "", "critical libmamba The given prefix does not exist: \"\(Self.root)/envs/bbmap\"\n"),
            ("bbversion.sh", "40.02\nPelagic Pals\n", ""),
            ("version inside a sentence", "", "Warning, BBTools version 40.02 is old\n"),
            ("empty", "", ""),
        ]
        for (name, stdout, stderr) in cases {
            XCTAssertNil(MappingToolVersionProbe.parseBBToolsVersion(stdout: stdout, stderr: stderr), name)
        }
    }

    /// The probe runs `reformat.sh --version` through the runner that runs
    /// BBMap. Its home lies under a folder named `LGE 2.0`, and its install
    /// folder names another version, so only the version line can give 39.01.
    func testProbesReformatThroughTheRunnerOnAnyRoot() async throws {
        let root = try TestTempDirectory.make(prefix: "bbtools-probe")
        defer { TestTempDirectory.cleanup(root) }
        let home = try ManagedSamtoolsHome.makeStub(rootURL: root.appendingPathComponent("LGE 2.0", isDirectory: true), namePrefix: "home")
        let reformat = CoreToolLocator.executableURL(environment: "bbtools", executableName: "reformat.sh", homeDirectory: home.homeURL)
        try FileManager.default.createDirectory(at: reformat.deletingLastPathComponent(), withIntermediateDirectories: true)
        let installPath = reformat.deletingLastPathComponent().deletingLastPathComponent().path + "/opt/bbmap-40.02-0/current/"
        let script = """
        #!/bin/sh
        [ "$1" = "--version" ] || exit 2
        echo 'java -ea   -Xmx300m -Xms300m -cp \(installPath) jgi.ReformatReads minratio=0.40 --version' >&2
        echo "BBTools version 39.01" >&2
        echo "\(Self.helpLine)" >&2
        """
        try script.write(to: reformat, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: reformat.path)

        let runner = NativeToolRunner(toolsDirectory: nil, homeDirectory: home.homeURL)
        let version = try await MappingToolVersionProbe.bbToolsVersion(runner: runner)
        XCTAssertEqual(version, "39.01")
    }

    /// A cancelled task throws instead of recording `unknown`. The task cancels itself before
    /// the probe starts, so the outcome does not depend on timing. The stub prints a valid
    /// version, so a swallowed cancellation would show as a version or as `unknown`.
    func testACancelledTaskThrowsCancellationError() async throws {
        let root = try TestTempDirectory.make(prefix: "bbtools-probe-cancel")
        defer { TestTempDirectory.cleanup(root) }
        let home = try ManagedSamtoolsHome.makeStub(rootURL: root, namePrefix: "home")
        let reformat = CoreToolLocator.executableURL(environment: "bbtools", executableName: "reformat.sh", homeDirectory: home.homeURL)
        try FileManager.default.createDirectory(at: reformat.deletingLastPathComponent(), withIntermediateDirectories: true)
        let script = "#!/bin/sh\necho \"BBTools version 39.01\" >&2\n"
        try script.write(to: reformat, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: reformat.path)

        let runner = NativeToolRunner(toolsDirectory: nil, homeDirectory: home.homeURL)
        let task = Task { () throws -> String in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await MappingToolVersionProbe.bbToolsVersion(runner: runner)
        }
        do {
            let version = try await task.value
            XCTFail("a cancelled probe returned \(version)")
        } catch is CancellationError {
            // expected
        }
    }

    func testAMissingProbeRecordsUnknown() async throws {
        let root = try TestTempDirectory.make(prefix: "bbtools-probe-missing")
        defer { TestTempDirectory.cleanup(root) }
        let home = try ManagedSamtoolsHome.makeStub(rootURL: root, namePrefix: "home")
        let runner = NativeToolRunner(toolsDirectory: nil, homeDirectory: home.homeURL)
        let version = try await MappingToolVersionProbe.bbToolsVersion(runner: runner)
        XCTAssertEqual(version, "unknown")
    }
}
