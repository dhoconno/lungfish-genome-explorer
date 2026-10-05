// RepositorySourceReadingTests.swift - the EINTR retry behind readRepositorySource
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Darwin
import LungfishTestSupport

/// The parallel unit gate failed source-scanning tests when a file read threw
/// NSCocoaErrorDomain 256 wrapping NSPOSIXErrorDomain 4 (EINTR). The shared
/// read helper retries that error and throws every other one.
final class RepositorySourceReadingTests: XCTestCase {

    private let wrappedEINTR = NSError(
        domain: NSCocoaErrorDomain,
        code: CocoaError.fileReadUnknown.rawValue,
        userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EINTR))]
    )

    func testTheGateFailureShapeCountsAsAnInterruptedCall() {
        XCTAssertTrue(isInterruptedSystemCall(wrappedEINTR))
        XCTAssertTrue(isInterruptedSystemCall(POSIXError(.EINTR)))
        XCTAssertFalse(isInterruptedSystemCall(CocoaError(.fileReadNoSuchFile)))
        XCTAssertFalse(isInterruptedSystemCall(POSIXError(.ENOENT)))
    }

    func testAnInterruptedReadIsTriedAgain() throws {
        var calls = 0
        let value = try retryingInterruptedSystemCalls { () throws -> String in
            calls += 1
            if calls < 3 { throw wrappedEINTR }
            return "read"
        }
        XCTAssertEqual(value, "read")
        XCTAssertEqual(calls, 3)
    }

    func testOtherErrorsAndAPersistentEINTRAreThrown() {
        var calls = 0
        XCTAssertThrowsError(try retryingInterruptedSystemCalls { () throws -> Int in
            calls += 1
            throw CocoaError(.fileReadNoSuchFile)
        })
        XCTAssertEqual(calls, 1, "a missing file is not retried")

        calls = 0
        XCTAssertThrowsError(try retryingInterruptedSystemCalls(attempts: 4) { () throws -> Int in
            calls += 1
            throw wrappedEINTR
        }) { error in
            XCTAssertTrue(isInterruptedSystemCall(error))
        }
        XCTAssertEqual(calls, 4)
    }

    func testReadsAndListsRepositorySources() throws {
        let root = CLITestBinaryResolver.repositoryRoot(containing: #filePath)
        let supportDirectory = root.appendingPathComponent("Tests/Support/LungfishTestSupport", isDirectory: true)
        let files = try repositoryFiles(under: supportDirectory)
        let helper = supportDirectory.appendingPathComponent("RepositorySourceReading.swift")
        XCTAssertTrue(files.map(\.standardizedFileURL).contains(helper.standardizedFileURL))
        XCTAssertEqual(files, files.sorted { $0.path < $1.path })
        XCTAssertTrue(try readRepositorySource(helper).hasPrefix("// RepositorySourceReading.swift"))
        XCTAssertThrowsError(try repositoryFiles(under: root.appendingPathComponent("no-such-directory")))
    }
}
