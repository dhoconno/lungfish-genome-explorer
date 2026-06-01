// AppDelegate+Helpers.swift - File-private helper functions extracted from AppDelegate
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// These were originally file-private free functions in AppDelegate.swift. They are
// widened to `internal` so the AppDelegate extension files (AppDelegate+*.swift) in
// the same module can reference them. Logic is unchanged from the original.

import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
import LungfishWorkflow
import SQLite3
import os

internal let appDelegateLogger = Logger(subsystem: LogSubsystem.app, category: "AppDelegate")

/// Debug logging using os.log (replaces file-based debugLog)
internal func debugLog(_ message: String) {
    appDelegateLogger.debug("\(message, privacy: .public)")
}

/// Builds a relative path string for `target` rooted at `base` when possible.
internal func appRelativePath(from base: URL, to target: URL) -> String {
    let basePath = base.standardizedFileURL.path
    let targetPath = target.standardizedFileURL.path
    let normalizedBase = basePath.hasSuffix("/") ? basePath : basePath + "/"
    if targetPath.hasPrefix(normalizedBase) {
        return String(targetPath.dropFirst(normalizedBase.count))
    }
    return target.lastPathComponent
}

/// Escapes a value for tab-separated output.
internal func appTSVField(_ value: String) -> String {
    if value.contains("\t") || value.contains("\n") || value.contains("\"") {
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    return value
}

/// Schedules a MainActor-isolated block to execute on the main run loop.
///
/// This function is critical for Swift concurrency integration with AppKit modal sessions.
/// During sheet dismissal and other modal transitions, both `Task { }` and `DispatchQueue.main.async`
/// may be blocked because GCD's main queue serialization can be stalled.
///
/// The solution is to use CFRunLoopPerformBlock directly with kCFRunLoopCommonModes,
/// which bypasses GCD and schedules directly to the run loop.
///
/// - Parameter block: The MainActor-isolated block to execute
internal func scheduleOnMainRunLoop(_ block: @escaping @MainActor @Sendable () -> Void) {
    // Use CFRunLoopPerformBlock directly - this bypasses GCD completely
    // and schedules the block directly to the main run loop
    CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
        // We're on main thread via CFRunLoop, safe to assume MainActor
        MainActor.assumeIsolated {
            block()
        }
    }
    // Wake up the run loop to process the block immediately
    CFRunLoopWakeUp(CFRunLoopGetMain())
}

internal func appPerformOnMainRunLoop<T: Sendable>(_ block: @escaping @MainActor @Sendable () -> T) async -> T {
    await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
        scheduleOnMainRunLoop {
            continuation.resume(returning: block())
        }
    }
}

/// Result of loading file data on a background thread using GCD sync pattern.
/// This struct contains only Sendable data that can be safely passed between threads.
/// Note: This is separate from DocumentLoader.FileLoadResult which uses async/await.
internal struct SyncFileLoadResult: Sendable {
    let url: URL
    let type: DocumentType
    let sequences: [Sequence]
    let annotations: [SequenceAnnotation]
    let error: String?

    init(url: URL, type: DocumentType, sequences: [Sequence] = [], annotations: [SequenceAnnotation] = [], error: String? = nil) {
        self.url = url
        self.type = type
        self.sequences = sequences
        self.annotations = annotations
        self.error = error
    }
}

internal struct SequenceExportDocumentSnapshot: Sendable {
    let name: String
    let url: URL
    let sequences: [LungfishCore.Sequence]
    let annotations: [SequenceAnnotation]
}

