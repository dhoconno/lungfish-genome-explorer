// FileSystemWatcher.swift - Pure Swift directory monitoring with content scanning
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log

/// Logger for file system watcher operations
private let logger = Logger(subsystem: "com.lungfish.browser", category: "FileSystemWatcher")

/// Watches a directory for filesystem changes using periodic content scanning.
///
/// This class monitors a directory and its subdirectories for changes including:
/// - File creation
/// - File deletion
/// - File modification
/// - File/folder rename or move
///
/// The watcher uses a polling-based approach that periodically scans the directory
/// contents and detects changes by comparing file names and modification dates.
/// This approach is more reliable than DispatchSource for detecting files added
/// by external applications (like Finder).
///
/// When changes are detected, the provided callback is invoked on the main thread.
///
/// Usage:
/// ```swift
/// let watcher = FileSystemWatcher { [weak self] in
///     self?.reloadSidebar()
/// }
/// watcher.startWatching(directory: projectURL)
/// // Later...
/// watcher.stopWatching()
/// ```
@MainActor
public final class FileSystemWatcher {
    
    // MARK: - Properties
    
    /// The callback to invoke when filesystem changes are detected
    private let onChange: @MainActor () -> Void
    
    /// Timer for periodic content scanning
    private nonisolated(unsafe) var scanTimer: Timer?
    
    /// The directory currently being watched
    private var watchedDirectory: URL?
    
    /// Snapshot of the directory contents for change detection
    private var contentSnapshot: DirectorySnapshot?
    
    /// Scan interval in seconds
    private let scanInterval: TimeInterval = 1.0
    
    /// Debounce work item to coalesce rapid changes
    private var debounceWorkItem: DispatchWorkItem?
    
    /// Debounce interval in seconds (coalesces rapid changes)
    private let debounceInterval: TimeInterval = 0.3
    
    /// Whether the watcher is currently active
    public var isWatching: Bool {
        scanTimer != nil
    }
    
    // MARK: - Initialization
    
    /// Creates a new FileSystemWatcher.
    ///
    /// - Parameter onChange: Callback invoked when filesystem changes are detected.
    ///                      Always called on the main thread.
    public init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        print("[FSW] FileSystemWatcher initialized")
        logger.debug("FileSystemWatcher initialized")
    }
    
    deinit {
        scanTimer?.invalidate()
    }
    
    // MARK: - Public API
    
    /// Starts watching the specified directory for changes.
    ///
    /// If already watching a directory, stops the previous watch first.
    ///
    /// - Parameter directory: The directory URL to watch (must be a file URL)
    public func startWatching(directory: URL) {
        // Stop any existing watch
        if scanTimer != nil {
            stopWatching()
        }
        
        guard directory.isFileURL else {
            logger.error("startWatching: URL is not a file URL: \(directory.absoluteString, privacy: .public)")
            return
        }
        
        let path = directory.path
        watchedDirectory = directory
        
        print("[FSW] startWatching: Starting to watch '\(path)'")
        logger.info("startWatching: Starting to watch '\(path, privacy: .public)'")
        
        // Take initial snapshot
        contentSnapshot = createSnapshot(of: directory)
        print("[FSW] startWatching: Initial snapshot has \(contentSnapshot?.entries.count ?? 0) entries")
        
        // Start periodic scanning timer
        scanTimer = Timer.scheduledTimer(withTimeInterval: scanInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.scanForChanges()
            }
        }
        
        // Make sure the timer fires even when UI is being interacted with
        if let timer = scanTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
        
        print("[FSW] startWatching: Timer started with interval \(scanInterval)s")
        logger.info("startWatching: Content scanning started successfully")
    }
    
    /// Stops watching the current directory.
    ///
    /// Safe to call even if not currently watching.
    public func stopWatching() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        
        guard scanTimer != nil else {
            logger.debug("stopWatching: Not currently watching")
            return
        }
        
        print("[FSW] stopWatching: Stopping watcher for '\(watchedDirectory?.path ?? "unknown")'")
        logger.info("stopWatching: Stopping watcher for '\(self.watchedDirectory?.path ?? "unknown", privacy: .public)'")
        
        scanTimer?.invalidate()
        scanTimer = nil
        watchedDirectory = nil
        contentSnapshot = nil
        
        print("[FSW] stopWatching: Watcher stopped")
        logger.info("stopWatching: Watcher stopped and released")
    }
    
    // MARK: - Content Scanning
    
    /// Scans the directory and checks for changes since last snapshot
    private func scanForChanges() {
        guard let directory = watchedDirectory else { return }
        
        let newSnapshot = createSnapshot(of: directory)
        
        // Compare snapshots
        if let oldSnapshot = contentSnapshot, oldSnapshot != newSnapshot {
            print("[FSW] scanForChanges: Changes detected!")
            logger.debug("scanForChanges: Directory content changed")
            
            // Update snapshot before triggering callback
            contentSnapshot = newSnapshot
            
            // Trigger debounced callback
            triggerChangeCallback()
        } else {
            // Update snapshot (in case modification dates changed)
            contentSnapshot = newSnapshot
        }
    }
    
    /// Creates a snapshot of the directory contents
    private func createSnapshot(of directory: URL) -> DirectorySnapshot {
        var entries: [DirectoryEntry] = []
        
        let fileManager = FileManager.default
        
        // Recursively scan directory
        if let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey, .isHiddenKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                // Get file attributes
                let relativePath = fileURL.path.replacingOccurrences(of: directory.path, with: "")
                
                var modDate: Date?
                var isDirectory = false
                
                if let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]) {
                    modDate = values.contentModificationDate
                    isDirectory = values.isDirectory ?? false
                }
                
                entries.append(DirectoryEntry(
                    relativePath: relativePath,
                    modificationDate: modDate,
                    isDirectory: isDirectory
                ))
            }
        }
        
        return DirectorySnapshot(entries: entries)
    }
    
    /// Triggers the change callback with debouncing
    private func triggerChangeCallback() {
        // Debounce: Cancel previous work item and schedule new one
        debounceWorkItem?.cancel()
        
        print("[FSW] Scheduling debounced callback in \(debounceInterval)s")
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else {
                print("[FSW] ERROR: self was deallocated before callback could fire!")
                logger.warning("triggerChangeCallback: self was deallocated before callback could fire")
                return
            }
            print("[FSW] Invoking onChange callback NOW")
            logger.info("triggerChangeCallback: Invoking onChange callback")
            self.onChange()
            print("[FSW] onChange callback completed")
            logger.info("triggerChangeCallback: onChange callback completed")
        }
        debounceWorkItem = workItem
        
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }
}

// MARK: - Directory Snapshot Types

/// Represents a single entry in a directory snapshot
private struct DirectoryEntry: Equatable, Hashable {
    let relativePath: String
    let modificationDate: Date?
    let isDirectory: Bool
}

/// Represents a snapshot of directory contents for change detection
private struct DirectorySnapshot: Equatable {
    let entries: [DirectoryEntry]
    
    static func == (lhs: DirectorySnapshot, rhs: DirectorySnapshot) -> Bool {
        // Quick check: different count means different
        if lhs.entries.count != rhs.entries.count {
            return false
        }
        
        // Create sets for efficient comparison
        let lhsSet = Set(lhs.entries)
        let rhsSet = Set(rhs.entries)
        
        return lhsSet == rhsSet
    }
}
