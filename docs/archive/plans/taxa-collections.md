# Built-in Taxa Collection Definitions

Reference document for pre-defined taxa collections used in the metagenomic
classification viewer. Each collection defines a set of organisms that can be
extracted simultaneously from classified FASTQ data, with each taxon written
to its own output file.

All taxonomy IDs verified against the NCBI Taxonomy Browser
(https://www.ncbi.nlm.nih.gov/Taxonomy/Browser/) as of 2026-03-23.

---

## Data Model

```
TaxaCollection
  id:          String           -- stable machine identifier
  name:        String           -- human-readable name
  description: String           -- one-sentence purpose
  sfSymbol:    String           -- SF Symbols icon name
  taxa:        [TaxonTarget]    -- member organisms
  tier:        CollectionTier   -- .builtin / .appWide / .project

TaxonTarget
  name:            String       -- scientific name used in NCBI Taxonomy
  taxId:           Int          -- NCBI Taxonomy ID
  includeChildren: Bool         -- true = extract this taxon + all descendants
  commonName:      String?      -- nil when scientific name is self-explanatory

CollectionTier
  .builtin   -- shipped with app, read-only
  .appWide   -- user-defined, persisted across projects
  .project   -- saved inside a project bundle
```

---

## 1. Respiratory Viruses

| Field | Value |
|---|---|
| **id** | `respiratory-viruses` |
| **name** | Respiratory Viruses |
| **description** | Common viral pathogens causing upper and lower respiratory tract infections. |
| **sfSymbol** | `lungs` |

### Taxa

| Scientific Name | Tax ID | Children | Common Name | Rank | Notes |
|---|---|---|---|---|---|
| Influenza A virus | 11320 | yes | Influenza A | species | All subtypes (H1N1, H3N2, etc.) |
| Influenza B virus | 11520 | yes | Influenza B | species | Victoria and Yamagata lineages |
| Human orthopneumovirus | 11250 | yes | RSV | species | RSV-A and RSV-B subtypes |
| Severe acute respiratory syndrome coronavirus 2 | 2697049 | yes | SARS-CoV-2 | no rank | All lineages/variants |
| Human coronavirus 229E | 11137 | yes | HCoV-229E | no rank | Alphacoronavirus |
| Human coronavirus OC43 | 31631 | yes | HCoV-OC43 | no rank | Betacoronavirus |
| Human coronavirus NL63 | 277944 | yes | HCoV-NL63 | no rank | Alphacoronavirus |
| Human coronavirus HKU1 | 290028 | yes | HCoV-HKU1 | no rank | Betacoronavirus |
| Rhinovirus A | 147711 | yes | Rhinovirus A | species | ~80 serotypes |
| Rhinovirus B | 147712 | yes | Rhinovirus B | species | ~30 serotypes |
| Rhinovirus C | 463676 | yes | Rhinovirus C | species | ~55 types |
| Human mastadenovirus B | 108098 | yes | Adenovirus B | species | Respiratory serotypes (3, 7, 14, 21) |
| Human mastadenovirus C | 129951 | yes | Adenovirus C | species | Respiratory serotypes (1, 2, 5, 6) |
| Human mastadenovirus E | 130310 | yes | Adenovirus E | species | Serotype 4 (military recruits) |
| Human respirovirus 1 | 12730 | yes | Parainfluenza 1 | species | Croup in children |
| Human respirovirus 3 | 11216 | yes | Parainfluenza 3 | species | Bronchiolitis, pneumonia |
| Human orthorubulavirus 2 | 11212 | yes | Parainfluenza 2 | no rank | Croup |
| Human orthorubulavirus 4 | 11203 | yes | Parainfluenza 4 | no rank | Mild respiratory illness |
| Human metapneumovirus | 162145 | yes | hMPV | species | Pneumoviridae |
| Enterovirus D68 | 42789 | no | EV-D68 | no rank | Respiratory + neurologic disease |

**Use case**: Respiratory illness surveillance panels. Researchers performing
metagenomic sequencing of nasopharyngeal swabs, BAL, or wastewater who want to
simultaneously extract reads for all common respiratory viruses. Mirrors the
scope of commercial multiplex respiratory panels (e.g., BioFire FilmArray RP).

---

## 2. Enteric Viruses

| Field | Value |
|---|---|
| **id** | `enteric-viruses` |
| **name** | Enteric Viruses |
| **description** | Viral pathogens causing acute gastroenteritis. |
| **sfSymbol** | `testtube.2` |

### Taxa

| Scientific Name | Tax ID | Children | Common Name | Rank | Notes |
|---|---|---|---|---|---|
| Norovirus | 142786 | yes | Norovirus | genus | GI and GII genogroups; leading cause of gastroenteritis outbreaks |
| Rotavirus | 10912 | yes | Rotavirus | genus | Genus-level captures all species (A, B, C); Rotavirus A (28875) is the primary human pathogen |
| Mamastrovirus 1 | 1239565 | yes | Human astrovirus | species | Classical human astrovirus serotypes 1-8 |
| Sapovirus | 95341 | yes | Sapovirus | genus | GI, GII, GIV, GV genogroups infect humans |
| Human mastadenovirus F | 130309 | yes | Enteric adenovirus | species | Types 40 and 41 only; causes pediatric gastroenteritis |
| Hepatovirus A | 12092 | yes | Hepatitis A virus | species | Fecal-oral transmission; waterborne outbreaks |

**Use case**: Gastroenteritis outbreak investigation. Researchers sequencing
stool samples or wastewater during diarrheal disease outbreaks. Matches the
scope of enteric virus surveillance panels used by public health labs.

---

## 3. Respiratory Bacteria

| Field | Value |
|---|---|
| **id** | `respiratory-bacteria` |
| **name** | Respiratory Bacteria |
| **description** | Bacterial pathogens causing community-acquired pneumonia and atypical respiratory infections. |
| **sfSymbol** | `microbe` |

### Taxa

| Scientific Name | Tax ID | Children | Common Name | Rank | Notes |
|---|---|---|---|---|---|
| Streptococcus pneumoniae | 1313 | yes | Pneumococcus | species | Most common bacterial CAP pathogen |
| Haemophilus influenzae | 727 | yes | H. flu | species | Typeable and nontypeable strains |
| Mycoplasmoides pneumoniae | 2104 | no | Mycoplasma pneumoniae | species | Atypical pneumonia; formerly Mycoplasma pneumoniae |
| Bordetella pertussis | 520 | yes | Whooping cough | species | Pertussis; vaccine-era resurgence |
| Legionella pneumophila | 446 | yes | Legionella | species | Legionnaires' disease; environmental source |
| Chlamydia pneumoniae | 83558 | yes | C. pneumoniae | species | Atypical pneumonia; also Chlamydophila pneumoniae |
| Staphylococcus aureus | 1280 | yes | Staph aureus | species | Post-influenza bacterial pneumonia |
| Klebsiella pneumoniae | 573 | yes | K. pneumoniae | species | Hospital-acquired pneumonia |
| Moraxella catarrhalis | 480 | yes | M. catarrhalis | species | Exacerbations in COPD patients |

**Use case**: Metagenomic investigation of pneumonia etiology, particularly
when culture-negative or when atypical pathogens are suspected. Useful for
studies comparing bacterial vs viral respiratory illness burden.

---

## 4. Antimicrobial Resistance Organisms (ESKAPE)

| Field | Value |
|---|---|
| **id** | `eskape-pathogens` |
| **name** | ESKAPE Pathogens |
| **description** | Multidrug-resistant ESKAPE group organisms prioritized by WHO for antimicrobial resistance surveillance. |
| **sfSymbol** | `shield.lefthalf.filled.badge.checkmark` |

### Taxa

| Scientific Name | Tax ID | Children | Common Name | Rank | Notes |
|---|---|---|---|---|---|
| Enterococcus faecium | 1352 | yes | VRE | species | Vancomycin-resistant enterococci |
| Staphylococcus aureus | 1280 | yes | MRSA | species | Methicillin-resistant S. aureus |
| Klebsiella pneumoniae | 573 | yes | CRKP | species | Carbapenem-resistant K. pneumoniae |
| Acinetobacter baumannii | 470 | yes | A. baumannii | species | Carbapenem-resistant; ICU pathogen |
| Pseudomonas aeruginosa | 287 | yes | P. aeruginosa | species | MDR Pseudomonas |
| Enterobacter | 547 | yes | Enterobacter spp. | genus | Genus-level; includeChildren captures all species |
| Escherichia coli | 562 | yes | E. coli | species | ESBL-producing strains; not in original ESKAPE but critical AMR organism |
| Clostridioides difficile | 1496 | yes | C. diff | species | Healthcare-associated infections |

**Use case**: Hospital infection control and AMR surveillance. Researchers
performing shotgun metagenomics on clinical or environmental (hospital surface)
samples to detect and characterize drug-resistant organisms. Note: species
detection alone does not confirm resistance -- downstream analysis of resistance
genes (e.g., via AMRFinderPlus or CARD) is required.

---

## 5. Wastewater Surveillance

| Field | Value |
|---|---|
| **id** | `wastewater-surveillance` |
| **name** | Wastewater Surveillance |
| **description** | Pathogens monitored in municipal wastewater for population-level public health surveillance. |
| **sfSymbol** | `drop.triangle` |

### Taxa

| Scientific Name | Tax ID | Children | Common Name | Rank | Notes |
|---|---|---|---|---|---|
| Severe acute respiratory syndrome coronavirus 2 | 2697049 | yes | SARS-CoV-2 | no rank | COVID-19 wastewater tracking |
| Influenza A virus | 11320 | yes | Influenza A | species | Seasonal and pandemic flu |
| Influenza B virus | 11520 | yes | Influenza B | species | Seasonal flu |
| Human orthopneumovirus | 11250 | yes | RSV | species | RSV season tracking |
| Norovirus | 142786 | yes | Norovirus | genus | Gastroenteritis outbreaks |
| Monkeypox virus | 10244 | yes | Mpox | species | Mpox (Orthopoxvirus) |
| Enterovirus C | 138950 | yes | Poliovirus group | species | Includes poliovirus 1/2/3; polio surveillance |
| Rotavirus | 10912 | yes | Rotavirus | genus | Pediatric gastroenteritis |
| Human metapneumovirus | 162145 | yes | hMPV | species | Respiratory surveillance |
| Rhinovirus A | 147711 | yes | Rhinovirus A | species | Common cold tracking |
| Rhinovirus B | 147712 | yes | Rhinovirus B | species | Common cold tracking |
| Rhinovirus C | 463676 | yes | Rhinovirus C | species | Common cold tracking |

**Use case**: Municipal wastewater-based epidemiology (WBE). Public health labs
and researchers performing metagenomic or targeted sequencing of wastewater
influent to track community pathogen circulation, detect emerging variants, and
provide early warning of outbreaks. Aligns with CDC National Wastewater
Surveillance System (NWSS) target list.

---

## 6. Sexually Transmitted Infections

| Field | Value |
|---|---|
| **id** | `sti-pathogens` |
| **name** | STI Pathogens |
| **description** | Bacterial and viral pathogens causing sexually transmitted infections. |
| **sfSymbol** | `figure.2` |

### Taxa

| Scientific Name | Tax ID | Children | Common Name | Rank | Notes |
|---|---|---|---|---|---|
| Treponema pallidum | 160 | yes | Syphilis | species | Includes subsp. pallidum (syphilis), pertenue (yaws), endemicum (bejel) |
| Neisseria gonorrhoeae | 485 | yes | Gonorrhea | species | AMR surveillance critical |
| Chlamydia trachomatis | 813 | yes | Chlamydia | species | Most common bacterial STI |
| Mycoplasmoides genitalium | 2097 | no | M. genitalium | species | Formerly Mycoplasma genitalium; macrolide resistance emerging |
| Papillomaviridae | 151340 | yes | HPV | family | Family-level; captures all HPV types (high-risk 16/18 and others) |
| Human immunodeficiency virus 1 | 11676 | yes | HIV-1 | species | Global pandemic strain |
| Human immunodeficiency virus 2 | 11709 | yes | HIV-2 | species | Endemic in West Africa |
| Human alphaherpesvirus 1 | 10298 | yes | HSV-1 | species | Oral and genital herpes |
| Human alphaherpesvirus 2 | 10310 | yes | HSV-2 | species | Genital herpes |

**Use case**: STI screening and surveillance from clinical specimens (genital
swabs, urine, rectal swabs). Useful for metagenomic characterization of STI
co-infections, resistance profiling (N. gonorrhoeae, M. genitalium), and HPV
genotyping.

---

## 7. Vector-Borne Pathogens

| Field | Value |
|---|---|
| **id** | `vector-borne-pathogens` |
| **name** | Vector-Borne Pathogens |
| **description** | Pathogens transmitted by mosquitoes, ticks, and other arthropod vectors. |
| **sfSymbol** | `ant` |

### Taxa

| Scientific Name | Tax ID | Children | Common Name | Rank | Notes |
|---|---|---|---|---|---|
| Dengue virus | 12637 | yes | Dengue | species | 4 serotypes (DENV-1 through DENV-4) |
| Zika virus | 64320 | yes | Zika | species | Aedes mosquito; congenital Zika syndrome |
| Chikungunya virus | 37124 | yes | Chikungunya | species | Alphavirus; Aedes mosquito |
| West Nile virus | 11082 | yes | West Nile | species | Culex mosquito; neuroinvasive disease |
| Plasmodium | 5820 | yes | Malaria | genus | Genus-level; captures P. falciparum, P. vivax, P. malariae, P. ovale, P. knowlesi |
| Borreliella | 64895 | yes | Lyme disease group | genus | Genus-level; includes B. burgdorferi sensu lato complex |
| Borrelia | 138 | yes | Relapsing fever group | genus | Relapsing fever Borrelia (B. hermsii, B. recurrentis, etc.) |
| Rickettsia | 780 | yes | Rickettsia | genus | Tick-borne: Rocky Mountain spotted fever, typhus group |
| Yellow fever virus | 11089 | yes | Yellow fever | species | Flavivirus; Aedes mosquito |
| Babesia | 5765 | yes | Babesia | genus | Tick-borne; intraerythrocytic parasite |

**Use case**: Surveillance of vector-borne diseases in endemic areas or
travelers. Metagenomic analysis of patient blood, mosquito pools, or tick
pools. Useful for arbovirus discovery and monitoring geographic spread of
vector-borne pathogens.

**Note on Borrelia/Borreliella split**: NCBI Taxonomy maintains two genera:
Borreliella (64895) for the Lyme disease spirochetes and Borrelia (138) for
the relapsing fever group. Both are included because Kraken2 databases follow
the NCBI taxonomy. Some researchers prefer the unsplit genus -- users can
create a custom collection with just Borrelia sensu lato if needed.

---

## 8. Fungal Pathogens

| Field | Value |
|---|---|
| **id** | `fungal-pathogens` |
| **name** | Fungal Pathogens |
| **description** | Clinically important fungi causing invasive and opportunistic infections. |
| **sfSymbol** | `leaf` |

### Taxa

| Scientific Name | Tax ID | Children | Common Name | Rank | Notes |
|---|---|---|---|---|---|
| Candidozyma auris | 498019 | yes | Candida auris | species | Emerging MDR; formerly [Candida] auris; CDC urgent threat |
| Aspergillus fumigatus | 746128 | yes | A. fumigatus | species | Invasive aspergillosis; triazole resistance |
| Cryptococcus neoformans | 5207 | yes | Cryptococcus | species | Meningoencephalitis in HIV/AIDS |
| Pneumocystis jirovecii | 42068 | no | PJP / PCP | species | Pneumocystis pneumonia; obligate human parasite (no children in taxonomy) |
| Coccidioides | 5500 | yes | Valley fever | genus | C. immitis and C. posadasii; endemic dimorphic |
| Histoplasma | 5036 | yes | Histoplasmosis | genus | H. capsulatum complex; endemic dimorphic |
| Candida albicans | 5476 | yes | C. albicans | species | Most common Candida species |
| Nakaseomyces glabratus | 5478 | yes | C. glabrata | species | Formerly Candida glabrata; echinocandin resistance emerging |
| Aspergillus niger | 5061 | yes | A. niger | species | Otomycosis, pulmonary aspergilloma |
| Mucor | 4830 | yes | Mucormycosis | genus | Rhizopus/Mucor group; genus-level for broad capture |
| Talaromyces marneffei | 37727 | yes | Penicilliosis | species | Endemic in Southeast Asia; HIV-associated |
| Blastomyces | 229219 | yes | Blastomycosis | genus | B. dermatitidis and B. gilchristii |

**Use case**: Investigation of invasive fungal infections (IFI) in
immunocompromised patients (transplant recipients, HIV/AIDS, ICU patients on
broad-spectrum antibiotics). Metagenomic sequencing of BAL, CSF, or tissue
specimens when culture is slow or negative. Useful for antifungal resistance
surveillance (C. auris, A. fumigatus azole resistance).

---

## Implementation Notes

### includeChildren rationale

- **Genus-level taxa** (Norovirus, Rotavirus, Plasmodium, Borreliella, Coccidioides, Histoplasma, Enterobacter, Mucor, Blastomyces): `includeChildren = true` is essential because Kraken2 may classify reads at any level in the subtree. Without children, reads classified to a child species or strain would be missed.

- **Species-level taxa** (most entries): `includeChildren = true` captures strain-level classifications. The Kraken2 standard database includes many strain-level nodes; a read classified to "Influenza A virus (A/California/07/2009(H1N1))" tax ID 641809 would be missed without includeChildren on the parent species node 11320.

- **Exceptions with `includeChildren = false`**:
  - Enterovirus D68 (42789): EV-D68 is a single serotype under Enterovirus D, which also contains EV-D70 and EV-D94. Including children of Enterovirus D would pull in unrelated viruses. We target the specific serotype node.
  - Mycoplasmoides pneumoniae (2104) and Mycoplasmoides genitalium (2097): Species-level nodes with limited substructure; set to false to be conservative, though true would also work.
  - Pneumocystis jirovecii (42068): Single obligate human species with minimal subtree.

### Classifier compatibility

These collections are designed to work with any classifier that uses NCBI
taxonomy IDs:

- **Kraken2**: Uses standard NCBI taxonomy. The `includeChildren` flag maps to extracting reads where the Kraken2-assigned tax ID is a descendant of the target tax ID in the taxonomy tree.
- **STAT (SRA Taxonomy Analysis Tool)**: Also uses NCBI taxonomy IDs. Same tree traversal logic applies.
- **GOTTCHA2**: Uses NCBI taxonomy. May classify at different levels than Kraken2 due to its unique signature approach, making `includeChildren = true` even more important.

### Taxonomy updates

NCBI Taxonomy is a living database. Names and IDs can change:
- Mycoplasma pneumoniae was reclassified to Mycoplasmoides pneumoniae (tax ID 2104 unchanged)
- Candida auris is now formally Candidozyma auris (tax ID 498019 unchanged)
- Borrelia burgdorferi was moved to genus Borreliella (tax ID 139 unchanged, genus changed to 64895)

Tax IDs are stable even when names change. The app should:
1. Store tax IDs as the primary key
2. Display current NCBI names but accept synonyms in search
3. Provide a mechanism to refresh names from NCBI Taxonomy periodically

### SF Symbol choices

| Collection | Symbol | Rationale |
|---|---|---|
| Respiratory Viruses | `lungs` | Respiratory tropism |
| Enteric Viruses | `testtube.2` | GI / enteric pathogens |
| Respiratory Bacteria | `microbe` | Bacterial pathogens |
| ESKAPE Pathogens | `shield.lefthalf.filled.badge.checkmark` | Drug resistance / infection control |
| Wastewater Surveillance | `drop.triangle` | Water/environmental |
| STI Pathogens | `figure.2` | Person-to-person transmission |
| Vector-Borne Pathogens | `ant` | Arthropod vectors |
| Fungal Pathogens | `leaf` | Fungal kingdom |

### Extraction behavior

When a user selects a collection for extraction:
1. For each TaxonTarget in the collection, create one output FASTQ file
2. Filename format: `{sampleName}_{commonName ?? name}_{taxId}.fastq.gz`
3. If `includeChildren` is true, traverse the Kraken2 taxonomy tree to find all descendant tax IDs, then extract all reads classified to any of those IDs
4. Reads classified to multiple taxa (Kraken2 does not do this, but STAT can) should be written to all matching output files
5. Provide a summary report showing read counts per taxon and percentage of total classified reads
