// SRADownloadToolVersionTests.swift - The sra-tools version fetch sra download records
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishCore
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishCLI

/// Phase 2.6 lane P5a. `lungfish-cli fetch sra download` records the SRA Toolkit steps with the
/// `sra-tools` version the managed tool lock pins. Reading the lock by tool id instead of through
/// the tools list must not change what the record holds. ENA is a mock HTTP client and the
/// toolkit is a scripted runner, as in `SRADownloadSubcommandProvenanceTests`.
final class SRADownloadToolVersionTests: XCTestCase {

    func testToolkitStepsRecordTheSRAToolsVersionTheLockPins() async throws {
        let folder = try TestTempDirectory.make(prefix: "sra-cli-tool-version")
        defer { TestTempDirectory.cleanup(folder) }
        let lockVersion = try XCTUnwrap(ManagedToolLock.loadFromBundle().tool(named: "sra-tools")?.version)

        let run = try await SRADownloadSubcommandProvenanceTests.download(into: folder, portal: .outage)

        let toolkit = run.steps.filter { ["prefetch", "fasterq-dump"].contains($0.toolName) }
        XCTAssertEqual(toolkit.map(\.toolName), ["prefetch", "fasterq-dump"])
        XCTAssertEqual(toolkit.map(\.toolVersion), Array(repeating: "sra-tools \(lockVersion)", count: 2))
    }
}
