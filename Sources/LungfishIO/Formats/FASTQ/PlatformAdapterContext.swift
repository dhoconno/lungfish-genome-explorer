// PlatformAdapterContext.swift - Platform-specific adapter+barcode construct builders
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Read Direction

/// Which read in a paired-end sequencing run.
///
/// For single-end or long-read data, always use `.read1`.
/// For paired-end short-read adapter trimming, `.read2` selects
/// the platform-specific R2 adapter sequence.
public enum ReadDirection: String, Codable, Sendable, CaseIterable {
    case read1
    case read2
}

// MARK: - Protocol

/// Constructs the full cutadapt adapter specification for a barcode,
/// including platform-specific flanking and adapter sequences.
///
/// Each implementation wraps bare barcode sequences with the appropriate
/// constant regions for its platform, enabling single-pass adapter+barcode
/// trimming in cutadapt.
public protocol PlatformAdapterContext: Sendable {
    /// Build the 5' adapter construct for cutadapt (`-g` flag).
    func fivePrimeSpec(barcodeSequence: String) -> String

    /// Build the 3' adapter construct for cutadapt (`-a` flag).
    func threePrimeSpec(barcodeSequence: String) -> String

    /// Build a linked adapter spec (`5'...3'`) for cutadapt.
    func linkedSpec(barcodeSequence: String) -> String

    /// The 3' adapter sequence for a specific read direction.
    ///
    /// Short-read platforms use different adapter sequences for R1 vs R2.
    /// Long-read platforms return the same sequence for both directions.
    /// Default implementation delegates to `threePrimeSpec`.
    func threePrimeSpec(barcodeSequence: String, readDirection: ReadDirection) -> String
}

extension PlatformAdapterContext {
    /// Default: both directions use the same 3' spec.
    public func threePrimeSpec(barcodeSequence: String, readDirection: ReadDirection) -> String {
        threePrimeSpec(barcodeSequence: barcodeSequence)
    }
}

// MARK: - BarcodeKitType

/// Classification of barcode kit types, used to select the correct adapter context.
public enum BarcodeKitType: String, Codable, Sendable, CaseIterable {
    case nativeBarcoding    // ONT SQK-NBD*
    case rapidBarcoding     // ONT SQK-RBK*
    case pcrBarcoding       // ONT SQK-PCB*, EXP-PBC*
    case sixteenS           // ONT 16S barcoding kits
    case truseq             // Illumina TruSeq
    case nextera            // Illumina Nextera / DNA Prep
    case pacbioStandard     // PacBio barcoded adapters (CCS/HiFi, bare barcodes)
    case pacbioM13Amplicon  // PacBio barcoded amplicon with M13 universal primers
    case custom             // User-defined
}

// MARK: - ONT Native Barcoding Context

/// Adapter context for ONT Native Barcoding kits (SQK-NBD104, SQK-NBD114, etc.).
///
/// Read structure:
/// ```
/// 5'-[Y-adapter]-[AAGGTTAA]-[Barcode_Fwd]-[CAGCACCT]-[INSERT]-[AGGTGCTG]-[Barcode_RC]-[TTAACCTT]-[Y-adapter_RC]-3'
/// ```
/// The outer flanks (AAGGTTAA / TTAACCTT) are part of the ONT adapter construct.
/// The rear flanks (CAGCACCT / AGGTGCTG) sit between the barcode and insert DNA.
/// They are concatenated into the adapter definition so cutadapt trims both in a
/// single pass — this is more robust to indels than a separate flank-trimming step.
/// See `docs/research/cutadapt-demux-pipeline-spec.md` for benchmarking details.
public struct ONTNativeAdapterContext: PlatformAdapterContext {
    public init() {}

    public func fivePrimeSpec(barcodeSequence: String) -> String {
        PlatformAdapters.ontYAdapterTop
            + PlatformAdapters.ontNativeOuterFlank5
            + barcodeSequence.uppercased()
            + PlatformAdapters.ontNativeBarcodeFlank5
    }

    public func threePrimeSpec(barcodeSequence: String) -> String {
        PlatformAdapters.ontNativeBarcodeFlank3
            + PlatformAdapters.reverseComplement(barcodeSequence)
            + PlatformAdapters.ontNativeOuterFlank3
            + PlatformAdapters.ontYAdapterBottom
    }

