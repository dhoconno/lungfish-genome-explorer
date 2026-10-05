// SRAWindowStreamingDownloadTests.swift - The window's mirror download ends on a cancel, never hangs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishTestSupport
@testable import LungfishApp

/// Review finding S4-S4: a mirror download started from an already cancelled
/// task could hang, because the cancel ended the transfer before the wait's
/// continuation was handed to the delegate, so nothing ever resumed it.
final class SRAWindowStreamingDownloadTests: XCTestCase {

    func testAnAlreadyCancelledTaskEndsWithACancellationAndNeverHangs() async throws {
        let outcome = Outcome()
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                // Port 9 (discard) on the loopback address: nothing is
                // reached, and the test never needs the network.
                _ = try await streamingDownload(
                    url: URL(string: "http://127.0.0.1:9/never.fastq.gz")!,
                    totalBytes: nil,
                    progressHandler: { _, _ in }
                )
                outcome.set("returned data")
            } catch is CancellationError {
                outcome.set("cancelled")
            } catch {
                outcome.set("other error: \(error)")
            }
        }
        let ended = await waitUntil(timeout: .seconds(10)) { outcome.value != nil }
        XCTAssertTrue(ended, "the download ends promptly when its task is already cancelled")
        XCTAssertEqual(outcome.value, "cancelled")
        if !ended { task.cancel() }
    }

    func testAnEndBeforeTheWaitResumesTheWait() async throws {
        let completion = SRAWindowTransferCompletion()
        XCTAssertTrue(completion.finish(.failure(URLError(.cancelled))))
        XCTAssertFalse(completion.finish(.success(URL(fileURLWithPath: "/late"))), "only the first end counts")

        let outcome = Outcome()
        Task.detached {
            do {
                _ = try await withCheckedThrowingContinuation { completion.wait($0) }
                outcome.set("returned")
            } catch let error as URLError where error.code == .cancelled {
                outcome.set("cancelled")
            } catch {
                outcome.set("other error: \(error)")
            }
        }
        await waitUntil(timeout: .seconds(10)) { outcome.value != nil }
        XCTAssertEqual(outcome.value, "cancelled", "an end that came first still resumes the wait")
    }

    func testAnEndAfterTheWaitResumesTheWait() async throws {
        let completion = SRAWindowTransferCompletion()
        let outcome = Outcome()
        let waiting = Outcome()
        Task.detached {
            do {
                let url = try await withCheckedThrowingContinuation { continuation in
                    completion.wait(continuation)
                    waiting.set("waiting")
                }
                outcome.set(url.path)
            } catch {
                outcome.set("error: \(error)")
            }
        }
        await waitUntil(timeout: .seconds(10)) { waiting.value != nil }
        completion.finish(.success(URL(fileURLWithPath: "/tmp/mate.fastq.gz")))
        await waitUntil(timeout: .seconds(10)) { outcome.value != nil }
        XCTAssertEqual(outcome.value, "/tmp/mate.fastq.gz")
    }
}

private final class Outcome: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    var value: String? { lock.withLock { stored } }
    func set(_ value: String) { lock.withLock { if stored == nil { stored = value } } }
}
