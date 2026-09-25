// DemoProjectArchiveLoader.swift - Downloads demo project archives with progress
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os

/// Fetches a demo project archive to a local file.
///
/// Injected into ``DemoProjectInstaller`` so tests can serve a fixture
/// without the network.
public protocol DemoProjectArchiveLoading: Sendable {
    /// Downloads `url` to `destination`, reporting `(bytesWritten, expectedTotal)`.
    func download(
        from url: URL,
        to destination: URL,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws
}

/// URLSession-backed loader.
///
/// Uses `downloadTask(with:)` with a delegate because the async
/// `download(for:)` API does not reliably forward progress callbacks, and
/// copies the file inside `didFinishDownloadingTo` because URLSession deletes
/// it as soon as that callback returns.
public struct URLSessionDemoProjectArchiveLoader: DemoProjectArchiveLoading {
    public init() {}

    public func download(
        from url: URL,
        to destination: URL,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws {
        let delegate = DemoProjectDownloadDelegate(destination: destination, progress: progress)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.setContinuation(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Maps transport errors to user-facing demo project errors.
    static func mapTransportError(_ error: Error) -> DemoProjectError {
        guard let urlError = error as? URLError else {
            return .network(error.localizedDescription)
        }
        switch urlError.code {
        case .cancelled:
            return .cancelled
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
             .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
            return .offline
        default:
            return .network(urlError.localizedDescription)
        }
    }
}

private final class DemoProjectDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Int64, Int64?) -> Void
    private let state = OSAllocatedUnfairLock<(continuation: CheckedContinuation<Void, Error>?, pending: Result<Void, Error>?)>(
        initialState: (nil, nil)
    )

    init(destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func setContinuation(_ continuation: CheckedContinuation<Void, Error>) {
        let pending: Result<Void, Error>? = state.withLock { state in
            if let pending = state.pending {
                state.pending = nil
                return pending
            }
            state.continuation = continuation
            return nil
        }
        if let pending { continuation.resume(with: pending) }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        progress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let url = downloadTask.originalRequest?.url ?? destination
        if let response = downloadTask.response as? HTTPURLResponse, response.statusCode != 200 {
            finish(.failure(response.statusCode == 404
                ? DemoProjectError.notFound(url)
                : DemoProjectError.httpStatus(response.statusCode, url)))
            return
        }
        do {
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: location, to: destination)
            finish(.success(()))
        } catch {
            finish(.failure(DemoProjectError.network("the downloaded file could not be saved (\(error.localizedDescription))")))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            finish(.failure(URLSessionDemoProjectArchiveLoader.mapTransportError(error)))
        } else if let response = task.response as? HTTPURLResponse, response.statusCode != 200 {
            let url = task.originalRequest?.url ?? destination
            finish(.failure(response.statusCode == 404
                ? DemoProjectError.notFound(url)
                : DemoProjectError.httpStatus(response.statusCode, url)))
        } else {
            // Success is reported by didFinishDownloadingTo; this is a no-op when it already fired.
            finish(.failure(DemoProjectError.network("the server closed the connection without sending the file")))
        }
    }

    private let finished = OSAllocatedUnfairLock(initialState: false)

    private func finish(_ result: Result<Void, Error>) {
        let first = finished.withLock { done -> Bool in
            if done { return false }
            done = true
            return true
        }
        guard first else { return }
        let continuation: CheckedContinuation<Void, Error>? = state.withLock { state in
            if let continuation = state.continuation {
                state.continuation = nil
                return continuation
            }
            state.pending = result
            return nil
        }
        continuation?.resume(with: result)
    }
}
