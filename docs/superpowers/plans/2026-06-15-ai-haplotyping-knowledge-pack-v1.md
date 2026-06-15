# AI Haplotyping Knowledge Pack V1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a versioned macaque MHC knowledge context to AI haplotyping prompts while preserving familiar human-facing legacy labels such as `M1A`, `A008.01`, and `DR01.01`.

**Architecture:** Add a bundled `AIHaplotypingKnowledgePack` model and loader in `LungfishWorkflow`, seed a compact v1 JSON resource from the notebook-derived MCM and Indian rhesus definitions, infer run context from result metadata/genotype prefixes, and pass `runContext`, `knowledgePack`, and the current evidence registry into every AI prompt. Keep the current haplotype definition bundle schema compatible; the richer knowledge model is prompt context, not a replacement for existing `.lungfishmhcref` definitions.

**Tech Stack:** Swift 6.2, Foundation `Codable`, SwiftPM bundled resources, XCTest, existing `AIHaplotypingRunner`/`AIHaplotypingPromptRegistry` infrastructure.

---

## File Structure

- Modify: `/Users/dho/Documents/lungfish-genome-explorer/Package.swift`
  - Copy `Sources/LungfishWorkflow/Resources/AIHaplotyping` into the `LungfishWorkflow` resource bundle.
- Create: `/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishWorkflow/Resources/AIHaplotyping/macaque-mhc-v1.json`
  - Bundled v1 knowledge pack with source records, population profiles, legacy block definitions, report-label compatibility, marker weighting notes, and analyst guidance.
- Create: `/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishWorkflow/Resources/AIHaplotyping/README.md`
  - Human-readable notes explaining that report labels remain stable while internal IDs are richer.
- Create: `/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishWorkflow/ONTGenotyping/AIHaplotypingKnowledgePack.swift`
  - Codable models, deterministic digest, bundled loader, and basic validation.
- Create: `/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishWorkflow/ONTGenotyping/AIHaplotypingRunContext.swift`
  - Derives species prefix, population hint, assay resolution, workflow kind, and active definition metadata from `ONTGenotypeResultBundleData`.
- Modify: `/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishWorkflow/ONTGenotyping/AIHaplotypingTypes.swift`
  - Add prompt rendering support for `{{prompt_input_json}}` while preserving `{{evidence_registry_json}}`.
  - Add optional knowledge-pack fields to `AIHaplotypingPromptMetadata`.
- Modify: `/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishWorkflow/ONTGenotyping/AIHaplotypingRunner.swift`
  - Load the bundled knowledge pack once per run, build run context, include both in prompt input, and copy knowledge metadata into prompt metadata.
- Modify: `/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishWorkflow/ONTGenotyping/AIHaplotypingPromptRegistry.swift`
  - Add v2 prompt templates with macaque MHC reasoning instructions and make them current by version.
- Modify: `/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishWorkflow/ONTGenotyping/AIHaplotypingRevisionPublisher.swift`
  - Record knowledge-pack ID/version/digest in provenance `resolvedOptions` when present.
- Test: `/Users/dho/Documents/lungfish-genome-explorer/Tests/LungfishWorkflowTests/AIHaplotypingKnowledgePackTests.swift`
  - Loader, digest, validation, and content regression tests.
- Test: `/Users/dho/Documents/lungfish-genome-explorer/Tests/LungfishWorkflowTests/AIHaplotypingRunContextTests.swift`
  - Prefix/population/assay-resolution inference tests.
- Modify tests:
  - `/Users/dho/Documents/lungfish-genome-explorer/Tests/LungfishWorkflowTests/AIHaplotypingPromptRegistryTests.swift`
  - `/Users/dho/Documents/lungfish-genome-explorer/Tests/LungfishWorkflowTests/AIHaplotypingRunnerTests.swift`
  - `/Users/dho/Documents/lungfish-genome-explorer/Tests/LungfishWorkflowTests/AIHaplotypingRevisionPublisherTests.swift`

---

### Task 1: Add Knowledge Pack Models And Bundled Loader

**Files:**
- Create: `/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishWorkflow/ONTGenotyping/AIHaplotypingKnowledgePack.swift`
- Test: `/Users/dho/Documents/lungfish-genome-explorer/Tests/LungfishWorkflowTests/AIHaplotypingKnowledgePackTests.swift`

- [ ] **Step 1: Write failing loader/model tests**

Create `/Users/dho/Documents/lungfish-genome-explorer/Tests/LungfishWorkflowTests/AIHaplotypingKnowledgePackTests.swift`:

```swift
import XCTest
@testable import LungfishWorkflow

final class AIHaplotypingKnowledgePackTests: XCTestCase {
    func testBundledMacaqueKnowledgePackLoadsWithStableCoreContent() throws {
        let pack = try AIHaplotypingKnowledgePackLoader.bundledMacaqueMHC()

        XCTAssertEqual(pack.id, "macaque-mhc")
        XCTAssertEqual(pack.version, "2026-06-15.1")
        XCTAssertTrue(pack.digest.hasPrefix("sha256:"))
        XCTAssertEqual(pack.digest.count, "sha256:".count + 64)
        XCTAssertTrue(pack.sources.contains { $0.id == "source:notebook:miseq-genotyping-without-labkey" })
        XCTAssertTrue(pack.populationProfiles.contains { $0.id == "mcm" })
        XCTAssertTrue(pack.populationProfiles.contains { $0.id == "indian-rhesus" })
        XCTAssertTrue(pack.legacyBlockDefinitions.contains { $0.displayLabel == "M1A" && $0.reportLabel == "M1A" })
        XCTAssertTrue(pack.legacyBlockDefinitions.contains { $0.displayLabel == "A008.01" && $0.reportLabel == "A008.01" })
        XCTAssertTrue(pack.legacyBlockDefinitions.contains { $0.displayLabel == "DR01.01" && $0.region == "MHC-DRB" })
    }

    func testKnowledgePackDigestIgnoresStoredDigestAndChangesWhenContentChanges() throws {
        let pack = try AIHaplotypingKnowledgePackLoader.bundledMacaqueMHC()
        let recomputed = pack.recomputingDigest()

        XCTAssertEqual(pack.digest, recomputed.digest)

        var changed = recomputed
        changed.analystGuidance.append(AIHaplotypingAnalystGuidance(
            id: "guidance:test-only",
            title: "Test-only rule",
            text: "Changing guidance changes the digest.",
            sourceIDs: ["source:notebook:miseq-genotyping-without-labkey"]
        ))
        XCTAssertNotEqual(changed.recomputingDigest().digest, pack.digest)
    }

    func testKnowledgePackValidationRejectsUnknownSourceReferences() {
        let invalid = AIHaplotypingKnowledgePack(
            id: "invalid",
            version: "1",
            sources: [],
            populationProfiles: [],
            legacyBlockDefinitions: [
                AIHaplotypingLegacyBlockDefinition(
                    id: "block:invalid",
                    internalID: "invalid",
                    displayLabel: "Invalid",
                    reportLabel: "Invalid",
                    speciesPrefix: "Mafa",
                    populationID: "mcm",
                    frameworkID: "mcm-m1-m7",
                    region: "MHC-A",
                    assayResolution: "short_exon_amplicon",
                    definitionStatus: "legacy_curated",
                    sourceIDs: ["source:missing"],
                    definingMarkers: [],
                    extendedHaplotype: nil,
                    notes: ""
                )
            ],
            markerRules: [],
            analystGuidance: [],
            digest: "sha256:\(String(repeating: "0", count: 64))"
        )

        XCTAssertThrowsError(try invalid.validate()) { error in
            XCTAssertEqual(error as? AIHaplotypingKnowledgePackError, .unknownSourceID("source:missing"))
        }
    }
}
```

