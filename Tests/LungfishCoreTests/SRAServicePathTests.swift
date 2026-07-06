// SRAServicePathTests.swift - Managed SRA toolkit path coverage
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Darwin
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

    func testDownloadFASTQDrainsLargeToolStderr() async throws {
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
            i=0
            while [ "$i" -lt 8192 ]; do
              printf 'stderr-fill-line-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\\n' >&2
              i=$((i + 1))
            done
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
            touch "$3/${accession}.fastq"
            exit 0
            """
        )

        let service = SRAService(homeDirectoryProvider: { home })
        let files = try await service.downloadFASTQ(
            accession: "SRR000002",
            outputDir: outputDir
        )

        XCTAssertEqual(files.map(\.lastPathComponent), ["SRR000002.fastq"])
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

    func testDownloadFASTQCancellationTerminatesPrefetchProcess() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sra-home-\(UUID().uuidString)",
            isDirectory: true
        )
        let binDir = home.appendingPathComponent(".lungfish/conda/envs/sra-tools/bin", isDirectory: true)
        let outputDir = home.appendingPathComponent("downloads", isDirectory: true)
        let prefetchPIDFile = home.appendingPathComponent("prefetch.pid")
        let prefetchChildPIDFile = home.appendingPathComponent("prefetch-child.pid")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: home)
        }

        try makeExecutableScript(
            at: binDir.appendingPathComponent("prefetch"),
            body: """
            #!/bin/sh
            echo $$ > '\(prefetchPIDFile.path)'
            nohup /bin/sh -c 'trap "" TERM HUP INT; while :; do sleep 1; done' >/dev/null 2>&1 &
            echo "$!" > '\(prefetchChildPIDFile.path)'
            while kill -0 "$!" 2>/dev/null; do sleep 1; done
            """
        )
        try makeExecutableScript(
            at: binDir.appendingPathComponent("fasterq-dump"),
            body: "#!/bin/sh\nexit 0\n"
        )

        let service = SRAService(homeDirectoryProvider: { home })
        let task = Task {
            try await service.downloadFASTQ(
                accession: "SRR000003",
                outputDir: outputDir
            )
        }

        let prefetchPID = try await waitForPIDFile(prefetchPIDFile)
        let prefetchChildPID = try await waitForPIDFile(prefetchChildPIDFile)
        addTeardownBlock {
            if processExists(pid: prefetchPID) {
                kill(prefetchPID, SIGKILL)
            }
            if processExists(pid: prefetchChildPID) {
                kill(prefetchChildPID, SIGKILL)
            }
        }
        XCTAssertTrue(processExists(pid: prefetchPID))
        XCTAssertTrue(processExists(pid: prefetchChildPID))

        task.cancel()

        let exited = await waitUntilProcessExits(pid: prefetchPID, timeout: 2.0)
        let childExited = await waitUntilProcessExits(pid: prefetchChildPID, timeout: 2.0)
        if !exited {
            kill(prefetchPID, SIGKILL)
        }
        if !childExited {
            kill(prefetchChildPID, SIGKILL)
        }
        XCTAssertTrue(exited, "Cancelling SRA download must terminate the active prefetch process")
        XCTAssertTrue(childExited, "Cancelling SRA download must terminate prefetch child processes")

        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private func makeExecutableScript(at url: URL, body: String) throws {
    try body.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

private func waitForPIDFile(_ url: URL, timeout: TimeInterval = 5.0) async throws -> Int32 {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let contents = try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let pid = Int32(contents) {
            return pid
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    throw NSError(
        domain: "SRAServicePathTests",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for process PID"]
    )
}

private func waitUntilProcessExits(pid: Int32, timeout: TimeInterval) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if !processExists(pid: pid) {
            return true
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return !processExists(pid: pid)
}

private func processExists(pid: Int32) -> Bool {
    guard pid > 0 else { return false }
    if kill(pid, 0) == 0 {
        return true
    }
    return errno != ESRCH
}
