// FASTAFileTypes.swift - Shared FASTA/GenBank UTType data for file panels
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import UniformTypeIdentifiers

public enum FASTAFileTypes {
    static let readableExtensions = ["fa", "fasta", "fna", "fsa", "fas", "faa", "ffn", "frn", "gb", "gbk", "gbff", "genbank", "embl"]
    static let compressionWrapperExtensions = ["gz", "gzip", "bgz", "bz2", "xz", "zst", "zstd"]

    /// Content types for reference sequence files, including common compressed wrappers.
    ///
    /// Includes plain FASTA/GenBank/EMBL extensions and compressed wrappers
    /// so NSOpenPanel accepts files like `sequence.fa.gz` and `reference.gbk.xz`.
    public static let readableContentTypes: [UTType] = {
        var types = readableExtensions.compactMap { UTType(filenameExtension: $0) }
        types.append(.gzip)
        for wrapper in compressionWrapperExtensions {
            if let wrapperType = UTType(filenameExtension: wrapper) {
                types.append(wrapperType)
            }
        }
        return types
    }()
}
