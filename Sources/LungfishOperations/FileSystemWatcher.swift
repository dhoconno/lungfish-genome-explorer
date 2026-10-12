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

    /// Internal seam around the FSEvents lifecycle so slow creation, start
    /// failures and cleanup can be exercised deterministically without changing
    /// public API. Every closure is `@Sendable` because setup runs off the main
    /// actor (see `startWatching`).
    struct StreamLifecycle: Sendable {
        let create: @Sendable (
            _ pathsToWatch: CFArray,
            _ latency: CFTimeInterval,
            _ flags: UInt32,
            _ context: UnsafeMutablePointer<FSEventStreamContext>
        ) -> FSEventStreamRef?
        let setDispatchQueue: @Sendable (FSEventStreamRef, DispatchQueue) -> Void
        let start: @Sendable (FSEventStreamRef) -> Bool
        let stop: @Sendable (FSEventStreamRef) -> Void
        let invalidate: @Sendable (FSEventStreamRef) -> Void
        let release: @Sendable (FSEventStreamRef) -> Void

        static let live = StreamLifecycle(
            create: { pathsToWatch, latency, flags, context in
                // `context.info` is a registry token, not a watcher pointer, so
                // a stream that finishes creating after the watcher is gone
                // resolves to nothing instead of dangling.
                FSEventStreamCreate(
                    nil,
                    FileSystemWatcher.fsEventsCallback,
                    context,
                    pathsToWatch,
                    FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                    latency,
                    flags
                )
            },
            setDispatchQueue: { FSEventStreamSetDispatchQueue($0, $1) },
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

    /// Everything the FSEvents callback reads, published as one immutable value
    /// so the callback queue never observes a half-updated watch.
    private struct CallbackSnapshot: Sendable {
        let watchedRootPath: String?
        let policy: StreamPolicy
        let generation: UInt

        static let inactive = CallbackSnapshot(watchedRootPath: nil, policy: .nativeVolume, generation: 0)
    }

    /// Maps a live watcher to the token its streams carry in `FSEventStreamContext.info`.
    ///
    /// Setup is asynchronous, so a stream can finish creating and start
    /// delivering after the watcher that requested it is gone. A raw
    /// `Unmanaged.passUnretained(self)` pointer would dangle in that window, so
    /// the callback resolves a token through this registry instead and finds
    /// nothing once the watcher has deregistered.
    private final class CallbackRegistry: @unchecked Sendable {
        static let shared = CallbackRegistry()

        private let lock = NSLock()
        private var nextToken: UInt = 1
        private var entries: [UInt: Entry] = [:]

        struct Entry {
            weak var watcher: FileSystemWatcher?
            var snapshot: CallbackSnapshot
        }

        func register(_ watcher: FileSystemWatcher) -> UInt {
            lock.lock()
            defer { lock.unlock() }
            let token = nextToken
            nextToken += 1
            entries[token] = Entry(watcher: watcher, snapshot: .inactive)
            return token
        }

        func deregister(_ token: UInt) {
            lock.lock()
            entries.removeValue(forKey: token)
            lock.unlock()
        }

        func publish(_ snapshot: CallbackSnapshot, for token: UInt) {
            lock.lock()
            entries[token]?.snapshot = snapshot
            lock.unlock()
        }

        func lookup(_ token: UInt) -> (watcher: FileSystemWatcher, snapshot: CallbackSnapshot)? {
            lock.lock()
            defer { lock.unlock() }
            guard let entry = entries[token], let watcher = entry.watcher else { return nil }
            return (watcher, entry.snapshot)
        }
    }

    // MARK: - Properties

    private let onChange: @MainActor (ChangedPaths) -> Void
    private let onRootChanged: (@MainActor () -> Void)?
    private let onUnavailable: (@MainActor (String) -> Void)?
    private let streamLifecycle: StreamLifecycle
    /// Registry token for this watcher's streams. Assigned once in `init`
    /// after the stored properties are in place (registration needs `self`).
    private var callbackToken: UInt = 0
    private var watchedDirectory: URL?
    /// Only ever mutated on the main actor; `nonisolated(unsafe)` exists so
    /// `deinit` can release a still-live stream.
    private nonisolated(unsafe) var eventStream: FSEventStreamRef?
    /// Policy chosen for the current watch; exposed for tests and diagnostics.
    public private(set) var streamPolicy: StreamPolicy = .nativeVolume
    /// Bumped by every `startWatching`/`stopWatching`. A background setup that
    /// lands with a stale generation has been superseded and must tear its
    /// stream down instead of attaching it.
    private var watchGeneration: UInt = 0
    /// How many setups have been dispatched but not yet landed back on the main
    /// actor, including superseded ones whose only remaining work is tearing
    /// their stream down.
    private var pendingSetupCount: Int = 0
    /// Serial queue the FSEvents stream delivers on, so a flood of events is
    /// classified off the main thread and only the coalesced result hops to it.
    private nonisolated static let callbackQueue = DispatchQueue(label: "com.lungfish.fsevents", qos: .utility)
    /// Queue that owns the blocking half of FSEvents setup. `FSEventStreamCreate`
    /// can wedge indefinitely inside `watch_all_parents`; on 2026-09-02 that
    /// happened on the main thread during `applicationDidFinishLaunching` and
    /// the app never drew a window. Losing a watcher only costs live
    /// auto-refresh, so setup must never be able to cost a window.
    private nonisolated static let setupQueue = DispatchQueue(label: "com.lungfish.fsevents.setup", qos: .utility)

    /// True from the moment a watch is requested until it is stopped, including
    /// while stream setup is still in flight. Callers treat this as "this
    /// watcher owns the directory", not as "fseventsd has acknowledged it".
    public var isWatching: Bool {
        eventStream != nil || hasClaimedWatch
    }

    /// True between `startWatching` and the matching stop/failure, whether or
    /// not the stream has finished coming up.
    private var hasClaimedWatch = false

    // MARK: - Initialization

    public init(
        onChange: @escaping @MainActor (ChangedPaths) -> Void,
        onRootChanged: (@MainActor () -> Void)? = nil,
        onUnavailable: (@MainActor (String) -> Void)? = nil
    ) {
        self.onChange = onChange
        self.onRootChanged = onRootChanged
        self.onUnavailable = onUnavailable
        self.streamLifecycle = .live
        self.callbackToken = CallbackRegistry.shared.register(self)
        logger.debug("FileSystemWatcher initialized")
    }

    init(
        onChange: @escaping @MainActor (ChangedPaths) -> Void,
        onRootChanged: (@MainActor () -> Void)?,
        onUnavailable: (@MainActor (String) -> Void)? = nil,
        streamLifecycle: StreamLifecycle
    ) {
        self.onChange = onChange
        self.onRootChanged = onRootChanged
        self.onUnavailable = onUnavailable
        self.streamLifecycle = streamLifecycle
        self.callbackToken = CallbackRegistry.shared.register(self)
        logger.debug("FileSystemWatcher initialized")
    }

    deinit {
        CallbackRegistry.shared.deregister(callbackToken)
        if let stream = eventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    // MARK: - Public API

    /// Begins watching `directory`. Returns immediately: the FSEvents stream is
    /// created, scheduled and started on `setupQueue` because
    /// `FSEventStreamCreate` can block for an unbounded time, and a hung
    /// filesystem watcher must never keep the app from drawing a window.
    public func startWatching(directory: URL) {
        tearDownCurrentStream(reason: "restart")

        guard directory.isFileURL else {
            logger.error("startWatching: URL is not a file URL: \(directory.absoluteString, privacy: .public)")
            return
        }

        // Every stream gets a fresh registry token; a retired stream cannot
        // resolve the new watch even if its callback was delayed.
        CallbackRegistry.shared.deregister(callbackToken)
        callbackToken = CallbackRegistry.shared.register(self)
        watchGeneration += 1
        watchedDirectory = directory
        let path = directory.path
        let volumeType = Self.volumeTypeName(of: directory)
        streamPolicy = StreamPolicy.policy(forVolumeTypeName: volumeType)
        // Publish before the stream can start: the callback must never see a
        // root path from the previous watch.
        CallbackRegistry.shared.publish(
            CallbackSnapshot(watchedRootPath: directory.standardizedFileURL.path, policy: streamPolicy, generation: watchGeneration),
            for: callbackToken
        )
        logger.info(
            "startWatching: Starting FSEvents watch on '\(path, privacy: .public)' (volume \(volumeType ?? "unknown", privacy: .public), perFileEvents=\(self.streamPolicy.perFileEvents, privacy: .public), latency=\(self.streamPolicy.latency, privacy: .public)s)"
        )

        hasClaimedWatch = true
        let generation = watchGeneration
        let lifecycle = streamLifecycle
        let policy = streamPolicy
        let token = callbackToken

        pendingSetupCount += 1
        // Dispatched straight onto `setupQueue` rather than through a MainActor
        // Task: hopping through the main actor first would mean a main thread
        // that later blocks could keep setup from ever starting, which is the
        // failure mode this whole change exists to remove.
        Self.setupQueue.async { [weak self] in
            let outcome = Self.makeStream(
                path: path,
                policy: policy,
                token: token,
                lifecycle: lifecycle
            )
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else {
                        // The watcher died mid-setup; the stream has no owner.
                        if case .started(let stream) = outcome {
                            Self.tearDown(stream, lifecycle: lifecycle)
                        }
                        return
                    }
                    self.finishSetup(outcome, generation: generation, directory: directory)
                }
            }
        }
    }

    public func stopWatching() {
        guard isWatching else {
            logger.debug("stopWatching: Not currently watching")
            return
        }

        logger.info("stopWatching: Stopping watcher for '\(self.watchedDirectory?.path ?? "unknown", privacy: .public)'")

        tearDownCurrentStream(reason: "stop")
        watchedDirectory = nil

        logger.info("stopWatching: Watcher stopped and released")
    }

    /// Waits until every in-flight stream setup has landed, including
    /// superseded ones whose only remaining work is tearing their stream down.
    /// Test-only: production callers must never wait on FSEvents setup, which
    /// is the whole point of this design.
    func waitForPendingStreamSetup() async {
        while pendingSetupCount > 0 {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - Stream setup

    /// Result of the blocking half of setup, performed off the main actor.
    private enum SetupOutcome {
        case creationFailed
        case startFailed
        case started(FSEventStreamRef)
    }

    /// The blocking half of setup: create, schedule and start. Runs on
    /// `setupQueue` and touches no watcher state, so it is safe to run while
    /// the main actor mutates that state concurrently.
    private nonisolated static func makeStream(
        path: String,
        policy: StreamPolicy,
        token: UInt,
        lifecycle: StreamLifecycle
    ) -> SetupOutcome {
        // The token, not a watcher pointer, identifies the callback target.
        // See `CallbackRegistry`.
        var context = FSEventStreamContext(
            version: 0,
            info: UnsafeMutableRawPointer(bitPattern: token),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let created = withUnsafeMutablePointer(to: &context) {
            lifecycle.create([path] as CFArray, policy.latency, policy.createFlags, $0)
        }
        guard let stream = created else { return .creationFailed }
        lifecycle.setDispatchQueue(stream, callbackQueue)
        guard lifecycle.start(stream) else {
            lifecycle.invalidate(stream)
            lifecycle.release(stream)
            return .startFailed
        }
        return .started(stream)
    }

    /// Installs (or discards) a stream whose setup has finished.
    private func finishSetup(_ outcome: SetupOutcome, generation: UInt, directory: URL) {
        pendingSetupCount -= 1

        // A stop or a restart that arrived while setup was in flight bumped the
        // generation. The stream we just started belongs to nobody.
        guard generation == watchGeneration else {
            if case .started(let stream) = outcome {
                logger.info("startWatching: Discarding a superseded FSEvents stream")
                Self.tearDown(stream, lifecycle: streamLifecycle)
            }
            return
        }

        switch outcome {
        case .creationFailed:
            logger.error("startWatching: FSEventStreamCreate returned nil — watcher will be inactive")
            hasClaimedWatch = false
            CallbackRegistry.shared.publish(.inactive, for: callbackToken)
            reportUnavailable(directory: directory)
        case .startFailed:
            logger.error("startWatching: FSEventStreamStart failed — watcher will be inactive")
            hasClaimedWatch = false
            watchedDirectory = nil
            CallbackRegistry.shared.publish(.inactive, for: callbackToken)
            reportUnavailable(directory: directory)
        case .started(let stream):
            eventStream = stream
            logger.info("startWatching: FSEvents stream started successfully")
        }
    }

    /// Retires whatever this watcher currently owns: the live stream if setup
    /// finished, and the generation claim if it did not.
    private func tearDownCurrentStream(reason: String) {
        // Bumping the generation is what makes an in-flight setup discard its
        // stream when it lands. There is nothing to cancel: the blocking work
        // is already committed on `setupQueue` and may be wedged inside
        // `FSEventStreamCreate`.
        watchGeneration += 1
        hasClaimedWatch = false
        CallbackRegistry.shared.publish(.inactive, for: callbackToken)
        guard let stream = eventStream else { return }
        eventStream = nil
        logger.debug("tearDownCurrentStream: releasing stream on \(reason, privacy: .public)")
        Self.tearDown(stream, lifecycle: streamLifecycle)
    }

    private nonisolated static func tearDown(_ stream: FSEventStreamRef, lifecycle: StreamLifecycle) {
        lifecycle.stop(stream)
        lifecycle.invalidate(stream)
        lifecycle.release(stream)
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

    private nonisolated static let fsEventsCallback: FSEventStreamCallback = {
        (streamRef, clientCallBackInfo, numEvents, eventPaths, eventFlags, eventIds) in
        guard let clientCallBackInfo else { return }
        // `info` carries a registry token, not a watcher pointer: setup is
        // asynchronous, so a stream can outlive the watcher that requested it
        // and a raw pointer would dangle. An unknown token means the watcher is
        // gone and the delivery is dropped.
        let token = UInt(bitPattern: clientCallBackInfo)
        guard let entry = CallbackRegistry.shared.lookup(token) else { return }
        let watcher = entry.watcher
        // The stream is scheduled on a private serial queue: path filtering and
        // burst coalescing happen here, off the main thread, and exactly one
        // main-thread hop delivers the result. A hung main thread therefore
        // never stops the stream from draining.
        guard let cfPaths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
        let flags = UnsafeBufferPointer(start: eventFlags, count: numEvents)
        let delivery = FileSystemWatcher.classify(
            paths: cfPaths,
            flags: flags.map { Int($0) },
            watchedRootPath: entry.snapshot.watchedRootPath,
            policy: entry.snapshot.policy
        )
        DispatchQueue.main.async {
            MainActor.assumeIsolated { watcher.deliver(delivery, generation: entry.snapshot.generation) }
        }
    }

    var testingCurrentGeneration: UInt { watchGeneration }

    /// The same guard covers callbacks already queued when a watch is replaced.
    func deliver(_ delivery: Delivery, generation: UInt) {
        guard generation == watchGeneration else { return }
        switch delivery {
        case .none: break
        case .rootChanged:
            stopWatching()
            onRootChanged?()
        case .fullReload:
            onChange(ChangedPaths(nonSidecar: [], all: []))
        case .paths(let changed):
            onChange(changed)
        }
    }

    /// What one FSEvents delivery turns into.
    enum Delivery: Equatable, Sendable {
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
            if flag & (kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagUnmount) != 0
                || (index < paths.count && URL(fileURLWithPath: paths[index]).standardizedFileURL.path == watchedRootPath
                    && flag & kFSEventStreamEventFlagItemRemoved != 0) {
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

    private func reportUnavailable(directory: URL) {
        logger.error("FSEvents unavailable for '\(directory.path, privacy: .public)'")
        onUnavailable?("Filesystem monitoring is unavailable. Retry to reconnect to this project folder.")
    }
}
