// NaoMgsSamplePartitionerTests.swift - Managed pigz path coverage
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import LungfishWorkflow

struct NaoMgsSamplePartitionerTests {
    @Test
    func managedDecompressorURLUsesPigzEnvironmentLayout() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pigz-home-\(UUID().uuidString)",
            isDirectory: true
        )
        let binDir = home.appendingPathComponent(".lungfish/conda/envs/pigz/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let pigzURL = binDir.appendingPathComponent("pigz")
        try "#!/bin/sh\nexit 0\n".write(to: pigzURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pigzURL.path)

        let resolved = NaoMgsSamplePartitioner.managedDecompressorURL(homeDirectory: home)

        #expect(resolved?.path == pigzURL.path)
    }

    @Test
    func managedDecompressorURLDoesNotFallBackToSystemGzipWhenPigzMissing() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pigz-missing-home-\(UUID().uuidString)",
            isDirectory: true
        )

        let resolved = NaoMgsSamplePartitioner.managedDecompressorURL(homeDirectory: home)

        #expect(resolved == nil)
    }
}
