// BarcodeKitDefinition.swift - A barcode kit definition for demultiplexing, supporting single
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// A barcode kit definition for demultiplexing, supporting single- and dual-indexed kits.
public struct BarcodeKitDefinition: Codable, Sendable, Equatable, Identifiable {
    /// Unique identifier (e.g., "truseq-single-a").
    public let id: String

    /// Human-readable name (e.g., "TruSeq Single Index Set A").
    public let displayName: String

    /// Vendor name.
    public let vendor: String

    /// Sequencing platform this kit belongs to.
    public let platform: SequencingPlatform

    /// Kit type classification for selecting the correct adapter context.
    public let kitType: BarcodeKitType

    /// Whether this kit uses dual indexing (i5 + i7).
    public let isDualIndexed: Bool

    /// Pairing strategy for barcode assignment.
    public let pairingMode: BarcodePairingMode

    /// Individual barcode entries.
    public let barcodes: [BarcodeEntry]

    public init(
        id: String,
        displayName: String,
        vendor: String = "illumina",
        platform: SequencingPlatform? = nil,
        kitType: BarcodeKitType = .custom,
        isDualIndexed: Bool = false,
        pairingMode: BarcodePairingMode? = nil,
        barcodes: [BarcodeEntry]
    ) {
        self.id = id
        self.displayName = displayName
        self.vendor = vendor
        self.platform = platform ?? SequencingPlatform(vendor: vendor)
        self.kitType = kitType
        self.isDualIndexed = isDualIndexed
        self.pairingMode = pairingMode ?? (isDualIndexed ? .fixedDual : .singleEnd)
        self.barcodes = barcodes
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case vendor
        case platform
        case kitType
        case isDualIndexed
        case pairingMode
        case barcodes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        vendor = try container.decodeIfPresent(String.self, forKey: .vendor) ?? "illumina"
        platform = try container.decodeIfPresent(SequencingPlatform.self, forKey: .platform)
            ?? SequencingPlatform(vendor: vendor)
        kitType = try container.decodeIfPresent(BarcodeKitType.self, forKey: .kitType) ?? .custom
        isDualIndexed = try container.decodeIfPresent(Bool.self, forKey: .isDualIndexed) ?? false
        pairingMode = try container.decodeIfPresent(BarcodePairingMode.self, forKey: .pairingMode)
            ?? (isDualIndexed ? .fixedDual : .singleEnd)
        barcodes = try container.decode([BarcodeEntry].self, forKey: .barcodes)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(vendor, forKey: .vendor)
        try container.encode(platform, forKey: .platform)
        try container.encode(kitType, forKey: .kitType)
        try container.encode(isDualIndexed, forKey: .isDualIndexed)
        try container.encode(pairingMode, forKey: .pairingMode)
        try container.encode(barcodes, forKey: .barcodes)
    }

    /// True for long-read kits whose cutadapt search uses the platform's full
    /// adapter+barcode construct (ONT native, rapid, PCR and 16S kits, and
    /// other symmetric or single-barcode ONT/PacBio kits). The demultiplexing
    /// pipeline searches that construct at both read ends in both orientations
    /// and, for symmetric kits, keeps only reads carrying the same barcode at
    /// both ends. The barcode location and 5'/3' distance settings shape
    /// anchored short-read adapter specs and do not apply to these kits.
    public var searchesFullPlatformConstruct: Bool {
        platform.readsCanBeReverseComplemented
            && (pairingMode == .symmetric || pairingMode == .singleEnd)
    }

    /// Returns the platform-specific adapter context for this kit.
    public var adapterContext: any PlatformAdapterContext {
        platform.adapterContext(kitType: kitType)
    }
}
