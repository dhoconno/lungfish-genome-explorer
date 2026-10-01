// PlainTextPreview.swift - Plain-text fallback for files Quick Look cannot preview
//
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import UniformTypeIdentifiers

/// Decides whether a file should be shown by the viewer's plain-text fallback
/// and reads a bounded, UTF-8 safe preview of it.
///
/// Quick Look stays the primary path for every type macOS knows how to preview
/// (.md, .txt, .py, .sh, .json and so on). This fallback only applies to
/// workflow and script files the system has no preview for, such as Nextflow
/// `main.nf`, Snakemake `Snakefile`, and unregistered extensions, plus small
/// unknown files that sniff as UTF-8 text.
enum PlainTextPreview {

    /// Largest number of bytes read into the preview. Larger files are
    /// truncated and say so.
    static let maxPreviewBytes = 2 * 1024 * 1024

    /// Largest file an unrecognised file may be before it is no longer sniffed
    /// as text. Matches `maxPreviewBytes` so a sniffed file is always shown whole.
    static let maxSniffedFileBytes = maxPreviewBytes

    /// Number of leading bytes inspected when sniffing for text.
    static let sniffBytes = 8 * 1024

    /// Extensions always shown as text, even when an installed app maps them to
    /// a type Quick Look does not render (for example `.r` resolves to Rez
    /// source, and `.yaml` shows only a generic icon when a third-party
    /// text app owns the type).
    static let workflowExtensions: Set<String> = ["nf", "smk", "config", "r", "yaml", "yml", "toml"]

    /// Extension-less file names always shown as text (lowercased).
    static let knownFileNames: Set<String> = [
        "snakefile", "makefile", "dockerfile", "license", "nextflow.config",
    ]

    /// How a file should be previewed.
    enum Decision: Equatable {
        /// Leave the file to Quick Look.
        case quickLook
        /// Show it as text, capped at `maxPreviewBytes`.
        case text
    }

    /// Result of reading a text preview.
    struct Content: Equatable {
        let text: String
        /// True when the file was longer than the preview cap.
        let isTruncated: Bool
        /// Size of the file on disk in bytes.
        let totalBytes: Int
    }

    /// Classifies a file URL. Cheap checks (name, extension, type) run first and
    /// the file is only opened when it has to be sniffed.
    static func decision(for url: URL) -> Decision {
        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()

        if knownFileNames.contains(name) || workflowExtensions.contains(ext) {
            return looksLikeText(at: url, requireSmall: false) ? .text : .quickLook
        }

        // Anything with a registered, non-dynamic type is Quick Look's job.
        if !ext.isEmpty,
           let type = UTType(filenameExtension: ext),
           !type.isDynamic {
            return .quickLook
        }

        return looksLikeText(at: url, requireSmall: true) ? .text : .quickLook
    }

    /// True when the leading bytes are valid UTF-8 with no NUL bytes.
    /// - Parameter requireSmall: also require the file to fit in the preview cap.
    static func looksLikeText(at url: URL, requireSmall: Bool) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize, size > 0 else { return false }
        if requireSmall && size > maxSniffedFileBytes { return false }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: sniffBytes) else { return false }
        return isLikelyText(head)
    }

    /// Pure sniff over a leading chunk of a file. A chunk cut in the middle of
    /// a multi-byte character is accepted.
    static func isLikelyText(_ data: Data) -> Bool {
        guard !data.isEmpty, !data.contains(0) else { return false }
        if String(data: data, encoding: .utf8) != nil { return true }
        // Accept a chunk that only fails because it ends inside a multi-byte character.
        let complete = data.count - incompleteTrailingByteCount(data)
        return complete < data.count && String(data: data.prefix(complete), encoding: .utf8) != nil
    }

    /// Number of bytes at the end of `data` that start a UTF-8 sequence which
    /// the data ends before finishing (0 to 3).
    static func incompleteTrailingByteCount(_ data: Data) -> Int {
        let bytes = [UInt8](data)
        for back in 1...min(3, bytes.count) {
            let byte = bytes[bytes.count - back]
            if byte & 0xC0 == 0x80 { continue }  // continuation byte, keep looking for the lead
            let needed: Int
            switch byte {
            case 0xC2...0xDF: needed = 2
            case 0xE0...0xEF: needed = 3
            case 0xF0...0xF4: needed = 4
            default: return 0
            }
            return back < needed ? back : 0
        }
        return 0
    }

    /// Reads up to `maxPreviewBytes` of the file as UTF-8 text.
    static func load(from url: URL, maxBytes: Int = maxPreviewBytes) -> Content? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard var data = try? handle.read(upToCount: maxBytes) else { return nil }
        let truncated = size > data.count
        if truncated {
            // Do not end on half a character.
            data = data.dropLast(incompleteTrailingByteCount(data))
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return Content(text: text, isTruncated: truncated, totalBytes: size)
    }
}
