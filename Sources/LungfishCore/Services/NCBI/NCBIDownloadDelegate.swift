// NCBIDownloadDelegate.swift - NCBI Entrez E-utilities integration
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: NCBI Integration Lead (Role 12)

import Foundation
import os

// MARK: - Download Progress Delegate

/// URLSession download delegate that bridges to async/await via a continuation.
///
/// Using `downloadTask(with:)` + continuation instead of the async `session.download(for:delegate:)`
/// API because the async API doesn't reliably forward `didWriteData` progress callbacks.
final class ContinuationDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let totalBytes: Int64?
    private let progressHandler: @Sendable (Int64, Int64?) -> Void
    private let continuationLock = OSAllocatedUnfairLock<CheckedContinuation<URL, Error>?>(initialState: nil)
    private let resumeLock = OSAllocatedUnfairLock(initialState: false)

    init(totalBytes: Int64?, progressHandler: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.totalBytes = totalBytes
        self.progressHandler = progressHandler
    }

    func setContinuation(_ continuation: CheckedContinuation<URL, Error>) {
        continuationLock.withLock { $0 = continuation }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let expectedTotal = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : totalBytes
        progressHandler(totalBytesWritten, expectedTotal)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Copy to a temp location that survives after the delegate callback returns,
        // since URLSession deletes the file at `location` after this method returns.
        let tempCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-" + location.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: location, to: tempCopy)
        } catch {
            resumeOnce(.failure(error))
            return
        }

        guard let response = downloadTask.response as? HTTPURLResponse,
              response.statusCode == 200 else {
            resumeOnce(.failure(DatabaseServiceError.networkError(
                underlying: "Bad server response: \((downloadTask.response as? HTTPURLResponse)?.statusCode ?? -1)"
            )))
            return
        }

        resumeOnce(.success(tempCopy))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        if let error {
            if (error as? URLError)?.code == .cancelled {
                resumeOnce(.failure(DatabaseServiceError.cancelled))
            } else {
                resumeOnce(.failure(error))
            }
        }
    }

    private func resumeOnce(_ result: Result<URL, Error>) {
        let shouldResume = resumeLock.withLock { resumed in
            if resumed { return false }
            resumed = true
            return true
        }
        guard shouldResume else { return }
        guard let continuation = continuationLock.withLock({ continuation -> CheckedContinuation<URL, Error>? in
            defer { continuation = nil }
            return continuation
        }) else { return }

        switch result {
        case .success(let url):
            continuation.resume(returning: url)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