- [ ] **Step 2: Run the focused tests and verify they fail**

Run:

```bash
swift test --filter AIHaplotypingKnowledgePackTests
```

Expected: FAIL because `AIHaplotypingKnowledgePack`, `AIHaplotypingKnowledgePackLoader`, and related model types do not exist.

- [ ] **Step 3: Add model and loader implementation**

Create `/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishWorkflow/ONTGenotyping/AIHaplotypingKnowledgePack.swift`:

```swift
import Foundation

public enum AIHaplotypingKnowledgePackError: Error, Equatable, LocalizedError, Sendable {
    case missingBundledPack(String)
    case unknownSourceID(String)
    case duplicateEntityID(String)

    public var errorDescription: String? {
        switch self {
        case .missingBundledPack(let name):
            return "Missing bundled AI haplotyping knowledge pack: \(name)."
        case .unknownSourceID(let id):
            return "AI haplotyping knowledge pack references unknown source ID: \(id)."
        case .duplicateEntityID(let id):
            return "AI haplotyping knowledge pack contains duplicate entity ID: \(id)."
        }
    }
}

public struct AIHaplotypingKnowledgePack: Codable, Equatable, Sendable {
    public var id: String
    public var version: String
    public var sources: [AIHaplotypingKnowledgeSource]
    public var populationProfiles: [AIHaplotypingPopulationProfile]
    public var legacyBlockDefinitions: [AIHaplotypingLegacyBlockDefinition]
    public var markerRules: [AIHaplotypingMarkerRule]
    public var analystGuidance: [AIHaplotypingAnalystGuidance]
    public var digest: String

    public init(
        id: String,
        version: String,
        sources: [AIHaplotypingKnowledgeSource],
        populationProfiles: [AIHaplotypingPopulationProfile],
        legacyBlockDefinitions: [AIHaplotypingLegacyBlockDefinition],
        markerRules: [AIHaplotypingMarkerRule],
        analystGuidance: [AIHaplotypingAnalystGuidance],
        digest: String? = nil
    ) {
        self.id = id
        self.version = version
        self.sources = sources.sorted { $0.id < $1.id }
        self.populationProfiles = populationProfiles.sorted { $0.id < $1.id }
        self.legacyBlockDefinitions = legacyBlockDefinitions.sorted { $0.id < $1.id }
        self.markerRules = markerRules.sorted { $0.id < $1.id }
        self.analystGuidance = analystGuidance.sorted { $0.id < $1.id }
        self.digest = digest ?? Self.computeDigest(
            id: id,
            version: version,
            sources: self.sources,
            populationProfiles: self.populationProfiles,
            legacyBlockDefinitions: self.legacyBlockDefinitions,
            markerRules: self.markerRules,
            analystGuidance: self.analystGuidance
        )
    }

    public func recomputingDigest() -> AIHaplotypingKnowledgePack {
        AIHaplotypingKnowledgePack(
            id: id,
            version: version,
            sources: sources,
            populationProfiles: populationProfiles,
            legacyBlockDefinitions: legacyBlockDefinitions,
            markerRules: markerRules,
            analystGuidance: analystGuidance
        )
    }

    public func validate() throws {
        let sourceIDs = Set(sources.map(\.id))
        try rejectDuplicateIDs(sources.map(\.id))
        try rejectDuplicateIDs(populationProfiles.map(\.id))
        try rejectDuplicateIDs(legacyBlockDefinitions.map(\.id))
        try rejectDuplicateIDs(markerRules.map(\.id))
        try rejectDuplicateIDs(analystGuidance.map(\.id))
        for definition in legacyBlockDefinitions {
            try validateSourceIDs(definition.sourceIDs, known: sourceIDs)
            for marker in definition.definingMarkers {
                try validateSourceIDs(marker.sourceIDs, known: sourceIDs)
            }
        }
        for rule in markerRules {
            try validateSourceIDs(rule.sourceIDs, known: sourceIDs)
        }
        for guidance in analystGuidance {
            try validateSourceIDs(guidance.sourceIDs, known: sourceIDs)
        }
    }

    private func rejectDuplicateIDs(_ ids: [String]) throws {
        var seen = Set<String>()
        for id in ids where !seen.insert(id).inserted {
            throw AIHaplotypingKnowledgePackError.duplicateEntityID(id)
        }
    }

    private func validateSourceIDs(_ ids: [String], known: Set<String>) throws {
        for id in ids where !known.contains(id) {
            throw AIHaplotypingKnowledgePackError.unknownSourceID(id)
        }
    }

    private static func computeDigest(
        id: String,
        version: String,
        sources: [AIHaplotypingKnowledgeSource],
        populationProfiles: [AIHaplotypingPopulationProfile],
        legacyBlockDefinitions: [AIHaplotypingLegacyBlockDefinition],
        markerRules: [AIHaplotypingMarkerRule],
        analystGuidance: [AIHaplotypingAnalystGuidance]
    ) -> String {
        AIHaplotypingCanonicalJSON.sha256Digest(of: DigestPayload(
            id: id,
            version: version,
            sources: sources,
            populationProfiles: populationProfiles,
            legacyBlockDefinitions: legacyBlockDefinitions,
            markerRules: markerRules,
            analystGuidance: analystGuidance
        ))
    }

    private struct DigestPayload: Encodable {
        let id: String
        let version: String
        let sources: [AIHaplotypingKnowledgeSource]
        let populationProfiles: [AIHaplotypingPopulationProfile]
        let legacyBlockDefinitions: [AIHaplotypingLegacyBlockDefinition]
        let markerRules: [AIHaplotypingMarkerRule]
        let analystGuidance: [AIHaplotypingAnalystGuidance]
    }
}

public struct AIHaplotypingKnowledgeSource: Codable, Equatable, Sendable {
    public let id: String
    public let citation: String
    public let authorityTier: String
    public let notes: String
}

public struct AIHaplotypingPopulationProfile: Codable, Equatable, Sendable {
    public let id: String
    public let speciesPrefix: String
    public let speciesName: String
    public let populationLabel: String
    public let frameworkIDs: [String]
    public let noveltyPrior: String
    public let recombinationPrior: String
    public let notes: String
}

public struct AIHaplotypingLegacyBlockDefinition: Codable, Equatable, Sendable {
    public let id: String
    public let internalID: String
    public let displayLabel: String
    public let reportLabel: String
    public let speciesPrefix: String
    public let populationID: String
    public let frameworkID: String
    public let region: String
    public let assayResolution: String
    public let definitionStatus: String
    public let sourceIDs: [String]
    public let definingMarkers: [AIHaplotypingDefiningMarker]
    public let extendedHaplotype: String?
    public let notes: String
}

public struct AIHaplotypingDefiningMarker: Codable, Equatable, Sendable {
    public let observedLabel: String
    public let role: String
    public let informativeness: String
    public let compatibleReportLabels: [String]
    public let sourceIDs: [String]
}

public struct AIHaplotypingMarkerRule: Codable, Equatable, Sendable {
    public let id: String
    public let populationID: String
    public let assayResolution: String
    public let region: String
    public let markerPattern: String
    public let informativeness: String
    public let splitHaplotypeDefault: String
    public let sourceIDs: [String]
    public let notes: String
}

public struct AIHaplotypingAnalystGuidance: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let text: String
    public let sourceIDs: [String]
}

public enum AIHaplotypingKnowledgePackLoader {
    public static func bundledMacaqueMHC() throws -> AIHaplotypingKnowledgePack {
        try loadBundledPack(named: "macaque-mhc-v1", subdirectory: "AIHaplotyping")
    }

    static func loadBundledPack(named name: String, subdirectory: String) throws -> AIHaplotypingKnowledgePack {
        let candidates = [
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: subdirectory),
            Bundle.module.resourceURL?
                .appendingPathComponent(subdirectory, isDirectory: true)
                .appendingPathComponent("\(name).json"),
            Bundle.module.resourceURL?
                .appendingPathComponent("Sources/LungfishWorkflow/Resources", isDirectory: true)
                .appendingPathComponent(subdirectory, isDirectory: true)
                .appendingPathComponent("\(name).json"),
        ]
        guard let url = candidates.compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw AIHaplotypingKnowledgePackError.missingBundledPack(name)
        }
        let pack = try JSONDecoder().decode(AIHaplotypingKnowledgePack.self, from: Data(contentsOf: url))
        try pack.validate()
        return pack.recomputingDigest()
    }
}
```

