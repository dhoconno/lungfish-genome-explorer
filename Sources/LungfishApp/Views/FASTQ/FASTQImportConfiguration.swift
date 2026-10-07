// FASTQImportConfiguration.swift - Data model for FASTQ import settings
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishWorkflow


/// User-configured settings for FASTQ file import, captured by the import config sheet.
public struct FASTQImportConfiguration: Sendable {
    /// Input files for this sample. [R1] for single-end, [R1, R2] for paired-end.
    public let inputFiles: [URL]
    /// Platform auto-detected from the FASTQ header.
    public let detectedPlatform: LungfishIO.SequencingPlatform
    /// Platform confirmed or overridden by the user.
    public let confirmedPlatform: LungfishIO.SequencingPlatform
    /// Whether the user picked ``confirmedPlatform``, or an archive record
    /// named it. `false` while the popup shows the detection: the import then
    /// runs with `--platform auto` and infers each sample from its reads.
    public var platformIsUserChoice: Bool
    /// Pairing mode shown in the sheet's Pairing popup.
    public let pairingMode: FASTQIngestionConfig.PairingMode
    /// Whether the user picked ``pairingMode``. `false` when the popup still
    /// shows the sheet's proposal: the import then runs with `--pairing auto`,
    /// which reads a lone file's records, and the bundle records the pairing
    /// as detected rather than chosen. Only a chosen `single_end` stops later
    /// tools from reading the records (`FASTQInputLayoutResolver`).
    public let pairingModeIsUserChoice: Bool
    /// Quality score binning scheme.
    public let qualityBinning: QualityBinningScheme
    /// Whether to skip clumpify (k-mer sorting). Useful for low-memory machines.
    public let skipClumpify: Bool
    /// Storage optimization tool selection.
    public let clumpingTool: ClumpingTool
    /// Whether to delete original files after successful ingestion.
    public let deleteOriginals: Bool
    /// Optional processing recipe to apply after ingestion (legacy format).
    public let postImportRecipe: ProcessingRecipe?
    /// Filled placeholder values for the recipe, keyed by placeholder key.
    public let resolvedPlaceholders: [String: String]
    /// V2 recipe identifier (e.g. "vsp2") to pass as `--recipe` to the CLI.
    /// Takes precedence over `postImportRecipe` when set.
    public let recipeName: String?
    /// Compression level for bgzip / clumpify output.
    public let compressionLevel: CompressionLevel?
    /// Optional subfolder name for ONT demultiplexing recipe outputs.
    public let demultiplexOutputFolderName: String?

    public init(
        inputFiles: [URL],
        detectedPlatform: LungfishIO.SequencingPlatform,
        confirmedPlatform: LungfishIO.SequencingPlatform,
        platformIsUserChoice: Bool = false,
        pairingMode: FASTQIngestionConfig.PairingMode,
        pairingModeIsUserChoice: Bool = true,
        qualityBinning: QualityBinningScheme,
        skipClumpify: Bool,
        clumpingTool: ClumpingTool = .default,
        deleteOriginals: Bool,
        postImportRecipe: ProcessingRecipe?,
        resolvedPlaceholders: [String: String],
        recipeName: String?,
        compressionLevel: CompressionLevel?,
        demultiplexOutputFolderName: String? = nil
    ) {
        self.inputFiles = inputFiles
        self.detectedPlatform = detectedPlatform
        self.confirmedPlatform = confirmedPlatform
        self.platformIsUserChoice = platformIsUserChoice
        self.pairingMode = pairingMode
        self.pairingModeIsUserChoice = pairingModeIsUserChoice
        self.qualityBinning = qualityBinning
        self.skipClumpify = skipClumpify
        self.clumpingTool = skipClumpify ? .none : clumpingTool
        self.deleteOriginals = deleteOriginals
        self.postImportRecipe = postImportRecipe
        self.resolvedPlaceholders = resolvedPlaceholders
        self.recipeName = recipeName
        self.compressionLevel = compressionLevel
        self.demultiplexOutputFolderName = demultiplexOutputFolderName
    }

    /// The `--platform` the CLI import receives: the chosen platform, or
    /// `auto` while nobody chose one. Never Illumina by default.
    public var cliPlatformValue: String {
        platformIsUserChoice ? confirmedPlatform.importCLIValue : ImportPlatformRequest.auto.cliValue
    }

