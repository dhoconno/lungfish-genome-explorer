// ToolProcessTestSupport.swift - Shared helpers for the ToolProcess tests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import XCTest
@testable import LungfishCore
import LungfishTestSupport

/// Collects ToolProcess events from the run's queue for later assertions.
final class ToolProcessEventLog: Sendable {
    private let events = Mutex<[(stage: Int, event: ToolProcessEvent)]>([])

    func append(stage: Int = 0, _ event: ToolProcessEvent) {
        events.withLock { $0.append((stage, event)) }
    }

    var all: [(stage: Int, event: ToolProcessEvent)] {
        events.withLock { $0 }
    }

    func lines(_ stream: ToolProcessStream, stage: Int? = nil) -> [String] {
        all.compactMap { entry in
            guard stage == nil || entry.stage == stage else { return nil }
            if case .output(let eventStream, let line) = entry.event, eventStream == stream {
                return line
            }
            return nil
        }
    }
}

enum ToolProcessFixtures {
    static let systemPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// A `/bin/sh -c` spec with a minimal hermetic environment.
    static func shell(
        _ script: String,
        stdin: ToolProcessInput = .null,
        stdout: ToolProcessOutput = .capture(),
        stderr: ToolProcessOutput = .capture(),
        timeout: Duration? = nil,
        idleTimeout: Duration? = nil,
        drainGracePeriod: Duration = .seconds(2),
        label: String = "sh"
    ) -> ToolProcessSpec {
        ToolProcessSpec(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            environment: ["PATH": systemPath],
            stdin: stdin,
            stdout: stdout,
            stderr: stderr,
            timeout: timeout,
            idleTimeout: idleTimeout,
            terminationGracePeriod: .milliseconds(200),
            drainGracePeriod: drainGracePeriod,
            label: label
        )
    }

    static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    static func readPID(_ url: URL) -> Int32? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func waitForPID(_ url: URL, timeout: Duration = .seconds(10)) async -> Int32? {
        var pid: Int32?
        _ = await waitUntil(timeout: timeout, pollInterval: .milliseconds(20)) {
            pid = readPID(url)
            return pid != nil
        }
        return pid
    }

    static func waitForExit(_ pid: Int32, timeout: Duration = .seconds(5)) async -> Bool {
        await waitUntil(timeout: timeout, pollInterval: .milliseconds(25)) {
            !ProcessTreeTerminator.processExists(pid: pid)
        }
    }

    static func killIfAlive(_ pid: Int32?) {
        guard let pid, ProcessTreeTerminator.processExists(pid: pid) else { return }
        kill(pid, SIGKILL)
    }
}

extension XCTestCase {
    func makeToolProcessTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToolProcessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
