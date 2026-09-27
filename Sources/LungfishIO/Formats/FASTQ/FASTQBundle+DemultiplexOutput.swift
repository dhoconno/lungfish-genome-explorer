// FASTQBundle+DemultiplexOutput.swift - Where a bundle's demultiplex runs live
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Demultiplex Barcodes writes its per-barcode bundles inside the source
// bundle. The first run owns `demux/`; a later run used to delete that
// directory before writing its own, silently discarding the earlier
// barcode bundles and whatever had been derived from them. Every run now
// gets its own directory (`demux`, `demux-2`, `demux-3`, ...), and the
// sidebar lists all of them.

import Foundation

extension FASTQBundle {
    /// The directory of a bundle's first demultiplex run.
    public static let demultiplexOutputDirectoryName = "demux"

    /// The directory the next demultiplex run of `bundleURL` writes:
    /// `demux` when it does not exist yet, otherwise the first free
    /// `demux-N` with N counted from 2.
    public static func nextDemultiplexOutputDirectory(in bundleURL: URL) -> URL {
        let fileManager = FileManager.default
        let first = bundleURL.appendingPathComponent(demultiplexOutputDirectoryName, isDirectory: true)
        guard fileManager.fileExists(atPath: first.path) else { return first }
        var ordinal = 2
        while true {
            let candidate = bundleURL.appendingPathComponent(demultiplexOutputDirectoryName(ordinal: ordinal), isDirectory: true)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            ordinal += 1
        }
    }

    /// Every demultiplex output directory inside `bundleURL`, in run
    /// order (`demux`, `demux-2`, `demux-3`, ...). Only existing
    /// directories are listed.
    public static func demultiplexOutputDirectories(in bundleURL: URL) -> [URL] {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: bundleURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var ordered: [(ordinal: Int, url: URL)] = []
        for url in contents {
            guard let ordinal = demultiplexOutputOrdinal(of: url.lastPathComponent) else { continue }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            ordered.append((ordinal, url))
        }
        return ordered.sorted { $0.ordinal < $1.ordinal }.map(\.url)
    }

    /// The run number a demultiplex directory name carries: 1 for `demux`,
    /// N for `demux-N` (N at least 2), nil for any other name.
    public static func demultiplexOutputOrdinal(of directoryName: String) -> Int? {
        if directoryName == demultiplexOutputDirectoryName { return 1 }
        let prefix = demultiplexOutputDirectoryName + "-"
        guard directoryName.hasPrefix(prefix) else { return nil }
        let suffix = directoryName.dropFirst(prefix.count)
        guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber), let ordinal = Int(suffix), ordinal >= 2 else {
            return nil
        }
        return ordinal
    }

    static func demultiplexOutputDirectoryName(ordinal: Int) -> String {
        ordinal <= 1 ? demultiplexOutputDirectoryName : "\(demultiplexOutputDirectoryName)-\(ordinal)"
    }
}
