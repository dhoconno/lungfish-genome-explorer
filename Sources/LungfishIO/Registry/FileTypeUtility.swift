// FileTypeUtility.swift - Synchronous file type detection utilities
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Provides fast, synchronous file type detection for UI components

import Foundation

/// Utility for synchronous file type detection.
///
/// This struct provides fast, non-async file type detection based on file extensions.
/// For comprehensive format detection including magic bytes and content sniffing,
/// use `FormatRegistry.shared.detectFormat(url:)` instead.
///
/// ## Usage
/// ```swift
/// let info = FileTypeUtility.detect(url: fileURL)
/// print(info.category.displayName)  // "Sequence"
/// print(info.iconName)              // "doc.text"
/// ```
public enum FileTypeUtility {

    // MARK: - Extension Mapping

    /// Maps file extensions to UI categories
    private static let extensionToCategory: [String: UICategory] = {
        var map: [String: UICategory] = [:]

        // Sequence formats
        for ext in ["fasta", "fa", "fna", "faa", "ffn", "frn", "fas", "fastq", "fq", "gb", "gbk", "genbank", "gbff", "embl"] {
            map[ext] = .sequence
        }

        // Annotation formats
        for ext in ["gff", "gff3", "gtf", "bed"] {
            map[ext] = .annotation
        }

        // Alignment formats
        for ext in ["bam", "sam", "cram"] {
            map[ext] = .alignment
        }

        // Variant formats
        for ext in ["vcf", "bcf"] {
            map[ext] = .variant
        }

        // Coverage formats
        for ext in ["bw", "bigwig", "bb", "bigbed", "bedgraph", "bg"] {
            map[ext] = .coverage
        }

        // Index formats
        for ext in ["fai", "bai", "csi", "tbi", "gzi"] {
            map[ext] = .index
        }

        // Document formats
        for ext in ["pdf", "txt", "text", "md", "markdown", "rtf", "rtfd", "csv", "tsv"] {
            map[ext] = .document
        }

        // Image formats
        for ext in ["png", "jpg", "jpeg", "gif", "tiff", "tif", "bmp", "svg", "heic", "heif", "webp"] {
            map[ext] = .image
        }

        // Compressed formats
        for ext in ["gz", "gzip", "bgz", "zip", "tar", "bz2", "xz", "zst", "zstd"] {
            map[ext] = .compressed
        }

        // Reference bundle
        map["lungfishref"] = .referenceBundle
        // FASTQ package bundle
        map[FASTQBundle.directoryExtension] = .sequence

        return map
    }()

    /// Maps file extensions to custom icon names (overrides category defaults)
    private static let extensionToIcon: [String: String] = [
        "gb": "doc.richtext",
        "gbk": "doc.richtext",
        "genbank": "doc.richtext",
        "gbff": "doc.richtext",
        "pdf": "doc.richtext",
        "txt": "doc.plaintext",
        "text": "doc.plaintext",
        "md": "doc.plaintext",
        "markdown": "doc.plaintext",
        "csv": "tablecells",
        "tsv": "tablecells",
        "vcf": "chart.bar.xaxis"
    ]

    // MARK: - Detection

    /// Detected file type information
    public struct FileTypeInfo: Sendable {
        /// UI category for this file type
        public let category: UICategory

        /// SF Symbol icon name
        public let iconName: String

        /// Whether this format supports QuickLook preview
        public let supportsQuickLook: Bool

        /// Whether this is a genomics-specific format
        public var isGenomicsFormat: Bool {
            category.isGenomicsCategory
        }
    }

    /// Detects file type information from a URL.
    ///
    /// This is a fast, synchronous method based on file extension only.
    /// For comprehensive detection, use `FormatRegistry.shared.detectFormat(url:)`.
    ///
    /// - Parameter url: The file URL to analyze
    /// - Returns: File type information
    public static func detect(url: URL) -> FileTypeInfo {
        let ext = url.pathExtension.lowercased()

        // Handle wrapped compressed files by looking at the inner extension
        if ["gz", "gzip", "bgz", "bz2", "xz", "zst", "zstd"].contains(ext) {
            let innerExt = url.deletingPathExtension().pathExtension.lowercased()
            if !innerExt.isEmpty, let category = extensionToCategory[innerExt] {
                let iconName = extensionToIcon[innerExt] ?? category.iconName
                return FileTypeInfo(
                    category: category,
                    iconName: iconName,
                    supportsQuickLook: false // Compressed files don't support QuickLook
                )
            }
        }

        // Look up extension
        if let category = extensionToCategory[ext] {
            let iconName = extensionToIcon[ext] ?? category.iconName
            let supportsQuickLook: Bool
            switch category {
            case .document, .image:
                supportsQuickLook = true
            default:
                supportsQuickLook = false
            }
            return FileTypeInfo(
                category: category,
                iconName: iconName,
                supportsQuickLook: supportsQuickLook
            )
        }

        // Unknown file type - will use QuickLook as fallback
        return FileTypeInfo(
            category: .unknown,
            iconName: UICategory.unknown.iconName,
            supportsQuickLook: true // Unknown files can try QuickLook
        )
    }

    /// Detects file type information from a file extension.
    ///
    /// - Parameter extension: The file extension (without leading dot)
    /// - Returns: File type information
    public static func detect(extension ext: String) -> FileTypeInfo {
        let lowercaseExt = ext.lowercased()

        if let category = extensionToCategory[lowercaseExt] {
            let iconName = extensionToIcon[lowercaseExt] ?? category.iconName
            let supportsQuickLook: Bool
            switch category {
            case .document, .image:
                supportsQuickLook = true
            default:
                supportsQuickLook = false
            }
            return FileTypeInfo(
                category: category,
                iconName: iconName,
                supportsQuickLook: supportsQuickLook
            )
        }

        return FileTypeInfo(
            category: .unknown,
            iconName: UICategory.unknown.iconName,
            supportsQuickLook: true
        )
    }

    /// Checks if a file extension is recognized (genomics or document/image).
    ///
    /// - Parameter extension: The file extension (without leading dot)
    /// - Returns: `true` if the extension is known
    public static func isKnownExtension(_ ext: String) -> Bool {
        extensionToCategory[ext.lowercased()] != nil
    }

    /// Returns all known file extensions.
    public static var allKnownExtensions: Set<String> {
        Set(extensionToCategory.keys)
    }
}