    /// This configuration with an ENA or SRA record's platform recorded as
    /// given, when the user kept it. The download's own provenance names the
    /// record the value came from. An unknown record platform stays `auto`.
    public func namingArchivePlatform(_ platform: LungfishIO.SequencingPlatform) -> FASTQImportConfiguration {
        guard !platformIsUserChoice, platform != .unknown, confirmedPlatform == platform else { return self }
        var copy = self
        copy.platformIsUserChoice = true
        return copy
    }

    /// The `--pairing` the CLI import receives: the chosen mode, or `nil`
    /// (the CLI's `auto`) while the popup still shows the sheet's proposal.
    public var cliPairingMode: FASTQIngestionConfig.PairingMode? {
        pairingModeIsUserChoice ? pairingMode : nil
    }
}

enum FASTQDemultiplexOutputFolderName {
    static let fallback = "ONT Demultiplexed FASTQs"

    static func defaultName(for sourceURL: URL) -> String {
        let name = sourceURL.lastPathComponent
        let lowercased = name.lowercased()
        let suggested: String
        if lowercased == "fastq_pass"
            || lowercased.hasPrefix("barcode")
            || lowercased == "unclassified" {
            suggested = sourceURL.deletingLastPathComponent().lastPathComponent
        } else {
            suggested = sourceURL.deletingPathExtension().lastPathComponent
        }
        return sanitize(suggested)
    }

    static func sanitize(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        let sanitized = trimmed
            .replacingOccurrences(
                of: #"[^A-Za-z0-9 ._-]+"#,
                with: "-",
                options: .regularExpression
            )
            .trimmingCharacters(in: CharacterSet(charactersIn: " ._-"))
        return sanitized.isEmpty ? fallback : sanitized
    }
}

/// One sample of dropped read files, as `lungfish-cli import fastq` detects
/// it (``groupFASTQByPairs(_:)``), or as a sample sheet row names it.
public struct FASTQFilePair: Sendable {
    /// The R1 (forward) file, or the only file for single-end.
    public let r1: URL
    /// The R2 (reverse) file, if paired-end.
    public let r2: URL?
    /// The run's reads whose mate is missing, from the file a download names
    /// after the run alone beside `<run>_1` and `<run>_2`. The CLI imports
    /// them with the pair as unpaired reads. Nil for every other sample.
    public let unpaired: URL?
    /// Sample name supplied by an external sample sheet, or the name the
    /// CLI's detection gave the sample.
    public let sampleNameOverride: String?
    /// Optional sample-sheet metadata for this row.
    public let metadata: [String: String]
    /// CSV sample sheet that supplied this pair, when applicable.
    public let sampleSheetURL: URL?
    /// Why the CLI's detection left a file of another folder out of this
    /// sample, as `import fastq` prints it for the same files. The sheet runs
    /// the CLI once a sample, so no run sees the other folders, and the
    /// sample's Operations row logs these instead. Empty for every other
    /// sample.
    public let pairingNotices: [FASTQBatchImporter.PairingNotice]

    public init(
        r1: URL,
        r2: URL?,
        unpaired: URL? = nil,
        sampleNameOverride: String? = nil,
        metadata: [String: String] = [:],
        sampleSheetURL: URL? = nil,
        pairingNotices: [FASTQBatchImporter.PairingNotice] = []
    ) {
        self.r1 = r1
        self.r2 = r2
        self.unpaired = unpaired
        self.sampleNameOverride = sampleNameOverride
        self.metadata = metadata
        self.sampleSheetURL = sampleSheetURL
        self.pairingNotices = pairingNotices
    }

    /// A sample `lungfish-cli import fastq` detected, under the name the CLI
    /// gives it, with the notices detection gave about it.
    init(_ sample: SamplePair, pairingNotices: [FASTQBatchImporter.PairingNotice] = []) {
        self.init(
            r1: sample.r1, r2: sample.r2, unpaired: sample.unpaired, sampleNameOverride: sample.sampleName,
            metadata: sample.metadata, sampleSheetURL: sample.sampleSheetURL, pairingNotices: pairingNotices
        )
    }

    /// This sample as the CLI's detection holds it.
    var samplePair: SamplePair {
        SamplePair(
            sampleName: sampleName, r1: r1, r2: r2, unpaired: unpaired,
            metadata: metadata, sampleSheetURL: sampleSheetURL
        )
    }