/// Loads file data synchronously on a background thread, completely avoiding MainActor.
///
/// This is critical for loading files during modal transitions when MainActor is blocked.
/// The function reads and parses the file entirely on a GCD background thread, then calls
/// the completion handler with the parsed data.
///
/// - Parameters:
///   - url: The file URL to load
///   - completion: Called on the main run loop with the load result
internal func loadFileInBackground(at url: URL, completion: @escaping @Sendable (SyncFileLoadResult) -> Void) {
    debugLog("loadFileInBackground: Starting for \(url.path)")

    DispatchQueue.global(qos: .userInitiated).async {
        debugLog("loadFileInBackground: Background thread starting")

        // Detect document type
        guard let type = DocumentType.detect(from: url) else {
            debugLog("loadFileInBackground: Unsupported format \(url.pathExtension)")
            completion(SyncFileLoadResult(url: url, type: .fasta, error: "Unsupported file format: \(url.pathExtension)"))
            return
        }

        debugLog("loadFileInBackground: Detected type \(type.rawValue)")

        do {
            var sequences: [Sequence] = []
            var annotations: [SequenceAnnotation] = []

            switch type {
            case .fasta:
                debugLog("loadFileInBackground: Reading FASTA synchronously")
                sequences = try loadFASTASync(from: url)
                debugLog("loadFileInBackground: FASTA loaded \(sequences.count) sequences")

            case .genbank:
                debugLog("loadFileInBackground: Reading GenBank synchronously")
                let records = try loadGenBankSync(from: url)
                for record in records {
                    sequences.append(record.sequence)
                    annotations.append(contentsOf: record.annotations)
                }
                debugLog("loadFileInBackground: GenBank loaded \(sequences.count) sequences, \(annotations.count) annotations")

            default:
                debugLog("loadFileInBackground: Type \(type.rawValue) not yet supported for background loading")
                completion(SyncFileLoadResult(url: url, type: type, error: "Format not supported for this operation"))
                return
            }

            debugLog("loadFileInBackground: Success - sequences=\(sequences.count), annotations=\(annotations.count)")
            completion(SyncFileLoadResult(url: url, type: type, sequences: sequences, annotations: annotations))

        } catch {
            debugLog("loadFileInBackground: Error - \(error.localizedDescription)")
            completion(SyncFileLoadResult(url: url, type: type, error: error.localizedDescription))
        }
    }
}

/// Loads FASTA file synchronously (no async/await, no MainActor).
internal func loadFASTASync(from url: URL) throws -> [Sequence] {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    guard let data = try handle.readToEnd() else {
        return []
    }

    guard let content = String(data: data, encoding: .utf8) else {
        throw FASTAError.invalidEncoding
    }

    var sequences: [Sequence] = []
    var currentName: String?
    var currentDescription: String?
    var currentBases = ""

    for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)

        if trimmedLine.isEmpty {
            continue
        }

        if trimmedLine.hasPrefix(">") {
            // Save previous sequence if exists
            if let name = currentName, !currentBases.isEmpty {
                let seq = try Sequence(
                    name: name,
                    description: currentDescription,
                    alphabet: detectAlphabet(currentBases),
                    bases: currentBases
                )
                sequences.append(seq)
            }

            // Parse new header
            let headerLine = String(trimmedLine.dropFirst())
            let parts = headerLine.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            currentName = String(parts.first ?? "")
            currentDescription = parts.count > 1 ? String(parts[1]) : nil
            currentBases = ""

        } else if currentName != nil {
            currentBases += trimmedLine
        }
    }

    // Don't forget the last sequence
    if let name = currentName, !currentBases.isEmpty {
        let seq = try Sequence(
            name: name,
            description: currentDescription,
            alphabet: detectAlphabet(currentBases),
            bases: currentBases
        )
        sequences.append(seq)
    }

    return sequences
}

/// Detects sequence alphabet from bases string.
internal func detectAlphabet(_ bases: String) -> SequenceAlphabet {
    let upper = bases.uppercased()

    // Check for protein-specific amino acids
    let proteinOnly = Set("EFILPQZ")
    for char in upper {
        if proteinOnly.contains(char) {
            return .protein
        }
    }

    // Check for U (RNA) vs T (DNA)
    let hasU = upper.contains("U")
    let hasT = upper.contains("T")

    if hasU && !hasT {
        return .rna
    }

    return .dna
}

/// Loads GenBank file synchronously (no async/await, no MainActor).
internal func loadGenBankSync(from url: URL) throws -> [GenBankRecord] {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    guard let data = try handle.readToEnd() else {
        return []
    }

    guard let content = String(data: data, encoding: .utf8) else {
        throw GenBankError.invalidEncoding
    }

    // Use the GenBankParser to parse the content synchronously
    let parser = GenBankParser()
    return try parser.parseContent(content)
}
