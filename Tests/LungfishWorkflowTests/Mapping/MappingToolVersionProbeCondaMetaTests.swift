// MappingToolVersionProbeCondaMetaTests.swift - A mapper whose probe cannot be trusted reads conda-meta
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.6 decision V8. The probe table marks bwa-mem2 as `.condaMetaOnly`, because the 2.3 build
// rejects `--version` and `-v` and prints a stale 2.2.1 from the `version` subcommand. The outputs
// below are the real ones, captured by `micromamba run` from the managed install on 2026-10-11.

import Foundation
import LungfishIO
import LungfishTestSupport
import XCTest
@testable import LungfishWorkflow

final class MappingToolVersionProbeCondaMetaTests: XCTestCase {
    private var root: URL!
    private var condaManager: CondaManager!
    private var runner: NativeToolRunner!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "mapping-probe-conda-meta")
        let micromamba = root.appendingPathComponent("bundled-micromamba")
        try Self.micromambaScript.write(to: micromamba, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: micromamba.path)
        condaManager = CondaManager(
            rootPrefix: root.appendingPathComponent("conda", isDirectory: true),
            bundledMicromambaProvider: { micromamba },
            bundledMicromambaVersionProvider: { "2.0.0" }
        )
        runner = NativeToolRunner(toolsDirectory: nil, homeDirectory: root.appendingPathComponent("home", isDirectory: true))
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// A fake micromamba that answers the probes the way the real tools do. A tool that prints the
    /// wrong thing for `--version` is exactly why bwa-mem2 needs conda-meta.
    private static let micromambaScript = """
    #!/bin/sh
    if [ "$1" = "--version" ]; then
      echo "micromamba 2.0.0"
      exit 0
    fi
    if [ "$1" != "run" ]; then
      echo "unexpected micromamba invocation: $*" >&2
      exit 64
    fi
    shift
    if [ "$1" = "-n" ]; then
      shift
      shift
    fi
    tool="$1"
    shift
    case "$tool" in
      bwa-mem2)
        if [ "$1" = "version" ]; then
          echo "2.2.1"
          exit 0
        fi
        echo "ERROR: unknown command '$1'" >&2
        exit 1
        ;;
      minimap2)
        echo "2.31-r1302"
        ;;
      bowtie2)
        echo "/Users/test/.lungfish/conda/envs/bowtie2/bin/bowtie2-align-s version 2.5.5"
        echo "64-bit"
        ;;
      *)
        echo "unexpected tool: $tool" >&2
        exit 64
        ;;
    esac
    """

    private func installPackage(_ name: String, version: String, build: String, inEnvironment environment: String) throws {
        let meta = root.appendingPathComponent("conda/envs/\(environment)/conda-meta", isDirectory: true)
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        try #"{"name":"\#(name)","version":"\#(version)","build":"\#(build)"}"#
            .write(to: meta.appendingPathComponent("\(name)-\(version)-\(build).json"), atomically: true, encoding: .utf8)
    }

    /// bwa-mem2 records the installed package version, never the error line its probe prints.
    func testBwaMem2VersionComesFromCondaMeta() async throws {
        try installPackage("bwa-mem2", version: "2.3", build: "hda5e58c_0", inEnvironment: "bwa-mem2")
        let version = try await MappingToolVersionProbe.version(
            of: .bwaMem2, executable: "bwa-mem2", condaManager: condaManager, nativeToolRunner: runner
        )
        XCTAssertEqual(version, "2.3")
    }

    /// Without a conda-meta record the probe is all that is left, and it prints only an error line,
    /// so the record holds `unknown` and never the error text (2.6).
    func testBwaMem2WithoutACondaMetaRecordRecordsUnknown() async throws {
        let version = try await MappingToolVersionProbe.version(
            of: .bwaMem2, executable: "bwa-mem2", condaManager: condaManager, nativeToolRunner: runner
        )
        XCTAssertEqual(version, "unknown")
    }

    /// minimap2 and Bowtie2 stay `.selfReported`, so conda-meta never replaces their own answer.
    func testSelfReportingMappersStillAskTheTool() async throws {
        try installPackage("minimap2", version: "9.9", build: "h0_0", inEnvironment: "minimap2")
        try installPackage("bowtie2", version: "9.9", build: "h0_0", inEnvironment: "bowtie2")
        let minimap2 = try await MappingToolVersionProbe.version(
            of: .minimap2, executable: "minimap2", condaManager: condaManager, nativeToolRunner: runner
        )
        let bowtie2 = try await MappingToolVersionProbe.version(
            of: .bowtie2, executable: "bowtie2", condaManager: condaManager, nativeToolRunner: runner
        )
        XCTAssertEqual(minimap2, "2.31")
        XCTAssertEqual(bowtie2, "2.5.5")
    }

    /// The package comes from the probe table's dialect, so only a `.condaMetaOnly` mapper has one.
    func testOnlyACondaMetaOnlyMapperNamesAPackage() {
        XCTAssertEqual(MappingToolVersionProbe.condaPackage(for: .bwaMem2), "bwa-mem2")
        XCTAssertNil(MappingToolVersionProbe.condaPackage(for: .minimap2))
        XCTAssertNil(MappingToolVersionProbe.condaPackage(for: .bowtie2))
        XCTAssertNil(MappingToolVersionProbe.condaPackage(for: .bbmap))
    }
}
