// SRAServicePathTests.swift - Managed SRA toolkit path coverage
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCore

final class SRAServicePathTests: XCTestCase {

    func testManagedToolkitExecutableURLUsesLungfishCondaLayout() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sra-home-\(UUID().uuidString)",
            isDirectory: true
        )

        let url = SRAService.managedExecutableURL(
            executableName: "prefetch",
            homeDirectory: home
        )

        XCTAssertEqual(
            url.path,
            home.appendingPathComponent(".lungfish/conda/envs/sra-tools/bin/prefetch").path
        )
    }

    func testManagedToolkitExecutableURLUsesConfiguredManagedStorageRoot() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sra-home-\(UUID().uuidString)",
            isDirectory: true
        )
        let configuredRoot = home.appendingPathComponent("shared-storage", isDirectory: true)
        let store = ManagedStorageConfigStore(homeDirectory: home)
        try store.setActiveRoot(configuredRoot)

        let url = SRAService.managedExecutableURL(
            executableName: "prefetch",
            homeDirectory: home
        )

        XCTAssertEqual(
            url.standardizedFileURL.path,
            configuredRoot
                .appendingPathComponent("conda/envs/sra-tools/bin/prefetch")
                .standardizedFileURL.path
        )
    }

    func testToolkitAvailabilityUsesManagedLayout() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sra-home-\(UUID().uuidString)",
            isDirectory: true
        )
        let binDir = home.appendingPathComponent(".lungfish/conda/envs/sra-tools/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try makeExecutableScript(
            at: binDir.appendingPathComponent("prefetch"),
            body: "#!/bin/sh\nexit 0\n"
        )
        try makeExecutableScript(
            at: binDir.appendingPathComponent("fasterq-dump"),
            body: "#!/bin/sh\nexit 0\n"
        )

        let service = SRAService(homeDirectoryProvider: { home })
        let available = await service.isSRAToolkitAvailable

        XCTAssertTrue(available)
    }

    func testToolkitAvailabilityUsesConfiguredManagedStorageRoot() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sra-home-\(UUID().uuidString)",
            isDirectory: true
        )
        let configuredRoot = home.appendingPathComponent("shared-storage", isDirectory: true)
        let store = ManagedStorageConfigStore(homeDirectory: home)
        try store.setActiveRoot(configuredRoot)

        let binDir = configuredRoot.appendingPathComponent("conda/envs/sra-tools/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try makeExecutableScript(
            at: binDir.appendingPathComponent("prefetch"),
            body: "#!/bin/sh\nexit 0\n"
        )
        try makeExecutableScript(
            at: binDir.appendingPathComponent("fasterq-dump"),
            body: "#!/bin/sh\nexit 0\n"
        )

        let service = SRAService(homeDirectoryProvider: { home })
        let available = await service.isSRAToolkitAvailable

        XCTAssertTrue(available)
    }

    func testDownloadFASTQReturnsOnlyFASTQFiles() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sra-home-\(UUID().uuidString)",
            isDirectory: true
        )
        let binDir = home.appendingPathComponent(".lungfish/conda/envs/sra-tools/bin", isDirectory: true)
        let outputDir = home.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        try makeExecutableScript(
            at: binDir.appendingPathComponent("prefetch"),
            body: """
            #!/bin/sh
            mkdir -p "$3/$1"
            touch "$3/$1/$1.sra"
            exit 0
            """
        )
        try makeExecutableScript(
            at: binDir.appendingPathComponent("fasterq-dump"),
            body: """
            #!/bin/sh
            accession="$(basename "$1" .sra)"
            touch "$3/${accession}_1.fastq"
            touch "$3/${accession}_2.fastq"
            exit 0
            """
        )

        let service = SRAService(homeDirectoryProvider: { home })
        let files = try await service.downloadFASTQ(
            accession: "SRR000001",
            outputDir: outputDir
        )

        XCTAssertEqual(
            files.map(\.lastPathComponent).sorted(),
            ["SRR000001_1.fastq", "SRR000001_2.fastq"]
        )
    }

    func testDownloadFASTQUsesProjectScopedTempDirectoryForFasterqDump() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sra-home-\(UUID().uuidString)",
            isDirectory: true
        )
        let binDir = home.appendingPathComponent(".lungfish/conda/envs/sra-tools/bin", isDirectory: true)
        let projectDir = home.appendingPathComponent("Project With Spaces.lungfish", isDirectory: true)
        let outputDir = projectDir.appendingPathComponent("Imports", isDirectory: true)
        let argsLog = home.appendingPathComponent("fasterq-args.txt")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        try makeExecutableScript(
            at: binDir.appendingPathComponent("prefetch"),
            body: """
            #!/bin/sh
            mkdir -p "$3/$1"
            touch "$3/$1/$1.sra"
            exit 0
            """
        )
        try makeExecutableScript(
            at: binDir.appendingPathComponent("fasterq-dump"),
            body: """
            #!/bin/sh
            printf '%s\n' "$@" > '\(argsLog.path)'
            accession="$(basename "$1" .sra)"
            outdir=""
            prev=""
            for arg in "$@"; do
                if [ "$prev" = "-O" ]; then
                    outdir="$arg"
                fi
                prev="$arg"
            done
            touch "$outdir/${accession}_1.fastq"
            touch "$outdir/${accession}_2.fastq"
            exit 0
            """
        )

        let service = SRAService(homeDirectoryProvider: { home })
        _ = try await service.downloadFASTQ(
            accession: "SRR38159018",
            outputDir: outputDir
        )

        let args = try String(contentsOf: argsLog, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        let tempIndex = try XCTUnwrap(args.firstIndex(of: "-t"))
        let tempDirectory = args[tempIndex + 1]

        XCTAssertTrue(
            tempDirectory.hasPrefix(projectDir.appendingPathComponent(".tmp", isDirectory: true).path),
            "Expected fasterq-dump temp dir to live under the project .tmp folder"
        )
    }
}

private func makeExecutableScript(at url: URL, body: String) throws {
    try body.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}
