// TaxaCollection.swift - Classifier-agnostic taxa collection for batch extraction
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - TaxonTarget

/// A single taxon to extract within a collection.
///
/// Each target specifies an organism by NCBI Taxonomy ID. When
/// ``includeChildren`` is `true`, reads classified to any descendant
/// taxon are also extracted (genus-level extraction). When `false`,
/// only exact matches are extracted (species-level).
public struct TaxonTarget: Sendable, Codable, Hashable, Identifiable {
    public var id: Int { taxId }

    /// Scientific name of the organism.
    public let name: String

    /// NCBI Taxonomy ID.
    public let taxId: Int

    /// Whether to include descendant taxa in extraction.
    public let includeChildren: Bool

    /// Common name (if different from scientific name).
    public let commonName: String?

    public init(name: String, taxId: Int, includeChildren: Bool = true, commonName: String? = nil) {
        self.name = name
        self.taxId = taxId
        self.includeChildren = includeChildren
        self.commonName = commonName
    }

    /// Display name — uses common name if available, otherwise scientific name.
    public var displayName: String {
        commonName ?? name
    }
}

// MARK: - CollectionTier

/// Where a taxa collection is stored and who can modify it.
public enum CollectionTier: String, Sendable, Codable, CaseIterable {
    /// Shipped with the app. Read-only. Available to all users.
    case builtin

    /// User-defined, saved in app preferences. Available across all projects.
    case appWide

    /// Saved within a specific project directory. Only for that project.
    case project
}

// MARK: - TaxaCollection

