// DemultiplexingPipeline+ExactBareReadIDs.swift - The read ID files of the exact bare-barcode pass
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension DemultiplexingPipeline {
    /// Writes the read ID of each record a pass places, a line each, to a file for each sample in `directory`, so that the
    /// pass keeps no ID in memory (DEMUXSPLIT-S3-GROUP: 20 M pairs held about 22 GB). The lines of a sample wait in a
    /// buffer of 64 KB, and the files are opened through the handle cache of the FASTQ output.
    final class ExactBareReadIDWriter {
        static let flushSize = 65_536

        private struct Sink {
            let url: URL
            var pending = Data()
        }

        private let directory: URL
        private let files = ExactBareFASTQOutputCache()
        private var sinks: [String: Sink] = [:]

        init(directory: URL) {
            self.directory = directory
        }

        /// The file of `sample` in `directory`.
        static func fileURL(in directory: URL, sample: String) -> URL {
            directory.appendingPathComponent("\(sample).read-ids.txt")
        }

        func append(_ readID: String, sample: String) throws {
            var sink = sinks.removeValue(forKey: sample) ?? Sink(url: Self.fileURL(in: directory, sample: sample))
            sink.pending.append(contentsOf: readID.utf8)
            sink.pending.append(0x0A)
            if sink.pending.count >= Self.flushSize {
                try files.write(sink.pending, to: sink.url)
                sink.pending.removeAll(keepingCapacity: true)
            }
            sinks[sample] = sink
        }

        /// Writes the lines that still wait and closes every file.
        func closeAll() throws {
            var firstError: Error?
            for sink in sinks.values where !sink.pending.isEmpty {
                do {
                    try files.write(sink.pending, to: sink.url)
                } catch {
                    if firstError == nil { firstError = error }
                }
            }
            sinks.removeAll()
            do {
                try files.closeAll()
            } catch {
                if firstError == nil { firstError = error }
            }
            if let firstError { throw firstError }
        }
    }
}
