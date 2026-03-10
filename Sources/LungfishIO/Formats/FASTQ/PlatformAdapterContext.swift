// PlatformAdapterContext.swift - Platform-specific adapter+barcode construct builders
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

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
    case pacbioStandard     // PacBio barcoded adapters
    case custom             // User-defined
}

// MARK: - ONT Native Barcoding Context

/// Adapter context for ONT Native Barcoding kits (SQK-NBD104, SQK-NBD114, etc.).
///
/// Read structure:
/// ```
/// 5'-[Y-adapter]-[AAGGTTAA]-[Barcode_Fwd]-[INSERT]-[Barcode_RC]-[TTAACCTT]-[Y-adapter_RC]-3'
/// ```
/// The outer flanks (AAGGTTAA / TTAACCTT) are part of the ONT adapter construct.
/// Primer flanks (e.g. CAGCACCT) are NOT included — they belong to a
/// separate primer-trimming step, not demultiplexing.
public struct ONTNativeAdapterContext: PlatformAdapterContext {
    public init() {}

    public func fivePrimeSpec(barcodeSequence: String) -> String {
        PlatformAdapters.ontYAdapterTop
            + PlatformAdapters.ontNativeOuterFlank5
            + barcodeSequence.uppercased()
    }

    public func threePrimeSpec(barcodeSequence: String) -> String {
        PlatformAdapters.reverseComplement(barcodeSequence)
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

// MARK: - Illumina TruSeq Context

/// Adapter context for Illumina TruSeq-compatible kits.
///
/// Used for post-demux adapter read-through trimming only.
/// Also applies to Element AVITI and Ultima Genomics (TruSeq-compatible adapters).
public struct IlluminaTruSeqAdapterContext: PlatformAdapterContext {
    public init() {}

    public func fivePrimeSpec(barcodeSequence: String) -> String {
        // No 5' adapter in Illumina read-through
        ""
    }

    public func threePrimeSpec(barcodeSequence: String) -> String {
        PlatformAdapters.truseqR1
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
            return PacBioAdapterContext()
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
