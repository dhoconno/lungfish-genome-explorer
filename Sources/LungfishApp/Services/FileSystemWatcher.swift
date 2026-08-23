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

    /// Internal seam around the FSEvents lifecycle so start failures and
    /// cleanup can be exercised deterministically without changing public API.
    struct StreamLifecycle {
        let start: (FSEventStreamRef) -> Bool
        let stop: (FSEventStreamRef) -> Void
        let invalidate: (FSEventStreamRef) -> Void
        let release: (FSEventStreamRef) -> Void

        @MainActor static let live = StreamLifecycle(
            start: { FSEventStreamStart($0) },
            stop: FSEventStreamStop,
            invalidate: FSEventStreamInvalidate,
            release: FSEventStreamRelease
        )
    }

    /// How the FSEvents stream is configured for the volume being watched.
    ///
    /// Per-file events (`kFSEventStreamCreateFlagFileEvents`) with a short
    /// latency are right for a local APFS/HFS+ project. On every other volume
    /// (exFAT/FAT via FSKit, SMB/NFS, ...) per-file events are expensive for
    /// fseventsd and arrive in floods while a tool writes thousands of files:
    /// on 2026-08-22 a Kraken2 batch plus a FASTQ import on an exFAT project
    /// drove fseventsd to 28 GB resident and the machine out of memory. Those
    /// volumes get directory-level events and a long latency instead.
    public struct StreamPolicy: Equatable, Sendable {
        public let perFileEvents: Bool
        public let latency: CFTimeInterval
        /// Above this many paths in one delivery the watcher reports a single
        /// "scan everything" change instead of fanning out per path.
        public let burstThreshold: Int

        public static let nativeVolume = StreamPolicy(perFileEvents: true, latency: 3.0, burstThreshold: 2_000)
        public static let foreignVolume = StreamPolicy(perFileEvents: false, latency: 10.0, burstThreshold: 500)

        /// Volume type names FSEvents handles efficiently with per-file events.
        static let nativeVolumeTypes: Set<String> = ["apfs", "hfs"]

        /// Picks the policy for a volume type name as reported by
        /// `URLResourceKey.volumeTypeNameKey` (nil means unknown: treat as foreign).
        public static func policy(forVolumeTypeName name: String?) -> StreamPolicy {
            guard let name else { return .foreignVolume }
            return nativeVolumeTypes.contains(name.lowercased()) ? .nativeVolume : .foreignVolume
        }

        var createFlags: UInt32 {
            var flags = kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot
            if perFileEvents {
                flags |= kFSEventStreamCreateFlagFileEvents
            }
            return UInt32(flags)
        }
    }

    /// Reads the volume type of `directory`; nil when it cannot be determined.
    public nonisolated static func volumeTypeName(of directory: URL) -> String? {
        try? directory.resourceValues(forKeys: [.volumeTypeNameKey]).volumeTypeName
    }

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
    private let streamLifecycle: StreamLifecycle
    private var watchedDirectory: URL?
    private nonisolated(unsafe) var eventStream: FSEventStreamRef?
    /// Policy chosen for the current watch; exposed for tests and diagnostics.
    public private(set) var streamPolicy: StreamPolicy = .nativeVolume
    /// Snapshots for the off-main callback.
    private nonisolated(unsafe) var watchedRootPathSnapshot: String?
    private nonisolated(unsafe) var callbackPolicySnapshot: StreamPolicy = .nativeVolume
    /// Serial queue the FSEvents stream delivers on, so a flood of events is
    /// classified off the main thread and only the coalesced result hops to it.
    private static let callbackQueue = DispatchQueue(label: "com.lungfish.fsevents", qos: .utility)

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
        self.streamLifecycle = .live
        logger.debug("FileSystemWatcher initialized")
    }

    init(
        onChange: @escaping @MainActor (ChangedPaths) -> Void,
        onRootChanged: (@MainActor () -> Void)?,
        streamLifecycle: StreamLifecycle
    ) {
        self.onChange = onChange
        self.onRootChanged = onRootChanged
        self.streamLifecycle = streamLifecycle
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
        let volumeType = Self.volumeTypeName(of: directory)
        streamPolicy = StreamPolicy.policy(forVolumeTypeName: volumeType)
        watchedRootPathSnapshot = directory.standardizedFileURL.path
        callbackPolicySnapshot = streamPolicy
        logger.info(
            "startWatching: Starting FSEvents watch on '\(path, privacy: .public)' (volume \(volumeType ?? "unknown", privacy: .public), perFileEvents=\(self.streamPolicy.perFileEvents, privacy: .public), latency=\(self.streamPolicy.latency, privacy: .public)s)"
        )

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
            streamPolicy.latency,
            streamPolicy.createFlags
        ) else {
            logger.error("startWatching: FSEventStreamCreate returned nil — watcher will be inactive")
            startPollingFallback(directory: directory)
            return
        }

        FSEventStreamSetDispatchQueue(stream, Self.callbackQueue)
        guard streamLifecycle.start(stream) else {
            logger.error("startWatching: FSEventStreamStart failed — watcher will be inactive")
            streamLifecycle.invalidate(stream)
            streamLifecycle.release(stream)
            watchedDirectory = nil
            startPollingFallback(directory: directory)
            return
        }

        eventStream = stream
        logger.info("startWatching: FSEvents stream started successfully")
    }

    public func stopWatching() {
        guard let stream = eventStream else {
            logger.debug("stopWatching: Not currently watching")
            return
        }

        logger.info("stopWatching: Stopping watcher for '\(self.watchedDirectory?.path ?? "unknown", privacy: .public)'")

        streamLifecycle.stop(stream)
        streamLifecycle.invalidate(stream)
        streamLifecycle.release(stream)
        eventStream = nil
        watchedDirectory = nil
        watchedRootPathSnapshot = nil

        logger.info("stopWatching: Watcher stopped and released")
    }

    // MARK: - Sidecar Filter

    /// Returns true if the given path is an internal sidecar/metadata file that should
    /// NOT trigger a sidebar refresh when changed.
    public nonisolated static func isSidecarPath(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()

        // Universal search database and WAL/SHM files
        if isUniversalSearchInternalPath(url) {
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

    /// Returns true for files written by the universal-search index itself.
    /// These must never be fed back into the index as source changes.
    public nonisolated static func isUniversalSearchInternalPath(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        let logicalName: String
        if name.hasPrefix("._") {
            logicalName = String(name.dropFirst(2))
        } else if name.hasPrefix("..universal-search.db") {
            // Atomic writes to a hidden `.universal-search.db…` file add one
            // leading dot, producing a temporary `..universal-search…` name.
            logicalName = String(name.dropFirst())
        } else {
            logicalName = name
        }
        return logicalName.hasPrefix(".universal-search.db")
    }

    // MARK: - FSEvents Callback

    private static let fsEventsCallback: FSEventStreamCallback = {
        (streamRef, clientCallBackInfo, numEvents, eventPaths, eventFlags, eventIds) in
        guard let clientCallBackInfo else { return }
        let watcher = Unmanaged<FileSystemWatcher>.fromOpaque(clientCallBackInfo).takeUnretainedValue()
        // The stream is scheduled on a private serial queue: path filtering and
        // burst coalescing happen here, off the main thread, and exactly one
        // main-thread hop delivers the result. A hung main thread therefore
        // never stops the stream from draining.
        guard let cfPaths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
        let flags = UnsafeBufferPointer(start: eventFlags, count: numEvents)
        let watchedRootPath = watcher.watchedRootPathSnapshot
        let policy = watcher.callbackPolicySnapshot
        let delivery = FileSystemWatcher.classify(
            paths: cfPaths,
            flags: flags.map { Int($0) },
            watchedRootPath: watchedRootPath,
            policy: policy
        )
        switch delivery {
        case .none:
            return
        case .rootChanged:
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    logger.warning("FSEvents: Root directory changed — stopping watcher")
                    watcher.stopWatching()
                    watcher.onRootChanged?()
                }
            }
        case .fullReload(let reason):
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    logger.info("FSEvents: \(reason, privacy: .public) — delivering empty ChangedPaths to trigger full reload")
                    watcher.onChange(ChangedPaths(nonSidecar: [], all: []))
                }
            }
        case .paths(let changed):
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    watcher.onChange(changed)
                }
            }
        }
    }

    /// What one FSEvents delivery turns into.
    enum Delivery: Equatable {
        case none
        case rootChanged
        case fullReload(reason: String)
        case paths(ChangedPaths)

        static func == (lhs: Delivery, rhs: Delivery) -> Bool {
            switch (lhs, rhs) {
            case (.none, .none), (.rootChanged, .rootChanged): return true
            case (.fullReload(let a), .fullReload(let b)): return a == b
            case (.paths(let a), .paths(let b)): return a.nonSidecar == b.nonSidecar && a.all == b.all
            default: return false
            }
        }
    }

    /// Pure classification of one delivery; runs off the main thread.
    nonisolated static func classify(
        paths: [String],
        flags: [Int],
        watchedRootPath: String?,
        policy: StreamPolicy
    ) -> Delivery {
        var allURLs: [URL] = []
        var mustScanSubDirs = false
        for (index, flag) in flags.enumerated() {
            if flag & kFSEventStreamEventFlagRootChanged != 0 {
                return .rootChanged
            }
            if flag & kFSEventStreamEventFlagMustScanSubDirs != 0 {
                mustScanSubDirs = true
            }
            if flag & kFSEventStreamEventFlagHistoryDone != 0 {
                continue
            }
            if index < paths.count {
                allURLs.append(URL(fileURLWithPath: paths[index]))
            }
        }
        if mustScanSubDirs {
            return .fullReload(reason: "MustScanSubDirs flag")
        }
        if allURLs.count > policy.burstThreshold {
            // A tool writing thousands of files: one coalesced rescan is far
            // cheaper than thousands of per-path sidebar updates.
            return .fullReload(reason: "burst of \(allURLs.count) changes")
        }
        let sourceURLs = allURLs.filter {
            let canonical = $0.standardizedFileURL
            return canonical.path != watchedRootPath
                && !FileSystemWatcher.isUniversalSearchInternalPath(canonical)
        }
        guard !sourceURLs.isEmpty else { return .none }
        let nonSidecar = sourceURLs.filter { !FileSystemWatcher.isSidecarPath($0) }
        // Always deliver — the sidebar consumer decides what to do:
        // - nonSidecar non-empty → incremental sidebar update + search index
        // - nonSidecar empty (sidecar-only) → search index update only
        return .paths(ChangedPaths(nonSidecar: nonSidecar, all: sourceURLs))
    }

    // MARK: - Polling Fallback

    private func startPollingFallback(directory: URL) {
        logger.error("startPollingFallback: FSEvents unavailable — no filesystem monitoring active for '\(directory.path, privacy: .public)'")
    }
}