    public func linkedSpec(barcodeSequence: String) -> String {
        fivePrimeSpec(barcodeSequence: barcodeSequence)
            + "..."
            + threePrimeSpec(barcodeSequence: barcodeSequence)
    }
}

// MARK: - ONT Rapid Barcoding Context

/// Adapter context for ONT Rapid Barcoding kits (SQK-RBK114, etc.).
///
/// Read structure:
/// ```
/// 5'-[Rapid Adapter]-[Barcode_Fwd]-[ME]-[INSERT]-[ME_RC]-[Barcode_RC]-[Rapid Adapter_RC]-3'
/// ```
public struct ONTRapidAdapterContext: PlatformAdapterContext {
    public init() {}

    public func fivePrimeSpec(barcodeSequence: String) -> String {
        PlatformAdapters.ontRapidAdapter
            + barcodeSequence.uppercased()
            + PlatformAdapters.ontTransposaseME
    }

    public func threePrimeSpec(barcodeSequence: String) -> String {
        PlatformAdapters.ontTransposaseMErc
            + PlatformAdapters.reverseComplement(barcodeSequence)
    }

    public func linkedSpec(barcodeSequence: String) -> String {
        fivePrimeSpec(barcodeSequence: barcodeSequence)
            + "..."
            + threePrimeSpec(barcodeSequence: barcodeSequence)
    }
}

// MARK: - PacBio HiFi Context

/// Adapter context for PacBio HiFi/CCS reads.
///
/// CCS processing already removes SMRTbell adapters. Only barcodes remain
/// flanking the insert: `[barcode_fwd]-[INSERT]-[barcode_rc]`.
public struct PacBioAdapterContext: PlatformAdapterContext {
    public init() {}

    public func fivePrimeSpec(barcodeSequence: String) -> String {
        barcodeSequence.uppercased()
    }

    public func threePrimeSpec(barcodeSequence: String) -> String {
        PlatformAdapters.reverseComplement(barcodeSequence)
    }

    public func linkedSpec(barcodeSequence: String) -> String {
        barcodeSequence.uppercased()
            + "..."
            + PlatformAdapters.reverseComplement(barcodeSequence)
    }
}

// MARK: - PacBio M13 Barcoded Amplicon Context

/// Adapter context for PacBio barcoded amplicon kits using M13 universal primers.
///
/// Used when PacBio barcodes are combined with M13 universal primer tails in
/// amplicon sequencing workflows. The M13 primer sits between the barcode and
/// the gene-specific primer:
/// ```
/// 5'-[barcode_fwd]-[M13F]-[gene_primer]-[amplicon]-[gene_primer]-[M13R_RC]-[barcode_rc]-3'
/// ```
///
/// For **demultiplexing** (barcode assignment), only the bare barcode is used in the
/// adapter spec — including flanking context reduces matching accuracy (validated
/// empirically: 56.5% with bare barcodes vs 25-27% with flanking context).
///
/// For **trimming** (removing adapter/primer from exported reads), the spec includes
/// both the barcode AND the M13 primer so cutadapt trims the full construct.
public struct PacBioM13AdapterContext: PlatformAdapterContext {
    /// When true, include M13 primer in the adapter spec for trimming.
    /// When false, use bare barcodes only (better for demux matching accuracy).
    public let includePrimerInSpec: Bool

    public init(includePrimerInSpec: Bool = false) {
        self.includePrimerInSpec = includePrimerInSpec
    }

    public func fivePrimeSpec(barcodeSequence: String) -> String {
        if includePrimerInSpec {
            return barcodeSequence.uppercased() + PlatformAdapters.m13Forward
        }
        return barcodeSequence.uppercased()
    }

    public func threePrimeSpec(barcodeSequence: String) -> String {
        if includePrimerInSpec {
            return PlatformAdapters.m13ReverseRC + PlatformAdapters.reverseComplement(barcodeSequence)
        }
        return PlatformAdapters.reverseComplement(barcodeSequence)
    }

    public func linkedSpec(barcodeSequence: String) -> String {
        fivePrimeSpec(barcodeSequence: barcodeSequence)
            + "..."
            + threePrimeSpec(barcodeSequence: barcodeSequence)
    }
}

// MARK: - Illumina TruSeq Context