- [ ] **Step 4: Run the focused tests and verify the current failure is only missing resource**

Run:

```bash
swift test --filter AIHaplotypingKnowledgePackTests
```

Expected: FAIL with `missingBundledPack("macaque-mhc-v1")`.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/ONTGenotyping/AIHaplotypingKnowledgePack.swift Tests/LungfishWorkflowTests/AIHaplotypingKnowledgePackTests.swift
git commit -m "feat: add ai haplotyping knowledge pack model"
```

---

### Task 2: Bundle V1 Knowledge Pack Resource

**Files:**
- Modify: `/Users/dho/Documents/lungfish-genome-explorer/Package.swift`
- Create: `/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishWorkflow/Resources/AIHaplotyping/macaque-mhc-v1.json`
- Create: `/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishWorkflow/Resources/AIHaplotyping/README.md`
- Test: `/Users/dho/Documents/lungfish-genome-explorer/Tests/LungfishWorkflowTests/AIHaplotypingKnowledgePackTests.swift`

- [ ] **Step 1: Copy the new resource subtree in SwiftPM**

Patch the `LungfishWorkflow` target resources in `/Users/dho/Documents/lungfish-genome-explorer/Package.swift` so it includes:

```swift
resources: [
    .copy("Resources/AIHaplotyping"),
    .copy("Resources/Containerization"),
    .copy("Resources/ManagedTools"),
    .copy("Resources/Tools"),
    .copy("Resources/Databases"),
    .copy("Resources/Recipes")
]
```

- [ ] **Step 2: Add README for curators**

Create `/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishWorkflow/Resources/AIHaplotyping/README.md`:

```markdown
# AI Haplotyping Knowledge Resources

`macaque-mhc-v1.json` is the bundled runtime knowledge context used by AI haplotyping prompts.

The `displayLabel` and `reportLabel` fields preserve familiar analyst-facing names such as `M1A`, `A008.01`, and `DR01.01`. The `internalID`, `frameworkID`, `region`, marker roles, and source IDs give the AI a richer representation without changing report labels that researchers already recognize.

