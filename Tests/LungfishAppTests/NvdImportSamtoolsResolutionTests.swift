// NvdImportSamtoolsResolutionTests.swift - The CLI NVD import resolves the samtools the app passes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The Import Center's NVD import passes BundleBuildHelpers'
// managed samtools to MetagenomicsImportService.importNvd. `lungfish-cli
// import nvd` and `nvd import` now pass
// MetagenomicsImportService.managedSamtoolsPath (R3). Both must name the same
// executable, or neither when it is not installed, for any home and app
// channel, so the two paths mark duplicates and count unique reads alike.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishWorkflow

final class NvdImportSamtoolsResolutionTests: XCTestCase {
    func testTheCLIResolvesTheSamtoolsTheAppHelperPasses() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("nvd-samtools-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        for identity in [LungfishAppIdentity.preview, .stable] {
            XCTAssertNil(BundleBuildHelpers.managedToolExecutablePath(.samtools, homeDirectory: home, appIdentity: identity))
            XCTAssertNil(MetagenomicsImportService.managedSamtoolsPath(homeDirectory: home, appIdentity: identity))
        }

        // The preview channel keeps its managed tools under ~/.lungfish.
        let binDirectory = home.appendingPathComponent(".lungfish/conda/envs/samtools/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let samtools = binDirectory.appendingPathComponent("samtools")
        try "#!/bin/sh\nexit 0\n".write(to: samtools, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: samtools.path)

        let app = BundleBuildHelpers.managedToolExecutablePath(.samtools, homeDirectory: home, appIdentity: .preview)
        XCTAssertEqual(app, samtools.path)
        XCTAssertEqual(MetagenomicsImportService.managedSamtoolsPath(homeDirectory: home, appIdentity: .preview), app)
        XCTAssertNil(MetagenomicsImportService.managedSamtoolsPath(homeDirectory: home, appIdentity: .stable))
    }
}
