// PortableWriterProbeTests.swift - The BBTools writer probe names the first bgzip answering on the step's PATH
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import Synchronization
import LungfishPortable

/// A launcher that records each launch and answers `bgzip -h` with the exit status the test names.
private final class AnsweringLauncher: PortableToolLauncher {
    typealias Record = PortableToolRun

    let launches = Mutex<[PortableToolLaunch]>([])
    let answers: Bool

    init(answers: Bool) {
        self.answers = answers
    }

    func executableURL(for tool: PortableStorageTool) async throws -> URL {
        URL(fileURLWithPath: "/image/bin/\(tool.rawValue)")
    }

    func run(_ launch: PortableToolLaunch) async throws -> PortableToolOutcome {
        launches.withLock { $0.append(launch) }
        let now = Date()
        return PortableToolOutcome(
            exitCode: answers ? 0 : 1, isSuccess: answers, stdout: answers ? "Usage:   bgzip [OPTIONS] [FILE]" : "",
            stderr: "", startTime: now, endTime: now
        )
    }

    func record(_ run: PortableToolRun) async -> PortableToolRun { run }
}

/// The probe reads no gzip, so a test that starts a child fails.
private struct NoChildLauncher: PortableChildLauncher {
    struct Refused: Error {}
    func start(_ request: PortableChildRequest) throws -> any PortableChild { throw Refused() }
}

final class PortableWriterProbeTests: XCTestCase {

    /// A `PATH` of a folder with no bgzip, a folder that holds a folder named bgzip, a folder with an executable
    /// bgzip and a second folder with another, in that order.
    private func makePath() throws -> (path: String, empty: String, first: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriterProbe-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let empty = root.appendingPathComponent("empty", isDirectory: true)
        let folderNamedBgzip = root.appendingPathComponent("dir", isDirectory: true)
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        try fm.createDirectory(
            at: folderNamedBgzip.appendingPathComponent("bgzip", isDirectory: true), withIntermediateDirectories: true
        )
        for folder in [first, second] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let shim = folder.appendingPathComponent("bgzip")
            try "#!/bin/sh\necho 'Usage:   bgzip [OPTIONS] [FILE]'\n".write(to: shim, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
        }
        let path = [empty, folderNamedBgzip, first, second].map(\.path).joined(separator: ":")
        return (path, empty.path, first.appendingPathComponent("bgzip"))
    }

    func testBBToolsWriterIsFirstBgzipAnsweringOnStepPath() async throws {
        let (path, empty, firstBgzip) = try makePath()
        let environment = ["PATH": path, "_JAVA_OPTIONS": "-Xmx2g"]
        for level in [1, 4, 9] {
            let launcher = AnsweringLauncher(answers: true)
            let step = PortableStorageStep(launcher: launcher, childLauncher: NoChildLauncher())
            let probe = try await step.probeBBToolsWriter(environment: environment, compressionLevel: level, threads: 3)
            XCTAssertEqual(probe, PortableBBToolsWriterProbe(
                writer: .bgzip(executable: firstBgzip, arguments: ["-c", "-f", "-l", String(level), "-@", "3"]),
                effectiveCompressionLevel: level
            ), "zl=\(level) with a bgzip on the step's PATH")
            XCTAssertEqual(probe.writer.name, "bgzip")
            let launches = launcher.launches.withLock { $0 }
            XCTAssertEqual(launches.map(\.arguments), [["-h"]], "the probe runs bgzip -h once")
            XCTAssertEqual(launches.first?.executable, firstBgzip, "the probe starts the first bgzip on the PATH")
            XCTAssertEqual(launches.first?.environment, environment, "the probe reads the step's own environment")

            let none = AnsweringLauncher(answers: true)
            let noBgzip = try await PortableStorageStep(launcher: none, childLauncher: NoChildLauncher())
                .probeBBToolsWriter(environment: ["PATH": empty], compressionLevel: level, threads: 3)
            XCTAssertEqual(noBgzip, PortableBBToolsWriterProbe(writer: .nativeBGZF, effectiveCompressionLevel: level))
            XCTAssertEqual(noBgzip.writer.name, "BBTools native BGZF")
            XCTAssertTrue(none.launches.withLock { $0 }.isEmpty, "with no bgzip on the PATH the probe starts nothing")

            let silent = AnsweringLauncher(answers: false)
            let unanswered = try await PortableStorageStep(launcher: silent, childLauncher: NoChildLauncher())
                .probeBBToolsWriter(environment: environment, compressionLevel: level, threads: 3)
            XCTAssertEqual(
                unanswered, PortableBBToolsWriterProbe(writer: .nativeBGZF, effectiveCompressionLevel: level),
                "a bgzip that does not answer leaves BBTools' own writer"
            )
        }
    }
}