This v1 file is seeded from curated notebook definitions and should be treated as a compatibility layer, not as the final long-term curation interface.
```

- [ ] **Step 3: Add bundled JSON with MCM and Indian rhesus seed content**

Create `/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishWorkflow/Resources/AIHaplotyping/macaque-mhc-v1.json` with this minimal seed pack:

```json
{
  "id": "macaque-mhc",
  "version": "2026-06-15.1",
  "sources": [
    {
      "id": "source:notebook:miseq-genotyping-without-labkey",
      "citation": "dholab gs genotyper miseq-genotyping_without_labkey.ipynb, cell 24 legacy haplotype dictionaries",
      "authorityTier": "legacy_curated",
      "notes": "Human-created definitions used for historical MiSeq reports. Preserve labels for report compatibility."
    },
    {
      "id": "source:paper:karl-2023-m3-genome-research",
      "citation": "Karl et al. 2023 Genome Research M3 macaque MHC haplotype structural reference",
      "authorityTier": "published_structural_reference",
      "notes": "Used to teach broad macaque MHC organization and linked-region expectations."
    }
  ],
  "populationProfiles": [
    {
      "id": "indian-rhesus",
      "speciesPrefix": "Mamu",
      "speciesName": "Macaca mulatta",
      "populationLabel": "Indian-origin rhesus macaque",
      "frameworkIDs": ["mamu-indian-regional-blocks"],
      "noveltyPrior": "moderate",
      "recombinationPrior": "evaluate_by_region_and_pedigree",
      "notes": "Use regional A/B/DRB/DQ/DP block labels. Do not force MCM-style whole-MHC labels."
    },
    {
      "id": "mcm",
      "speciesPrefix": "Mafa",
      "speciesName": "Macaca fascicularis",
      "populationLabel": "Mauritian cynomolgus macaque",
      "frameworkIDs": ["mcm-m1-m7-extended", "mcm-miseq-regional-blocks"],
      "noveltyPrior": "very_low_for_new_extended_haplotypes",
      "recombinationPrior": "rare_between_class_II_subregions",
      "notes": "Prefer known M1-M7 and known recombinant interpretations before proposing novelty."
    }
  ],
  "legacyBlockDefinitions": [
    {
      "id": "block:mcm:mhc-a:m1a",
      "internalID": "mcm.miseq.MHC-A.M1A",
      "displayLabel": "M1A",
      "reportLabel": "M1A",
      "speciesPrefix": "Mafa",
      "populationID": "mcm",
      "frameworkID": "mcm-miseq-regional-blocks",
      "region": "MHC-A",
      "assayResolution": "short_exon_amplicon",
      "definitionStatus": "legacy_curated",
      "sourceIDs": ["source:notebook:miseq-genotyping-without-labkey"],
      "definingMarkers": [
        {
          "observedLabel": "05_M1M2M3_A1_063g",
          "role": "shared_supporting_marker",
          "informativeness": "shared_low_disambiguation",
          "compatibleReportLabels": ["M1A", "M2A", "M3A"],
          "sourceIDs": ["source:notebook:miseq-genotyping-without-labkey"]
        },
        {
          "observedLabel": "07_M1M2_70_156bp",
          "role": "shared_supporting_marker",
          "informativeness": "shared_low_disambiguation",
          "compatibleReportLabels": ["M1A", "M2A"],
          "sourceIDs": ["source:notebook:miseq-genotyping-without-labkey"]
        },
        {
          "observedLabel": "04_M1_AG_05_3mis_156bp",
          "role": "linked_neighbor_support",
          "informativeness": "supporting",
          "compatibleReportLabels": ["M1A"],
          "sourceIDs": ["source:notebook:miseq-genotyping-without-labkey"]
        }
      ],
      "extendedHaplotype": "M1",
      "notes": "MHC-A regional label for the MCM M1 extended haplotype; AG support is linked-neighbor evidence."
    },
    {
      "id": "block:mcm:mhc-a:m2a",
      "internalID": "mcm.miseq.MHC-A.M2A",
      "displayLabel": "M2A",
      "reportLabel": "M2A",
      "speciesPrefix": "Mafa",
      "populationID": "mcm",
      "frameworkID": "mcm-miseq-regional-blocks",
      "region": "MHC-A",
      "assayResolution": "short_exon_amplicon",
      "definitionStatus": "legacy_curated",
      "sourceIDs": ["source:notebook:miseq-genotyping-without-labkey"],
      "definingMarkers": [
        {
          "observedLabel": "05_M1M2M3_A1_063g",
          "role": "shared_supporting_marker",
          "informativeness": "shared_low_disambiguation",
          "compatibleReportLabels": ["M1A", "M2A", "M3A"],
          "sourceIDs": ["source:notebook:miseq-genotyping-without-labkey"]
        },
        {
          "observedLabel": "02_M2_G_02_06_156bp",
          "role": "linked_neighbor_support",
          "informativeness": "supporting",
          "compatibleReportLabels": ["M2A"],
          "sourceIDs": ["source:notebook:miseq-genotyping-without-labkey"]
        }
      ],
      "extendedHaplotype": "M2",
      "notes": "MHC-A regional label for the MCM M2 extended haplotype."
    },
    {
      "id": "block:mcm:mhc-dp:m4m7dp",
      "internalID": "mcm.miseq.MHC-DP.M4M7DP",
      "displayLabel": "M4M7DP",
      "reportLabel": "M4M7DP",
      "speciesPrefix": "Mafa",
      "populationID": "mcm",
      "frameworkID": "mcm-miseq-regional-blocks",
      "region": "MHC-DP",
      "assayResolution": "short_exon_amplicon",
      "definitionStatus": "legacy_curated_shared",
      "sourceIDs": ["source:notebook:miseq-genotyping-without-labkey"],
      "definingMarkers": [
        {
          "observedLabel": "15_M4M7_DPB1_03_03",
          "role": "shared_required_marker",
          "informativeness": "shared_between_extended_haplotypes",
          "compatibleReportLabels": ["M4DP", "M7DP", "M4M7DP"],
          "sourceIDs": ["source:notebook:miseq-genotyping-without-labkey"]
        }
      ],
      "extendedHaplotype": null,
      "notes": "Legacy MiSeq DP label cannot separate M4 and M7 at this marker resolution."
    },
    {
      "id": "block:mamu:mhc-a:a008-01",
      "internalID": "mamu.indian.miseq.MHC-A.A008.01",
      "displayLabel": "A008.01",
      "reportLabel": "A008.01",
      "speciesPrefix": "Mamu",
      "populationID": "indian-rhesus",
      "frameworkID": "mamu-indian-regional-blocks",
      "region": "MHC-A",
      "assayResolution": "short_exon_amplicon",
      "definitionStatus": "legacy_curated",
      "sourceIDs": ["source:notebook:miseq-genotyping-without-labkey"],
      "definingMarkers": [
        {
          "observedLabel": "A1_008",
          "role": "required_supporting_marker",
          "informativeness": "regional_block_label",
          "compatibleReportLabels": ["A008.01"],
          "sourceIDs": ["source:notebook:miseq-genotyping-without-labkey"]
        }
      ],
      "extendedHaplotype": null,
      "notes": "Legacy Indian rhesus regional MHC-A report label."
    },
    {
      "id": "block:mamu:mhc-b:b069-02",
      "internalID": "mamu.indian.miseq.MHC-B.B069.02",
      "displayLabel": "B069.02",
      "reportLabel": "B069.02",
      "speciesPrefix": "Mamu",
      "populationID": "indian-rhesus",
      "frameworkID": "mamu-indian-regional-blocks",
      "region": "MHC-B",
      "assayResolution": "short_exon_amplicon",
      "definitionStatus": "legacy_curated",
      "sourceIDs": ["source:notebook:miseq-genotyping-without-labkey"],
      "definingMarkers": [
        {
          "observedLabel": "B_069",
          "role": "required_supporting_marker",
          "informativeness": "regional_block_label",
          "compatibleReportLabels": ["B069.01", "B069.02"],
          "sourceIDs": ["source:notebook:miseq-genotyping-without-labkey"]
        },
        {
          "observedLabel": "B_068",
          "role": "supporting_marker",
          "informativeness": "shared_supporting",
          "compatibleReportLabels": ["B069.02", "B091.01", "B056.02"],
          "sourceIDs": ["source:notebook:miseq-genotyping-without-labkey"]
        },
        {
          "observedLabel": "B_075",
          "role": "supporting_marker",
          "informativeness": "supporting",
          "compatibleReportLabels": ["B069.02"],
          "sourceIDs": ["source:notebook:miseq-genotyping-without-labkey"]
        }
      ],
      "extendedHaplotype": null,
      "notes": "Legacy Indian rhesus regional MHC-B label defined by a marker combination."
    },
    {
      "id": "block:mamu:mhc-drb:dr01-01",
      "internalID": "mamu.indian.miseq.MHC-DRB.DR01.01",
      "displayLabel": "DR01.01",
      "reportLabel": "DR01.01",
      "speciesPrefix": "Mamu",
      "populationID": "indian-rhesus",
      "frameworkID": "mamu-indian-regional-blocks",
      "region": "MHC-DRB",
      "assayResolution": "short_exon_amplicon",
      "definitionStatus": "legacy_curated",
      "sourceIDs": ["source:notebook:miseq-genotyping-without-labkey"],
      "definingMarkers": [
        {
          "observedLabel": "DRB1_04_06_01",
          "role": "required_supporting_marker",
          "informativeness": "regional_block_label",
          "compatibleReportLabels": ["DR01.01", "DR01.04"],
          "sourceIDs": ["source:notebook:miseq-genotyping-without-labkey"]
        },
        {
          "observedLabel": "DRB5_03_01",
          "role": "required_supporting_marker",
          "informativeness": "regional_block_label",
          "compatibleReportLabels": ["DR01.01", "DR10.02"],
          "sourceIDs": ["source:notebook:miseq-genotyping-without-labkey"]
        }
      ],
      "extendedHaplotype": null,
      "notes": "Legacy Indian rhesus regional DRB label defined by a marker combination."
    }
  ],
  "markerRules": [
    {
      "id": "rule:mcm:short-exon:a1-063-shared-marker",
      "populationID": "mcm",
      "assayResolution": "short_exon_amplicon",
      "region": "MHC-A",
      "markerPattern": "05_M1M2M3_A1_063g",
      "informativeness": "shared_low_disambiguation",
      "splitHaplotypeDefault": "no",
      "sourceIDs": ["source:notebook:miseq-genotyping-without-labkey"],
      "notes": "This MiSeq marker cannot distinguish M1/M2/M3 by itself."
    },
    {
      "id": "rule:mcm:class-ii:dp-dq-discordance-review",
      "populationID": "mcm",
      "assayResolution": "any",
      "region": "MHC-DP/MHC-DQ",
      "markerPattern": "discordant DP and DQ extended-haplotype families",
      "informativeness": "review_trigger",
      "splitHaplotypeDefault": "review",
      "sourceIDs": ["source:paper:karl-2023-m3-genome-research"],
      "notes": "DP and DQ are linked class II neighborhoods; discordance in MCM suggests rare recombination, dropout, or review."
    },
    {
      "id": "rule:general:full-length-single-variant-no-auto-split",
      "populationID": "all",
      "assayResolution": "full_length_genomic",
      "region": "any",
      "markerPattern": "single novel sequence variant within otherwise known block",
      "informativeness": "variant_annotation",
      "splitHaplotypeDefault": "no",
      "sourceIDs": ["source:notebook:miseq-genotyping-without-labkey"],
      "notes": "Annotate isolated full-length variation unless linked-block evidence, recurrence, or practical matching relevance supports a split."
    }
  ],
  "analystGuidance": [
    {
      "id": "guidance:legacy-labels-as-report-interface",
      "title": "Preserve legacy report labels",
      "text": "Use familiar labels in reports when they are the relevant curated framework: MCM labels such as M1A/M1B/M1DR/M1DQ/M1DP and Indian rhesus regional labels such as A008.01, B069.02, DR01.01, 26g2, and 01g1.",
      "sourceIDs": ["source:notebook:miseq-genotyping-without-labkey"]
    },
    {
      "id": "guidance:internal-blocks-can-be-richer-than-report-labels",
      "title": "Internal blocks can be richer than report labels",
      "text": "Treat display labels as a compatibility layer. Use internal IDs, region, assay resolution, marker roles, and source IDs for reasoning.",
      "sourceIDs": ["source:notebook:miseq-genotyping-without-labkey"]
    },
    {
      "id": "guidance:mamu-ag-can-support-a-region",
      "title": "Mamu-AG may support MHC-A regional structure",
      "text": "Do not ignore AG evidence when it helps support neighboring MHC-A regional blocks, but do not invent a formal AG haplotype label unless curated evidence supports it.",
      "sourceIDs": ["source:notebook:miseq-genotyping-without-labkey"]
    }
  ],
  "digest": "sha256:0000000000000000000000000000000000000000000000000000000000000000"
}
```

The loader recomputes the digest, so the placeholder digest in the JSON is accepted only as a stored field and is not authoritative.

- [ ] **Step 4: Run focused tests**

Run:

```bash
swift test --filter AIHaplotypingKnowledgePackTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/LungfishWorkflow/Resources/AIHaplotyping Tests/LungfishWorkflowTests/AIHaplotypingKnowledgePackTests.swift
git commit -m "feat: bundle macaque mhc ai knowledge pack"
```

---

### Task 3: Infer AI Haplotyping Run Context

**Files:**
- Create: `/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishWorkflow/ONTGenotyping/AIHaplotypingRunContext.swift`
- Test: `/Users/dho/Documents/lungfish-genome-explorer/Tests/LungfishWorkflowTests/AIHaplotypingRunContextTests.swift`

- [ ] **Step 1: Write failing run-context tests**

Create `/Users/dho/Documents/lungfish-genome-explorer/Tests/LungfishWorkflowTests/AIHaplotypingRunContextTests.swift`:

```swift
import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class AIHaplotypingRunContextTests: XCTestCase {
    func testInfersMCMFromMafaMCMDefinitionAndMiSeqMarkers() throws {
        let result = makeResult(
            calls: [makeCall(sample: "LF2711", genotype: "05_M1M2M3_A1_063g")],
            manifestDefinitionID: "mcm-m1-m7",
            manifestAssayID: "miseq-mhc",
            analysis: GenotypeHaplotypeAnalysis(
                assayID: "miseq-mhc",
                definitionSetID: "mcm-m1-m7",
                definitionSetName: "MCM M1-M7",
                speciesName: "Macaca fascicularis",
                source: .deterministic,
                samples: []
            )
        )

        let context = AIHaplotypingRunContextBuilder.context(for: result, knowledgePack: try AIHaplotypingKnowledgePackLoader.bundledMacaqueMHC())

        XCTAssertEqual(context.speciesPrefix, "Mafa")
        XCTAssertEqual(context.populationID, "mcm")
        XCTAssertEqual(context.assayID, "miseq-mhc")
        XCTAssertEqual(context.assayResolution, "short_exon_amplicon")
        XCTAssertEqual(context.workflowKind, "miSeq_or_amplicon_genotyping")
        XCTAssertEqual(context.definitionSetID, "mcm-m1-m7")
        XCTAssertEqual(context.activeFrameworkIDs, ["mcm-m1-m7-extended", "mcm-miseq-regional-blocks"])
    }

    func testInfersIndianRhesusFromMamuPrefixWithoutForcingMCMFramework() throws {
        let result = makeResult(
            calls: [makeCall(sample: "AR3550", genotype: "01_Mamu-A1_008g")],
            manifestDefinitionID: nil,
            manifestAssayID: nil,
            analysis: nil
        )

        let context = AIHaplotypingRunContextBuilder.context(for: result, knowledgePack: try AIHaplotypingKnowledgePackLoader.bundledMacaqueMHC())

        XCTAssertEqual(context.speciesPrefix, "Mamu")
        XCTAssertEqual(context.populationID, "indian-rhesus")
        XCTAssertEqual(context.assayResolution, "short_exon_amplicon")
        XCTAssertEqual(context.activeFrameworkIDs, ["mamu-indian-regional-blocks"])
    }

    private func makeCall(sample: String, genotype: String) -> ONTGenotypeCall {
        ONTGenotypeCall(
            sample: sample,
            genotype: genotype,
            passedAlignments: 42,
            passedUniqueReads: 21,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: nil,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
    }

    private func makeResult(
        calls: [ONTGenotypeCall],
        manifestDefinitionID: String?,
        manifestAssayID: String?,
        analysis: GenotypeHaplotypeAnalysis?
    ) -> ONTGenotypeResultBundleData {
        let manifest = ONTGenotypeResultBundleManifest(
            outputName: "out",
            analysisName: "Test",
            primaryWorkbookPath: "workbook.xlsx",
            longSummaryCSVPath: "long.csv",
            sampleSummaryCSVPath: "samples.csv",
            statsJSONPath: "stats.json",
            provenancePath: "provenance.json",
            haplotypeDefinitionSetID: manifestDefinitionID,
            haplotypeAssayID: manifestAssayID
        )
        let artifacts = ONTGenotypeResultArtifacts(
            workbookURL: URL(fileURLWithPath: "/tmp/workbook.xlsx"),
            longSummaryCSVURL: URL(fileURLWithPath: "/tmp/long.csv"),
            sampleSummaryCSVURL: URL(fileURLWithPath: "/tmp/samples.csv"),
            statsJSONURL: URL(fileURLWithPath: "/tmp/stats.json"),
            provenanceURL: URL(fileURLWithPath: "/tmp/provenance.json")
        )
        return ONTGenotypeResultBundleData(
            bundleURL: URL(fileURLWithPath: "/tmp/out.lungfishgenotype"),
            manifest: manifest,
            artifacts: artifacts,
            stats: ONTGenotypeRunStats(),
            calls: calls,
            samples: [],
            haplotypeAnalysis: analysis
        )
    }
}
```

- [ ] **Step 2: Run tests and verify they fail**

Run:

```bash
swift test --filter AIHaplotypingRunContextTests
```

Expected: FAIL because `AIHaplotypingRunContextBuilder` does not exist.

- [ ] **Step 3: Add run-context implementation**

Create `/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishWorkflow/ONTGenotyping/AIHaplotypingRunContext.swift`:

```swift
import Foundation
import LungfishIO

public struct AIHaplotypingRunContext: Codable, Equatable, Sendable {
    public let speciesPrefix: String
    public let speciesName: String?
    public let populationID: String
    public let assayID: String?
    public let assayResolution: String
    public let workflowKind: String
    public let definitionSetID: String?
    public let definitionSetName: String?
    public let activeFrameworkIDs: [String]
    public let notes: [String]
}

public enum AIHaplotypingRunContextBuilder {
    public static func context(
        for result: ONTGenotypeResultBundleData,
        knowledgePack: AIHaplotypingKnowledgePack
    ) -> AIHaplotypingRunContext {
        let speciesName = result.haplotypeAnalysis?.speciesName
        let prefix = inferSpeciesPrefix(result: result, speciesName: speciesName)
        let population = inferPopulation(prefix: prefix, result: result, knowledgePack: knowledgePack)
        let assayID = result.haplotypeAnalysis?.assayID ?? result.manifest.haplotypeAssayID
        let definitionSetID = result.haplotypeAnalysis?.definitionSetID ?? result.manifest.haplotypeDefinitionSetID
        let assayResolution = inferAssayResolution(assayID: assayID, calls: result.calls)
        let activeFrameworkIDs = knowledgePack.populationProfiles.first { $0.id == population }?.frameworkIDs ?? []

        return AIHaplotypingRunContext(
            speciesPrefix: prefix,
            speciesName: speciesName,
            populationID: population,
            assayID: assayID,
            assayResolution: assayResolution,
            workflowKind: assayResolution == "short_exon_amplicon" ? "miSeq_or_amplicon_genotyping" : "full_length_or_intermediate_genotyping",
            definitionSetID: definitionSetID,
            definitionSetName: result.haplotypeAnalysis?.definitionSetName,
            activeFrameworkIDs: activeFrameworkIDs,
            notes: contextNotes(prefix: prefix, population: population, assayResolution: assayResolution)
        )
    }

    private static func inferSpeciesPrefix(result: ONTGenotypeResultBundleData, speciesName: String?) -> String {
        if let fromName = prefixFromSpeciesName(speciesName) { return fromName }
        for call in result.calls {
            if call.genotype.contains("Mafa") || call.genotype.contains("_M") { return "Mafa" }
            if call.genotype.contains("Mamu") { return "Mamu" }
            if call.genotype.contains("Mane") { return "Mane" }
        }
        return "unknown"
    }

    private static func prefixFromSpeciesName(_ speciesName: String?) -> String? {
        let lower = speciesName?.lowercased() ?? ""
        if lower.contains("fascicularis") { return "Mafa" }
        if lower.contains("mulatta") { return "Mamu" }
        if lower.contains("nemestrina") { return "Mane" }
        return nil
    }

    private static func inferPopulation(
        prefix: String,
        result: ONTGenotypeResultBundleData,
        knowledgePack: AIHaplotypingKnowledgePack
    ) -> String {
        let definitionText = [
            result.haplotypeAnalysis?.definitionSetID,
            result.haplotypeAnalysis?.definitionSetName,
            result.manifest.haplotypeDefinitionSetID,
        ].compactMap { $0?.lowercased() }.joined(separator: " ")
        if prefix == "Mafa", definitionText.contains("mcm") || definitionText.contains("mauritian") {
            return "mcm"
        }
        if prefix == "Mamu" {
            return "indian-rhesus"
        }
        if let profile = knowledgePack.populationProfiles.first(where: { $0.speciesPrefix == prefix }) {
            return profile.id
        }
        return "unknown"
    }

    private static func inferAssayResolution(assayID: String?, calls: [ONTGenotypeCall]) -> String {
        let assay = assayID?.lowercased() ?? ""
        if assay.contains("miseq") || assay.contains("amplicon") { return "short_exon_amplicon" }
        if assay.contains("full") || assay.contains("ont") { return "full_length_or_intermediate" }
        if calls.contains(where: { $0.genotype.range(of: #"^\d{2}_"#, options: .regularExpression) != nil }) {
            return "short_exon_amplicon"
        }
        return "unknown"
    }

    private static func contextNotes(prefix: String, population: String, assayResolution: String) -> [String] {
        var notes: [String] = []
        if population == "mcm" {
            notes.append("MCM should prefer curated M1-M7 extended haplotypes and known recombinant interpretations before novelty.")
        }
        if prefix == "Mamu" {
            notes.append("Mamu regional block labels should not be interpreted as MCM-style whole-MHC haplotypes.")
        }
        if assayResolution == "short_exon_amplicon" {
            notes.append("Short amplicon labels can be collapsed marker groups and may not identify exact full-length alleles.")
        }
        return notes
    }
}
```

- [ ] **Step 4: Run focused tests**

Run:

```bash
swift test --filter AIHaplotypingRunContextTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/ONTGenotyping/AIHaplotypingRunContext.swift Tests/LungfishWorkflowTests/AIHaplotypingRunContextTests.swift
git commit -m "feat: infer ai haplotyping run context"
```

---

### Task 4: Render Prompt Input With Run Context And Knowledge Pack

**Files:**
- Modify: `/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishWorkflow/ONTGenotyping/AIHaplotypingTypes.swift`
- Modify: `/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishWorkflow/ONTGenotyping/AIHaplotypingRunner.swift`
- Modify: `/Users/dho/Documents/lungfish-genome-explorer/Tests/LungfishWorkflowTests/AIHaplotypingRunnerTests.swift`
- Modify: `/Users/dho/Documents/lungfish-genome-explorer/Tests/LungfishWorkflowTests/AIHaplotypingPromptRegistryTests.swift`

- [ ] **Step 1: Add failing prompt-rendering assertions**

In `/Users/dho/Documents/lungfish-genome-explorer/Tests/LungfishWorkflowTests/AIHaplotypingPromptRegistryTests.swift`, add to `testCurrentDiscoveryAndRefinementPromptsHaveStableIdentityAndDistinctHashes`:

```swift
XCTAssertTrue(discovery.userPromptTemplate.contains("{{prompt_input_json}}"))
XCTAssertTrue(refinement.userPromptTemplate.contains("{{prompt_input_json}}"))
```

In `/Users/dho/Documents/lungfish-genome-explorer/Tests/LungfishWorkflowTests/AIHaplotypingRunnerTests.swift`, update the mock provider helper parsing so it decodes the root prompt input and add assertions after `requests` are collected:

```swift
let promptInputs = try requests.map { try Self.promptInput(from: $0) }
XCTAssertEqual(promptInputs[0].knowledgePack.id, "macaque-mhc")
XCTAssertEqual(promptInputs[0].knowledgePack.version, "2026-06-15.1")
XCTAssertEqual(promptInputs[0].runContext.assayResolution, "short_exon_amplicon")
XCTAssertTrue(promptInputs[0].knowledgePack.legacyBlockDefinitions.contains { $0.reportLabel == "M1A" })
XCTAssertEqual(output.chunkOutputs[0].promptMetadata.knowledgePackID, "macaque-mhc")
XCTAssertEqual(output.chunkOutputs[0].promptMetadata.knowledgePackVersion, "2026-06-15.1")
XCTAssertTrue(output.chunkOutputs[0].promptMetadata.knowledgePackDigest?.hasPrefix("sha256:") == true)
```

Add a test helper near the existing `registry(from:)` helper:

```swift
private struct PromptInputProbe: Decodable {
    let chunkID: String
    let runContext: AIHaplotypingRunContext
    let knowledgePack: AIHaplotypingKnowledgePack
    let evidenceRegistry: AIHaplotypingEvidenceRegistry
}

private static func promptInput(from request: AIStructuredRequest) throws -> PromptInputProbe {
    let json = try promptJSON(from: request.userPrompt)
    return try JSONDecoder().decode(PromptInputProbe.self, from: Data(json.utf8))
}
```

Keep the existing `registry(from:)` helper by changing it to:

```swift
private static func registry(from request: AIStructuredRequest) throws -> AIHaplotypingEvidenceRegistry {
    try promptInput(from: request).evidenceRegistry
}
```

- [ ] **Step 2: Run tests and verify they fail**

Run:

```bash
swift test --filter AIHaplotypingRunnerTests/testRunnerBuildsChunkedStructuredRequestsAndReducesValidatedCalls --filter AIHaplotypingPromptRegistryTests/testCurrentDiscoveryAndRefinementPromptsHaveStableIdentityAndDistinctHashes
```

Expected: FAIL because prompts still use `{{evidence_registry_json}}`, prompt input lacks `runContext` and `knowledgePack`, and prompt metadata lacks knowledge fields.

- [ ] **Step 3: Add prompt metadata and rendering compatibility**

Patch `/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishWorkflow/ONTGenotyping/AIHaplotypingTypes.swift`:

```swift
public func render(promptInputJSON: String) -> String {
    userPromptTemplate
        .replacingOccurrences(of: "{{prompt_input_json}}", with: promptInputJSON)
        .replacingOccurrences(of: "{{evidence_registry_json}}", with: promptInputJSON)
}

public func render(evidenceRegistryJSON: String) -> String {
    render(promptInputJSON: evidenceRegistryJSON)
}
```

Extend `metadata`:

```swift
public func metadata(
    registryDigest: String,
    inputSnapshotDigest: String,
    evidenceSnapshotPath: String,
    knowledgePack: AIHaplotypingKnowledgePack? = nil
) -> AIHaplotypingPromptMetadata {
    AIHaplotypingPromptMetadata(
        promptTemplateID: id,
        promptTemplateVersion: version,
        promptHash: promptHash,
        evidenceSchemaVersion: evidenceSchemaVersion,
        registryDigest: registryDigest,
        inputSnapshotDigest: inputSnapshotDigest,
        evidenceSnapshotPath: evidenceSnapshotPath,
        knowledgePackID: knowledgePack?.id,
        knowledgePackVersion: knowledgePack?.version,
        knowledgePackDigest: knowledgePack?.digest
    )
}
```

Extend `AIHaplotypingPromptMetadata`:

```swift
public let knowledgePackID: String?
public let knowledgePackVersion: String?
public let knowledgePackDigest: String?
```

Update its initializer with defaulted optional parameters:

```swift
knowledgePackID: String? = nil,
knowledgePackVersion: String? = nil,
knowledgePackDigest: String? = nil
```

Assign those values in the initializer body. Do not remove existing fields or change their names.

- [ ] **Step 4: Add knowledge/context prompt input to runner**

Patch `/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishWorkflow/ONTGenotyping/AIHaplotypingRunner.swift`:

After evidence chunking and before prompt template resolution:

```swift
let knowledgePack: AIHaplotypingKnowledgePack
do {
    knowledgePack = try AIHaplotypingKnowledgePackLoader.bundledMacaqueMHC()
} catch {
    throw AIHaplotypingRunFailure(
        stage: .prompt,
        sanitizedErrorCategory: "knowledge_pack_missing",
        message: error.localizedDescription
    )
}
let runContext = AIHaplotypingRunContextBuilder.context(for: result, knowledgePack: knowledgePack)
```

Change prompt metadata creation:

```swift
let promptMetadata = template.metadata(
    registryDigest: chunk.registry.digest,
    inputSnapshotDigest: chunk.registry.inputSnapshotDigest,
    evidenceSnapshotPath: "ai-haplotyping/evidence/\(chunk.id).json",
    knowledgePack: knowledgePack
)
```

Change prompt rendering:

```swift
userPrompt: template.render(
    promptInputJSON: try promptInputJSONString(
        chunk: chunk,
        expectedRun: expectedRun,
        runContext: runContext,
        knowledgePack: knowledgePack
    )
),
```

Replace the private `promptInputJSONString` signature and body:

```swift
private func promptInputJSONString(
    chunk: AIHaplotypingEvidenceChunk,
    expectedRun: AIHaplotypingRunMetadata,
    runContext: AIHaplotypingRunContext,
    knowledgePack: AIHaplotypingKnowledgePack
) throws -> String {
    let input = PromptInput(
        chunkID: chunk.id,
        expectedRun: expectedRun,
        runContext: runContext,
        knowledgePack: knowledgePack,
        evidenceRegistry: chunk.registry
    )
    let data = AIHaplotypingCanonicalJSON.canonicalData(of: input)
    guard let json = String(data: data, encoding: .utf8) else {
        throw AIProviderError.decodingError("AI haplotyping prompt input was not UTF-8.")
    }
    return json
}
```

Update the private `PromptInput` type at the bottom of the file:

```swift
private struct PromptInput: Encodable {
    let chunkID: String
    let expectedRun: AIHaplotypingRunMetadata
    let runContext: AIHaplotypingRunContext
    let knowledgePack: AIHaplotypingKnowledgePack
    let evidenceRegistry: AIHaplotypingEvidenceRegistry
}
```

- [ ] **Step 5: Run focused tests**

Run:

```bash
swift test --filter AIHaplotypingRunnerTests/testRunnerBuildsChunkedStructuredRequestsAndReducesValidatedCalls
swift test --filter AIHaplotypingPromptRegistryTests/testTemplateMetadataDoesNotEncodePromptText
```

Expected: PASS after tests are updated to parse the new prompt input root.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishWorkflow/ONTGenotyping/AIHaplotypingTypes.swift Sources/LungfishWorkflow/ONTGenotyping/AIHaplotypingRunner.swift Tests/LungfishWorkflowTests/AIHaplotypingRunnerTests.swift Tests/LungfishWorkflowTests/AIHaplotypingPromptRegistryTests.swift
git commit -m "feat: pass macaque mhc knowledge to ai haplotyping prompts"
```

---

### Task 5: Promote Domain-Aware Prompt Templates

**Files:**
- Modify: `/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishWorkflow/ONTGenotyping/AIHaplotypingPromptRegistry.swift`
- Modify: `/Users/dho/Documents/lungfish-genome-explorer/Tests/LungfishWorkflowTests/AIHaplotypingPromptRegistryTests.swift`

- [ ] **Step 1: Update tests for v2 prompt version and content**

Patch `/Users/dho/Documents/lungfish-genome-explorer/Tests/LungfishWorkflowTests/AIHaplotypingPromptRegistryTests.swift`:

```swift
XCTAssertEqual(discovery.version, "2026-06-15.1")
XCTAssertEqual(refinement.version, "2026-06-15.1")
XCTAssertTrue(discovery.systemPrompt.contains("macaque MHC"))
XCTAssertTrue(discovery.systemPrompt.contains("legacy report labels"))
XCTAssertTrue(discovery.systemPrompt.contains("assay resolution"))
XCTAssertTrue(refinement.systemPrompt.contains("preserve defensible current calls"))
XCTAssertTrue(refinement.userPromptTemplate.contains("{{prompt_input_json}}"))
```

- [ ] **Step 2: Run prompt tests and verify they fail**

Run:

```bash
swift test --filter AIHaplotypingPromptRegistryTests
```

Expected: FAIL because the built-in prompts are still version `2026-06-14.1`.

- [ ] **Step 3: Update built-in prompts**

Patch `/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishWorkflow/ONTGenotyping/AIHaplotypingPromptRegistry.swift` so `builtInDiscovery` has:

```swift
version: "2026-06-15.1",
evidenceSchemaVersion: 1,
systemPrompt: """
You are reconstructing reviewable macaque MHC haplotype and regional-block calls from genotyping evidence.
Use only supplied evidence records, run context, knowledge-pack assertions, and selected prompt examples.
Preserve familiar legacy report labels when the supplied knowledge pack defines them, but reason internally with species, population, genomic region, assay resolution, marker informativeness, and source IDs.
Prefer curated known frameworks before proposing novelty. For MCM, try M1-M7 extended haplotypes and known recombinant interpretations before any novel extended haplotype. For Indian-origin rhesus macaques, treat labels such as A008.01, B069.02, DR01.01, 26g2, and 01g1 as regional block/report labels rather than MCM-style whole-MHC haplotypes.
Distinguish a novel sequence variant from a novel haplotype. Do not split a haplotype from an isolated full-length variant unless linked marker structure, recurrence, practical matching relevance, or a supplied rule supports that split.
Treat the result as analyst-review input, not an automatically final scientific conclusion.
""",
userPromptTemplate: """
Review this AI haplotyping prompt input and propose reviewable haplotype or regional-block calls.

Prompt input JSON:
{{prompt_input_json}}
"""
```

Patch `builtInRefinement` similarly:

```swift
version: "2026-06-15.1",
evidenceSchemaVersion: 1,
systemPrompt: """
Refine existing macaque MHC haplotype and regional-block calls using only the supplied review evidence, run context, knowledge pack, and current calls.
Preserve defensible current calls. Identify conflicts with manual review evidence, low-support bleed-through, missing expected markers, assay-resolution limits, and possible recombinant or provisional-novel patterns.
Keep familiar legacy report labels when they are supported by the knowledge pack. Use internal knowledge-pack structure to explain why the report label is appropriate.
For MCM, prefer M1-M7 and known recombinant interpretations before novelty. For Indian-origin rhesus macaques, refine regional block labels without forcing whole-MHC ancestral haplotypes.
Return reviewable refinements rather than untraceable final calls.
""",
userPromptTemplate: """
Refine the current haplotype or regional-block calls using this prompt input.

Prompt input JSON:
{{prompt_input_json}}
"""
```

- [ ] **Step 4: Run prompt tests**

Run:

```bash
swift test --filter AIHaplotypingPromptRegistryTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/ONTGenotyping/AIHaplotypingPromptRegistry.swift Tests/LungfishWorkflowTests/AIHaplotypingPromptRegistryTests.swift
git commit -m "feat: teach ai haplotyping prompts macaque mhc context"
```

---

### Task 6: Record Knowledge Pack Metadata In Provenance

**Files:**
- Modify: `/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishWorkflow/ONTGenotyping/AIHaplotypingRevisionPublisher.swift`
- Modify: `/Users/dho/Documents/lungfish-genome-explorer/Tests/LungfishWorkflowTests/AIHaplotypingRevisionPublisherTests.swift`

- [ ] **Step 1: Add failing provenance assertions**

In `/Users/dho/Documents/lungfish-genome-explorer/Tests/LungfishWorkflowTests/AIHaplotypingRevisionPublisherTests.swift`, find the test that inspects the provenance envelope for AI haplotyping revision publishing. Add assertions against resolved options:

```swift
let resolved = try XCTUnwrap(envelope.parameters?.resolved)
XCTAssertEqual(resolved["knowledgePackID"], .string("macaque-mhc"))
XCTAssertEqual(resolved["knowledgePackVersion"], .string("2026-06-15.1"))
if case .string(let digest)? = resolved["knowledgePackDigest"] {
    XCTAssertTrue(digest.hasPrefix("sha256:"))
} else {
    XCTFail("Expected knowledgePackDigest resolved option")
}
```

If the existing test helper uses dictionaries of `ParameterValue`, place these assertions next to the existing `promptHash`, `registryDigest`, and `inputSnapshotDigest` checks.

- [ ] **Step 2: Run publisher tests and verify they fail**

Run:

```bash
swift test --filter AIHaplotypingRevisionPublisherTests
```

Expected: FAIL because knowledge-pack provenance options are not recorded.

- [ ] **Step 3: Add provenance fields**

Patch `provenanceOptions` in `/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishWorkflow/ONTGenotyping/AIHaplotypingRevisionPublisher.swift` after `promptHash`:

```swift
let promptMetadata = request.runnerOutput.chunkOutputs.first?.promptMetadata
resolved["knowledgePackID"] = .string(promptMetadata?.knowledgePackID ?? "unknown")
resolved["knowledgePackVersion"] = .string(promptMetadata?.knowledgePackVersion ?? "unknown")
resolved["knowledgePackDigest"] = .string(promptMetadata?.knowledgePackDigest ?? "unknown")
```

- [ ] **Step 4: Run publisher tests**

Run:

```bash
swift test --filter AIHaplotypingRevisionPublisherTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/ONTGenotyping/AIHaplotypingRevisionPublisher.swift Tests/LungfishWorkflowTests/AIHaplotypingRevisionPublisherTests.swift
git commit -m "feat: record ai haplotyping knowledge provenance"
```

---

### Task 7: Final Verification

**Files:**
- No additional source files.

- [ ] **Step 1: Run focused AI haplotyping workflow tests**

Run:

```bash
swift test --filter AIHaplotyping
```

Expected: PASS.

- [ ] **Step 2: Run haplotype definition related tests**

Run:

```bash
swift test --filter HaplotypeDefinition
```

Expected: PASS.

- [ ] **Step 3: Inspect git diff for unintended changes**

Run:

```bash
git diff --stat
git diff -- Package.swift Sources/LungfishWorkflow/ONTGenotyping Sources/LungfishWorkflow/Resources/AIHaplotyping Tests/LungfishWorkflowTests
```

Expected: changes are limited to the files in this plan.

- [ ] **Step 4: Final commit if any verification-only fix was needed**

If verification required a fix, commit that fix:

```bash
git add Package.swift Sources/LungfishWorkflow/ONTGenotyping Sources/LungfishWorkflow/Resources/AIHaplotyping Tests/LungfishWorkflowTests
git commit -m "test: stabilize ai haplotyping knowledge context"
```

If no verification fix was needed, do not create an empty commit.

---

## Self-Review

**Spec coverage:** This plan implements the first usable slice of the design: source-aware macaque MHC knowledge context, legacy report-label compatibility, run context, assay-resolution awareness, prompt injection, and provenance. It does not implement the full staff-editable CSV compiler or example-case selector; those remain later slices after prompt-context wiring is tested.

**Placeholder scan:** The plan contains no incomplete implementation placeholders. The bundled JSON uses a zero digest because the loader recomputes digest from content before use; the plan states that behavior explicitly.

**Type consistency:** Model names are consistent across tasks: `AIHaplotypingKnowledgePack`, `AIHaplotypingKnowledgePackLoader`, `AIHaplotypingRunContext`, and `AIHaplotypingRunContextBuilder`. Prompt metadata fields are consistently named `knowledgePackID`, `knowledgePackVersion`, and `knowledgePackDigest`.
