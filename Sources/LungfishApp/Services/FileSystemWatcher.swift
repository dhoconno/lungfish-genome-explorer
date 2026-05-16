// FileSystemWatcher.swift - FSEvents-based directory monitoring with sidecar filtering
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import CoreServices
import os.log
import LungfishCore

/// Logger for file system watcher operations
private let logger = Logger(subsystem: LogSubsystem.app, category: "FileSystemWatcher")

/// Watches a directory for filesystem changes using macOS FSEvents.
///
/// This class monitors a directory and its subdirectories for changes including
/// file creation, deletion, modification, and rename/move. Changes to internal
/// sidecar files (`.lungfish-meta.json`, search databases, bundle-internal JSON)
/// are filtered out to prevent feedback loops.
///
/// When non-sidecar changes are detected, the provided callback is invoked on the
/// main thread with the list of changed paths. Sidecar-only changes are suppressed.
///
/// FSEvents coalesces changes within a 3-second window before delivering them,
/// providing natural debouncing.
@MainActor
public final class FileSystemWatcher {

    // MARK: - Types

    /// Paths delivered to the callback, split by sidecar classification.
    public struct ChangedPaths: Sendable {
        /// Paths that are NOT internal sidecars — these trigger sidebar subtree refreshes.
        public let nonSidecar: [URL]
        /// All changed paths including sidecars — used by the search index.
        public let all: [URL]
    }

    // MARK: - Properties

    private let onChange: @MainActor (ChangedPaths) -> Void
    private let onRootChanged: (@MainActor () -> Void)?
    private var watchedDirectory: URL?
    private nonisolated(unsafe) var eventStream: FSEventStreamRef?
    private let latency: CFTimeInterval = 3.0

    public var isWatching: Bool {
        eventStream != nil
    }

    // MARK: - Initialization

    public init(
        onChange: @escaping @MainActor (ChangedPaths) -> Void,
        onRootChanged: (@MainActor () -> Void)? = nil
    ) {
        self.onChange = onChange
        self.onRootChanged = onRootChanged
        logger.debug("FileSystemWatcher initialized")
    }

    deinit {
        if let stream = eventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    // MARK: - Public API

    public func startWatching(directory: URL) {
        if eventStream != nil {
            stopWatching()
        }

        guard directory.isFileURL else {
            logger.error("startWatching: URL is not a file URL: \(directory.absoluteString, privacy: .public)")
            return
        }

        watchedDirectory = directory
        let path = directory.path
        logger.info("startWatching: Starting FSEvents watch on '\(path, privacy: .public)'")

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let pathsToWatch = [path] as CFArray

        guard let stream = FSEventStreamCreate(
            nil,
            FileSystemWatcher.fsEventsCallback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            UInt32(
                kFSEventStreamCreateFlagFileEvents |
                kFSEventStreamCreateFlagUseCFTypes |
                kFSEventStreamCreateFlagNoDefer
            )
        ) else {
            logger.error("startWatching: FSEventStreamCreate returned nil — watcher will be inactive")
            startPollingFallback(directory: directory)
            return
        }

        eventStream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)

        logger.info("startWatching: FSEvents stream started successfully")
    }

    public func stopWatching() {
        guard let stream = eventStream else {
            logger.debug("stopWatching: Not currently watching")
            return
        }

        logger.info("stopWatching: Stopping watcher for '\(self.watchedDirectory?.path ?? "unknown", privacy: .public)'")

        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        eventStream = nil
        watchedDirectory = nil

        logger.info("stopWatching: Watcher stopped and released")
    }

    // MARK: - Sidecar Filter

    /// Returns true if the given path is an internal sidecar/metadata file that should
    /// NOT trigger a sidebar refresh when changed.
    public nonisolated static func isSidecarPath(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()

        // Universal search database and WAL/SHM files
        if name.hasPrefix(".universal-search.db") {
            return true
        }

        // FASTQ metadata sidecar
        if name.hasSuffix(".lungfish-meta.json") {
            return true
        }

        // FASTQBundleCSVMetadata
        if name == "metadata.csv" {
            return true
        }

        // JSON files inside .lungfishfastq or .lungfishref bundles are internal manifests.
        // JSON files outside bundles (e.g. classification-result.json in Analyses/) are NOT sidecars.
        if ext == "json" {
            let pathString = url.path
            if pathString.contains(".lungfishfastq/") || pathString.contains(".lungfishref/") {
                return true
            }
        }

        return false
    }

    // MARK: - FSEvents Callback

    private static let fsEventsCallback: FSEventStreamCallback = {
        (streamRef, clientCallBackInfo, numEvents, eventPaths, eventFlags, eventIds) in

        guard let clientCallBackInfo else { return }
        let watcher = Unmanaged<FileSystemWatcher>.fromOpaque(clientCallBackInfo).takeUnretainedValue()

        guard let cfPaths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
        let flags = UnsafeBufferPointer(start: eventFlags, count: numEvents)

        var allURLs: [URL] = []
        var mustScanSubDirs = false

        for i in 0..<numEvents {
            let flag = Int(flags[i])

            if flag & kFSEventStreamEventFlagRootChanged != 0 {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        logger.warning("FSEvents: Root directory changed — stopping watcher")
                        watcher.stopWatching()
                        watcher.onRootChanged?()
                    }
                }
                return
            }

            if flag & kFSEventStreamEventFlagMustScanSubDirs != 0 {
                mustScanSubDirs = true
            }

            if flag & kFSEventStreamEventFlagHistoryDone != 0 {
                continue
            }

            allURLs.append(URL(fileURLWithPath: cfPaths[i]))
        }

        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if mustScanSubDirs {
                    logger.info("FSEvents: MustScanSubDirs flag — delivering empty ChangedPaths to trigger full reload")
                    watcher.onChange(ChangedPaths(nonSidecar: [], all: []))
                    return
                }

                guard !allURLs.isEmpty else { return }

                let nonSidecar = allURLs.filter { !FileSystemWatcher.isSidecarPath($0) }

                // Always deliver — the sidebar consumer decides what to do:
                // - nonSidecar non-empty → incremental sidebar update + search index
                // - nonSidecar empty (sidecar-only) → search index update only
                watcher.onChange(ChangedPaths(nonSidecar: nonSidecar, all: allURLs))
            }
        }
    }

    // MARK: - Polling Fallback

    private func startPollingFallback(directory: URL) {
        logger.error("startPollingFallback: FSEvents unavailable — no filesystem monitoring active for '\(directory.path, privacy: .public)'")
    }
}
