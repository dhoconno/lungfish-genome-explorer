// ToolProcessChildLauncherTests.swift - the Mac's portable launcher starts its child through ToolProcess
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
@testable import LungfishCore
import XCTest

/// `ToolProcessChildLauncher` is the Mac adapter of ``PortableChildLauncher``. These tests start real children and read
/// their stdout, their exit status and whether the launcher counts the run a success.
final class ToolProcessChildLauncherTests: XCTestCase {

    func testChildStdoutArrivesWholeAndExitZeroIsSuccess() async throws {
        let (output, exit) = try await Task.detached {
            let child = try ToolProcessChildLauncher().start(PortableChildRequest(
                executableURL: URL(fileURLWithPath: "/bin/echo"),
                arguments: ["portable", "launcher"],
                environment: ["PATH": "/usr/bin:/bin"],
                label: "echo"
            ))
            let output = child.readStdout(filling: 1024)
            return (output, try child.waitForExit())
        }.value

        XCTAssertEqual(String(decoding: output, as: UTF8.self), "portable launcher\n")
        XCTAssertEqual(exit, PortableChildExit(status: 0, isSuccess: true))
    }

    func testNonZeroExitReportsItsStatusAndNoSuccess() async throws {
        let exit = try await Task.detached {
            let child = try ToolProcessChildLauncher().start(PortableChildRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "exit 3"],
                environment: ["PATH": "/usr/bin:/bin"],
                label: "sh exit 3"
            ))
            _ = child.readStdout(filling: 16)
            return try child.waitForExit()
        }.value

        XCTAssertEqual(exit, PortableChildExit(status: 3, isSuccess: false))
    }

    func testReadStdoutFillsTheRequestedCountAcrossPieces() async throws {
        let pieces = try await Task.detached {
            let child = try ToolProcessChildLauncher().start(PortableChildRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf abc; sleep 0.2; printf def"],
                environment: ["PATH": "/usr/bin:/bin"],
                label: "sh printf"
            ))
            let first = child.readStdout(filling: 5)
            let rest = child.readStdout(filling: 5)
            let end = child.readStdout(filling: 5)
            _ = try child.waitForExit()
            return [first, rest, end].map { String(decoding: $0, as: UTF8.self) }
        }.value

        XCTAssertEqual(pieces, ["abcde", "f", ""])
    }
}