    /// Every read file of the sample, R1, then R2, then the unpaired reads.
    public var inputFiles: [URL] {
        [r1] + [r2, unpaired].compactMap { $0 }
    }

    /// Applies the Import sheet's Pairing choice to detected samples.
    ///
    /// Single-end and Interleaved split every R1/R2 pair, and its unpaired
    /// reads, into single-file samples named after each file's stem with
    /// `FASTQBatchImporter.applyPairing`, the rule `--pairing single` and
    /// `--pairing interleaved` apply, so the sheet and the CLI make the same
    /// samples. Paired-end keeps the pairs. Each sample's files keep the
    /// sample's place in the list. A split sample keeps no pairing notice,
    /// as `import fastq` prints none for those choices.
    public static func applying(
        pairingMode: FASTQIngestionConfig.PairingMode,
        to pairs: [FASTQFilePair]
    ) -> [FASTQFilePair] {
        guard pairingMode != .pairedEnd else { return pairs }
        let pairing: FASTQBatchImporter.ImportPairing = pairingMode == .interleaved ? .interleaved : .single
        return pairs.flatMap { pair in
            FASTQBatchImporter.applyPairing(pairing, to: [pair.samplePair]).map { FASTQFilePair($0) }
        }
    }

    /// Human-readable sample name derived from the filename.
    public var sampleName: String {
        if let sampleNameOverride, !sampleNameOverride.isEmpty {
            return sampleNameOverride
        }
        var name = r1.deletingPathExtension().lastPathComponent
        // Strip .fastq from .fastq.gz
        if name.hasSuffix(".fastq") || name.hasSuffix(".fq") {
            name = (name as NSString).deletingPathExtension
        }
        // Strip read suffix to get the sample base name
        for suffix in ["_R1_001", "_R2_001", "_R1", "_R2", "_1", "_2", ".1", ".2"] {
            if name.hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count))
                break
            }
        }
        return name
    }

    /// The sample's files as the Import sheet's summary lists them, one
    /// `R1:`, `R2:` and `Unpaired:` line each.
    var summaryFileLines: String {
        var lines = ["R1: \(r1.lastPathComponent)"]
        if let r2 { lines.append("R2: \(r2.lastPathComponent)") }
        if let unpaired { lines.append("Unpaired: \(unpaired.lastPathComponent)") }
        return lines.joined(separator: "\n")
    }

    /// Total file size in bytes across the sample's files.
    public var totalSizeBytes: Int64 {
        inputFiles.reduce(Int64(0)) { total, url in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64
            return total + (size ?? 0)
        }
    }

    /// Whether this represents paired-end data.
    public var isPaired: Bool { r2 != nil }
}

// MARK: - Sample Detection

/// Groups dropped read files into the samples `lungfish-cli import fastq`
/// makes of the same files, with the CLI's own detection,
/// ``FASTQBatchImporter/detectPairs(from:)``, and under the CLI's names.
///
/// R1 and R2 files pair by `_R1_001`/`_R2_001`, `_R1`/`_R2` or `_1`/`_2`,
/// and a run's file of reads whose mate is missing, `<run>.fastq` beside
/// `<run>_1` and `<run>_2`, joins its pair as ``FASTQFilePair/unpaired``.
/// Files pair inside one folder first, and across folders only by names no
/// other dropped file has. Each sample keeps the notices detection gave
/// about it (``FASTQFilePair/pairingNotices``). The sheet imports each
/// sample's files in one CLI run, which checks that join from the first
/// reads. Any other file is a single-end sample named after its file, read
/// suffix included, as the CLI names it.
///
/// The sheet used to pair files by rules of its own and import each pair on
/// its own, so a run's three files became two samples and its reads whose
/// mate is missing never joined the pair, and a lone `x_1.fastq` was named
/// `x` where the CLI names it `x_1` (f9-report.md, concern 3).
public func groupFASTQByPairs(_ urls: [URL]) -> [FASTQFilePair] {
    let detection = FASTQBatchImporter.detectingPairs(from: urls)
    return detection.samples.map { sample in
        FASTQFilePair(sample, pairingNotices: detection.notices.filter { $0.r1 == sample.r1 })
    }
}
