// SequencingReadImportSource.swift - Raw read input classification for import
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Identifies files accepted by the sequencing-read import workflow.
///
/// BAM remains a distinct scientific format. It is accepted here only so the
/// ONT importer can materialize its reads as temporary FASTQ before processing.
public enum SequencingReadImportSource {
    public static func isBAM(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "bam"
    }

    public static func isSupported(_ url: URL) -> Bool {
        FASTQBundle.isFASTQFileURL(url) || isBAM(url)
    }
}