/// A named collection of taxa for batch sequence extraction.
///
/// Collections are **classifier-agnostic** — the same collection works with
/// Kraken2, STAT, GOTTCHA2, or any future classifier that produces
/// taxonomy-based read assignments.
///
/// Each taxon in a collection extracts to its own FASTQ file. For example,
/// the "Respiratory Viruses" collection extracts Influenza A reads to one file,
/// RSV reads to another, SARS-CoV-2 to a third, etc.
///
/// ## Tiers
///
/// Collections exist at three levels:
/// - **Built-in**: Pre-defined, read-only, shipped with the app
/// - **App-wide**: User-created, stored in `~/Library/Application Support/Lungfish/`
/// - **Project-specific**: Stored in the `.lungfish` project directory
///
/// ## Usage
///
/// ```swift
/// let respiratory = TaxaCollection.builtIn.first { $0.id == "respiratory-viruses" }!
/// for target in respiratory.taxa {
///     // Extract reads matching target.taxId (with children if specified)
/// }
/// ```
public struct TaxaCollection: Sendable, Codable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let description: String
    public let sfSymbol: String
    public let taxa: [TaxonTarget]
    public let tier: CollectionTier

    public init(
        id: String, name: String, description: String,
        sfSymbol: String, taxa: [TaxonTarget], tier: CollectionTier = .builtin
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.sfSymbol = sfSymbol
        self.taxa = taxa
        self.tier = tier
    }

    /// Number of taxa in this collection.
    public var taxonCount: Int { taxa.count }

    // MARK: - Built-in Collections

    /// All built-in taxa collections shipped with the app.
    public static let builtIn: [TaxaCollection] = [
        respiratoryViruses,
        entericViruses,
        respiratoryBacteria,
        amrOrganisms,
        wastewaterSurveillance,
        stiPathogens,
        vectorBornePathogens,
        fungalPathogens,
    ]

    // MARK: - Respiratory Viruses

    public static let respiratoryViruses = TaxaCollection(
        id: "respiratory-viruses",
        name: "Respiratory Viruses",
        description: "Common viral respiratory pathogens including influenza, RSV, coronaviruses, and rhinoviruses",
        sfSymbol: "lungs",
        taxa: [
            TaxonTarget(name: "Influenza A virus", taxId: 11320, includeChildren: true, commonName: "Influenza A"),
            TaxonTarget(name: "Influenza B virus", taxId: 11520, includeChildren: true, commonName: "Influenza B"),
            TaxonTarget(name: "Respiratory syncytial virus", taxId: 12814, includeChildren: true, commonName: "RSV"),
            TaxonTarget(name: "Severe acute respiratory syndrome coronavirus 2", taxId: 2697049, includeChildren: true, commonName: "SARS-CoV-2"),
            TaxonTarget(name: "Human coronavirus 229E", taxId: 11137, includeChildren: true, commonName: "HCoV-229E"),
            TaxonTarget(name: "Human coronavirus OC43", taxId: 31631, includeChildren: true, commonName: "HCoV-OC43"),
            TaxonTarget(name: "Human coronavirus NL63", taxId: 277944, includeChildren: true, commonName: "HCoV-NL63"),
            TaxonTarget(name: "Human coronavirus HKU1", taxId: 290028, includeChildren: true, commonName: "HCoV-HKU1"),
            TaxonTarget(name: "Rhinovirus", taxId: 12059, includeChildren: true, commonName: "Rhinovirus"),
            TaxonTarget(name: "Human mastadenovirus", taxId: 9832, includeChildren: true, commonName: "Adenovirus"),
            TaxonTarget(name: "Human parainfluenza virus", taxId: 11212, includeChildren: true, commonName: "Parainfluenza"),
            TaxonTarget(name: "Human metapneumovirus", taxId: 162145, includeChildren: true, commonName: "hMPV"),
        ]
    )

    // MARK: - Enteric Viruses

    public static let entericViruses = TaxaCollection(
        id: "enteric-viruses",
        name: "Enteric Viruses",
        description: "Gastrointestinal viral pathogens causing diarrhea and gastroenteritis",
        sfSymbol: "stomach",
        taxa: [
            TaxonTarget(name: "Norovirus", taxId: 142786, includeChildren: true, commonName: "Norovirus"),
            TaxonTarget(name: "Rotavirus", taxId: 10912, includeChildren: true, commonName: "Rotavirus"),
            TaxonTarget(name: "Mamastrovirus", taxId: 249588, includeChildren: true, commonName: "Astrovirus"),
            TaxonTarget(name: "Sapovirus", taxId: 95340, includeChildren: true, commonName: "Sapovirus"),
            TaxonTarget(name: "Human mastadenovirus F", taxId: 130309, includeChildren: true, commonName: "Adenovirus F"),
            TaxonTarget(name: "Hepatovirus A", taxId: 12092, includeChildren: true, commonName: "Hepatitis A"),
        ]
    )

    // MARK: - Respiratory Bacteria

    public static let respiratoryBacteria = TaxaCollection(
        id: "respiratory-bacteria",
        name: "Respiratory Bacteria",
        description: "Common bacterial respiratory pathogens",
        sfSymbol: "bubbles.and.sparkles",
        taxa: [
            TaxonTarget(name: "Streptococcus pneumoniae", taxId: 1313, includeChildren: true),
            TaxonTarget(name: "Haemophilus influenzae", taxId: 727, includeChildren: true),
            TaxonTarget(name: "Mycoplasma pneumoniae", taxId: 2104, includeChildren: true),
            TaxonTarget(name: "Bordetella pertussis", taxId: 520, includeChildren: true),
            TaxonTarget(name: "Legionella pneumophila", taxId: 446, includeChildren: true),
            TaxonTarget(name: "Chlamydia pneumoniae", taxId: 83558, includeChildren: true),
            TaxonTarget(name: "Klebsiella pneumoniae", taxId: 573, includeChildren: true),
        ]
    )

    // MARK: - AMR Organisms (ESKAPE)

    public static let amrOrganisms = TaxaCollection(
        id: "amr-eskape",
        name: "AMR Organisms (ESKAPE)",
        description: "Key antimicrobial-resistant pathogens: Enterococcus, Staphylococcus, Klebsiella, Acinetobacter, Pseudomonas, Enterobacter",
        sfSymbol: "shield.lefthalf.filled.badge.checkmark",
        taxa: [
            TaxonTarget(name: "Enterococcus faecium", taxId: 1352, includeChildren: true),
            TaxonTarget(name: "Staphylococcus aureus", taxId: 1280, includeChildren: true),
            TaxonTarget(name: "Klebsiella pneumoniae", taxId: 573, includeChildren: true),
            TaxonTarget(name: "Acinetobacter baumannii", taxId: 470, includeChildren: true),
            TaxonTarget(name: "Pseudomonas aeruginosa", taxId: 287, includeChildren: true),
            TaxonTarget(name: "Enterobacter", taxId: 547, includeChildren: true, commonName: "Enterobacter spp."),
        ]
    )

    // MARK: - Wastewater Surveillance

    public static let wastewaterSurveillance = TaxaCollection(
        id: "wastewater-surveillance",
        name: "Wastewater Surveillance",
        description: "Key pathogens monitored in wastewater-based epidemiology",
        sfSymbol: "drop.triangle",
        taxa: [
            TaxonTarget(name: "Severe acute respiratory syndrome coronavirus 2", taxId: 2697049, includeChildren: true, commonName: "SARS-CoV-2"),
            TaxonTarget(name: "Influenza A virus", taxId: 11320, includeChildren: true, commonName: "Influenza A"),
            TaxonTarget(name: "Respiratory syncytial virus", taxId: 12814, includeChildren: true, commonName: "RSV"),
            TaxonTarget(name: "Norovirus", taxId: 142786, includeChildren: true, commonName: "Norovirus"),
            TaxonTarget(name: "Monkeypox virus", taxId: 10244, includeChildren: true, commonName: "Mpox"),
            TaxonTarget(name: "Poliovirus", taxId: 12080, includeChildren: true, commonName: "Poliovirus"),
        ]
    )

    // MARK: - STI Pathogens

    public static let stiPathogens = TaxaCollection(
        id: "sti-pathogens",
        name: "Sexually Transmitted Infections",
        description: "Pathogens causing sexually transmitted infections",
        sfSymbol: "cross.case",
        taxa: [
            TaxonTarget(name: "Treponema pallidum", taxId: 160, includeChildren: true, commonName: "Syphilis"),
            TaxonTarget(name: "Neisseria gonorrhoeae", taxId: 485, includeChildren: true, commonName: "Gonorrhea"),
            TaxonTarget(name: "Chlamydia trachomatis", taxId: 813, includeChildren: true, commonName: "Chlamydia"),
            TaxonTarget(name: "Mycoplasma genitalium", taxId: 2097, includeChildren: true),
            TaxonTarget(name: "Papillomaviridae", taxId: 151340, includeChildren: true, commonName: "HPV"),
            TaxonTarget(name: "Human immunodeficiency virus 1", taxId: 11676, includeChildren: true, commonName: "HIV-1"),
            TaxonTarget(name: "Human alphaherpesvirus 1", taxId: 10298, includeChildren: true, commonName: "HSV-1"),
            TaxonTarget(name: "Human alphaherpesvirus 2", taxId: 10310, includeChildren: true, commonName: "HSV-2"),
        ]
    )

    // MARK: - Vector-Borne Pathogens

    public static let vectorBornePathogens = TaxaCollection(
        id: "vector-borne",
        name: "Vector-Borne Pathogens",
        description: "Mosquito- and tick-transmitted pathogens",
        sfSymbol: "ant",
        taxa: [
            TaxonTarget(name: "Dengue virus", taxId: 12637, includeChildren: true, commonName: "Dengue"),
            TaxonTarget(name: "Zika virus", taxId: 64320, includeChildren: true, commonName: "Zika"),
            TaxonTarget(name: "Chikungunya virus", taxId: 37124, includeChildren: true, commonName: "Chikungunya"),
            TaxonTarget(name: "West Nile virus", taxId: 11082, includeChildren: true, commonName: "West Nile"),
            TaxonTarget(name: "Plasmodium", taxId: 5820, includeChildren: true, commonName: "Malaria"),
            TaxonTarget(name: "Borrelia", taxId: 138, includeChildren: true, commonName: "Lyme disease"),
        ]
    )

    // MARK: - Fungal Pathogens

    public static let fungalPathogens = TaxaCollection(
        id: "fungal-pathogens",
        name: "Fungal Pathogens",
        description: "Clinically important fungal infections",
        sfSymbol: "leaf.fill",
        taxa: [
            TaxonTarget(name: "Candida auris", taxId: 498019, includeChildren: true),
            TaxonTarget(name: "Aspergillus fumigatus", taxId: 746128, includeChildren: true),
            TaxonTarget(name: "Cryptococcus neoformans", taxId: 5207, includeChildren: true),
            TaxonTarget(name: "Pneumocystis jirovecii", taxId: 42068, includeChildren: true),
            TaxonTarget(name: "Coccidioides", taxId: 5500, includeChildren: true),
            TaxonTarget(name: "Histoplasma", taxId: 5036, includeChildren: true),
        ]
    )
}