/// Adapter context for Illumina TruSeq-compatible kits.
///
/// Used for post-demux adapter read-through trimming only.
/// Also applies to Element AVITI and Ultima Genomics (TruSeq-compatible adapters).
public struct IlluminaTruSeqAdapterContext: PlatformAdapterContext {
    public init() {}

    public func fivePrimeSpec(barcodeSequence: String) -> String {
        ""
    }

    public func threePrimeSpec(barcodeSequence: String) -> String {
        PlatformAdapters.truseqR1
    }

    public func threePrimeSpec(barcodeSequence: String, readDirection: ReadDirection) -> String {
        switch readDirection {
        case .read1: return PlatformAdapters.truseqR1
        case .read2: return PlatformAdapters.truseqR2
        }
    }

    public func linkedSpec(barcodeSequence: String) -> String {
        threePrimeSpec(barcodeSequence: barcodeSequence)
    }
}

// MARK: - Illumina Nextera Context

/// Adapter context for Illumina Nextera / DNA Prep kits.
public struct IlluminaNexteraAdapterContext: PlatformAdapterContext {
    public init() {}

    public func fivePrimeSpec(barcodeSequence: String) -> String {
        ""
    }

    public func threePrimeSpec(barcodeSequence: String) -> String {
        PlatformAdapters.nexteraR1
    }

    public func threePrimeSpec(barcodeSequence: String, readDirection: ReadDirection) -> String {
        switch readDirection {
        case .read1: return PlatformAdapters.nexteraR1
        case .read2: return PlatformAdapters.nexteraR2
        }
    }

    public func linkedSpec(barcodeSequence: String) -> String {
        threePrimeSpec(barcodeSequence: barcodeSequence)
    }
}

// MARK: - MGI / DNBSEQ Context

/// Adapter context for MGI/DNBSEQ platforms.
///
/// MGI has distinct adapter sequences from Illumina.
/// Demux is handled by zebracallV2; app does adapter read-through trimming only.
public struct MGIAdapterContext: PlatformAdapterContext {
    public init() {}

    public func fivePrimeSpec(barcodeSequence: String) -> String {
        ""
    }

    public func threePrimeSpec(barcodeSequence: String) -> String {
        PlatformAdapters.mgiR1
    }

    public func threePrimeSpec(barcodeSequence: String, readDirection: ReadDirection) -> String {
        switch readDirection {
        case .read1: return PlatformAdapters.mgiR1
        case .read2: return PlatformAdapters.mgiR2
        }
    }

    public func linkedSpec(barcodeSequence: String) -> String {
        threePrimeSpec(barcodeSequence: barcodeSequence)
    }
}

// MARK: - Bare Context (Custom Kits)

/// No flanking context — bare barcode sequences for custom or unknown kits.
public struct BareAdapterContext: PlatformAdapterContext {
    public init() {}

    public func fivePrimeSpec(barcodeSequence: String) -> String {
        barcodeSequence.uppercased()
    }

    public func threePrimeSpec(barcodeSequence: String) -> String {
        PlatformAdapters.reverseComplement(barcodeSequence)
    }

    public func linkedSpec(barcodeSequence: String) -> String {
        barcodeSequence.uppercased()
            + "..."
            + PlatformAdapters.reverseComplement(barcodeSequence)
    }
}

// MARK: - Factory

extension SequencingPlatform {
    /// Returns the appropriate adapter context for a kit on this platform.
    public func adapterContext(kitType: BarcodeKitType = .custom) -> any PlatformAdapterContext {
        switch self {
        case .oxfordNanopore:
            switch kitType {
            case .nativeBarcoding, .pcrBarcoding, .sixteenS:
                return ONTNativeAdapterContext()
            case .rapidBarcoding:
                return ONTRapidAdapterContext()
            default:
                return ONTNativeAdapterContext()
            }
        case .pacbio:
            switch kitType {
            case .pacbioM13Amplicon:
                return PacBioM13AdapterContext(includePrimerInSpec: false)
            default:
                return PacBioAdapterContext()
            }
        case .illumina:
            switch kitType {
            case .nextera: return IlluminaNexteraAdapterContext()
            default:       return IlluminaTruSeqAdapterContext()
            }
        case .element:
            return IlluminaTruSeqAdapterContext()
        case .ultima:
            return IlluminaTruSeqAdapterContext()
        case .mgi:
            return MGIAdapterContext()
        case .unknown:
            return BareAdapterContext()
        }
    }
}
