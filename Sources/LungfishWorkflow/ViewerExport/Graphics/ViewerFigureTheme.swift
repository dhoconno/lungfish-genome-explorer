// ViewerFigureTheme.swift - Fixed sRGB colours for viewer figures
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import LungfishCore

/// The appearance a figure is drawn in.
public enum ViewerFigureAppearance: String, Sendable, Hashable, Codable, CaseIterable {
    case light
    case dark
}

/// One colour as sRGB components from 0 to 1.
public struct ViewerFigureColor: Sendable, Hashable, Codable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public init(white: Double, alpha: Double = 1) {
        self.init(red: white, green: white, blue: white, alpha: alpha)
    }

    /// An sRGB `HexColor` of LungfishCore, such as a `SemanticColors` entry.
    public init(_ hex: HexColor) {
        self.init(red: hex.red, green: hex.green, blue: hex.blue, alpha: hex.alpha)
    }

    /// The same colour with its alpha replaced, as `NSColor.withAlphaComponent(_:)` replaces it.
    public func withAlpha(_ alpha: Double) -> ViewerFigureColor {
        ViewerFigureColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// The colour in the sRGB space, the one space a figure draws in.
    public var cgColor: CGColor {
        CGColor(srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
    }
}

/// What a colour is for. A scene names a role and never a colour, so one scene draws in either
/// appearance.
///
/// The system roles carry the name of the AppKit colour the live viewer draws with, so code that
/// moves into this folder swaps `NSColor.secondaryLabelColor` for `.secondaryLabel`. Add a role
/// with its two values below and its live colour in `ViewerFigureThemeParityTests`, and never
/// change the value of a role a figure already uses.
public enum ViewerFigureColorRole: String, Sendable, Hashable, Codable, CaseIterable {
    /// `NSColor.textBackgroundColor`, the track area of the sequence viewer.
    case textBackground
    /// `NSColor.windowBackgroundColor`, the ruler band.
    case windowBackground
    /// `NSColor.separatorColor`, borders and the ruler's bottom line.
    case separator
    /// `NSColor.labelColor`, ruler labels and primary text.
    case label
    /// `NSColor.secondaryLabelColor`, major ticks and secondary text.
    case secondaryLabel
    /// `NSColor.tertiaryLabelColor`, minor ticks and faint text.
    case tertiaryLabel
    /// `NSColor.systemGray`, the sequence line when bases are too small to draw.
    case systemGray
    /// `NSColor.white`, letters drawn on a coloured base or feature.
    case textOnColor
    /// `BaseColors.A` of the live viewer.
    case baseA
    /// `BaseColors.C` of the live viewer.
    case baseC
    /// `BaseColors.G` of the live viewer.
    case baseG
    /// `BaseColors.T` of the live viewer, also used for U.
    case baseT
    /// `BaseColors.N` of the live viewer, also used for any other letter.
    case baseN

    // Roles of the read and variant track renderers (lane 13.29). The fixed ones carry the name
    // of the renderer constant they replace and hold one value in both appearances.

    /// `NSColor.controlBackgroundColor`, the masked-column veil of the read track.
    case controlBackground
    /// `NSColor.quaternarySystemFill`, the read overflow bar.
    case quaternarySystemFill
    /// `ReadTrackRenderer.forwardReadColor`.
    case forwardRead
    /// `ReadTrackRenderer.forwardReadStroke`.
    case forwardReadStroke
    /// `ReadTrackRenderer.reverseReadColor`.
    case reverseRead
    /// `ReadTrackRenderer.reverseReadStroke`.
    case reverseReadStroke
    /// `ReadTrackRenderer.forwardCoverageColor`, also the depth area and legend key.
    case forwardCoverage
    /// `ReadTrackRenderer.reverseCoverageColor`.
    case reverseCoverage
    /// `ReadTrackRenderer.matchDotColor`.
    case matchDot
    /// `ReadTrackRenderer.insertionColor`, ticks and insertion labels.
    case insertion
    /// `ReadTrackRenderer.deletionColor`, `NSColor.gray`.
    case deletion
    /// `ReadTrackRenderer.softClipColor`.
    case softClip
    /// `ReadTrackRenderer.insertNormalColor`.
    case insertNormal
    /// `ReadTrackRenderer.insertTooSmallColor`.
    case insertTooSmall
    /// `ReadTrackRenderer.insertTooLargeColor`.
    case insertTooLarge
    /// `ReadTrackRenderer.insertInterchromosomalColor`.
    case insertInterchromosomal
    /// `ReadTrackRenderer.insertAbnormalOrientationColor`.
    case insertAbnormalOrientation
    /// `ReadTrackRenderer.firstInPairColor`.
    case firstInPair
    /// `ReadTrackRenderer.secondInPairColor`.
    case secondInPair
    /// `ReadTrackRenderer.splitReadColor`.
    case splitRead
    /// `NSColor(white: 0.33, alpha: 1)`, the coverage outline.
    case coverageOutline
    /// `NSColor(white: 0.25, alpha: 1)`, the depth legend key's border.
    case coverageLegendStroke
    /// The forward read background of the base tier, `NSColor(red: 0.84, green: 0.89, blue: 0.95)`.
    case baseReadForwardBackground
    /// The reverse read background of the base tier, `NSColor(red: 0.95, green: 0.86, blue: 0.86)`.
    case baseReadReverseBackground
    /// The neutral read background of the base tier, `NSColor(red: 0.90, green: 0.90, blue: 0.90)`.
    case baseReadNeutralBackground
    /// The neutral read border of the base tier, `NSColor(red: 0.72, green: 0.72, blue: 0.72)`.
    case baseReadNeutralStroke
    /// `ReadTrackRenderer.intronColor`.
    case intron
    /// `NSColor(white: 0.6, alpha: 0.4)`, the line between mates.
    case mateLink
    /// `VariantTrackRenderer.gutterBackgroundColor`.
    case variantGutterBackground
    /// `VariantTrackRenderer.gutterSeparatorColor`.
    case variantGutterSeparator
    /// `VariantTrackRenderer.dataAreaBackgroundColor`.
    case variantDataBackground
    /// `VariantTrackRenderer.summaryBorderColor`.
    case variantSummaryBorder
    /// `VariantTrackRenderer.rowSeparatorColor`.
    case variantRowSeparator
    /// `VariantTrackRenderer.labelMarginColor`.
    case variantLabelMargin
    /// `VariantTrackRenderer.scrollTrackColor`.
    case variantScrollTrack
    /// `VariantTrackRenderer.scrollThumbColor`.
    case variantScrollThumb
    /// `SemanticColors.DNA.baseA`, a read mismatch, which is not `baseA` (`BaseColors.A`).
    case readBaseA
    /// `SemanticColors.DNA.baseC`, a read mismatch.
    case readBaseC
    /// `SemanticColors.DNA.baseG`, a read mismatch.
    case readBaseG
    /// `SemanticColors.DNA.baseT`, a read mismatch, also used for U.
    case readBaseT
    /// `SemanticColors.DNA.baseN`, a read mismatch at any other letter.
    case readBaseN

    // Annotation feature colours (lane 13.29 M3), one role for each `AnnotationType.defaultColor`
    // of LungfishCore, as the live viewer draws it through `NSColor(calibratedRed:...)`. The
    // figure's annotation track picks one with `ViewerFigureAnnotationColors.role(for:)`.

    /// `AnnotationType` `.gene`.
    case annotationGene
    /// `AnnotationType` `.mRNA`.
    case annotationMRNA
    /// `AnnotationType` `.transcript`.
    case annotationTranscript
    /// `AnnotationType` `.cds`.
    case annotationCDS
    /// `AnnotationType` `.orf`.
    case annotationORF
    /// `AnnotationType` `.translation`.
    case annotationTranslation
    /// `AnnotationType` `.exon`.
    case annotationExon
    /// `AnnotationType` `.intron`.
    case annotationIntron
    /// `AnnotationType` `.utr5` and `.utr3`.
    case annotationUTR
    /// `AnnotationType` `.tRNA`.
    case annotationTRNA
    /// `AnnotationType` `.rRNA`.
    case annotationRRNA
    /// `AnnotationType` `.region`.
    case annotationRegion
    /// `AnnotationType` `.promoter`.
    case annotationPromoter
    /// `AnnotationType` `.enhancer`.
    case annotationEnhancer
    /// `AnnotationType` `.silencer`.
    case annotationSilencer
    /// `AnnotationType` `.terminator`.
    case annotationTerminator
    /// `AnnotationType` `.polyASignal`.
    case annotationPolyASignal
    /// `AnnotationType` `.regulatory`.
    case annotationRegulatory
    /// `AnnotationType` `.ncRNA`.
    case annotationNcRNA
    /// `AnnotationType` `.primer` and `.primerPair`.
    case annotationPrimer
    /// `AnnotationType` `.restrictionSite`.
    case annotationRestrictionSite
    /// `AnnotationType` `.snp` and `.variation`.
    case annotationVariation
    /// `AnnotationType` `.insertion`.
    case annotationInsertion
    /// `AnnotationType` `.deletion`.
    case annotationDeletion
    /// `AnnotationType` `.repeatRegion`.
    case annotationRepeatRegion
    /// `AnnotationType` `.stem_loop`.
    case annotationStemLoop
    /// `AnnotationType` `.misc_feature`.
    case annotationMiscFeature
    /// `AnnotationType` `.pseudogene`.
    case annotationPseudogene
    /// `AnnotationType` `.mobileElement`.
    case annotationMobileElement
    /// `AnnotationType` `.mat_peptide`.
    case annotationMatPeptide
    /// `AnnotationType` `.sig_peptide`.
    case annotationSigPeptide
    /// `AnnotationType` `.transit_peptide`.
    case annotationTransitPeptide
    /// `AnnotationType` `.misc_binding`.
    case annotationMiscBinding
    /// `AnnotationType` `.protein_bind`.
    case annotationProteinBind
    /// `AnnotationType` `.amplicon`.
    case annotationAmplicon
    /// `AnnotationType` `.contig`.
    case annotationContig
    /// `AnnotationType` `.gap`.
    case annotationGap
    /// `AnnotationType` `.scaffold`.
    case annotationScaffold
    /// `AnnotationType` `.source`.
    case annotationSource
    /// `AnnotationType` `.custom`.
    case annotationCustom
    /// `AnnotationType` `.barcode5p`.
    case annotationBarcode5p
    /// `AnnotationType` `.barcode3p`.
    case annotationBarcode3p
    /// `AnnotationType` `.adapter5p`.
    case annotationAdapter5p
    /// `AnnotationType` `.adapter3p`.
    case annotationAdapter3p
    /// `AnnotationType` `.primer5p`.
    case annotationPrimer5p
    /// `AnnotationType` `.primer3p`.
    case annotationPrimer3p
    /// `AnnotationType` `.trimQuality`.
    case annotationTrimQuality
    /// `AnnotationType` `.trimFixed`.
    case annotationTrimFixed
    /// `AnnotationType` `.orientMarker`.
    case annotationOrientMarker
    /// `AnnotationType` `.umiRegion`.
    case annotationUmiRegion
    /// `AnnotationType` `.contaminantMatch`.
    case annotationContaminantMatch
    /// `NSColor.textColor`, annotation labels and strand arrows.
    case text
}

/// The colours of a figure in one appearance, fixed sRGB values and never a dynamic colour.
///
/// The values were measured from the live viewer's colours on macOS 26, resolved under the Aqua
/// and Dark Aqua appearances and converted to sRGB, and rounded to four places.
/// `ViewerFigureThemeParityTests` in LungfishAppWorkflowTests measures them again. The base
/// colours are the live `NSColor(calibratedRed:...)` values converted to sRGB, which is what the
/// viewer shows, rather than the calibrated components themselves.
public struct ViewerFigureTheme: Sendable, Hashable, Codable {
    public let appearance: ViewerFigureAppearance

    public init(appearance: ViewerFigureAppearance) {
        self.appearance = appearance
    }

    public static let light = ViewerFigureTheme(appearance: .light)
    public static let dark = ViewerFigureTheme(appearance: .dark)

    /// The colour of a role in this theme's appearance.
    public func color(_ role: ViewerFigureColorRole) -> ViewerFigureColor {
        switch appearance {
        case .light: Self.lightColor(role)
        case .dark: Self.darkColor(role)
        }
    }

    private static func lightColor(_ role: ViewerFigureColorRole) -> ViewerFigureColor {
        switch role {
        case .textBackground: ViewerFigureColor(white: 1)
        case .windowBackground: ViewerFigureColor(white: 1)
        case .separator: ViewerFigureColor(white: 0, alpha: 0.098)
        case .label: ViewerFigureColor(white: 0, alpha: 0.8471)
        case .secondaryLabel: ViewerFigureColor(white: 0, alpha: 0.498)
        case .tertiaryLabel: ViewerFigureColor(white: 0, alpha: 0.2588)
        case .systemGray: ViewerFigureColor(red: 0.5569, green: 0.5569, blue: 0.5765)
        case .textOnColor: Self.white
        case .baseA: Self.baseA
        case .baseC: Self.baseC
        case .baseG: Self.baseG
        case .baseT: Self.baseT
        case .baseN: Self.baseN
        case .controlBackground: ViewerFigureColor(white: 1)
        case .quaternarySystemFill: ViewerFigureColor(white: 0, alpha: 0.0275)
        case .text: ViewerFigureColor(white: 0)
        case .forwardRead, .forwardReadStroke, .reverseRead, .reverseReadStroke, .forwardCoverage, .reverseCoverage,
             .matchDot, .insertion, .deletion, .softClip, .insertNormal, .insertTooSmall, .insertTooLarge,
             .insertInterchromosomal, .insertAbnormalOrientation, .firstInPair, .secondInPair, .splitRead,
             .coverageOutline, .coverageLegendStroke, .baseReadForwardBackground, .baseReadReverseBackground,
             .baseReadNeutralBackground, .baseReadNeutralStroke, .intron, .mateLink, .variantGutterBackground,
             .variantGutterSeparator, .variantDataBackground, .variantSummaryBorder, .variantRowSeparator,
             .variantLabelMargin, .variantScrollTrack, .variantScrollThumb, .readBaseA, .readBaseC, .readBaseG,
             .readBaseT, .readBaseN, .annotationGene, .annotationMRNA, .annotationTranscript, .annotationCDS,
             .annotationORF, .annotationTranslation, .annotationExon, .annotationIntron, .annotationUTR,
             .annotationTRNA, .annotationRRNA, .annotationRegion, .annotationPromoter, .annotationEnhancer,
             .annotationSilencer, .annotationTerminator, .annotationPolyASignal, .annotationRegulatory,
             .annotationNcRNA, .annotationPrimer, .annotationRestrictionSite, .annotationVariation,
             .annotationInsertion, .annotationDeletion, .annotationRepeatRegion, .annotationStemLoop,
             .annotationMiscFeature, .annotationPseudogene, .annotationMobileElement, .annotationMatPeptide,
             .annotationSigPeptide, .annotationTransitPeptide, .annotationMiscBinding, .annotationProteinBind,
             .annotationAmplicon, .annotationContig, .annotationGap, .annotationScaffold, .annotationSource,
             .annotationCustom, .annotationBarcode5p, .annotationBarcode3p, .annotationAdapter5p,
             .annotationAdapter3p, .annotationPrimer5p, .annotationPrimer3p, .annotationTrimQuality,
             .annotationTrimFixed, .annotationOrientMarker, .annotationUmiRegion, .annotationContaminantMatch:
            Self.trackColor(role)
        }
    }

    private static func darkColor(_ role: ViewerFigureColorRole) -> ViewerFigureColor {
        switch role {
        case .textBackground: ViewerFigureColor(white: 0.1176)
        case .windowBackground: ViewerFigureColor(white: 0.1176)
        case .separator: ViewerFigureColor(white: 1, alpha: 0.098)
        case .label: ViewerFigureColor(white: 1, alpha: 0.8471)
        case .secondaryLabel: ViewerFigureColor(white: 1, alpha: 0.549)
        case .tertiaryLabel: ViewerFigureColor(white: 1, alpha: 0.2471)
        case .systemGray: ViewerFigureColor(red: 0.5961, green: 0.5961, blue: 0.6157)
        case .textOnColor: Self.white
        case .baseA: Self.baseA
        case .baseC: Self.baseC
        case .baseG: Self.baseG
        case .baseT: Self.baseT
        case .baseN: Self.baseN
        case .controlBackground: ViewerFigureColor(white: 0.1176)
        case .quaternarySystemFill: ViewerFigureColor(white: 1, alpha: 0.0275)
        case .text: ViewerFigureColor(white: 1)
        case .forwardRead, .forwardReadStroke, .reverseRead, .reverseReadStroke, .forwardCoverage, .reverseCoverage,
             .matchDot, .insertion, .deletion, .softClip, .insertNormal, .insertTooSmall, .insertTooLarge,
             .insertInterchromosomal, .insertAbnormalOrientation, .firstInPair, .secondInPair, .splitRead,
             .coverageOutline, .coverageLegendStroke, .baseReadForwardBackground, .baseReadReverseBackground,
             .baseReadNeutralBackground, .baseReadNeutralStroke, .intron, .mateLink, .variantGutterBackground,
             .variantGutterSeparator, .variantDataBackground, .variantSummaryBorder, .variantRowSeparator,
             .variantLabelMargin, .variantScrollTrack, .variantScrollThumb, .readBaseA, .readBaseC, .readBaseG,
             .readBaseT, .readBaseN, .annotationGene, .annotationMRNA, .annotationTranscript, .annotationCDS,
             .annotationORF, .annotationTranslation, .annotationExon, .annotationIntron, .annotationUTR,
             .annotationTRNA, .annotationRRNA, .annotationRegion, .annotationPromoter, .annotationEnhancer,
             .annotationSilencer, .annotationTerminator, .annotationPolyASignal, .annotationRegulatory,
             .annotationNcRNA, .annotationPrimer, .annotationRestrictionSite, .annotationVariation,
             .annotationInsertion, .annotationDeletion, .annotationRepeatRegion, .annotationStemLoop,
             .annotationMiscFeature, .annotationPseudogene, .annotationMobileElement, .annotationMatPeptide,
             .annotationSigPeptide, .annotationTransitPeptide, .annotationMiscBinding, .annotationProteinBind,
             .annotationAmplicon, .annotationContig, .annotationGap, .annotationScaffold, .annotationSource,
             .annotationCustom, .annotationBarcode5p, .annotationBarcode3p, .annotationAdapter5p,
             .annotationAdapter3p, .annotationPrimer5p, .annotationPrimer3p, .annotationTrimQuality,
             .annotationTrimFixed, .annotationOrientMarker, .annotationUmiRegion, .annotationContaminantMatch:
            Self.trackColor(role)
        }
    }

    /// The track colours that are the same in both appearances, as the renderers fixed them.
    private static func trackColor(_ role: ViewerFigureColorRole) -> ViewerFigureColor {
        trackColors[role] ?? ViewerFigureColor(white: 0, alpha: 0)
    }

    private static let trackColors: [ViewerFigureColorRole: ViewerFigureColor] = [
        .forwardRead: ViewerFigureColor(red: 0.69, green: 0.77, blue: 0.87),
        .forwardReadStroke: ViewerFigureColor(red: 0.55, green: 0.65, blue: 0.77),
        .reverseRead: ViewerFigureColor(red: 0.87, green: 0.69, blue: 0.69),
        .reverseReadStroke: ViewerFigureColor(red: 0.77, green: 0.55, blue: 0.55),
        .forwardCoverage: ViewerFigureColor(red: 0.42, green: 0.60, blue: 0.77, alpha: 0.7),
        .reverseCoverage: ViewerFigureColor(red: 0.77, green: 0.42, blue: 0.42, alpha: 0.7),
        .matchDot: ViewerFigureColor(white: 0.48, alpha: 0.82),
        .insertion: ViewerFigureColor(red: 0.8, green: 0, blue: 0.8),
        .deletion: ViewerFigureColor(white: 0.5),
        .softClip: ViewerFigureColor(red: 0.5, green: 0.6, blue: 0.75, alpha: 0.6),
        .insertNormal: ViewerFigureColor(white: 0.75),
        .insertTooSmall: ViewerFigureColor(red: 0, green: 0, blue: 0.85),
        .insertTooLarge: ViewerFigureColor(red: 0.85, green: 0, blue: 0),
        .insertInterchromosomal: ViewerFigureColor(red: 0.6, green: 0, blue: 0.85),
        .insertAbnormalOrientation: ViewerFigureColor(red: 0, green: 0.75, blue: 0.75),
        .firstInPair: ViewerFigureColor(red: 0.45, green: 0.45, blue: 0.85),
        .secondInPair: ViewerFigureColor(red: 0.85, green: 0.45, blue: 0.45),
        .splitRead: ViewerFigureColor(red: 1, green: 0.5, blue: 0, alpha: 0.8),
        .coverageOutline: ViewerFigureColor(white: 0.33),
        .coverageLegendStroke: ViewerFigureColor(white: 0.25),
        .baseReadForwardBackground: ViewerFigureColor(red: 0.84, green: 0.89, blue: 0.95),
        .baseReadReverseBackground: ViewerFigureColor(red: 0.95, green: 0.86, blue: 0.86),
        .baseReadNeutralBackground: ViewerFigureColor(white: 0.90),
        .baseReadNeutralStroke: ViewerFigureColor(white: 0.72),
        .intron: ViewerFigureColor(white: 0.5, alpha: 0.7),
        .mateLink: ViewerFigureColor(white: 0.6, alpha: 0.4),
        // The variant constants are `CGColor(red:green:blue:alpha:)`, generic RGB, so their sRGB
        // values are lighter than their components (0.96 is 0.9682).
        .variantGutterBackground: ViewerFigureColor(white: 0.9682),
        .variantGutterSeparator: ViewerFigureColor(white: 0.8541),
        .variantDataBackground: ViewerFigureColor(white: 0.9602),
        .variantSummaryBorder: ViewerFigureColor(white: 0.8374),
        .variantRowSeparator: ViewerFigureColor(white: 0.9198),
        .variantLabelMargin: ViewerFigureColor(white: 1),
        .variantScrollTrack: ViewerFigureColor(white: 0, alpha: 0.05),
        .variantScrollThumb: ViewerFigureColor(white: 0, alpha: 0.25),
        .readBaseA: ViewerFigureColor(SemanticColors.DNA.baseA),
        .readBaseC: ViewerFigureColor(SemanticColors.DNA.baseC),
        .readBaseG: ViewerFigureColor(SemanticColors.DNA.baseG),
        .readBaseT: ViewerFigureColor(SemanticColors.DNA.baseT),
        .readBaseN: ViewerFigureColor(SemanticColors.DNA.baseN),
        // `AnnotationType.defaultColor`, calibrated RGB converted to sRGB.
        .annotationGene: ViewerFigureColor(red: 0.2398, green: 0.6658, blue: 0.8382),
        .annotationMRNA: ViewerFigureColor(red: 0.2479, green: 0.5841, blue: 0.9209),
        .annotationTranscript: ViewerFigureColor(red: 0.4761, green: 0.488, blue: 0.7531),
        .annotationCDS: ViewerFigureColor(red: 0.844, green: 0.4811, blue: 0.2575),
        .annotationORF: ViewerFigureColor(red: 0.0809, green: 0.6065, blue: 0.3175),
        .annotationTranslation: ViewerFigureColor(red: 0.7157, green: 0.36, blue: 0.7958),
        .annotationExon: ViewerFigureColor(red: 0.6639, green: 0.6557, blue: 0.2579),
        .annotationIntron: ViewerFigureColor(red: 0.6662, green: 0.5715, blue: 0.4751),
        .annotationUTR: ViewerFigureColor(red: 0.759, green: 0.3848, blue: 0.3715),
        .annotationTRNA: ViewerFigureColor(red: 0.2297, green: 0.7438, blue: 0.6645),
        .annotationRRNA: ViewerFigureColor(red: 0.47, green: 0.6678, blue: 0.8381),
        .annotationRegion: ViewerFigureColor(red: 0.6199, green: 0.5718, blue: 0.5244),
        .annotationPromoter: ViewerFigureColor(red: 0.9249, green: 0.6611, blue: 0.1225),
        .annotationEnhancer: ViewerFigureColor(red: 0.8815, green: 0.7452, blue: 0.256),
        .annotationSilencer: ViewerFigureColor(red: 0.756, green: 0.5696, blue: 0.2577),
        .annotationTerminator: ViewerFigureColor(red: 0.6681, green: 0.4773, blue: 0.3717),
        .annotationPolyASignal: ViewerFigureColor(red: 0.8418, green: 0.6158, blue: 0.1942),
        .annotationRegulatory: ViewerFigureColor(red: 0.9673, green: 0.5753, blue: 0.1225),
        .annotationNcRNA: ViewerFigureColor(red: 0.3555, green: 0.7422, blue: 0.5723),
        .annotationPrimer: ViewerFigureColor(red: 0.2177, green: 0.8194, blue: 0.2584),
        .annotationRestrictionSite: ViewerFigureColor(red: 0.846, green: 0.2873, blue: 0.2579),
        .annotationVariation: ViewerFigureColor(red: 0.8464, green: 0.3266, blue: 0.8379),
        .annotationInsertion: ViewerFigureColor(red: 0.2287, green: 0.7378, blue: 0.3719),
        .annotationDeletion: ViewerFigureColor(red: 0.9286, green: 0.3935, blue: 0.3707),
        .annotationRepeatRegion: ViewerFigureColor(red: 0.6699, green: 0.3948, blue: 0.6645),
        .annotationStemLoop: ViewerFigureColor(red: 0.5695, green: 0.6575, blue: 0.4751),
        .annotationMiscFeature: ViewerFigureColor(red: 0.6188, green: 0.6188, blue: 0.6188),
        .annotationPseudogene: ViewerFigureColor(red: 0.5725, green: 0.5774, blue: 0.7091),
        .annotationMobileElement: ViewerFigureColor(red: 0.758, green: 0.4951, blue: 0.7527),
        .annotationMatPeptide: ViewerFigureColor(red: 0.7601, green: 0.2973, blue: 0.5722),
        .annotationSigPeptide: ViewerFigureColor(red: 0.5628, green: 0.8231, blue: 0.3709),
        .annotationTransitPeptide: ViewerFigureColor(red: 0.3663, green: 0.5763, blue: 0.7531),
        .annotationMiscBinding: ViewerFigureColor(red: 0.6686, green: 0.4975, blue: 0.8381),
        .annotationProteinBind: ViewerFigureColor(red: 0.4785, green: 0.3951, blue: 0.7531),
        .annotationAmplicon: ViewerFigureColor(red: 0.3607, green: 0.653, blue: 0.372),
        .annotationContig: ViewerFigureColor(red: 0.5248, green: 0.5281, blue: 0.6191),
        .annotationGap: ViewerFigureColor(red: 0.6642, green: 0.6642, blue: 0.6642),
        .annotationScaffold: ViewerFigureColor(red: 0.5734, green: 0.5241, blue: 0.4754),
        .annotationSource: ViewerFigureColor(red: 0.4756, green: 0.4756, blue: 0.4756),
        .annotationCustom: ViewerFigureColor(red: 0.5723, green: 0.5723, blue: 0.5723),
        .annotationBarcode5p: ViewerFigureColor(red: 0, green: 0.7857, blue: 0.7092),
        .annotationBarcode3p: ViewerFigureColor(red: 0, green: 0.6569, blue: 0.6192),
        .annotationAdapter5p: ViewerFigureColor(red: 0.9679, green: 0.53, blue: 0),
        .annotationAdapter3p: ViewerFigureColor(red: 0.8866, green: 0.4337, blue: 0),
        .annotationPrimer5p: ViewerFigureColor(red: 0.0297, green: 0.7352, blue: 0.1289),
        .annotationPrimer3p: ViewerFigureColor(red: 0, green: 0.6041, blue: 0.0516),
        .annotationTrimQuality: ViewerFigureColor(red: 0.7948, green: 0.7836, blue: 0),
        .annotationTrimFixed: ViewerFigureColor(red: 0.7083, green: 0.699, blue: 0.1948),
        .annotationOrientMarker: ViewerFigureColor(red: 0.6713, green: 0.3169, blue: 0.8382),
        .annotationUmiRegion: ViewerFigureColor(red: 0.9301, green: 0.2323, blue: 0.6641),
        .annotationContaminantMatch: ViewerFigureColor(red: 0.9298, green: 0.1951, blue: 0.1254),
    ]

    // Colours that are the same in both appearances.
    private static let white = ViewerFigureColor(white: 1)
    private static let baseA = ViewerFigureColor(red: 0, green: 0.8178, blue: 0)
    private static let baseC = ViewerFigureColor(red: 0.0113, green: 0.1593, blue: 0.8386)
    private static let baseG = ViewerFigureColor(red: 1, green: 0.7473, blue: 0)
    private static let baseT = ViewerFigureColor(red: 0.8467, green: 0.1176, blue: 0)
    private static let baseN = ViewerFigureColor(white: 0.6003)

    /// The colour role of a base letter, as `BaseColors.color(for:)` picks it.
    public static func baseRole(for base: Character) -> ViewerFigureColorRole {
        switch base.uppercased().first {
        case "A": .baseA
        case "C": .baseC
        case "G": .baseG
        case "T", "U": .baseT
        default: .baseN
        }
    }
}
