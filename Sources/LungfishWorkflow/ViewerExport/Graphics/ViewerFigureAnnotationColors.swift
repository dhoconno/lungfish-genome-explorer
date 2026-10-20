// ViewerFigureAnnotationColors.swift - The colour role of each annotation type
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishCore

/// The colour roles of the figure's annotation track. A feature fills with its type's role at
/// alpha 0.7 and strokes it at full alpha, and a density bar uses alpha 0.6, as the live viewer's
/// `cachedColors(for:)` and `cachedDensityColor(for:)` do with `AnnotationType.defaultColor`.
public enum ViewerFigureAnnotationColors {
    /// The alpha of a feature's fill.
    public static let fillAlpha = 0.7
    /// The alpha of a density bar.
    public static let densityAlpha = 0.6

    /// The role that stands for `type.defaultColor`.
    public static func role(for type: AnnotationType) -> ViewerFigureColorRole {
        switch type {
        case .gene: .annotationGene
        case .mRNA: .annotationMRNA
        case .transcript: .annotationTranscript
        case .cds: .annotationCDS
        case .orf: .annotationORF
        case .translation: .annotationTranslation
        case .exon: .annotationExon
        case .intron: .annotationIntron
        case .utr5, .utr3: .annotationUTR
        case .tRNA: .annotationTRNA
        case .rRNA: .annotationRRNA
        case .region: .annotationRegion
        case .promoter: .annotationPromoter
        case .enhancer: .annotationEnhancer
        case .silencer: .annotationSilencer
        case .terminator: .annotationTerminator
        case .polyASignal: .annotationPolyASignal
        case .regulatory: .annotationRegulatory
        case .ncRNA: .annotationNcRNA
        case .primer, .primerPair: .annotationPrimer
        case .restrictionSite: .annotationRestrictionSite
        case .snp, .variation: .annotationVariation
        case .insertion: .annotationInsertion
        case .deletion: .annotationDeletion
        case .repeatRegion: .annotationRepeatRegion
        case .stem_loop: .annotationStemLoop
        case .misc_feature: .annotationMiscFeature
        case .pseudogene: .annotationPseudogene
        case .mobileElement: .annotationMobileElement
        case .mat_peptide: .annotationMatPeptide
        case .sig_peptide: .annotationSigPeptide
        case .transit_peptide: .annotationTransitPeptide
        case .misc_binding: .annotationMiscBinding
        case .protein_bind: .annotationProteinBind
        case .amplicon: .annotationAmplicon
        case .contig: .annotationContig
        case .gap: .annotationGap
        case .scaffold: .annotationScaffold
        case .source: .annotationSource
        case .custom: .annotationCustom
        case .barcode5p: .annotationBarcode5p
        case .barcode3p: .annotationBarcode3p
        case .adapter5p: .annotationAdapter5p
        case .adapter3p: .annotationAdapter3p
        case .primer5p: .annotationPrimer5p
        case .primer3p: .annotationPrimer3p
        case .trimQuality: .annotationTrimQuality
        case .trimFixed: .annotationTrimFixed
        case .orientMarker: .annotationOrientMarker
        case .umiRegion: .annotationUmiRegion
        case .contaminantMatch: .annotationContaminantMatch
        }
    }
}
