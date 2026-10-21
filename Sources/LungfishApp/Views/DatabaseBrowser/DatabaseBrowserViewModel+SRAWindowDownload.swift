// DatabaseBrowserViewModel+SRAWindowDownload.swift - The transfer helpers and record of the window's SRA staging
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow
import os

final class SRAGUIDownloadTraceCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var traces: [SRAService.FASTQDownloadStepTrace] = []

    func record(_ trace: SRAService.FASTQDownloadStepTrace) {
        lock.lock()
        traces.append(trace)
        lock.unlock()
    }

    var steps: [SRAService.FASTQDownloadStepTrace] {
        lock.lock()
        defer { lock.unlock() }
        return traces
    }
}

// MARK: - Streaming Download Helper

/// Downloads a file using URLSession downloadTask with byte-level progress callbacks.
///
/// Unlike `URLSession.shared.data(for:)`, this uses the delegate-based `downloadTask`
/// API which reliably fires `didWriteData` progress callbacks. The file is written to
/// a temp location and its contents returned as Data.
///
/// - Parameters:
///   - url: The URL to download.
///   - totalBytes: Expected total size (used when Content-Length header is absent).
///   - progressHandler: Called with (bytesDownloaded, totalBytes?) during download.
/// - Returns: The downloaded data.
/// - Throws: `DatabaseServiceError` on network or HTTP errors, or a
///   `CancellationError` when the task is cancelled, even before it starts.
func streamingDownload(
    url: URL,
    totalBytes: Int64?,
    progressHandler: @escaping @Sendable (Int64, Int64?) -> Void
) async throws -> Data {
    final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let knownTotal: Int64?
        let progress: @Sendable (Int64, Int64?) -> Void
        let completion = SRAWindowTransferCompletion()

        init(knownTotal: Int64?, progress: @escaping @Sendable (Int64, Int64?) -> Void) {
            self.knownTotal = knownTotal
            self.progress = progress
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData _: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite expected: Int64) {
            let total: Int64? = expected > 0 ? expected : knownTotal
            progress(totalBytesWritten, total)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "-" + location.lastPathComponent)
            do {
                try FileManager.default.copyItem(at: location, to: tmp)
            } catch {
                completion.finish(.failure(error))
                return
            }
            guard let resp = downloadTask.response as? HTTPURLResponse,
                  (200...299).contains(resp.statusCode) else {
                try? FileManager.default.removeItem(at: tmp)
                let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? -1
                completion.finish(.failure(DatabaseServiceError.serverError(
                    message: "HTTP \(code) downloading \(downloadTask.originalRequest?.url?.lastPathComponent ?? "file")"
                )))
                return
            }
            if !completion.finish(.success(tmp)) {
                try? FileManager.default.removeItem(at: tmp)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didCompleteWithError error: (any Error)?) {
            if let error {
                completion.finish(.failure(error))
            }
        }
    }

    // An already cancelled task never creates the transfer.
    try Task.checkCancellation()

    var request = URLRequest(url: url)
    request.setValue("Lungfish Genome Explorer", forHTTPHeaderField: "User-Agent")
    request.timeoutInterval = 600

    let delegate = Delegate(knownTotal: totalBytes, progress: progressHandler)
    let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

    // A cancel can end the transfer before the continuation is handed over.
    // The completion keeps that early end and resumes the wait with it.
    let transfer = session.downloadTask(with: request)
    let tempURL: URL
    do {
        tempURL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.completion.wait(continuation)
                transfer.resume()
            }
        } onCancel: {
            transfer.cancel()
        }
    } catch {
        session.invalidateAndCancel()
        if Task.isCancelled {
            throw CancellationError()
        }
        throw error
    }
    session.invalidateAndCancel()

    let data = try Data(contentsOf: tempURL)
    try? FileManager.default.removeItem(at: tempURL)
    return data
}

/// Hands a URLSession transfer's end to the wait for it, in either order.
///
/// The transfer can end, for example when a cancel stops it, before the
/// wait's continuation is handed over. The end is then kept and resumes the
/// wait at once, so the wait never hangs. Only the first end counts.
final class SRAWindowTransferCompletion: Sendable {
    private struct State {
        var continuation: CheckedContinuation<URL, Error>?
        var result: Result<URL, Error>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Resumes `continuation` with the transfer's end, now if it has ended.
    func wait(_ continuation: CheckedContinuation<URL, Error>) {
        let ended: Result<URL, Error>? = state.withLock { state in
            if let result = state.result { return result }
            state.continuation = continuation
            return nil
        }
        if let ended {
            continuation.resume(with: ended)
        }
    }

    /// Records the transfer's end and resumes the wait if it is waiting.
    ///
    /// - Returns: Whether this was the first end. A later end is ignored.
    @discardableResult
    func finish(_ result: Result<URL, Error>) -> Bool {
        let (first, waiting) = state.withLock { state -> (Bool, CheckedContinuation<URL, Error>?) in
            guard state.result == nil else { return (false, nil) }
            state.result = result
            defer { state.continuation = nil }
            return (true, state.continuation)
        }
        waiting?.resume(with: result)
        return first
    }
}
