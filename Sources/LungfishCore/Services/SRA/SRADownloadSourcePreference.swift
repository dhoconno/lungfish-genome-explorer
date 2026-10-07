// SRADownloadSourcePreference.swift - Which archive an SRA run's FASTQ files are fetched from first
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Which archive a download of an SRA run tries first.
///
/// ENA serves a run as FASTQ files ready to use. NCBI serves an SRA archive
/// that the SRA Toolkit fetches with `prefetch` and converts with
/// `fasterq-dump --split-3`, which takes longer but can still be faster when
/// ENA is slow. Both routes give the same reads in the same layout. The
/// window's "Download source" setting and `lungfish-cli fetch sra download
/// --prefer-source` both take this value. `fetch sra download` downloads with
/// `SRAService.downloadFASTQ(accession:outputDir:preferring:)` and the window
/// with `SRAWindowRunDownload`, which also looks up ENA's record beside the
/// toolkit for the bundle's metadata. Both name an ENA fallback with
/// `SRAFASTQDownloadSource.enaFallback(afterToolkitError:)`.
public enum SRADownloadSourcePreference: String, CaseIterable, Sendable {
    /// ENA's mirror first, then the SRA Toolkit when ENA cannot serve the
    /// run. This is the default and the behaviour before the setting existed.
    case ena
    /// The SRA Toolkit first, then ENA's mirror when the toolkit is not
    /// installed or fails and ENA lists FASTQ files for the run.
    case ncbi

    /// The UserDefaults key the window stores the choice under.
    public static let userDefaultsKey = "SRADownloadSourcePreference"

    /// The choice stored in `defaults`, or `.ena` when none or an unknown
    /// value is stored.
    public static func stored(in defaults: UserDefaults = .standard) -> SRADownloadSourcePreference {
        defaults.string(forKey: userDefaultsKey).flatMap(SRADownloadSourcePreference.init(rawValue:)) ?? .ena
    }

    /// Stores the choice in `defaults`.
    public func store(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.userDefaultsKey)
    }

    /// The title the window's menu shows.
    public var menuTitle: String {
        switch self {
        case .ena: return "Prefer ENA"
        case .ncbi: return "Prefer NCBI"
        }
    }

    /// The trade-off, in the words the window and the CLI help use.
    public static let tradeOff = "ENA serves ready FASTQ files. NCBI needs the SRA Toolkit to convert its archive, which takes longer, but it can be faster when ENA is slow. When the preferred source fails, the other one is tried."
}

public extension SRAFASTQDownloadSource {
    /// The source a download records when the preferred SRA Toolkit failed
    /// with `error` and ENA's mirror serves the run instead, or nil for a
    /// cancellation, which stops the download.
    static func enaFallback(afterToolkitError error: any Error) -> SRAFASTQDownloadSource? {
        if isArchiveRequestCancellation(error) {
            return nil
        }
        if case SRAError.toolkitNotFound? = error as? SRAError {
            return .enaAfterMissingToolkit
        }
        return .enaAfterFailedToolkit
    }

    /// The line both surfaces log when the preferred SRA Toolkit failed with
    /// `error` and ENA's mirror serves the run instead.
    static func enaFallbackMessage(accession: String, after error: any Error) -> String {
        if case SRAError.toolkitNotFound? = error as? SRAError {
            return "The SRA Toolkit is not installed, so ENA serves \(accession) instead."
        }
        return "The SRA Toolkit failed for \(accession), so ENA serves it instead. \(SRADownloadMessages.reason(of: error))"
    }
}
