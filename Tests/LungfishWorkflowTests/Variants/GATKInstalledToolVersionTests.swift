// GATKInstalledToolVersionTests.swift - The GATK a sidecar names is the four-part version gatk prints
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.6 decision V8. `gatk --version` prints `The Genome Analysis Toolkit (GATK) v4.6.2.0`, and
// the version pattern used to stop at three parts, so an executed GATK command recorded 4.6.2. The
// output below is the real one, captured by `micromamba run` from the managed install on 2026-10-11.

import Foundation
import LungfishTestSupport
import XCTest
@testable import LungfishWorkflow

final class GATKInstalledToolVersionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "gatk-installed-version")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// A fake micromamba whose `gatk --version` prints what the real tool prints, the banner on
    /// stdout and the jar and the java command on stderr.
    private func makeCondaManager(gatkAnswer: String) throws -> CondaManager {
        let micromamba = root.appendingPathComponent("bundled-micromamba")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo "micromamba 2.0.0"
          exit 0
        fi
        shift
        if [ "$1" = "-n" ]; then
          shift
          shift
        fi
        tool="$1"
        shift
        if [ "$tool" = "gatk" ] && [ "$1" = "--version" ]; then
        \(gatkAnswer)
          exit 0
        fi
        echo "unexpected invocation: $tool $*" >&2
        exit 64
        """
        try script.write(to: micromamba, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: micromamba.path)
        return CondaManager(
            rootPrefix: root.appendingPathComponent("conda", isDirectory: true),
            bundledMicromambaProvider: { micromamba },
            bundledMicromambaVersionProvider: { "2.0.0" }
        )
    }

    private static let realOutput = """
      echo "The Genome Analysis Toolkit (GATK) v4.6.2.0"
      echo "HTSJDK Version: 4.2.0"
      echo "Picard Version: 3.4.0"
      echo "Using GATK jar /Users/test/.lungfish/conda/envs/gatk-core/share/gatk4-4.6.2.0-1/gatk-package-4.6.2.0-local.jar" >&2
      echo "Running:" >&2
      echo "    java -Dsamjdk.compression_level=2 -jar /Users/test/.lungfish/conda/envs/gatk-core/share/gatk4-4.6.2.0-1/gatk-package-4.6.2.0-local.jar --version" >&2
    """

    /// The installed version keeps its fourth part.
    func testTheProbeRecordsAllFourParts() async throws {
        let condaManager = try makeCondaManager(gatkAnswer: Self.realOutput)
        let version = await GATKInstalledToolVersion.probe(condaManager: condaManager, timeout: 30)
        XCTAssertEqual(version, "4.6.2.0")
    }

    /// A GATK that answers with nothing gives nil, which the caller replaces with the lock pin.
    func testAnEmptyAnswerGivesNoVersion() async throws {
        let condaManager = try makeCondaManager(gatkAnswer: "  :")
        let version = await GATKInstalledToolVersion.probe(condaManager: condaManager, timeout: 30)
        XCTAssertNil(version)
    }
}
