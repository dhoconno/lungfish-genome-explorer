# Dependency Upgrade Mechanism Implementation Plan (Plan A)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Fable orchestrates and reviews every task; see the master index for model routing.

**Goal:** One dependency manifest with a `dependencySet` version, an on-disk install receipt, and a reconciler (plan + apply) that brings fresh and previously installed machines to the manifest state, exposed through an Update Tools sheet and `lungfish-cli tools update`.

**Architecture:** `ManagedToolLock` (the JSON at `Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json`) grows optional sections (`dependencySet`, `packTools`, `pipelines`, `databases`, `bootstrap`); every other pin site becomes a lookup. A new `Sources/LungfishWorkflow/Dependencies/` module holds `DependencyReceipt` (+ store), `DependencyPlanner` (pure plan computation), and `DependencyReconciler` (actor that applies a plan through `CondaManager`, `DatabaseRegistry`, `MetagenomicsDatabaseRegistry`). GUI sheet and CLI subcommands are thin views over the same plan.

**Tech Stack:** Swift 6.2, SwiftPM, XCTest, SwiftUI sheet inside AppKit host, ArgumentParser CLI, micromamba.

**Spec:** `docs/superpowers/specs/2026-08-17-dependency-upgrade-mechanism-design.md` (sections 4.1 to 4.5, 4.8, 4.9)

## Global Constraints

- Manifest path and filename unchanged: `Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json`, loaded via `ManagedToolLock.loadFromBundle()`.
- Every conda spec in the manifest carries a full build string (`channel::name=version=build`).
- New sections are optional in decoding; old manifest shapes must still decode.
- Receipt path: `<storage root>/dependency-receipt.json`, schemaVersion 1, atomic writes, guarded by `CondaRootMutationLock`.
- Reconciler policy: required pack changes block new analyses; optional packs reinstall only if installed; retired named envs removed after reinstalls; databases advisory unless `updatePolicy == "required"`; superseded copies removed after success.
- All long operations go through `OperationCenter.shared.start/update/log/complete/fail`; write a `.metadataOnly` provenance envelope under `<storage root>/provenance/dependencies/`.
- CLI never presents UI; `--apply` requires `--yes`.
- Test baseline: green bar = XCTest failures ⊆ the 9 known-environmental failures and swift-testing = 0. Run `swift test --skip-update --filter <Name>` for inner loop; `bash scripts/full-suite-gate.sh` before merge. One swift invocation at a time.

## File structure

Create:
- `Sources/LungfishWorkflow/Dependencies/DependencyManifestSections.swift` (PackToolSpec, PipelineSpec, DatabaseSpec, BootstrapSpec, DependencyManifest typealias + accessors)
- `Sources/LungfishWorkflow/Dependencies/DependencyReceipt.swift` (receipt model)
- `Sources/LungfishWorkflow/Dependencies/DependencyReceiptStore.swift` (load/save/synthesize)
- `Sources/LungfishWorkflow/Dependencies/CondaMetaReader.swift` (shared conda-meta reader, replaces private struct in PluginPackStatusService)
- `Sources/LungfishWorkflow/Dependencies/ReconciliationPlan.swift` (plan types)
- `Sources/LungfishWorkflow/Dependencies/DependencyPlanner.swift` (pure planning)
- `Sources/LungfishWorkflow/Dependencies/DependencyReconciler.swift` (actor: gather inputs, apply plan)
- `Sources/LungfishWorkflow/Dependencies/DependencyReconcilerProvenance.swift` (envelope writer)
- `Sources/LungfishCLI/Commands/ToolsCommand.swift` (`tools update`)
- `Sources/LungfishApp/Views/Dependencies/UpdateToolsSheet.swift` (SwiftUI)
- `Sources/LungfishApp/Views/Dependencies/UpdateToolsSheetController.swift` (AppKit host + view model)
- `Sources/LungfishApp/App/AppDelegate+DependencyReconciliation.swift` (launch trigger)
- Tests: `Tests/LungfishWorkflowTests/Dependencies/*.swift`, `Tests/LungfishCLITests/ToolsCommandTests.swift`, `Tests/LungfishAppTests/UpdateToolsSheetViewModelTests.swift`

Modify:
- `Sources/LungfishWorkflow/Conda/ManagedToolLock.swift` (add optional sections)
- `Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json` (add sections for the current 2026.1 set)
- `Sources/LungfishWorkflow/Conda/PluginPack.swift` (pack requirements resolve specs from manifest)
- `Sources/LungfishWorkflow/Conda/PluginPackStatusService.swift` (use CondaMetaReader; compare build string)
- `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCGenotypingRunRequest.swift`, `Sources/LungfishWorkflow/Savont/SavontClusteringRunRequest.swift`, `Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline.swift`, `Sources/LungfishWorkflow/ONTGenotyping/ONTGenotypingPipeline.swift`, `Sources/LungfishWorkflow/Metagenomics/EsVirituPipeline.swift` (lookups)
- `Sources/LungfishWorkflow/TaxTriage/TaxTriageConfig.swift`, `Sources/LungfishWorkflow/nf-core/NFCoreSupportedWorkflowCatalog.swift`
- `Sources/LungfishWorkflow/Metagenomics/MetagenomicsDatabaseInfo.swift`, `MetagenomicsModels.swift`, `EsVirituDatabaseManager.swift`, `MetagenomicsDatabaseRegistry.swift`
- `Sources/LungfishWorkflow/Databases/DatabaseRegistry.swift` (manifests from the dependency manifest; delete `Resources/Databases/*/manifest.json`)
- `Sources/LungfishWorkflow/Native/ToolProvisioning/ToolManifest.swift`, `Sources/LungfishWorkflow/Resources/Tools/tool-versions.json`
- `Sources/LungfishWorkflow/Provenance/ProvenanceEnvelope.swift`, `ProvenanceRunBuilder.swift`
- `Sources/LungfishCore/Storage/ManagedStorageConfigStore.swift` (`LUNGFISH_STORAGE_ROOT`)
- `Sources/LungfishCLI/LungfishCLI.swift`, `Sources/LungfishCLI/Commands/DbCommand.swift`, `Sources/LungfishCLI/Commands/VersionCommand.swift`
- `Sources/LungfishApp/App/AppDelegate.swift`, `Sources/LungfishApp/Views/PluginManager/PluginManagerView.swift`, `PluginManagerViewModel.swift`, `Sources/LungfishApp/Windows/AboutWindowController.swift` (or wherever the tools table lives; locate with `grep -rn "third-party-tools-lock\|ManagedToolLock" Sources/LungfishApp`)
- Tests to rewrite/delete: `Tests/LungfishWorkflowTests/CondaManagerTests.swift:208-224`, `PluginPackRegistryTests.swift`, `Metagenomics/EsVirituPipelineTests.swift:1060,1063`, `Tests/LungfishAppTests/PluginPackVisibilityTests.swift:655,748`, `PluginPackStatusServiceTests.swift:421`, `CondaLockfileServiceTests.swift:35,43`, `BundleContainerExportTests.swift:38`

---

### Task A1: Manifest sections and `dependencySet`

**Files:**
- Create: `Sources/LungfishWorkflow/Dependencies/DependencyManifestSections.swift`
- Modify: `Sources/LungfishWorkflow/Conda/ManagedToolLock.swift:145-165` (stored properties + init + decoding)
- Modify: `Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json`
- Test: `Tests/LungfishWorkflowTests/Dependencies/DependencyManifestTests.swift`

**Interfaces:**
- Produces: `ManagedToolLock.dependencySet: String?`, `dependencySetDate: String?`, `packTools: [PackToolSpec]`, `pipelines: [PipelineSpec]`, `databases: [DatabaseSpec]`, `bootstrap: BootstrapSpec?`, `resolvedDependencySet: String`, `packTool(packID:id:) -> PackToolSpec?`, `pipeline(id:) -> PipelineSpec?`, `database(id:) -> DatabaseSpec?`, `manifestHash: String` (sha256 of canonical JSON), `allCondaSpecs: [String]`. `typealias DependencyManifest = ManagedToolLock`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/LungfishWorkflowTests/Dependencies/DependencyManifestTests.swift
import XCTest
@testable import LungfishWorkflow

final class DependencyManifestTests: XCTestCase {
    func testBundledManifestHasDependencySetAndSections() throws {
        let manifest = try ManagedToolLock.loadFromBundle()
        XCTAssertNotNil(manifest.dependencySet)
        XCTAssertTrue(manifest.resolvedDependencySet.range(of: #"^\d{4}\.[12]$"#, options: .regularExpression) != nil,
                      "dependencySet must be YYYY.N, got \(manifest.resolvedDependencySet)")
        XCTAssertFalse(manifest.packTools.isEmpty)
        XCTAssertNotNil(manifest.pipeline(id: "taxtriage"))
        XCTAssertNotNil(manifest.database(id: "human-scrubber"))
        XCTAssertNotNil(manifest.bootstrap?.micromamba.version)
    }

    func testEveryCondaSpecHasFullBuildString() throws {
        let manifest = try ManagedToolLock.loadFromBundle()
        for spec in manifest.allCondaSpecs {
            let parts = spec.split(separator: "=", omittingEmptySubsequences: false)
            XCTAssertEqual(parts.count, 3, "spec must be channel::name=version=build, got \(spec)")
            XCTAssertTrue(spec.contains("::"), "spec must carry a channel, got \(spec)")
        }
    }

    func testLegacyShapeStillDecodes() throws {
        let legacy = """
        {"packID":"lungfish-tools","displayName":"Third-Party Tools","version":"0.5.0-beta29",
         "tools":[{"id":"samtools","environment":"samtools","packageSpec":"bioconda::samtools=1.23.1=hc612e98_0","executables":["samtools"],"version":"1.23.1"}],
         "managedData":[]}
        """.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(ManagedToolLock.self, from: legacy)
        XCTAssertNil(manifest.dependencySet)
        XCTAssertEqual(manifest.resolvedDependencySet, "legacy-0.5.0-beta29")
        XCTAssertTrue(manifest.packTools.isEmpty)
    }

    func testManifestHashIsStableAcrossKeyOrder() throws {
        let a = try JSONDecoder().decode(ManagedToolLock.self, from: Data(#"{"packID":"p","displayName":"d","version":"1","tools":[],"managedData":[],"dependencySet":"2026.1"}"#.utf8))
        let b = try JSONDecoder().decode(ManagedToolLock.self, from: Data(#"{"dependencySet":"2026.1","managedData":[],"tools":[],"version":"1","displayName":"d","packID":"p"}"#.utf8))
        XCTAssertEqual(a.manifestHash, b.manifestHash)
        XCTAssertEqual(a.manifestHash.count, 64)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --skip-update --filter DependencyManifestTests`
Expected: FAIL (compile error: `dependencySet` not a member).

- [ ] **Step 3: Add section types**

```swift
// Sources/LungfishWorkflow/Dependencies/DependencyManifestSections.swift
import Foundation
import CryptoKit

public typealias DependencyManifest = ManagedToolLock

public struct PackToolSpec: Sendable, Codable, Hashable, Identifiable {
    public var id: String { "\(packID)/\(toolID)" }
    public let packID: String
    public let toolID: String
    public let environment: String
    public let packageSpec: String
    public let executables: [String]
    public let version: String
    public let license: String?
    public let sourceUrl: String?

    enum CodingKeys: String, CodingKey {
        case packID, toolID = "id", environment, packageSpec, executables, version, license, sourceUrl
    }
}

public struct PipelineSpec: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let repository: String
    public let revision: String
    public let releaseVersion: String
}

public enum DatabaseUpdatePolicy: String, Sendable, Codable {
    case advisory
    case required
}

public struct DatabaseSpec: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let tool: String
    public let displayName: String
    public let version: String
    public let url: String?
    public let filename: String?
    public let md5: String?
    public let sha256: String?
    public let md5Sidecar: Bool?
    public let indexFormat: Int?
    public let minimumToolVersion: String?
    public let sizeBytes: Int64?
    public let sizeOnDisk: Int64?
    public let recommendedRAM: Int64?
    public let description: String?
    public let releaseDate: String?
    public let sourceUrl: String?
    public let releasesUrl: String?
    public let updatePolicy: DatabaseUpdatePolicy?
    /// Kraken2 collection raw value when this entry is a Kraken2 catalog entry (e.g. "standard-16").
    public let collection: String?

    public var effectiveUpdatePolicy: DatabaseUpdatePolicy { updatePolicy ?? .advisory }
}

public struct MicromambaSpec: Sendable, Codable, Hashable {
    public let version: String
    /// Keyed by platform ("osx-arm64").
    public let sha256: [String: String]?
}

public struct BootstrapSpec: Sendable, Codable, Hashable {
    public let micromamba: MicromambaSpec
}

public extension ManagedToolLock {
    var resolvedDependencySet: String { dependencySet ?? "legacy-\(version)" }

    func packTool(packID: String, id: String) -> PackToolSpec? {
        packTools.first { $0.packID == packID && $0.toolID == id }
    }
    func pipeline(id: String) -> PipelineSpec? { pipelines.first { $0.id == id } }
    func database(id: String) -> DatabaseSpec? { databases.first { $0.id == id } }

    /// Every conda spec the manifest pins (managed tools + pack tools).
    var allCondaSpecs: [String] { tools.map(\.packageSpec) + packTools.map(\.packageSpec) }

    /// sha256 over canonical (sorted-keys) JSON of the manifest.
    var manifestHash: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(self)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
```

- [ ] **Step 4: Extend `ManagedToolLock` with optional stored sections**

In `Sources/LungfishWorkflow/Conda/ManagedToolLock.swift` replace the stored properties + init (lines 145-165) with:

```swift
    public let packID: String
    public let displayName: String
    public let version: String
    public let tools: [ToolSpec]
    public let managedData: [ManagedDataSpec]
    public let dependencySet: String?
    public let dependencySetDate: String?
    public let packTools: [PackToolSpec]
    public let pipelines: [PipelineSpec]
    public let databases: [DatabaseSpec]
    public let bootstrap: BootstrapSpec?

    public init(
        packID: String,
        displayName: String,
        version: String,
        tools: [ToolSpec],
        managedData: [ManagedDataSpec],
        dependencySet: String? = nil,
        dependencySetDate: String? = nil,
        packTools: [PackToolSpec] = [],
        pipelines: [PipelineSpec] = [],
        databases: [DatabaseSpec] = [],
        bootstrap: BootstrapSpec? = nil
    ) {
        self.packID = packID
        self.displayName = displayName
        self.version = version
        self.tools = tools
        self.managedData = managedData
        self.dependencySet = dependencySet
        self.dependencySetDate = dependencySetDate
        self.packTools = packTools
        self.pipelines = pipelines
        self.databases = databases
        self.bootstrap = bootstrap
    }

    enum CodingKeys: String, CodingKey {
        case packID, displayName, version, tools, managedData
        case dependencySet, dependencySetDate, packTools, pipelines, databases, bootstrap
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        packID = try c.decode(String.self, forKey: .packID)
        displayName = try c.decode(String.self, forKey: .displayName)
        version = try c.decode(String.self, forKey: .version)
        tools = try c.decode([ToolSpec].self, forKey: .tools)
        managedData = try c.decodeIfPresent([ManagedDataSpec].self, forKey: .managedData) ?? []
        dependencySet = try c.decodeIfPresent(String.self, forKey: .dependencySet)
        dependencySetDate = try c.decodeIfPresent(String.self, forKey: .dependencySetDate)
        packTools = try c.decodeIfPresent([PackToolSpec].self, forKey: .packTools) ?? []
        pipelines = try c.decodeIfPresent([PipelineSpec].self, forKey: .pipelines) ?? []
        databases = try c.decodeIfPresent([DatabaseSpec].self, forKey: .databases) ?? []
        bootstrap = try c.decodeIfPresent(BootstrapSpec.self, forKey: .bootstrap)
    }
```

(Keep the synthesized `encode(to:)`; `Codable` conformance stays.)

- [ ] **Step 5: Add the sections to the JSON for the current set (2026.1)**

Edit `third-party-tools-lock.json`: keep `tools` and `managedData` exactly as they are; add after `"version"`:

```json
  "dependencySet": "2026.1",
  "dependencySetDate": "2026-08-17",
```

Add `packTools` with one entry per active pack requirement in `PluginPack.builtIn` (read-mapping: minimap2, bwa-mem2, bowtie2; full-length-mhc-genotyping: savont, blast; variant-calling: lofreq, ivar, medaka, clair3; gatk-core: gatk4; phasing: whatshap; assembly: spades, megahit, skesa, flye, hifiasm; multiple-sequence-alignment: mafft; phylogenetics: iqtree; metagenomics: kraken2, bracken, esviritu, ribodetector; wastewater-surveillance: freyja). Resolve each full build string for the CURRENT pinned version with the local micromamba, for example:

```bash
~/.lungfish/conda/bin/micromamba search -c bioconda -c conda-forge --platform osx-arm64 'minimap2=2.30' --json | python3 -c 'import json,sys; [print(p["version"],p["build"],p["subdir"]) for p in json.load(sys.stdin)["result"]["pkgs"]]'
```

Prefer the `osx-arm64` build; use `noarch` when no arm64 build exists (esviritu, bracken, freyja). Known values as of 2026-08-17: minimap2 `2.30=hba9b596_0`, bwa-mem2 `2.3=hda5e58c_0`, bowtie2 `2.5.4=hdd4e3a4_7`, savont `0.5.0=ha819e4a_0`, blast `2.16.0=hb260f6e_5`, lofreq `2.1.5=py310h9cf5bfa_16`, ivar `1.4.4=hda5e58c_0`, clair3 `2.0.0=py311h9aa1f4a_2`, spades `4.2.0=h4d841d5_2`, megahit `1.2.9=h96a01ab_8`, skesa `2.5.1=hda5e58c_3`, flye `2.9.6=py310hba4535a_1`, hifiasm `0.25.0=h697fd72_0`, mafft (conda-forge) `7.526=h99b78c6_0`, iqtree `3.1.1=h56a6eee_1`, kraken2 `2.17.1=pl5321h158e17b_0`, bracken `1.0.0=1`, esviritu `1.3.1=pyhdfd78af_0`, ribodetector `0.3.3=pyhdfd78af_0`. Resolve medaka 2.1.1, gatk4 4.6.2.0, whatshap 2.3, freyja 2.0.0 with the command above.

Entry shape:

```json
  "packTools": [
    { "packID": "read-mapping", "id": "minimap2", "environment": "minimap2", "packageSpec": "bioconda::minimap2=2.30=hba9b596_0", "executables": ["minimap2"], "version": "2.30", "license": "MIT", "sourceUrl": "https://github.com/lh3/minimap2" },
    ...
  ],
  "pipelines": [
    { "id": "taxtriage", "repository": "jhuapl-bio/taxtriage", "revision": "8fd1fb5bb236e4978f5734e522e6b89e0640a2a9", "releaseVersion": "v3.3.6" },
    { "id": "nf-core-viralrecon", "repository": "nf-core/viralrecon", "revision": "3.0.0", "releaseVersion": "3.0.0" }
  ],
  "databases": [
    { "id": "kraken2-standard", "tool": "kraken2", "collection": "standard", "displayName": "Standard", "version": "20240904", "url": "https://genome-idx.s3.amazonaws.com/kraken/k2_standard_20240904.tar.gz" },
    { "id": "kraken2-standard-8", "tool": "kraken2", "collection": "standard-8", "displayName": "Standard-8", "version": "20240904", "url": "https://genome-idx.s3.amazonaws.com/kraken/k2_standard_08gb_20240904.tar.gz" },
    { "id": "kraken2-standard-16", "tool": "kraken2", "collection": "standard-16", "displayName": "Standard-16", "version": "20240904", "url": "https://genome-idx.s3.amazonaws.com/kraken/k2_standard_16gb_20240904.tar.gz" },
    { "id": "kraken2-pluspf", "tool": "kraken2", "collection": "pluspf", "displayName": "PlusPF", "version": "20240904", "url": "https://genome-idx.s3.amazonaws.com/kraken/k2_pluspf_20240904.tar.gz" },
    { "id": "kraken2-pluspf-8", "tool": "kraken2", "collection": "pluspf-8", "displayName": "PlusPF-8", "version": "20240904", "url": "https://genome-idx.s3.amazonaws.com/kraken/k2_pluspf_08gb_20240904.tar.gz" },
    { "id": "kraken2-pluspf-16", "tool": "kraken2", "collection": "pluspf-16", "displayName": "PlusPF-16", "version": "20240904", "url": "https://genome-idx.s3.amazonaws.com/kraken/k2_pluspf_16gb_20240904.tar.gz" },
    { "id": "kraken2-viral", "tool": "kraken2", "collection": "viral", "displayName": "Viral", "version": "20240904", "url": "https://genome-idx.s3.amazonaws.com/kraken/k2_viral_20240904.tar.gz" },
    { "id": "kraken2-minus-b", "tool": "kraken2", "collection": "minus-b", "displayName": "MinusB", "version": "20240904", "url": "https://genome-idx.s3.amazonaws.com/kraken/k2_minusb_20240904.tar.gz" },
    { "id": "kraken2-eupathdb46", "tool": "kraken2", "collection": "eupathdb46", "displayName": "EuPathDB46", "version": "20230407", "url": "https://genome-idx.s3.amazonaws.com/kraken/k2_eupathdb48_20230407.tar.gz" },
    { "id": "esviritu-viral-v3", "tool": "esviritu", "displayName": "EsViritu Viral DB", "version": "v3.2.4", "url": "https://zenodo.org/records/17716199/files/esviritu_db_v3.2.4.tar.gz", "sizeBytes": 419430400, "sizeOnDisk": 5368709120, "recommendedRAM": 8589934592, "description": "19,925 curated viral assemblies across 63 families (Tisza et al. 2023)", "minimumToolVersion": "1.0.0" },
    { "id": "ncbi-taxonomy", "tool": "ncbi-taxonomy", "displayName": "NCBI Taxonomy", "version": "2025-03", "url": "https://ftp.ncbi.nlm.nih.gov/pub/taxonomy/taxdump.tar.gz", "sizeBytes": 66060288, "sizeOnDisk": 209715200, "recommendedRAM": 268435456, "description": "NCBI Taxonomy names and hierarchy for taxon ID resolution" },
    { "id": "kraken2-special-silva", "tool": "kraken2", "displayName": "SILVA", "version": "kraken2-special-v1", "description": "Kraken2 database built from the SILVA rRNA reference collection" },
    { "id": "kraken2-special-greengenes", "tool": "kraken2", "displayName": "Greengenes", "version": "kraken2-special-v1", "description": "Kraken2 database built from the Greengenes rRNA reference collection" },
    { "id": "human-scrubber", "tool": "sra-human-scrubber", "displayName": "Human Read Scrubber Database", "version": "20250916v2", "filename": "human_filter.db.20250916v2", "url": "https://ftp.ncbi.nlm.nih.gov/sra/dbs/human_filter/human_filter.db.20250916v2", "md5Sidecar": true, "releaseDate": "2025-09-16", "description": "k-mer database for human read identification and removal, built from human RefSeq. Eukaryota-derived k-mers with non-Eukaryota k-mers subtracted. Conservative on viral and bacterial pathogens.", "sourceUrl": "https://github.com/ncbi/sra-human-scrubber", "releasesUrl": "https://github.com/ncbi/sra-human-scrubber/releases" },
    { "id": "deacon-panhuman", "tool": "deacon", "displayName": "Human Read Removal Data", "version": "panhuman-1", "filename": "panhuman-1.k31w15.idx", "indexFormat": 3, "releaseDate": "2025-04-01", "description": "Prebuilt Deacon panhuman minimizer index used for host-read depletion before metagenomic and targeted-viral analysis.", "sourceUrl": "https://github.com/bede/deacon", "releasesUrl": "https://zenodo.org/records/17288185" },
    { "id": "deacon-ribokmers", "tool": "deacon", "displayName": "Ribosomal RNA Removal Data", "version": "bbmap-ribokmers-k31w15", "filename": "ribokmers.k31w15.idx", "indexFormat": 3, "releaseDate": "2026-04-29", "description": "Deacon minimizer index built from BBMap ribokmers for rRNA depletion.", "sourceUrl": "https://bbmap.org/resources/ribokmers.fa.gz" }
  ],
  "bootstrap": { "micromamba": { "version": "2.0.5-0", "sha256": {} } },
```

Copy the exact `description`/`releaseDate`/`sourceUrl`/`releasesUrl` values from the three existing `Sources/LungfishWorkflow/Resources/Databases/<id>/manifest.json` files (they are deleted in Task A6). Note EuPathDB is corrected to the only existing archive (`20230407`); the current `20240904` URL is a 404.

- [ ] **Step 6: Run tests**

Run: `swift test --skip-update --filter DependencyManifestTests`
Expected: PASS (4 tests). Also run `swift test --skip-update --filter 'CondaManagerTests|PluginPackRegistryTests'` and expect the existing suites still pass (they only read `tools`).

- [ ] **Step 7: Commit**

```bash
git add Sources/LungfishWorkflow/Dependencies/DependencyManifestSections.swift Sources/LungfishWorkflow/Conda/ManagedToolLock.swift Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json Tests/LungfishWorkflowTests/Dependencies/DependencyManifestTests.swift
git commit -m "feat(deps): add dependencySet and pack/pipeline/database/bootstrap sections to the tool manifest"
```

---

### Task A2: Pack requirements resolve specs from the manifest

**Files:**
- Modify: `Sources/LungfishWorkflow/Conda/PluginPack.swift:344-900`
- Test: `Tests/LungfishWorkflowTests/Dependencies/PackToolManifestConsistencyTests.swift`
- Delete/rewrite literal mirrors: `Tests/LungfishWorkflowTests/PluginPackRegistryTests.swift` (assertions on `installPackages` literals), `Tests/LungfishAppTests/PluginPackVisibilityTests.swift:655,748`, `Tests/LungfishWorkflowTests/PluginPackStatusServiceTests.swift:421`

**Interfaces:**
- Consumes: `ManagedToolLock.packTool(packID:id:)`.
- Produces: `PackToolRequirement.fromManifest(packID:id:displayName:executables:fallbackExecutablePaths:smokeTest:) -> PackToolRequirement` (throws `PluginPackManifestError.missingPackTool(packID:id:)`); `PluginPack.builtIn` unchanged in shape.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/LungfishWorkflowTests/Dependencies/PackToolManifestConsistencyTests.swift
import XCTest
@testable import LungfishWorkflow

final class PackToolManifestConsistencyTests: XCTestCase {
    func testEveryPinnedPackRequirementComesFromManifest() throws {
        let manifest = try ManagedToolLock.loadFromBundle()
        for pack in PluginPack.builtIn where pack.kind == .optionalTools {
            for req in pack.requirements where !req.installPackages.isEmpty && req.managedDatabaseID == nil {
                let spec = manifest.packTool(packID: pack.id, id: req.id)
                XCTAssertNotNil(spec, "\(pack.id)/\(req.id) has no packTools entry")
                XCTAssertEqual(req.installPackages, [spec?.packageSpec ?? ""], "\(pack.id)/\(req.id) must install the manifest spec")
                XCTAssertEqual(req.version, spec?.version)
            }
        }
    }

    func testNoManifestPackToolIsOrphaned() throws {
        let manifest = try ManagedToolLock.loadFromBundle()
        let known = Set(PluginPack.builtIn.flatMap { pack in pack.requirements.map { "\(pack.id)/\($0.id)" } })
        for spec in manifest.packTools {
            XCTAssertTrue(known.contains(spec.id), "manifest packTools entry \(spec.id) has no PluginPack requirement")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --skip-update --filter PackToolManifestConsistencyTests`
Expected: FAIL on `installPackages` (literal `bioconda::minimap2=2.30` vs manifest full spec).

- [ ] **Step 3: Add the manifest-backed factory**

Append to `Sources/LungfishWorkflow/Conda/PluginPack.swift` (after `PackToolRequirement`):

```swift
public enum PluginPackManifestError: Error, CustomStringConvertible {
    case missingPackTool(packID: String, id: String)
    public var description: String {
        switch self {
        case let .missingPackTool(packID, id): return "Manifest has no packTools entry for \(packID)/\(id)"
        }
    }
}

extension PackToolRequirement {
    /// Builds a requirement whose spec/version come from the dependency manifest.
    /// Display metadata, executables, and smoke tests remain in Swift.
    static func fromManifest(
        _ manifest: ManagedToolLock,
        packID: String,
        id: String,
        displayName: String,
        executables: [String],
        fallbackExecutablePaths: [String: [String]] = [:],
        smokeTest: PackToolSmokeTest? = nil
    ) -> PackToolRequirement {
        guard let spec = manifest.packTool(packID: packID, id: id) else {
            // Surface loudly in debug; keep the pack visible but uninstallable in release.
            assertionFailure(PluginPackManifestError.missingPackTool(packID: packID, id: id).description)
            return PackToolRequirement(id: id, displayName: displayName, environment: id,
                                       installPackages: [], executables: executables,
                                       fallbackExecutablePaths: fallbackExecutablePaths, smokeTest: smokeTest)
        }
        return PackToolRequirement(
            id: id, displayName: displayName, environment: spec.environment,
            installPackages: [spec.packageSpec], executables: executables,
            fallbackExecutablePaths: fallbackExecutablePaths, smokeTest: smokeTest,
            version: spec.version, license: spec.license, sourceURL: spec.sourceUrl
        )
    }
}
```

- [ ] **Step 4: Rewrite each optional pack requirement**

`PluginPack.builtIn` is a `static let`; introduce `private static let manifest: ManagedToolLock = (try? ManagedToolLock.loadFromBundle()) ?? ManagedToolLock(packID: "lungfish-tools", displayName: "Third-Party Tools", version: "unknown", tools: [], managedData: [])` next to `requiredSetupPack`, and change every requirement that currently has a literal `installPackages: ["bioconda::..."]` to the factory. Example for read-mapping (repeat for all 23):

```swift
                PackToolRequirement.fromManifest(
                    manifest, packID: "read-mapping", id: "minimap2",
                    displayName: "minimap2", executables: ["minimap2"],
                    smokeTest: .command(executable: "minimap2", arguments: ["--help"], timeoutSeconds: 10,
                                        acceptedExitCodes: [0, 1], requiredOutputSubstring: "Usage")
                ),
```

Leave `.package("ivar")`-style unpinned shorthand entries in inactive/experimental packs untouched (they are not pinned today and are out of scope), but move any active pack's shorthand to `fromManifest` if it has a manifest entry.

- [ ] **Step 5: Fix mirrored test literals**

- `Tests/LungfishWorkflowTests/PluginPackRegistryTests.swift`: replace assertions of the form `XCTAssertEqual(req.installPackages, ["bioconda::minimap2=2.30"])` with `XCTAssertEqual(req.installPackages, [manifest.packTool(packID: "read-mapping", id: "minimap2")!.packageSpec])` where `let manifest = try ManagedToolLock.loadFromBundle()`; delete assertions that only re-state a version literal.
- `Tests/LungfishWorkflowTests/PluginPackStatusServiceTests.swift:421`: the fake `conda-meta` in that test uses `bioconda::minimap2=2.30=h577a1d6_0`; change the fixture to derive `version`/`build` from the manifest spec so it matches production.
- `Tests/LungfishAppTests/PluginPackVisibilityTests.swift:655,748`: same substitution.

- [ ] **Step 6: Run tests**

Run: `swift test --skip-update --filter 'PackToolManifestConsistencyTests|PluginPackRegistryTests|PluginPackStatusServiceTests|PluginPackVisibilityTests'`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/LungfishWorkflow/Conda/PluginPack.swift Tests/
git commit -m "refactor(deps): resolve optional pack tool specs from the dependency manifest"
```

---

### Task A3: Replace duplicated literals with manifest lookups and add a no-literal guard test

**Files:**
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCGenotypingRunRequest.swift:20-22`, `Sources/LungfishWorkflow/Savont/SavontClusteringRunRequest.swift:34`, `Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline.swift:5547`, `Sources/LungfishWorkflow/ONTGenotyping/ONTGenotypingPipeline.swift:617,622`, `Sources/LungfishWorkflow/Metagenomics/EsVirituPipeline.swift:321`
- Test: `Tests/LungfishWorkflowTests/Dependencies/NoLiteralDependencyPinsTests.swift`
- Modify tests: `Tests/LungfishWorkflowTests/CondaManagerTests.swift:208-224`, `Metagenomics/EsVirituPipelineTests.swift:1060,1063`, `CondaLockfileServiceTests.swift:35,43`, `BundleContainerExportTests.swift:38`

**Interfaces:**
- Produces: `ManagedToolLock.packageSpec(forEnvironment:) -> String?` (searches `tools` then `packTools`), `ManagedToolLock.toolVersion(forEnvironment:) -> String?`.

- [ ] **Step 1: Write the guard test**

```swift
// Tests/LungfishWorkflowTests/Dependencies/NoLiteralDependencyPinsTests.swift
import XCTest

final class NoLiteralDependencyPinsTests: XCTestCase {
    /// Files that may legitimately contain conda specs.
    private let allowlist: [String] = [
        "Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json",
        "Sources/LungfishWorkflow/Conda/CondaManager.swift",           // channel names, not pins
        "Sources/LungfishCLI/Commands/CondaCommand.swift",             // help text examples
    ]

    func testNoCondaSpecLiteralsOutsideManifest() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sourcesRoot = root.appendingPathComponent("Sources")
        let pattern = try NSRegularExpression(pattern: #"\b(bioconda|conda-forge)::[a-z0-9_.-]+=[0-9]"#)
        var offenders: [String] = []
        let enumerator = FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil)!
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
            if allowlist.contains(rel) { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            if pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                offenders.append(rel)
            }
        }
        XCTAssertTrue(offenders.isEmpty, "Conda spec literals outside the manifest:\n" + offenders.joined(separator: "\n"))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --skip-update --filter NoLiteralDependencyPinsTests`
Expected: FAIL listing `FullLengthONTMHCGenotypingRunRequest.swift`, `ONTBarcodeDemuxGenotypingPipeline.swift`, `PluginPack.swift` (if any literal remains), etc.

- [ ] **Step 3: Add lookup helpers**

Append to `DependencyManifestSections.swift`:

```swift
public extension ManagedToolLock {
    func packageSpec(forEnvironment environment: String) -> String? {
        tools.first { $0.environment == environment }?.packageSpec
            ?? packTools.first { $0.environment == environment }?.packageSpec
    }
    func toolVersion(forEnvironment environment: String) -> String? {
        tools.first { $0.environment == environment }?.version
            ?? packTools.first { $0.environment == environment }?.version
    }
    /// Cached bundle manifest for call sites that need a lookup without error handling.
    static let bundled: ManagedToolLock = (try? loadFromBundle())
        ?? ManagedToolLock(packID: "lungfish-tools", displayName: "Third-Party Tools", version: "unknown", tools: [], managedData: [])
}
```

- [ ] **Step 4: Replace literals**

- `FullLengthONTMHCGenotypingRunRequest.swift:20-22`:
  ```swift
  public static var savontToolVersion: String { ManagedToolLock.bundled.toolVersion(forEnvironment: "savont") ?? "unknown" }
  public static let savontCondaEnvironment = "savont"
  public static var savontPackageSpec: String { ManagedToolLock.bundled.packageSpec(forEnvironment: "savont") ?? "bioconda::savont" }
  ```
- `SavontClusteringRunRequest.swift:34`: `toolVersion` becomes `FullLengthONTMHCGenotypingRunRequest.savontToolVersion`.
- `ONTBarcodeDemuxGenotypingPipeline.swift:5547`: `"packageSpec": ManagedToolLock.bundled.packageSpec(forEnvironment: "minimap2") ?? "bioconda::minimap2"`.
- `ONTGenotypingPipeline.swift:617,622`: fallbacks become `ManagedToolLock.bundled.packageSpec(forEnvironment: "pysam") ?? "bioconda::pysam"` and same for minimap2 (the manifest lookup already happens first; keep the fallback but derive from the manifest).
- `EsVirituPipeline.swift:321`: `static var esVirituGithubReleaseVersion: String { "v" + (ManagedToolLock.bundled.toolVersion(forEnvironment: "esviritu") ?? "unknown") }`.

- [ ] **Step 5: Fix mirrored tests**

- `CondaManagerTests.swift:208-224`: replace the literal expected spec table with a loop asserting each `lock.tools[i].packageSpec` parses as `channel::name=version=build` and that `version` equals the `=version=` component; keep `lock.version == LungfishAppVersion.short` (release script still writes it).
- `EsVirituPipelineTests.swift:1060,1063`: assert against `ManagedToolLock.bundled.toolVersion(forEnvironment: "esviritu")`.
- `CondaLockfileServiceTests.swift:35,43`, `BundleContainerExportTests.swift:38`: these construct their own lock fixtures inline; keep them (they are test-local inputs, not mirrors) but make sure they use full build strings so they remain representative.

- [ ] **Step 6: Run tests**

Run: `swift test --skip-update --filter 'NoLiteralDependencyPinsTests|CondaManagerTests|EsVirituPipelineTests|FullLengthONTMHC|SavontClustering'`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources Tests
git commit -m "refactor(deps): route duplicated tool pins through the manifest and guard against new literals"
```

---

### Task A4: Pipeline pins from the manifest

**Files:**
- Modify: `Sources/LungfishWorkflow/TaxTriage/TaxTriageConfig.swift:240-253`, `Sources/LungfishWorkflow/nf-core/NFCoreSupportedWorkflowCatalog.swift:123`
- Test: `Tests/LungfishWorkflowTests/Dependencies/PipelinePinTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LungfishWorkflow

final class PipelinePinTests: XCTestCase {
    func testTaxTriageDefaultsComeFromManifest() throws {
        let manifest = try ManagedToolLock.loadFromBundle()
        let spec = try XCTUnwrap(manifest.pipeline(id: "taxtriage"))
        XCTAssertEqual(TaxTriageConfig.defaultRevision, spec.revision)
        XCTAssertEqual(TaxTriageConfig.defaultGithubReleaseVersion, spec.releaseVersion)
        XCTAssertEqual(TaxTriageConfig.pipelineRepository, spec.repository)
        XCTAssertEqual(TaxTriageConfig.githubReleaseVersion(for: spec.revision), spec.releaseVersion)
    }

    func testViralreconPinComesFromManifest() throws {
        let manifest = try ManagedToolLock.loadFromBundle()
        let spec = try XCTUnwrap(manifest.pipeline(id: "nf-core-viralrecon"))
        let entry = try XCTUnwrap(NFCoreSupportedWorkflowCatalog.entry(id: "nf-core/viralrecon"))
        XCTAssertEqual(entry.pinnedVersion, spec.revision)
    }
}
```

(If `NFCoreSupportedWorkflowCatalog` exposes a different accessor than `entry(id:)`, use the existing one; read the file first.)

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --skip-update --filter PipelinePinTests`
Expected: FAIL (compiles, but only if the manifest already lists the same commit; the assertion passes trivially for the revision. To make it meaningful, temporarily confirm the constants are `static var` computed from the manifest after Step 3 by grepping: `grep -n "8fd1fb5" Sources/LungfishWorkflow/TaxTriage/TaxTriageConfig.swift` must return nothing.)

- [ ] **Step 3: Implement**

`TaxTriageConfig.swift:240-253`:

```swift
    public static var pipelineRepository: String { ManagedToolLock.bundled.pipeline(id: "taxtriage")?.repository ?? "jhuapl-bio/taxtriage" }
    public static var defaultRevision: String { ManagedToolLock.bundled.pipeline(id: "taxtriage")?.revision ?? "main" }
    public static var defaultGithubReleaseVersion: String { ManagedToolLock.bundled.pipeline(id: "taxtriage")?.releaseVersion ?? "unknown" }
    public static func githubReleaseVersion(for revision: String) -> String? {
        revision == defaultRevision ? defaultGithubReleaseVersion : nil
    }
```

`NFCoreSupportedWorkflowCatalog.swift:123`: `pinnedVersion: ManagedToolLock.bundled.pipeline(id: "nf-core-viralrecon")?.revision ?? "3.0.0"`.

- [ ] **Step 4: Run tests and the TaxTriage suites**

Run: `swift test --skip-update --filter 'PipelinePinTests|TaxTriage'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/TaxTriage/TaxTriageConfig.swift Sources/LungfishWorkflow/nf-core/NFCoreSupportedWorkflowCatalog.swift Tests/LungfishWorkflowTests/Dependencies/PipelinePinTests.swift
git commit -m "refactor(deps): read pipeline revisions from the manifest"
```

---

### Task A5: Metagenomics catalog from the manifest (per-collection URLs, dead-URL correction)

**Files:**
- Modify: `Sources/LungfishWorkflow/Metagenomics/MetagenomicsDatabaseInfo.swift:265-402`, `Sources/LungfishWorkflow/Metagenomics/MetagenomicsModels.swift:160-176`, `Sources/LungfishWorkflow/Metagenomics/EsVirituDatabaseManager.swift:92-101`, `Sources/LungfishWorkflow/Metagenomics/MetagenomicsDatabaseRegistry.swift:293-347` (load merge)
- Test: `Tests/LungfishWorkflowTests/Dependencies/MetagenomicsCatalogManifestTests.swift`, extend `Tests/LungfishWorkflowTests/Metagenomics/MetagenomicsDatabaseTests.swift`

**Interfaces:**
- Produces: `MetagenomicsDatabaseInfo.builtInCatalog` built from `ManagedToolLock.bundled.databases`; `DatabaseCollection.downloadURLBase` removed (URL comes from manifest); `MetagenomicsDatabaseRegistry.reconcileCatalogURLs()` invoked in `loadIfNeeded()`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LungfishWorkflow

final class MetagenomicsCatalogManifestTests: XCTestCase {
    func testKrakenCatalogEntriesUseManifestURLs() throws {
        let manifest = try ManagedToolLock.loadFromBundle()
        for entry in MetagenomicsDatabaseInfo.builtInCatalog where entry.tool == "kraken2" && entry.collection != nil {
            let spec = try XCTUnwrap(manifest.database(id: entry.catalogID!), "\(entry.name) missing from manifest")
            XCTAssertEqual(entry.downloadURL, spec.url)
            XCTAssertEqual(entry.version, spec.version)
        }
    }

    func testEuPathDBPointsAtExistingArchive() throws {
        let entry = try XCTUnwrap(MetagenomicsDatabaseInfo.builtInCatalog.first { $0.catalogID == "kraken2-eupathdb46" })
        XCTAssertEqual(entry.version, "20230407")
        XCTAssertTrue(entry.downloadURL!.hasSuffix("k2_eupathdb48_20230407.tar.gz"))
    }

    func testEsVirituManagerAgreesWithManifest() throws {
        let manifest = try ManagedToolLock.loadFromBundle()
        let spec = try XCTUnwrap(manifest.database(id: "esviritu-viral-v3"))
        XCTAssertEqual(EsVirituDatabaseManager.currentVersion, spec.version)
        XCTAssertEqual(EsVirituDatabaseManager.downloadURL, spec.url)
    }

    func testRegistryCorrectsDeadCatalogURLOnLoad() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let registry = MetagenomicsDatabaseRegistry(baseDirectory: tmp)
        // Seed a stale registry file: EuPathDB with the dead 20240904 URL, status missing.
        let stale = """
        {"databases":[{"name":"EuPathDB46","tool":"kraken2","version":"20240904","sizeBytes":1,"downloadURL":"https://genome-idx.s3.amazonaws.com/kraken/k2_eupathdb48_20240904.tar.gz","catalogID":"kraken2-eupathdb46","installationRecipe":{"archive":{"url":"https://genome-idx.s3.amazonaws.com/kraken/k2_eupathdb48_20240904.tar.gz"}},"description":"x","collection":"eupathdb46","isExternal":false,"status":"missing"}]}
        """
        try stale.write(to: tmp.appendingPathComponent("metagenomics-db-registry.json"), atomically: true, encoding: .utf8)
        try registry.loadIfNeeded()
        let db = try XCTUnwrap(try registry.database(named: "EuPathDB46"))
        XCTAssertEqual(db.version, "20230407")
        XCTAssertTrue(db.downloadURL!.hasSuffix("20230407.tar.gz"))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --skip-update --filter MetagenomicsCatalogManifestTests`
Expected: FAIL (URLs still built from `latestBuildDate`).

- [ ] **Step 3: Implement**

`MetagenomicsDatabaseInfo.swift`: delete `latestBuildDate`; build `builtInCatalog` by iterating `ManagedToolLock.bundled.databases`:

```swift
    public static let builtInCatalog: [MetagenomicsDatabaseInfo] = {
        let manifest = ManagedToolLock.bundled
        var catalog: [MetagenomicsDatabaseInfo] = []
        for spec in manifest.databases {
            switch spec.tool {
            case MetagenomicsTool.kraken2.rawValue where spec.collection != nil:
                guard let collection = DatabaseCollection(rawValue: spec.collection!), let url = spec.url else { continue }
                catalog.append(MetagenomicsDatabaseInfo(
                    name: collection.displayName, tool: spec.tool, version: spec.version,
                    sizeBytes: spec.sizeBytes ?? collection.approximateSizeBytes,
                    sizeOnDisk: spec.sizeOnDisk ?? collection.approximateSizeBytes,
                    downloadURL: url, catalogID: spec.id,
                    installationRecipe: .archive(url: URL(string: url)!),
                    description: spec.description ?? collection.contentsDescription,
                    collection: collection, path: nil, isExternal: false, bookmarkData: nil,
                    lastUpdated: nil, status: .missing,
                    recommendedRAM: spec.recommendedRAM ?? collection.approximateRAMBytes))
            case MetagenomicsTool.kraken2.rawValue where spec.id.hasPrefix("kraken2-special-"):
                let type: Kraken2SpecialDatabaseType = spec.id.hasSuffix("silva") ? .silva : .greengenes
                catalog.append(MetagenomicsDatabaseInfo(
                    name: spec.displayName, tool: spec.tool, version: spec.version,
                    sizeBytes: spec.sizeBytes ?? 0, sizeOnDisk: spec.sizeOnDisk, downloadURL: nil, catalogID: spec.id,
                    installationRecipe: .kraken2Special(type: type),
                    description: spec.description ?? "", collection: nil, path: nil, isExternal: false,
                    bookmarkData: nil, lastUpdated: nil, status: .missing,
                    recommendedRAM: spec.recommendedRAM ?? 0))
            case MetagenomicsTool.esviritu.rawValue, MetagenomicsTool.ncbiTaxonomy.rawValue:
                guard let url = spec.url else { continue }
                catalog.append(MetagenomicsDatabaseInfo(
                    name: spec.displayName, tool: spec.tool, version: spec.version,
                    sizeBytes: spec.sizeBytes ?? 0, sizeOnDisk: spec.sizeOnDisk, downloadURL: url, catalogID: spec.id,
                    installationRecipe: .archive(url: URL(string: url)!),
                    description: spec.description ?? "", collection: nil, path: nil, isExternal: false,
                    bookmarkData: nil, lastUpdated: nil, status: .missing,
                    recommendedRAM: spec.recommendedRAM ?? 0))
            default:
                continue // human-scrubber / deacon are DatabaseRegistry-managed
            }
        }
        return catalog
    }()
```

Keep the existing SILVA/Greengenes size constants by putting them into the manifest entries (`sizeBytes`, `sizeOnDisk`, `recommendedRAM`) so no behavior changes. Check `MetagenomicsTool.ncbiTaxonomy.rawValue` equals `"ncbi-taxonomy"`; if it is a different string, use that string in the manifest `tool` field.

`MetagenomicsModels.swift:160-176`: delete `downloadURLBase` (no callers after this change; grep to confirm).

`EsVirituDatabaseManager.swift:92-101`:
```swift
    public static var currentVersion: String { ManagedToolLock.bundled.database(id: "esviritu-viral-v3")?.version ?? "v3.2.4" }
    public static var downloadURL: String { ManagedToolLock.bundled.database(id: "esviritu-viral-v3")?.url ?? "" }
```

`MetagenomicsDatabaseRegistry.swift` in `loadIfNeeded()` after the merge-on-load block, add:

```swift
        reconcileCatalogURLs()
    ...
    /// For catalog-backed entries that are not installed, refresh downloadURL/recipe/version from the built-in catalog
    /// so entries pointing at retired upstream archives self-correct.
    private func reconcileCatalogURLs() {
        for (name, db) in databases where db.status != .ready && db.path == nil {
            guard let catalogID = db.catalogID,
                  let fresh = MetagenomicsDatabaseInfo.builtInCatalog.first(where: { $0.catalogID == catalogID }),
                  fresh.downloadURL != db.downloadURL || fresh.version != db.version else { continue }
            var updated = db
            updated.version = fresh.version
            updated.downloadURL = fresh.downloadURL      // make `downloadURL` `var` if it is `let`
            updated.installationRecipe = fresh.installationRecipe
            databases[name] = updated
            logger.notice("Corrected catalog URL for \(name): \(fresh.downloadURL ?? "nil")")
        }
        try? save()
    }
```

If `downloadURL`/`installationRecipe` are `let`, change them to `public private(set) var` and update `Equatable`/`Codable` accordingly (synthesized).

- [ ] **Step 4: Run tests**

Run: `swift test --skip-update --filter 'MetagenomicsCatalogManifestTests|MetagenomicsDatabaseTests|EsViritu'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/Metagenomics Tests/LungfishWorkflowTests
git commit -m "refactor(deps): build the metagenomics database catalog from the manifest with per-collection URLs"
```

---

### Task A6: Bundled database manifests and micromamba version from the manifest

**Files:**
- Modify: `Sources/LungfishWorkflow/Databases/DatabaseRegistry.swift:270-283` (`manifest(for:)`), `:929-934` (`bundledManifestURL`), `Sources/LungfishWorkflow/Native/ToolProvisioning/ToolManifest.swift:333`, `Sources/LungfishWorkflow/Conda/CondaManager.swift` (`defaultBundledMicromambaVersion`)
- Delete: `Sources/LungfishWorkflow/Resources/Databases/human-scrubber/manifest.json`, `.../deacon-panhuman/manifest.json`, `.../deacon-ribokmers/manifest.json` (keep the directories only if they carry other payloads; check with `ls`)
- Modify: `Sources/LungfishWorkflow/Resources/Tools/tool-versions.json` stays as the build artifact but its `version` must equal the manifest bootstrap version (test enforces)
- Test: `Tests/LungfishWorkflowTests/Dependencies/BundledDatabaseManifestTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LungfishWorkflow

final class BundledDatabaseManifestTests: XCTestCase {
    func testDatabaseRegistryManifestsComeFromDependencyManifest() async throws {
        let manifest = try ManagedToolLock.loadFromBundle()
        for id in DatabaseRegistry.knownIDs {
            let spec = try XCTUnwrap(manifest.database(id: id), "\(id) missing from manifest")
            let bundled = try XCTUnwrap(await DatabaseRegistry.shared.manifest(for: id))
            XCTAssertEqual(bundled.version, spec.version)
            XCTAssertEqual(bundled.filename, spec.filename)
            XCTAssertEqual(bundled.tool, spec.tool)
        }
    }

    func testNoLegacyManifestJSONRemains() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for id in DatabaseRegistry.knownIDs {
            let legacy = root.appendingPathComponent("Sources/LungfishWorkflow/Resources/Databases/\(id)/manifest.json")
            XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path), "legacy manifest still present: \(legacy.path)")
        }
    }

    func testMicromambaVersionAgreesAcrossManifestAndToolVersions() throws {
        let manifest = try ManagedToolLock.loadFromBundle()
        let expected = try XCTUnwrap(manifest.bootstrap?.micromamba.version)
        XCTAssertEqual(ToolManifest.micromamba().version, expected)
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Sources/LungfishWorkflow/Resources/Tools/tool-versions.json"))
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let tools = json["tools"] as! [[String: Any]]
        let mm = tools.first { ($0["name"] as? String) == "micromamba" }!
        XCTAssertEqual(mm["version"] as? String, expected)
    }
}
```

(Adjust the `tool-versions.json` key path after reading the file; it is small.)

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --skip-update --filter BundledDatabaseManifestTests`
Expected: FAIL on `testNoLegacyManifestJSONRemains`.

- [ ] **Step 3: Implement**

`DatabaseRegistry.manifest(for:)`:

```swift
    public func manifest(for id: String) -> BundledDatabase? {
        let resolvedID = Self.normalizedDatabaseID(id)
        if let cached = manifests[resolvedID] { return cached }
        guard let spec = ManagedToolLock.bundled.database(id: resolvedID), let filename = spec.filename else {
            dbLogger.error("Dependency manifest has no database entry for '\(resolvedID)'")
            return nil
        }
        let db = BundledDatabase(
            id: spec.id, displayName: spec.displayName, tool: spec.tool, version: spec.version,
            filename: filename, releaseDate: spec.releaseDate ?? "", description: spec.description ?? "",
            sourceUrl: spec.sourceUrl ?? "", releasesUrl: spec.releasesUrl ?? "")
        manifests[resolvedID] = db
        return db
    }
```

Add a public memberwise `init` to `BundledDatabase` if it lacks one. Delete `bundledManifestURL(for:)` and the three JSON files. `bundledDatabasePath(for:)` keeps using `databasesRoot()` for payloads (none ship today; leave as is).

`ToolManifest.swift:333`: `micromamba(version: String = ManagedToolLock.bundled.bootstrap?.micromamba.version ?? "2.0.5-0")`. In `CondaManager.defaultBundledMicromambaVersion`, return the same manifest value.

- [ ] **Step 4: Run tests**

Run: `swift test --skip-update --filter 'BundledDatabaseManifestTests|DatabaseRegistry|HumanScrubber|Deacon|CondaManagerTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A Sources/LungfishWorkflow/Databases Sources/LungfishWorkflow/Resources/Databases Sources/LungfishWorkflow/Native/ToolProvisioning/ToolManifest.swift Sources/LungfishWorkflow/Conda/CondaManager.swift Tests/LungfishWorkflowTests/Dependencies/BundledDatabaseManifestTests.swift
git commit -m "refactor(deps): source bundled database metadata and micromamba version from the manifest"
```

---

### Task A7: `dependencySet` in provenance and version surfaces

**Files:**
- Modify: `Sources/LungfishWorkflow/Provenance/ProvenanceEnvelope.swift:598-604` (`ProvenanceRuntimeIdentity`), `Sources/LungfishWorkflow/Provenance/ProvenanceRunBuilder.swift` (populate), `Sources/LungfishCLI/Commands/VersionCommand.swift` (`--tools` output), the About window tools list (locate with `grep -rn "ManagedToolLock" Sources/LungfishApp | head`)
- Test: `Tests/LungfishWorkflowTests/Dependencies/ProvenanceDependencySetTests.swift`, extend `Tests/LungfishCLITests/CLIRegressionTests.swift` version test

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LungfishWorkflow

final class ProvenanceDependencySetTests: XCTestCase {
    func testRuntimeIdentityCarriesDependencySet() throws {
        let identity = ProvenanceRuntimeIdentity.current()   // adjust to the existing factory name
        XCTAssertEqual(identity.dependencySet, ManagedToolLock.bundled.resolvedDependencySet)
    }

    func testLegacyEnvelopeDecodesWithNilDependencySet() throws {
        let json = #"{"appVersion":"0.5.0-beta29","executablePath":"/x","processIdentifier":1,"operatingSystemVersion":"26.0","architecture":"arm64"}"#
        let identity = try JSONDecoder().decode(ProvenanceRuntimeIdentity.self, from: Data(json.utf8))
        XCTAssertNil(identity.dependencySet)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --skip-update --filter ProvenanceDependencySetTests`
Expected: FAIL (no `dependencySet` member).

- [ ] **Step 3: Implement**

Add `public let dependencySet: String?` to `ProvenanceRuntimeIdentity` with `decodeIfPresent`; populate wherever the identity is constructed (grep `ProvenanceRuntimeIdentity(`) with `ManagedToolLock.bundled.resolvedDependencySet`. In `VersionCommand` `--tools`, print a first line `Dependency set: <set> (<date>)`. In the About window tools list, add the same line above the table.

- [ ] **Step 4: Run tests**

Run: `swift test --skip-update --filter 'ProvenanceDependencySetTests|Provenance|CLIRegressionTests/testVersion'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "feat(deps): record dependencySet in provenance runtime identity and version surfaces"
```

---

### Task A8: `LUNGFISH_STORAGE_ROOT` override

**Files:**
- Modify: `Sources/LungfishCore/Storage/ManagedStorageConfigStore.swift:98-112` (`currentLocation()` and `currentCondaRootURL()`)
- Test: `Tests/LungfishCoreTests/ManagedStorageConfigStoreTests.swift` (add cases)

- [ ] **Step 1: Write the failing test**

```swift
    func testStorageRootEnvironmentOverrideWins() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lgeroot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let store = ManagedStorageConfigStore()
        let env = ["LUNGFISH_STORAGE_ROOT": tmp.path]
        XCTAssertEqual(store.currentLocation(environment: env).rootURL.standardizedFileURL, tmp.standardizedFileURL)
        XCTAssertEqual(store.currentCondaRootURL(environment: env), tmp.appendingPathComponent("conda", isDirectory: true).standardizedFileURL)
    }

    func testCondaRootOverrideStillWinsOverStorageRootForConda() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("r-\(UUID().uuidString)")
        let conda = FileManager.default.temporaryDirectory.appendingPathComponent("c-\(UUID().uuidString)")
        for u in [root, conda] { try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true) }
        let store = ManagedStorageConfigStore()
        let env = ["LUNGFISH_STORAGE_ROOT": root.path, "LUNGFISH_CONDA_ROOT": conda.path]
        XCTAssertEqual(store.currentCondaRootURL(environment: env), conda.standardizedFileURL)
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --skip-update --filter ManagedStorageConfigStoreTests`
Expected: FAIL (`currentLocation(environment:)` does not exist).

- [ ] **Step 3: Implement**

Give `currentLocation()` an `environment: [String: String] = ProcessInfo.processInfo.environment` parameter; if `LUNGFISH_STORAGE_ROOT` is set, non-empty, and passes `ManagedStorageLocation.validateSelection`, return `ManagedStorageLocation(rootURL: override)` (use the existing initializer). `currentCondaRootURL(environment:)` keeps checking `LUNGFISH_CONDA_ROOT` first, then falls back to `currentLocation(environment:).condaRootURL`.

- [ ] **Step 4: Run tests**

Run: `swift test --skip-update --filter 'ManagedStorageConfigStoreTests|ManagedStorage'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishCore/Storage/ManagedStorageConfigStore.swift Tests/LungfishCoreTests
git commit -m "feat(storage): add LUNGFISH_STORAGE_ROOT override for isolated test roots"
```

---

### Task A9: Shared conda-meta reader

**Files:**
- Create: `Sources/LungfishWorkflow/Dependencies/CondaMetaReader.swift`
- Modify: `Sources/LungfishWorkflow/Conda/PluginPackStatusService.swift:179-183, 955-990`
- Test: `Tests/LungfishWorkflowTests/Dependencies/CondaMetaReaderTests.swift`

**Interfaces:**
- Produces: `struct CondaMetaPackage: Sendable, Equatable { name, version, build, subdir, channel }`, `enum CondaMetaReader { static func packages(inEnvironment envURL: URL) -> [CondaMetaPackage]; static func primaryPackage(named:inEnvironment:) -> CondaMetaPackage? }`, `struct CondaSpec { channel, name, version, build; init?(spec: String); var matches(_ meta: CondaMetaPackage) -> Bool }`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LungfishWorkflow

final class CondaMetaReaderTests: XCTestCase {
    private func makeEnv(_ files: [String: String]) throws -> URL {
        let env = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let meta = env.appendingPathComponent("conda-meta")
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        for (name, body) in files { try body.write(to: meta.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        return env
    }

    func testReadsNameVersionBuildSubdir() throws {
        let env = try makeEnv(["samtools-1.23.1-hc612e98_0.json":
            #"{"name":"samtools","version":"1.23.1","build":"hc612e98_0","subdir":"osx-arm64","channel":"https://conda.anaconda.org/bioconda/osx-arm64"}"#])
        let pkgs = CondaMetaReader.packages(inEnvironment: env)
        XCTAssertEqual(pkgs.count, 1)
        XCTAssertEqual(pkgs[0].name, "samtools")
        XCTAssertEqual(pkgs[0].build, "hc612e98_0")
    }

    func testSpecParsingAndMatching() throws {
        let spec = try XCTUnwrap(CondaSpec(spec: "bioconda::samtools=1.23.1=hc612e98_0"))
        XCTAssertEqual(spec.channel, "bioconda"); XCTAssertEqual(spec.name, "samtools")
        XCTAssertEqual(spec.version, "1.23.1"); XCTAssertEqual(spec.build, "hc612e98_0")
        XCTAssertTrue(spec.matches(CondaMetaPackage(name: "samtools", version: "1.23.1", build: "hc612e98_0", subdir: "osx-arm64", channel: nil)))
        XCTAssertFalse(spec.matches(CondaMetaPackage(name: "samtools", version: "1.23.1", build: "hc612e98_1", subdir: "osx-arm64", channel: nil)))
        XCTAssertNil(CondaSpec(spec: "samtools"))               // no version -> not a pin
        XCTAssertNotNil(CondaSpec(spec: "bioconda::samtools=1.23.1")) // build optional in parser
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --skip-update --filter CondaMetaReaderTests`
Expected: FAIL (types missing).

- [ ] **Step 3: Implement**

```swift
// Sources/LungfishWorkflow/Dependencies/CondaMetaReader.swift
import Foundation

public struct CondaMetaPackage: Sendable, Equatable, Codable {
    public let name: String
    public let version: String
    public let build: String?
    public let subdir: String?
    public let channel: String?
    public init(name: String, version: String, build: String?, subdir: String?, channel: String?) {
        self.name = name; self.version = version; self.build = build; self.subdir = subdir; self.channel = channel
    }
}

public struct CondaSpec: Sendable, Equatable {
    public let channel: String?
    public let name: String
    public let version: String
    public let build: String?

    public init?(spec: String) {
        let channelSplit = spec.components(separatedBy: "::")
        let channel = channelSplit.count == 2 ? channelSplit[0] : nil
        let rest = channelSplit.last ?? spec
        let parts = rest.split(separator: "=", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        self.channel = channel; self.name = parts[0]; self.version = parts[1]
        self.build = parts.count >= 3 && !parts[2].isEmpty ? parts[2] : nil
    }

    public func matches(_ meta: CondaMetaPackage) -> Bool {
        guard meta.name == name, meta.version == version else { return false }
        if let build { return meta.build == build }
        return true
    }
}

public enum CondaMetaReader {
    private struct Raw: Decodable { let name: String?; let version: String?; let build: String?; let subdir: String?; let channel: String? }

    public static func packages(inEnvironment envURL: URL) -> [CondaMetaPackage] {
        let metaURL = envURL.appendingPathComponent("conda-meta", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(at: metaURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return urls.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url), let raw = try? JSONDecoder().decode(Raw.self, from: data),
                  let name = raw.name, let version = raw.version else { return nil }
            return CondaMetaPackage(name: name, version: version, build: raw.build, subdir: raw.subdir, channel: raw.channel)
        }
    }

    public static func primaryPackage(named name: String, inEnvironment envURL: URL) -> CondaMetaPackage? {
        packages(inEnvironment: envURL).first { $0.name == name }
    }
}
```

In `PluginPackStatusService.packageMetadataFailure`, replace the private struct with `CondaMetaReader.packages(inEnvironment: envURL)` and, when the requirement's `installPackages.first` parses as `CondaSpec` with a build, compare with `spec.matches(pkg)` so build-only changes are reported ("...is build X, but Lungfish requires Y. Reinstall this tool."). Keep the subdir check.

- [ ] **Step 4: Run tests**

Run: `swift test --skip-update --filter 'CondaMetaReaderTests|PluginPackStatusServiceTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/Dependencies/CondaMetaReader.swift Sources/LungfishWorkflow/Conda/PluginPackStatusService.swift Tests/LungfishWorkflowTests/Dependencies/CondaMetaReaderTests.swift
git commit -m "feat(deps): shared conda-meta reader and build-string aware version check"
```

---

### Task A10: Dependency receipt model and store (load, save, synthesize)

**Files:**
- Create: `Sources/LungfishWorkflow/Dependencies/DependencyReceipt.swift`, `Sources/LungfishWorkflow/Dependencies/DependencyReceiptStore.swift`
- Test: `Tests/LungfishWorkflowTests/Dependencies/DependencyReceiptStoreTests.swift`

**Interfaces:**
- Produces:
```swift
public struct DependencyReceipt: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var dependencySet: String?
    public var appVersion: String?
    public var manifestHash: String?
    public var updatedAt: Date
    public var synthesized: Bool
    public var environments: [String: EnvironmentEntry]     // keyed by env name
    public var databases: [String: DatabaseEntry]           // keyed by database id (DatabaseRegistry-managed only)
    public var pipelines: [String: PipelineEntry]
    public var bootstrap: BootstrapEntry?
    public struct EnvironmentEntry: Codable, Sendable, Equatable { public var packageSpec: String; public var packID: String?; public var installedAt: Date; public var state: EntryState }
    public struct DatabaseEntry: Codable, Sendable, Equatable { public var version: String; public var path: String?; public var installedAt: Date }
    public struct PipelineEntry: Codable, Sendable, Equatable { public var revision: String; public var prefetchedAt: Date? }
    public struct BootstrapEntry: Codable, Sendable, Equatable { public var micromambaVersion: String }
    public enum EntryState: String, Codable, Sendable { case installed, pending, failed }
    public static func empty() -> DependencyReceipt
}
public struct DependencyReceiptStore: Sendable {
    public init(storageRoot: URL)
    public var receiptURL: URL   // <root>/dependency-receipt.json
    public func load() throws -> DependencyReceipt?          // nil if missing; throws on corrupt (caller synthesizes)
    public func save(_ receipt: DependencyReceipt) throws    // atomic
    public func synthesize(condaRoot: URL, manifest: ManagedToolLock) -> DependencyReceipt
}
```

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LungfishWorkflow

final class DependencyReceiptStoreTests: XCTestCase {
    private func tmpRoot() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("lge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u
    }
    private func fakeEnv(root: URL, name: String, pkg: String, version: String, build: String) throws {
        let meta = root.appendingPathComponent("conda/envs/\(name)/conda-meta")
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        try #"{"name":"\#(pkg)","version":"\#(version)","build":"\#(build)","subdir":"osx-arm64","channel":"https://conda.anaconda.org/bioconda/osx-arm64"}"#
            .write(to: meta.appendingPathComponent("\(pkg)-\(version)-\(build).json"), atomically: true, encoding: .utf8)
    }

    func testRoundTrip() throws {
        let root = try tmpRoot(); let store = DependencyReceiptStore(storageRoot: root)
        XCTAssertNil(try store.load())
        var r = DependencyReceipt.empty(); r.dependencySet = "2026.1"
        r.environments["samtools"] = .init(packageSpec: "bioconda::samtools=1.23.1=hc612e98_0", packID: "lungfish-tools", installedAt: Date(), state: .installed)
        try store.save(r)
        XCTAssertEqual(try store.load(), r)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("dependency-receipt.json").path))
    }

    func testCorruptReceiptThrows() throws {
        let root = try tmpRoot(); let store = DependencyReceiptStore(storageRoot: root)
        try "not json".write(to: store.receiptURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.load())
    }

    func testSynthesizeFromCondaMeta() throws {
        let root = try tmpRoot(); let store = DependencyReceiptStore(storageRoot: root)
        try fakeEnv(root: root, name: "samtools", pkg: "samtools", version: "1.23.1", build: "hc612e98_0")
        try fakeEnv(root: root, name: "bbtools", pkg: "bbmap", version: "39.80", build: "h2e3bd82_0")
        try fakeEnv(root: root, name: "trim_galore", pkg: "trim-galore", version: "2.3.0", build: "h48b4a6d_0")
        let manifest = try ManagedToolLock.loadFromBundle()
        let r = store.synthesize(condaRoot: root.appendingPathComponent("conda"), manifest: manifest)
        XCTAssertTrue(r.synthesized)
        XCTAssertNil(r.dependencySet)
        XCTAssertEqual(r.environments["samtools"]?.packageSpec, "bioconda::samtools=1.23.1=hc612e98_0")
        XCTAssertEqual(r.environments["bbtools"]?.packageSpec, "bioconda::bbmap=39.80=h2e3bd82_0")   // primary package name from manifest spec
        XCTAssertEqual(r.environments["trim_galore"]?.packageSpec, "bioconda::trim-galore=2.3.0=h48b4a6d_0")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --skip-update --filter DependencyReceiptStoreTests`
Expected: FAIL (types missing).

- [ ] **Step 3: Implement**

`DependencyReceipt.swift`: the struct exactly as in Interfaces, with `static func empty() -> DependencyReceipt { .init(schemaVersion: currentSchemaVersion, dependencySet: nil, appVersion: nil, manifestHash: nil, updatedAt: Date(), synthesized: false, environments: [:], databases: [:], pipelines: [:], bootstrap: nil) }`.

`DependencyReceiptStore.swift`:

```swift
import Foundation

public struct DependencyReceiptStore: Sendable {
    public let storageRoot: URL
    public init(storageRoot: URL) { self.storageRoot = storageRoot.standardizedFileURL }
    public var receiptURL: URL { storageRoot.appendingPathComponent("dependency-receipt.json") }

    public func load() throws -> DependencyReceipt? {
        guard FileManager.default.fileExists(atPath: receiptURL.path) else { return nil }
        let data = try Data(contentsOf: receiptURL)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let receipt = try decoder.decode(DependencyReceipt.self, from: data)
        guard receipt.schemaVersion == DependencyReceipt.currentSchemaVersion else {
            throw DependencyReceiptError.unsupportedSchema(receipt.schemaVersion)
        }
        return receipt
    }

    public func save(_ receipt: DependencyReceipt) throws {
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        var copy = receipt; copy.updatedAt = Date()
        let data = try encoder.encode(copy)
        let tmp = receiptURL.appendingPathExtension("tmp-\(UUID().uuidString)")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(receiptURL, withItemAt: tmp)
    }

    /// Builds a receipt from what is on disk when none exists (users upgrading from pre-receipt builds).
    public func synthesize(condaRoot: URL, manifest: ManagedToolLock) -> DependencyReceipt {
        var receipt = DependencyReceipt.empty(); receipt.synthesized = true
        let envsURL = condaRoot.appendingPathComponent("envs", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: envsURL.path)) ?? []
        // Map env name -> primary package name using the manifest (env "bbtools" -> package "bbmap").
        var primaryPackageByEnv: [String: (name: String, channel: String?)] = [:]
        for spec in manifest.tools.map(\.packageSpec) + manifest.packTools.map(\.packageSpec) {
            if let parsed = CondaSpec(spec: spec) {
                let env = manifest.tools.first { $0.packageSpec == spec }?.environment
                    ?? manifest.packTools.first { $0.packageSpec == spec }?.environment ?? parsed.name
                primaryPackageByEnv[env] = (parsed.name, parsed.channel)
            }
        }
        for name in names where !name.hasPrefix(".") {
            let envURL = envsURL.appendingPathComponent(name)
            let pkgs = CondaMetaReader.packages(inEnvironment: envURL)
            guard !pkgs.isEmpty else { continue }
            let primaryName = primaryPackageByEnv[name]?.name ?? name
            guard let pkg = pkgs.first(where: { $0.name == primaryName }) ?? pkgs.first(where: { $0.name == name }) else { continue }
            let channel = primaryPackageByEnv[name]?.channel ?? inferChannel(pkg.channel)
            let spec = [channel.map { "\($0)::" } ?? "", pkg.name, "=", pkg.version, pkg.build.map { "=\($0)" } ?? ""].joined()
            let installedAt = (try? FileManager.default.attributesOfItem(atPath: envURL.path)[.creationDate] as? Date) ?? Date()
            receipt.environments[name] = .init(packageSpec: spec, packID: nil, installedAt: installedAt, state: .installed)
        }
        return receipt
    }

    private func inferChannel(_ url: String?) -> String? {
        guard let url else { return nil }
        if url.contains("/bioconda") { return "bioconda" }
        if url.contains("/conda-forge") { return "conda-forge" }
        return nil
    }
}

public enum DependencyReceiptError: Error, Equatable { case unsupportedSchema(Int) }
```

- [ ] **Step 4: Run tests**

Run: `swift test --skip-update --filter DependencyReceiptStoreTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/Dependencies/DependencyReceipt.swift Sources/LungfishWorkflow/Dependencies/DependencyReceiptStore.swift Tests/LungfishWorkflowTests/Dependencies/DependencyReceiptStoreTests.swift
git commit -m "feat(deps): dependency install receipt with synthesis from conda-meta"
```

---

### Task A11: Reconciliation plan types and pure planner

**Files:**
- Create: `Sources/LungfishWorkflow/Dependencies/ReconciliationPlan.swift`, `Sources/LungfishWorkflow/Dependencies/DependencyPlanner.swift`
- Test: `Tests/LungfishWorkflowTests/Dependencies/DependencyPlannerTests.swift`

**Interfaces:**
```swift
public struct ReconciliationPlan: Codable, Sendable, Equatable {
    public enum ChangeReason: String, Codable, Sendable { case missing, specChanged, buildChanged, metadataMismatch, retired, bootstrap }
    public struct EnvironmentChange: Codable, Sendable, Equatable, Identifiable {
        public var id: String { environment }
        public let environment: String; public let packID: String; public let currentSpec: String?; public let targetSpec: String; public let reason: ChangeReason; public let isRequired: Bool
    }
    public struct DatabaseChange: Codable, Sendable, Equatable, Identifiable {
        public let id: String; public let displayName: String; public let installedVersion: String?; public let targetVersion: String
        public let policy: DatabaseUpdatePolicy; public let estimatedBytes: Int64; public let managedBy: DatabaseManager   // .databaseRegistry | .metagenomicsRegistry
    }
    public enum DatabaseManager: String, Codable, Sendable { case databaseRegistry, metagenomicsRegistry }
    public struct PipelineChange: Codable, Sendable, Equatable, Identifiable { public let id: String; public let currentRevision: String?; public let targetRevision: String }
    public struct BootstrapChange: Codable, Sendable, Equatable { public let currentVersion: String?; public let targetVersion: String }
    public var installEnvironments: [EnvironmentChange]
    public var reinstallEnvironments: [EnvironmentChange]
    public var removeEnvironments: [String]
    public var databaseUpdates: [DatabaseChange]
    public var pipelinePrefetch: [PipelineChange]
    public var bootstrapUpdate: BootstrapChange?
    public var targetDependencySet: String
    public var estimatedDownloadBytes: Int64
    public var isEmpty: Bool
    public var hasRequiredWork: Bool   // any required env change or required DB
}
public struct DependencyPlannerInputs: Sendable {
    public let manifest: ManagedToolLock
    public let receipt: DependencyReceipt
    public let installedEnvironments: [String: [CondaMetaPackage]]        // env name -> conda-meta packages (empty array = env dir exists but no metadata)
    public let installedPackIDs: Set<String>                              // optional packs considered installed
    public let registryDatabaseVersions: [String: String]                 // DatabaseRegistry-managed: id -> installed version (only installed ones)
    public let metagenomicsDatabaseVersions: [String: String]             // catalogID -> installed version (only status == .ready)
    public let installedMicromambaVersion: String?
    public let estimatedEnvBytes: (String) -> Int64                        // env name -> estimate; default 150 MB
}
public enum DependencyPlanner { public static func plan(_ inputs: DependencyPlannerInputs) -> ReconciliationPlan }
```

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import LungfishWorkflow

final class DependencyPlannerTests: XCTestCase {
    private func manifest(set: String = "2026.2",
                          tools: [(env: String, spec: String)] = [("samtools", "bioconda::samtools=1.24=h36b3a25_1")],
                          packTools: [(pack: String, env: String, spec: String)] = [("read-mapping", "minimap2", "bioconda::minimap2=2.31=h6bd33b9_0")],
                          databases: [DatabaseSpec] = []) -> ManagedToolLock {
        ManagedToolLock(
            packID: "lungfish-tools", displayName: "T", version: "0",
            tools: tools.map { ManagedToolLock.ToolSpec(id: $0.env, environment: $0.env, packageSpec: $0.spec, executables: [$0.env], version: CondaSpec(spec: $0.spec)!.version) },
            managedData: [], dependencySet: set,
            packTools: packTools.map { PackToolSpec(packID: $0.pack, toolID: $0.env, environment: $0.env, packageSpec: $0.spec, executables: [$0.env], version: CondaSpec(spec: $0.spec)!.version, license: nil, sourceUrl: nil) },
            pipelines: [PipelineSpec(id: "taxtriage", repository: "r", revision: "abc", releaseVersion: "v1")],
            databases: databases,
            bootstrap: BootstrapSpec(micromamba: MicromambaSpec(version: "2.9.0-0", sha256: nil)))
    }
    private func meta(_ name: String, _ v: String, _ b: String) -> CondaMetaPackage { .init(name: name, version: v, build: b, subdir: "osx-arm64", channel: nil) }
    private func inputs(_ m: ManagedToolLock, receipt: DependencyReceipt = .empty(), envs: [String: [CondaMetaPackage]] = [:],
                        packs: Set<String> = [], regDB: [String: String] = [:], metaDB: [String: String] = [:], mm: String? = "2.9.0-0") -> DependencyPlannerInputs {
        .init(manifest: m, receipt: receipt, installedEnvironments: envs, installedPackIDs: packs,
              registryDatabaseVersions: regDB, metagenomicsDatabaseVersions: metaDB, installedMicromambaVersion: mm, estimatedEnvBytes: { _ in 100 })
    }

    func testFreshInstallPlansRequiredToolsOnly() {
        let plan = DependencyPlanner.plan(inputs(manifest()))
        XCTAssertEqual(plan.installEnvironments.map(\.environment), ["samtools"])
        XCTAssertTrue(plan.installEnvironments[0].isRequired)
        XCTAssertTrue(plan.reinstallEnvironments.isEmpty)     // minimap2 pack not installed -> not planned
        XCTAssertTrue(plan.hasRequiredWork)
    }

    func testNoOpWhenReceiptAndDiskMatchManifest() {
        var r = DependencyReceipt.empty(); r.dependencySet = "2026.2"
        r.environments["samtools"] = .init(packageSpec: "bioconda::samtools=1.24=h36b3a25_1", packID: "lungfish-tools", installedAt: Date(), state: .installed)
        let plan = DependencyPlanner.plan(inputs(manifest(), receipt: r, envs: ["samtools": [meta("samtools", "1.24", "h36b3a25_1")]]))
        XCTAssertTrue(plan.isEmpty, "\(plan)")
    }

    func testBuildStringOnlyChangeTriggersReinstall() {
        var r = DependencyReceipt.empty()
        r.environments["samtools"] = .init(packageSpec: "bioconda::samtools=1.24=h36b3a25_0", packID: "lungfish-tools", installedAt: Date(), state: .installed)
        let plan = DependencyPlanner.plan(inputs(manifest(), receipt: r, envs: ["samtools": [meta("samtools", "1.24", "h36b3a25_0")]]))
        XCTAssertEqual(plan.reinstallEnvironments.map(\.environment), ["samtools"])
        XCTAssertEqual(plan.reinstallEnvironments[0].reason, .buildChanged)
    }

    func testMetadataMismatchWinsOverReceipt() {
        // Receipt claims 1.24 but conda-meta says 1.23.1 (e.g. user tampered): plan reinstall.
        var r = DependencyReceipt.empty()
        r.environments["samtools"] = .init(packageSpec: "bioconda::samtools=1.24=h36b3a25_1", packID: "lungfish-tools", installedAt: Date(), state: .installed)
        let plan = DependencyPlanner.plan(inputs(manifest(), receipt: r, envs: ["samtools": [meta("samtools", "1.23.1", "hc612e98_0")]]))
        XCTAssertEqual(plan.reinstallEnvironments.first?.reason, .metadataMismatch)
    }

    func testRetiredNamedEnvIsRemovedAndHexEnvsIgnored() {
        let plan = DependencyPlanner.plan(inputs(manifest(), envs: [
            "samtools": [meta("samtools", "1.24", "h36b3a25_1")],
            "trim_galore": [meta("trim-galore", "2.3.0", "h48b4a6d_0")],
            "env-e09e297bc7c40f8b3a57d80c8b5390c6": [meta("python", "3.10", "x")],
        ]))
        XCTAssertEqual(plan.removeEnvironments, ["trim_galore"])
    }

    func testInstalledOptionalPackIsReinstalledWhenSpecChanges() {
        let plan = DependencyPlanner.plan(inputs(manifest(), envs: [
            "samtools": [meta("samtools", "1.24", "h36b3a25_1")],
            "minimap2": [meta("minimap2", "2.30", "hba9b596_0")],
        ], packs: ["read-mapping"]))
        XCTAssertEqual(plan.reinstallEnvironments.map(\.environment), ["minimap2"])
        XCTAssertFalse(plan.reinstallEnvironments[0].isRequired)
        XCTAssertFalse(plan.hasRequiredWork)
    }

    func testDatabaseAdvisoryVsRequired() {
        let dbs = [
            DatabaseSpec(id: "human-scrubber", tool: "sra-human-scrubber", displayName: "HS", version: "20260706v2", url: "u", filename: "f", md5: nil, sha256: nil, md5Sidecar: true, indexFormat: nil, minimumToolVersion: nil, sizeBytes: 5, sizeOnDisk: nil, recommendedRAM: nil, description: nil, releaseDate: nil, sourceUrl: nil, releasesUrl: nil, updatePolicy: nil, collection: nil),
            DatabaseSpec(id: "deacon-panhuman", tool: "deacon", displayName: "PH", version: "panhuman-2", url: nil, filename: "f2", md5: nil, sha256: nil, md5Sidecar: nil, indexFormat: 4, minimumToolVersion: nil, sizeBytes: 7, sizeOnDisk: nil, recommendedRAM: nil, description: nil, releaseDate: nil, sourceUrl: nil, releasesUrl: nil, updatePolicy: .required, collection: nil),
            DatabaseSpec(id: "kraken2-viral", tool: "kraken2", displayName: "Viral", version: "20260626", url: "u3", filename: nil, md5: nil, sha256: nil, md5Sidecar: nil, indexFormat: nil, minimumToolVersion: nil, sizeBytes: 9, sizeOnDisk: nil, recommendedRAM: nil, description: nil, releaseDate: nil, sourceUrl: nil, releasesUrl: nil, updatePolicy: nil, collection: "viral"),
        ]
        let plan = DependencyPlanner.plan(inputs(manifest(databases: dbs), envs: ["samtools": [meta("samtools", "1.24", "h36b3a25_1")]],
                                                 regDB: ["human-scrubber": "20250916v2", "deacon-panhuman": "panhuman-1"], metaDB: ["kraken2-viral": "20240904"]))
        XCTAssertEqual(Set(plan.databaseUpdates.map(\.id)), ["human-scrubber", "deacon-panhuman", "kraken2-viral"])
        XCTAssertEqual(plan.databaseUpdates.first { $0.id == "deacon-panhuman" }?.policy, .required)
        XCTAssertEqual(plan.databaseUpdates.first { $0.id == "kraken2-viral" }?.managedBy, .metagenomicsRegistry)
        XCTAssertTrue(plan.hasRequiredWork)
        XCTAssertEqual(plan.estimatedDownloadBytes, 5 + 7 + 9)
        // Not-installed databases are never planned.
        XCTAssertFalse(plan.databaseUpdates.contains { $0.id == "kraken2-standard" })
    }

    func testBootstrapAndPipelineChanges() {
        var r = DependencyReceipt.empty(); r.pipelines["taxtriage"] = .init(revision: "old", prefetchedAt: nil)
        let plan = DependencyPlanner.plan(inputs(manifest(), receipt: r, envs: ["samtools": [meta("samtools", "1.24", "h36b3a25_1")]], mm: "2.0.5-0"))
        XCTAssertEqual(plan.bootstrapUpdate?.targetVersion, "2.9.0-0")
        XCTAssertEqual(plan.pipelinePrefetch.map(\.targetRevision), ["abc"])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --skip-update --filter DependencyPlannerTests`
Expected: FAIL (types missing).

- [ ] **Step 3: Implement**

`ReconciliationPlan.swift`: types exactly as in Interfaces; `isEmpty` = all collections empty and `bootstrapUpdate == nil`; `hasRequiredWork` = any env change with `isRequired` or any DB with `.required`.

`DependencyPlanner.swift`:

```swift
import Foundation

public enum DependencyPlanner {
    static let hexEnvPattern = try! NSRegularExpression(pattern: #"^(env-)?[0-9a-f]{32,64}$"#)

    public static func plan(_ inputs: DependencyPlannerInputs) -> ReconciliationPlan {
        let m = inputs.manifest
        var plan = ReconciliationPlan(installEnvironments: [], reinstallEnvironments: [], removeEnvironments: [],
                                      databaseUpdates: [], pipelinePrefetch: [], bootstrapUpdate: nil,
                                      targetDependencySet: m.resolvedDependencySet, estimatedDownloadBytes: 0)

        // 1. Desired environments: required pack always; optional packs only if installed.
        struct Desired { let env: String; let spec: String; let packID: String; let required: Bool }
        var desired: [Desired] = m.tools.map { Desired(env: $0.environment, spec: $0.packageSpec, packID: m.packID, required: true) }
        for pt in m.packTools where inputs.installedPackIDs.contains(pt.packID) {
            desired.append(Desired(env: pt.environment, spec: pt.packageSpec, packID: pt.packID, required: false))
        }
        for d in desired {
            let onDisk = inputs.installedEnvironments[d.env]
            let receiptEntry = inputs.receipt.environments[d.env]
            let target = CondaSpec(spec: d.spec)
            let change = { (reason: ReconciliationPlan.ChangeReason) in
                ReconciliationPlan.EnvironmentChange(environment: d.env, packID: d.packID, currentSpec: receiptEntry?.packageSpec,
                                                     targetSpec: d.spec, reason: reason, isRequired: d.required)
            }
            guard let pkgs = onDisk else {
                if d.required { plan.installEnvironments.append(change(.missing)); plan.estimatedDownloadBytes += inputs.estimatedEnvBytes(d.env) }
                continue
            }
            // Disk truth first.
            if let target, let primary = pkgs.first(where: { $0.name == target.name }) {
                if !target.matches(primary) {
                    let reason: ReconciliationPlan.ChangeReason =
                        (primary.version == target.version) ? .buildChanged : (receiptEntry == nil ? .metadataMismatch : .specChanged)
                    // If receipt agrees with manifest but disk disagrees -> metadataMismatch; else classify by diff kind.
                    let finalReason: ReconciliationPlan.ChangeReason =
                        (receiptEntry?.packageSpec == d.spec) ? .metadataMismatch : reason
                    plan.reinstallEnvironments.append(change(finalReason)); plan.estimatedDownloadBytes += inputs.estimatedEnvBytes(d.env)
                    continue
                }
            } else if pkgs.isEmpty || target == nil {
                plan.reinstallEnvironments.append(change(.metadataMismatch)); plan.estimatedDownloadBytes += inputs.estimatedEnvBytes(d.env)
                continue
            }
            // Disk matches manifest; receipt drift alone (e.g. pending/failed state) also triggers reinstall.
            if let receiptEntry, receiptEntry.state != .installed {
                plan.reinstallEnvironments.append(change(.metadataMismatch)); plan.estimatedDownloadBytes += inputs.estimatedEnvBytes(d.env)
            }
        }

        // 2. Retired named envs.
        let knownEnvs = Set(m.tools.map(\.environment) + m.packTools.map(\.environment))
        for name in inputs.installedEnvironments.keys.sorted() where !knownEnvs.contains(name) {
            let range = NSRange(name.startIndex..., in: name)
            if hexEnvPattern.firstMatch(in: name, range: range) != nil { continue }   // Nextflow caches: existing orphan logic
            plan.removeEnvironments.append(name)
        }

        // 3. Databases (only installed ones).
        for spec in m.databases {
            if let installed = inputs.registryDatabaseVersions[spec.id], installed != spec.version {
                plan.databaseUpdates.append(.init(id: spec.id, displayName: spec.displayName, installedVersion: installed, targetVersion: spec.version,
                                                  policy: spec.effectiveUpdatePolicy, estimatedBytes: spec.sizeBytes ?? 0, managedBy: .databaseRegistry))
                plan.estimatedDownloadBytes += spec.sizeBytes ?? 0
            } else if let installed = inputs.metagenomicsDatabaseVersions[spec.id], installed != spec.version {
                plan.databaseUpdates.append(.init(id: spec.id, displayName: spec.displayName, installedVersion: installed, targetVersion: spec.version,
                                                  policy: spec.effectiveUpdatePolicy, estimatedBytes: spec.sizeBytes ?? 0, managedBy: .metagenomicsRegistry))
                plan.estimatedDownloadBytes += spec.sizeBytes ?? 0
            }
        }

        // 4. Pipelines.
        for p in m.pipelines where inputs.receipt.pipelines[p.id]?.revision != p.revision {
            plan.pipelinePrefetch.append(.init(id: p.id, currentRevision: inputs.receipt.pipelines[p.id]?.revision, targetRevision: p.revision))
        }

        // 5. Bootstrap.
        if let target = m.bootstrap?.micromamba.version, inputs.installedMicromambaVersion != target {
            plan.bootstrapUpdate = .init(currentVersion: inputs.installedMicromambaVersion, targetVersion: target)
        }
        return plan
    }
}
```

Adjust the reason classification until the four reason tests pass; the intent: build-only diff → `.buildChanged`; version diff with a receipt that recorded the old spec → `.specChanged`; disk disagrees with a receipt that already claims the manifest spec → `.metadataMismatch`.

- [ ] **Step 4: Run tests**

Run: `swift test --skip-update --filter DependencyPlannerTests`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/Dependencies/ReconciliationPlan.swift Sources/LungfishWorkflow/Dependencies/DependencyPlanner.swift Tests/LungfishWorkflowTests/Dependencies/DependencyPlannerTests.swift
git commit -m "feat(deps): pure reconciliation planner with policy tests"
```

---

### Task A12: `DependencyReconciler` actor (gather inputs, apply plan, resumable receipt, provenance)

**Files:**
- Create: `Sources/LungfishWorkflow/Dependencies/DependencyReconciler.swift`, `Sources/LungfishWorkflow/Dependencies/DependencyReconcilerProvenance.swift`
- Test: `Tests/LungfishWorkflowTests/Dependencies/DependencyReconcilerTests.swift`

**Interfaces:**
```swift
public struct ReconcilerServices: Sendable {
    public var createEnvironment: @Sendable (_ name: String, _ spec: String, _ progress: @escaping @Sendable (Double, String) -> Void) async throws -> Void
    public var removeEnvironment: @Sendable (_ name: String) async throws -> Void
    public var smokeTest: @Sendable (_ environment: String) async throws -> Void
    public var installRegistryDatabase: @Sendable (_ id: String, _ progress: @escaping @Sendable (Double, String) -> Void) async throws -> URL
    public var updateMetagenomicsDatabase: @Sendable (_ catalogID: String, _ progress: @escaping @Sendable (Double, String) -> Void) async throws -> Void
    public var installBootstrap: @Sendable (_ targetVersion: String) async throws -> Void
    public var prefetchPipeline: @Sendable (_ id: String, _ revision: String) async throws -> Void
    public var listEnvironments: @Sendable () async -> [String: [CondaMetaPackage]]
    public var installedPackIDs: @Sendable () async -> Set<String>
    public var registryDatabaseVersions: @Sendable () async -> [String: String]
    public var metagenomicsDatabaseVersions: @Sendable () async -> [String: String]
    public var installedMicromambaVersion: @Sendable () async -> String?
    public static func live(condaManager: CondaManager, storageRoot: URL) -> ReconcilerServices
}
public struct PlanSelection: Sendable, Equatable { public var environments: Set<String>; public var databases: Set<String>; public var includeRemovals: Bool; public static func all(from plan: ReconciliationPlan) -> PlanSelection; public static func requiredOnly(from plan:) -> PlanSelection }
public struct ReconciliationResult: Sendable, Equatable { public var succeeded: [String]; public var failed: [String: String]; public var receipt: DependencyReceipt }
public actor DependencyReconciler {
    public init(manifest: ManagedToolLock, storageRoot: URL, services: ReconcilerServices, appVersion: String, operationCenter: DependencyOperationSink?)
    public func loadOrSynthesizeReceipt() throws -> DependencyReceipt
    public func currentPlan() async throws -> ReconciliationPlan
    public func apply(_ plan: ReconciliationPlan, selection: PlanSelection, progress: @escaping @Sendable (String, Double, String) -> Void) async throws -> ReconciliationResult
    public func stampCurrentSet() throws            // used when plan is empty at launch
}
public protocol DependencyOperationSink: Sendable { func start(title: String, detail: String) -> UUID; func update(id: UUID, progress: Double, detail: String); func log(id: UUID, message: String); func complete(id: UUID, detail: String); func fail(id: UUID, detail: String, error: String) }
```
`DependencyOperationSink` keeps `LungfishWorkflow` free of `LungfishKit`; the App provides an adapter over `OperationCenter.shared` (Task A14).

- [ ] **Step 1: Write the failing tests (fake services, no conda)**

```swift
import XCTest
@testable import LungfishWorkflow

final class DependencyReconcilerTests: XCTestCase {
    actor Calls { var created: [String] = []; var removed: [String] = []; var dbs: [String] = []
        func create(_ n: String) { created.append(n) }; func remove(_ n: String) { removed.append(n) }; func db(_ n: String) { dbs.append(n) } }

    private func manifest() -> ManagedToolLock {
        ManagedToolLock(packID: "lungfish-tools", displayName: "T", version: "0",
            tools: [.init(id: "samtools", environment: "samtools", packageSpec: "bioconda::samtools=1.24=h36b3a25_1", executables: ["samtools"], version: "1.24")],
            managedData: [], dependencySet: "2026.2",
            databases: [DatabaseSpec(id: "human-scrubber", tool: "sra-human-scrubber", displayName: "HS", version: "20260706v2", url: "u", filename: "f", md5: nil, sha256: nil, md5Sidecar: true, indexFormat: nil, minimumToolVersion: nil, sizeBytes: 1, sizeOnDisk: nil, recommendedRAM: nil, description: nil, releaseDate: nil, sourceUrl: nil, releasesUrl: nil, updatePolicy: nil, collection: nil)],
            bootstrap: BootstrapSpec(micromamba: .init(version: "2.9.0-0", sha256: nil)))
    }

    private func services(calls: Calls, envs: [String: [CondaMetaPackage]], failCreate: Set<String> = []) -> ReconcilerServices {
        var s = ReconcilerServices.live(condaManager: .shared, storageRoot: FileManager.default.temporaryDirectory) // start from live, override everything
        s.createEnvironment = { name, _, _ in if failCreate.contains(name) { throw NSError(domain: "t", code: 1) }; await calls.create(name) }
        s.removeEnvironment = { name in await calls.remove(name) }
        s.smokeTest = { _ in }
        s.installRegistryDatabase = { id, _ in await calls.db(id); return URL(fileURLWithPath: "/x") }
        s.updateMetagenomicsDatabase = { _, _ in }
        s.installBootstrap = { _ in }
        s.prefetchPipeline = { _, _ in }
        s.listEnvironments = { envs }
        s.installedPackIDs = { [] }
        s.registryDatabaseVersions = { ["human-scrubber": "20250916v2"] }
        s.metagenomicsDatabaseVersions = { [:] }
        s.installedMicromambaVersion = { "2.9.0-0" }
        return s
    }

    func testApplyInstallsRequiredAndWritesReceipt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let calls = Calls()
        let r = DependencyReconciler(manifest: manifest(), storageRoot: root, services: services(calls: calls, envs: [:]), appVersion: "0.5.0-beta30", operationCenter: nil)
        let plan = try await r.currentPlan()
        XCTAssertEqual(plan.installEnvironments.map(\.environment), ["samtools"])
        let result = try await r.apply(plan, selection: .all(from: plan)) { _, _, _ in }
        XCTAssertEqual(await calls.created, ["samtools"])
        XCTAssertEqual(await calls.dbs, ["human-scrubber"])
        XCTAssertTrue(result.failed.isEmpty)
        let saved = try XCTUnwrap(try DependencyReceiptStore(storageRoot: root).load())
        XCTAssertEqual(saved.dependencySet, "2026.2")
        XCTAssertEqual(saved.environments["samtools"]?.packageSpec, "bioconda::samtools=1.24=h36b3a25_1")
        XCTAssertEqual(saved.databases["human-scrubber"]?.version, "20260706v2")
    }

    func testFailedInstallLeavesEntryFailedAndSetUnstamped() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let calls = Calls()
        let r = DependencyReconciler(manifest: manifest(), storageRoot: root, services: services(calls: calls, envs: [:], failCreate: ["samtools"]), appVersion: "x", operationCenter: nil)
        let plan = try await r.currentPlan()
        let result = try await r.apply(plan, selection: .all(from: plan)) { _, _, _ in }
        XCTAssertNotNil(result.failed["samtools"])
        let saved = try XCTUnwrap(try DependencyReceiptStore(storageRoot: root).load())
        XCTAssertEqual(saved.environments["samtools"]?.state, .failed)
        XCTAssertNil(saved.dependencySet, "set must not be stamped while required work failed")
        // Re-planning after failure still wants samtools.
        let again = try await r.currentPlan()
        XCTAssertEqual(again.installEnvironments.map(\.environment) + again.reinstallEnvironments.map(\.environment), ["samtools"])
    }

    func testRequiredOnlySelectionSkipsDatabases() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let calls = Calls()
        let r = DependencyReconciler(manifest: manifest(), storageRoot: root, services: services(calls: calls, envs: [:]), appVersion: "x", operationCenter: nil)
        let plan = try await r.currentPlan()
        _ = try await r.apply(plan, selection: .requiredOnly(from: plan)) { _, _, _ in }
        XCTAssertEqual(await calls.dbs, [])
    }

    func testMissingReceiptIsSynthesizedFromDisk() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let r = DependencyReconciler(manifest: manifest(), storageRoot: root,
            services: services(calls: Calls(), envs: ["samtools": [.init(name: "samtools", version: "1.24", build: "h36b3a25_1", subdir: "osx-arm64", channel: nil)]]),
            appVersion: "x", operationCenter: nil)
        let receipt = try await r.loadOrSynthesizeReceipt()
        XCTAssertTrue(receipt.synthesized)
        let plan = try await r.currentPlan()
        XCTAssertTrue(plan.installEnvironments.isEmpty && plan.reinstallEnvironments.isEmpty)
    }
}
```

`loadOrSynthesizeReceipt` in the last test needs disk conda-meta; `services.listEnvironments` returns the packages, so make `synthesize` in the reconciler use `services.listEnvironments()` rather than reading the disk directly (the store's `synthesize(condaRoot:)` stays for the CLI path; add an overload `synthesize(environments:manifest:)` in `DependencyReceiptStore` and route both through it).

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --skip-update --filter DependencyReconcilerTests`
Expected: FAIL (types missing).

- [ ] **Step 3: Implement the actor**

Key behaviors (write the code accordingly; keep functions small):

- `currentPlan()`: `let receipt = try loadOrSynthesizeReceipt()`; gather inputs from services; `DependencyPlanner.plan(...)`.
- `apply`: order = bootstrap → required installs/reinstalls → optional reinstalls → databases (selected) → removals (if `includeRemovals` and no failures among reinstalls) → pipeline prefetch (best effort, errors logged not counted). For each env: mark receipt entry `.pending` and save; `removeEnvironment` if exists; `createEnvironment(name, spec, progress)`; `smokeTest(env)`; mark `.installed`, `packageSpec = target`, save. On error: mark `.failed`, save, record in `result.failed`, continue. After loop: if `result.failed.isEmpty` for all required items and no required DB failed → set `receipt.dependencySet = manifest.resolvedDependencySet`, `manifestHash`, `appVersion`; save. Each item is one operation via `operationCenter?.start/update/log/complete/fail`; a wrapping parent operation titled "Update tools to \(set)". Write one provenance envelope at the end via `DependencyReconcilerProvenance.write(result:plan:manifest:storageRoot:)` to `<root>/provenance/dependencies/<ISO timestamp>-<set>.lungfish-provenance.json` using `ProvenanceRunBuilder` with `workflowName: "dependency-reconcile"`, `toolName: "lungfish"`, `toolVersion: appVersion`; steps = one `ProvenanceStep` per item.
- `stampCurrentSet()`: load/synthesize, set `dependencySet`/`manifestHash`/`appVersion`, `synthesized = false`, save.
- `ReconcilerServices.live`: `createEnvironment` = `condaManager.createEnvironment(name:packages:[spec])`; `removeEnvironment` = `condaManager.removeEnvironment(name:)`; `smokeTest` = look up the requirement's `smokeTest` via `PluginPack.builtIn` and run it through the existing smoke runner used by `PluginPackStatusService` (expose a `static func runSmokeTest(_:environment:) async throws` there); `installRegistryDatabase` = `DatabaseRegistry.shared.installManagedDatabase(id, reinstall: true, progress:)`; `updateMetagenomicsDatabase` = the staging-swap flow from Task A13; `installBootstrap` = copy the bundled micromamba over `<condaRoot>/bin/micromamba` after verifying sha256 against `manifest.bootstrap.micromamba.sha256["osx-arm64"]` when present; `prefetchPipeline` = `TaxTriagePipeline.prefetchRepository(revision:)` (add a small static wrapper around the existing `fetchCachedRepository` if none is public; if it is not straightforward, log and skip); `listEnvironments` = enumerate `<condaRoot>/envs` with `CondaMetaReader`; `installedPackIDs` = packs where every requirement env dir exists; `registryDatabaseVersions` = for each `DatabaseRegistry.knownIDs`, if `effectiveDatabasePath(for:)` is non-nil, version parsed from the installed filename (match against `manifest.database(id:).filename`; if the file name differs from the manifest's, report the version recorded in the receipt or `"unknown"`); `metagenomicsDatabaseVersions` = `MetagenomicsDatabaseRegistry.shared.availableDatabases()` filtered `status == .ready` mapped `catalogID -> version`; `installedMicromambaVersion` = run `<condaRoot>/bin/micromamba --version` and trim.

- [ ] **Step 4: Run tests**

Run: `swift test --skip-update --filter DependencyReconcilerTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/Dependencies Tests/LungfishWorkflowTests/Dependencies
git commit -m "feat(deps): DependencyReconciler applies plans with resumable receipt and provenance"
```

---

### Task A13: Database update flow (staging, checksum, atomic swap, removal of old copy)

**Files:**
- Modify: `Sources/LungfishWorkflow/Databases/DatabaseRegistry.swift` (`installManagedDatabase` reinstall path: download to `<id>/.staging-<version>/`, verify md5 sidecar / manifest md5, move into place, delete other files in `<id>/`), `Sources/LungfishWorkflow/Metagenomics/MetagenomicsDatabaseRegistry.swift` (new `updateDatabase(catalogID:progress:)`: download recipe into `<name>.staging-<version>`, verify `md5`/`sha256` from `ManagedToolLock.bundled.database(id:)` when present, swap directories, remove old, update `version`/`installedAt`/`path`, save), `Sources/LungfishWorkflow/Metagenomics/MetagenomicsDatabaseInfo.swift` (`availableUpdateVersion` reads the manifest via `builtInCatalog`, unchanged API)
- Test: `Tests/LungfishWorkflowTests/Dependencies/DatabaseUpdateFlowTests.swift`

- [ ] **Step 1: Write the failing test (fake downloader)**

```swift
import XCTest
@testable import LungfishWorkflow

final class DatabaseUpdateFlowTests: XCTestCase {
    func testMetagenomicsUpdateSwapsAndRemovesOld() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let registry = MetagenomicsDatabaseRegistry(baseDirectory: base)
        try registry.loadIfNeeded()
        // Seed an installed old Viral DB directory.
        let oldDir = base.appendingPathComponent("kraken2/viral")
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try "old".write(to: oldDir.appendingPathComponent("hash.k2d"), atomically: true, encoding: .utf8)
        _ = try registry.registerExisting(at: oldDir, name: "Viral")
        // Inject a downloader that materializes a fake new archive extraction.
        registry.archiveInstaller = { url, destination, progress in
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try "new".write(to: destination.appendingPathComponent("hash.k2d"), atomically: true, encoding: .utf8)
        }
        try await registry.updateDatabase(catalogID: "kraken2-viral") { _, _ in }
        let db = try XCTUnwrap(try registry.database(named: "Viral"))
        XCTAssertEqual(db.version, ManagedToolLock.bundled.database(id: "kraken2-viral")?.version)
        XCTAssertEqual(try String(contentsOf: db.path!.appendingPathComponent("hash.k2d")), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("kraken2/viral.staging-\(db.version!)").path))
    }

    func testChecksumMismatchKeepsOldCopy() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let registry = MetagenomicsDatabaseRegistry(baseDirectory: base)
        try registry.loadIfNeeded()
        let oldDir = base.appendingPathComponent("esviritu/esviritu-viral-db")
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try "old".write(to: oldDir.appendingPathComponent("db.fna"), atomically: true, encoding: .utf8)
        _ = try registry.registerExisting(at: oldDir, name: "EsViritu Viral DB")
        registry.archiveInstaller = { _, destination, _ in
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try "new".write(to: destination.appendingPathComponent("db.fna"), atomically: true, encoding: .utf8)
        }
        registry.checksumOverride = { _ in "deadbeef" }   // force mismatch against manifest md5 when present
        await XCTAssertThrowsErrorAsync(try await registry.updateDatabase(catalogID: "esviritu-viral-v3") { _, _ in })
        XCTAssertEqual(try String(contentsOf: oldDir.appendingPathComponent("db.fna")), "old")
    }
}
```

(Add `XCTAssertThrowsErrorAsync` to `Tests/Support/LungfishTestSupport` if not present. `archiveInstaller` and `checksumOverride` are test seams: `internal var` closures on the registry with live defaults.)

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --skip-update --filter DatabaseUpdateFlowTests`
Expected: FAIL (`updateDatabase` missing).

- [ ] **Step 3: Implement**

`MetagenomicsDatabaseRegistry.updateDatabase(catalogID:progress:)`:
1. Find installed entry with `catalogID`; find catalog spec `MetagenomicsDatabaseInfo.builtInCatalog` entry; guard `installationRecipe` is `.archive(url:)` (special/local-built DBs: rebuild via existing installer path).
2. `staging = installedPath.deletingLastPathComponent().appendingPathComponent("\(dirName).staging-\(targetVersion)")`; remove if exists.
3. `try await archiveInstaller(url, staging, progress)` (default = existing download+extract used by `downloadDatabase`, refactored to take a destination).
4. If manifest spec has `md5`/`sha256`, compute over the downloaded archive (the installer must return the archive URL or write `checksum.txt` in staging; simplest: `archiveInstaller` returns the archive file URL) and compare via `checksumOverride ?? real`. On mismatch: remove staging, throw `MetagenomicsDatabaseRegistryError.checksumMismatch(name:)`.
5. Move installed dir to `<dir>.old-<uuid>`, move staging to installed path, remove `.old-*`. If the second move fails, restore.
6. Update entry `version`, `installedAt`, `lastUpdated`, `payloadDigest`, save; write provenance via the existing installer's provenance writer.

`DatabaseRegistry.installManagedDatabase(_, reinstall: true)`: after successful download to a temp file and md5 verification (existing code), move into `<root>/databases/<id>/<filename>` and delete every other regular file in `<root>/databases/<id>/` whose name differs from `filename` (old versions), logging each removal.

- [ ] **Step 4: Run tests**

Run: `swift test --skip-update --filter 'DatabaseUpdateFlowTests|MetagenomicsDatabase|DatabaseRegistry'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow Tests
git commit -m "feat(deps): checksum-verified staged database updates that replace superseded copies"
```

---

### Task A14: CLI `tools update` and `db update`

**Files:**
- Create: `Sources/LungfishCLI/Commands/ToolsCommand.swift`
- Modify: `Sources/LungfishCLI/LungfishCLI.swift:33` (add `ToolsCommand.self`), `Sources/LungfishCLI/Commands/DbCommand.swift` (add `DbUpdateSubcommand`)
- Test: `Tests/LungfishCLITests/ToolsCommandTests.swift`

**Interfaces:**
- `lungfish-cli tools update [--plan] [--apply --yes] [--json] [--required-only] [--include-databases] [--storage-root PATH]`; exit codes: 0 = nothing to do or applied; 3 = plan non-empty (with `--plan`, for scripting); `CLIExitCode.inputError` if `--apply` without `--yes`.
- `lungfish-cli db update <catalogID|--all> [--yes]`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import LungfishTestSupport

final class ToolsCommandTests: XCTestCase {
    func testPlanJSONOnEmptyRootListsRequiredInstalls() throws {
        let cli = try CLITestBinaryResolver.resolve()   // existing helper
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let (status, stdout, _) = try runProcess(cli, ["tools", "update", "--plan", "--json"], env: ["LUNGFISH_STORAGE_ROOT": root.path])
        XCTAssertEqual(status, 3)
        let json = try JSONSerialization.jsonObject(with: Data(stdout.utf8)) as! [String: Any]
        let installs = json["installEnvironments"] as! [[String: Any]]
        XCTAssertTrue(installs.contains { ($0["environment"] as? String) == "samtools" })
        XCTAssertEqual(json["targetDependencySet"] as? String, "2026.1")   // update when the set changes
    }

    func testApplyRequiresYes() throws {
        let cli = try CLITestBinaryResolver.resolve()
        let (status, _, stderr) = try runProcess(cli, ["tools", "update", "--apply"], env: [:])
        XCTAssertNotEqual(status, 0)
        XCTAssertTrue(stderr.contains("--yes"))
    }
}
```

(Use whatever process-running helper the CLI tests already use, e.g. in `CLIRegressionTests`; add `env:` support if missing. Do not hard-code the set string; read it from `ManagedToolLock.bundled` in the test.)

- [ ] **Step 2: Run to verify it fails**

Run: `swift build --product lungfish-cli && swift test --skip-update --filter ToolsCommandTests`
Expected: FAIL (unknown subcommand).

- [ ] **Step 3: Implement**

```swift
// Sources/LungfishCLI/Commands/ToolsCommand.swift
import ArgumentParser
import Foundation
import LungfishCore
import LungfishWorkflow

struct ToolsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tools", abstract: "Inspect and update managed third-party tools",
        subcommands: [UpdateSubcommand.self], defaultSubcommand: UpdateSubcommand.self)

    struct UpdateSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "update", abstract: "Plan or apply updates to the pinned dependency set")
        @Flag(help: "Print the plan and exit 3 if work is pending") var plan = false
        @Flag(help: "Apply the plan (requires --yes)") var apply = false
        @Flag(help: "Confirm non-interactive application") var yes = false
        @Flag(help: "Machine-readable JSON output") var json = false
        @Flag(help: "Only required tools") var requiredOnly = false
        @Flag(help: "Include advisory database updates") var includeDatabases = false
        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            let manifest = try ManagedToolLock.loadFromBundle()
            let store = ManagedStorageConfigStore()
            let root = store.currentLocation().rootURL
            let reconciler = DependencyReconciler(
                manifest: manifest, storageRoot: root,
                services: .live(condaManager: .shared, storageRoot: root),
                appVersion: LungfishAppVersion.short, operationCenter: nil)
            let plan = try await reconciler.currentPlan()
            if json { print(String(decoding: try JSONEncoder.pretty.encode(plan), as: UTF8.self)) } else { print(Self.render(plan)) }
            guard apply else { throw plan.isEmpty ? ExitCode.success : ExitCode(3) }
            guard yes else { FileHandle.standardError.write(Data("--apply requires --yes\n".utf8)); throw CLIExitCode.inputError.exitCode }
            var selection: PlanSelection = requiredOnly ? .requiredOnly(from: plan) : .all(from: plan)
            if !includeDatabases { selection.databases = Set(plan.databaseUpdates.filter { $0.policy == .required }.map(\.id)) }
            let result = try await reconciler.apply(plan, selection: selection) { item, fraction, detail in
                if !json { print("[\(Int(fraction * 100))%] \(item): \(detail)") }
            }
            if json { print(String(decoding: try JSONEncoder.pretty.encode(result), as: UTF8.self)) }
            if !result.failed.isEmpty { throw CLIExitCode.executionError.exitCode }
        }

        static func render(_ plan: ReconciliationPlan) -> String {
            var lines = ["Target dependency set: \(plan.targetDependencySet)"]
            if plan.isEmpty { lines.append("Nothing to do."); return lines.joined(separator: "\n") }
            for c in plan.installEnvironments { lines.append("install   \(c.environment)  \(c.targetSpec)\(c.isRequired ? "  (required)" : "")") }
            for c in plan.reinstallEnvironments { lines.append("reinstall \(c.environment)  \(c.currentSpec ?? "?") -> \(c.targetSpec)  [\(c.reason.rawValue)]") }
            for e in plan.removeEnvironments { lines.append("remove    \(e)  (retired)") }
            for d in plan.databaseUpdates { lines.append("database  \(d.id)  \(d.installedVersion ?? "?") -> \(d.targetVersion)  [\(d.policy.rawValue)]") }
            for p in plan.pipelinePrefetch { lines.append("pipeline  \(p.id)  \(p.currentRevision ?? "?") -> \(p.targetRevision)") }
            if let b = plan.bootstrapUpdate { lines.append("bootstrap micromamba \(b.currentVersion ?? "?") -> \(b.targetVersion)") }
            lines.append("Estimated download: \(ByteCountFormatter.string(fromByteCount: plan.estimatedDownloadBytes, countStyle: .file))")
            return lines.joined(separator: "\n")
        }
    }
}

extension JSONEncoder { static var pretty: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601; return e } }
```

Add `ReconciliationResult: Codable`. Register `ToolsCommand.self` in `LungfishCLI.swift`. Add `DbUpdateSubcommand` to `DbCommand` calling `MetagenomicsDatabaseRegistry.shared.updateDatabase(catalogID:progress:)` for one or all entries with `isUpdateAvailable`; require `--yes`.

- [ ] **Step 4: Run tests**

Run: `swift build --product lungfish-cli && swift test --skip-update --filter 'ToolsCommandTests|CLIRegressionTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishCLI Tests/LungfishCLITests/ToolsCommandTests.swift
git commit -m "feat(cli): tools update and db update commands over the dependency reconciler"
```

---

### Task A15: Launch trigger, Update Tools sheet, Plugin Manager button, Welcome gate

**Files:**
- Create: `Sources/LungfishApp/App/AppDelegate+DependencyReconciliation.swift`, `Sources/LungfishApp/Views/Dependencies/UpdateToolsSheet.swift`, `Sources/LungfishApp/Views/Dependencies/UpdateToolsSheetController.swift`, `Sources/LungfishApp/Services/OperationCenterDependencySink.swift`
- Modify: `Sources/LungfishApp/App/AppDelegate.swift:148` (call `scheduleDependencyReconciliation()` after `registerNotifications()`), `Sources/LungfishApp/Views/PluginManager/PluginManagerView.swift` (toolbar button "Check for Tool Updates…"), `Sources/LungfishApp/Views/PluginManager/PluginManagerViewModel.swift` (`checkForToolUpdates()`), `Sources/LungfishApp/Windows/WelcomeWindowController.swift:240-242,317-321,376` (re-evaluate required setup after the sheet completes; hook via `NotificationCenter` name `.lungfishDependencyReconciliationDidFinish`)
- Test: `Tests/LungfishAppTests/UpdateToolsSheetViewModelTests.swift`

**Interfaces:**
```swift
@MainActor @Observable final class UpdateToolsSheetViewModel {
    init(plan: ReconciliationPlan, reconciler: DependencyReconciler?)   // nil in unit tests; run() is a no-op when nil
    var plan: ReconciliationPlan
    var selectedOptionalEnvironments: Set<String>   // default: all optional
    var selectedDatabases: Set<String>              // default: required only
    var includeRemovals: Bool = true
    var isRunning: Bool; var itemStatus: [String: ItemStatus]; var completed: Bool; var failureSummary: String?
    var canDismissLater: Bool { !plan.hasRequiredWork }
    var estimatedBytes: Int64                        // recomputed from selection
    var freeSpaceWarning: String?                    // when free < estimate * 1.1
    func selection() -> PlanSelection
    func run() async
}
enum ItemStatus: Equatable { case pending, running(String), done, failed(String) }
```

- [ ] **Step 1: Write the failing view-model test**

```swift
import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

@MainActor
final class UpdateToolsSheetViewModelTests: XCTestCase {
    private func plan() -> ReconciliationPlan {
        var p = ReconciliationPlan(installEnvironments: [], reinstallEnvironments: [], removeEnvironments: [], databaseUpdates: [], pipelinePrefetch: [], bootstrapUpdate: nil, targetDependencySet: "2026.2", estimatedDownloadBytes: 0)
        p.reinstallEnvironments = [
            .init(environment: "samtools", packID: "lungfish-tools", currentSpec: "a", targetSpec: "b", reason: .specChanged, isRequired: true),
            .init(environment: "minimap2", packID: "read-mapping", currentSpec: "a", targetSpec: "b", reason: .specChanged, isRequired: false),
        ]
        p.databaseUpdates = [
            .init(id: "kraken2-viral", displayName: "Viral", installedVersion: "1", targetVersion: "2", policy: .advisory, estimatedBytes: 500, managedBy: .metagenomicsRegistry),
            .init(id: "deacon-panhuman", displayName: "PH", installedVersion: "1", targetVersion: "2", policy: .required, estimatedBytes: 300, managedBy: .databaseRegistry),
        ]
        return p
    }

    func testDefaultsSelectRequiredDBsAndAllOptionalEnvs() {
        let vm = UpdateToolsSheetViewModel(plan: plan(), reconciler: nil)
        XCTAssertEqual(vm.selectedOptionalEnvironments, ["minimap2"])
        XCTAssertEqual(vm.selectedDatabases, ["deacon-panhuman"])
        XCTAssertFalse(vm.canDismissLater)
        let sel = vm.selection()
        XCTAssertTrue(sel.environments.contains("samtools"))   // required always included
        XCTAssertEqual(sel.databases, ["deacon-panhuman"])
    }

    func testEstimatedBytesFollowsSelection() {
        let vm = UpdateToolsSheetViewModel(plan: plan(), reconciler: nil)
        let base = vm.estimatedBytes
        vm.selectedDatabases.insert("kraken2-viral")
        XCTAssertEqual(vm.estimatedBytes, base + 500)
    }
}
```

(`reconciler` optional in the initializer for tests; `run()` is a no-op when nil.)

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --skip-update --filter UpdateToolsSheetViewModelTests`
Expected: FAIL (type missing).

- [ ] **Step 3: Implement view model, sheet, controller, sink, launch hook**

- `OperationCenterDependencySink`: `struct` conforming to `DependencyOperationSink`, forwarding to `OperationCenter.shared.start(title:detail:operationType: .condaPluginPack)`, `.update(id:progress:detail:)`, `.log(id:level:.info,message:)`, `.complete(id:detail:)`, `.fail(id:detail:errorMessage:)`. All calls hop to main via `DispatchQueue.main.async { MainActor.assumeIsolated { ... } }` (project rule).
- `UpdateToolsSheet` (SwiftUI): width 500; header "Update tools to \(set)"; sections as in spec 4.5; primary button "Update" (Lungfish Orange), secondary "Later" when `canDismissLater` else "Quit". During run: per-item status list. On completion: "Done" button posts `.lungfishDependencyReconciliationDidFinish` and dismisses.
- `UpdateToolsSheetController`: `NSHostingController` presented as a sheet on the key window or the Welcome window (`beginSheet`, never `runModal`).
- `AppDelegate+DependencyReconciliation.swift`:

```swift
extension AppDelegate {
    private static let lastSetKey = "com.lungfish.lastLaunchedDependencySet"
    private static let lastAppKey = "com.lungfish.lastLaunchedAppVersion"

    func scheduleDependencyReconciliation() {
        guard ProcessInfo.processInfo.environment["LUNGFISH_DEBUG_BYPASS_REQUIRED_SETUP"] == nil else { return }
        let manifest = ManagedToolLock.bundled
        let defaults = UserDefaults.standard
        let store = ManagedStorageConfigStore()
        let root = store.currentLocation().rootURL
        let receiptStore = DependencyReceiptStore(storageRoot: root)
        let receipt = try? receiptStore.load()
        let unchanged = defaults.string(forKey: Self.lastSetKey) == manifest.resolvedDependencySet
            && defaults.string(forKey: Self.lastAppKey) == LungfishAppVersion.short
            && receipt?.manifestHash == manifest.manifestHash
        guard !unchanged else { return }
        let reconciler = DependencyReconciler(manifest: manifest, storageRoot: root,
            services: .live(condaManager: .shared, storageRoot: root),
            appVersion: LungfishAppVersion.short, operationCenter: OperationCenterDependencySink())
        Task { [weak self] in
            do {
                let plan = try await reconciler.currentPlan()
                if plan.isEmpty {
                    try await reconciler.stampCurrentSet()
                    await MainActor.run { defaults.set(manifest.resolvedDependencySet, forKey: Self.lastSetKey); defaults.set(LungfishAppVersion.short, forKey: Self.lastAppKey) }
                    return
                }
                await MainActor.run { self?.presentUpdateToolsSheet(plan: plan, reconciler: reconciler) }
            } catch {
                debugLog("Dependency reconciliation failed to plan: \(error)")
            }
        }
    }
}
```

`presentUpdateToolsSheet` presents on the Welcome window if visible, else key window; on `.lungfishDependencyReconciliationDidFinish` stamp the defaults if `receipt.dependencySet == manifest.resolvedDependencySet`.
- Plugin Manager: toolbar button calling `viewModel.checkForToolUpdates()` which builds a reconciler, computes the plan, and presents the same sheet (or an alert "Tools are up to date (2026.x)").
- Welcome window: observe `.lungfishDependencyReconciliationDidFinish` and re-run its required-setup evaluation.

- [ ] **Step 4: Run tests and build the app**

Run: `swift test --skip-update --filter 'UpdateToolsSheetViewModelTests|WelcomeWindow|PluginManager'` then `swift build --product Lungfish`
Expected: PASS; build succeeds.

- [ ] **Step 5: GUI verification (Computer Use, required)**

Launch `.build/debug/Lungfish` with `LUNGFISH_STORAGE_ROOT` pointing at (a) an empty dir, (b) a copy of a beta29-shaped root (copy `~/.lungfish/conda/envs/samtools` and two other envs into `<tmp>/conda/envs`, no receipt). Confirm: sheet appears with expected sections and counts; "Later" disabled when required work pending; Update runs with OperationCenter entries visible; after completion `dependency-receipt.json` exists with `dependencySet` stamped; Welcome window allows creating a project. Record screenshots under `docs/verification/2026-08-XX-update-tools-sheet.md`.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishApp Tests/LungfishAppTests docs/verification
git commit -m "feat(app): Update Tools sheet, launch-time reconciliation, Plugin Manager check for updates"
```

---

### Task A16: Bootstrap checksum, retire `update-tool-versions.sh`, smoke script alignment

**Files:**
- Modify: `scripts/bundle-native-tools.sh:124-147` (verify sha256 from manifest `bootstrap.micromamba.sha256["osx-arm64"]` when non-empty), `scripts/smoke-test-release-tools.sh` (add: `tool-versions.json` micromamba version equals manifest bootstrap version), delete `scripts/update-tool-versions.sh`, update `SKILLS.md`/docs references (`grep -rn update-tool-versions docs scripts SKILLS.md`)
- Test: `scripts/tests/test_bundle_native_tools_checksum.py` (python unittest, runs in CI)

- [ ] **Step 1: Write the failing script test**

```python
# scripts/tests/test_bundle_native_tools_checksum.py
import json, pathlib, subprocess, unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]

class BundleNativeToolsChecksumTests(unittest.TestCase):
    def test_script_reads_manifest_checksum(self):
        text = (ROOT / "scripts/bundle-native-tools.sh").read_text()
        self.assertIn("third-party-tools-lock.json", text)
        self.assertIn("shasum -a 256", text)

    def test_update_tool_versions_script_is_gone(self):
        self.assertFalse((ROOT / "scripts/update-tool-versions.sh").exists())

    def test_manifest_and_tool_versions_agree(self):
        manifest = json.loads((ROOT / "Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json").read_text())
        tv = json.loads((ROOT / "Sources/LungfishWorkflow/Resources/Tools/tool-versions.json").read_text())
        mm = next(t for t in tv["tools"] if t["name"] == "micromamba")
        self.assertEqual(mm["version"], manifest["bootstrap"]["micromamba"]["version"])

if __name__ == "__main__":
    unittest.main()
```

(Adjust the `tool-versions.json` key path to the real file structure.)

- [ ] **Step 2: Run to verify it fails**

Run: `python3 -B -m unittest scripts/tests/test_bundle_native_tools_checksum.py`
Expected: FAIL.

- [ ] **Step 3: Implement**

In `bundle-native-tools.sh` after download: `EXPECTED=$(jq -r '.bootstrap.micromamba.sha256["osx-arm64"] // empty' "$MANIFEST")`; if non-empty, `ACTUAL=$(shasum -a 256 "$OUT" | cut -d' ' -f1)`; mismatch → exit 66 with message. Delete `update-tool-versions.sh`; fix references. In `smoke-test-release-tools.sh`, add the version-agreement check reading the manifest from the app bundle resources.

- [ ] **Step 4: Run tests**

Run: `python3 -B -m unittest discover -s scripts/tests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A scripts SKILLS.md docs
git commit -m "chore(deps): checksum-verify micromamba download and retire update-tool-versions.sh"
```

---

### Task A17: Full-suite gate and integration review for Plan A

- [ ] **Step 1: Run the whole suite**

Run: `bash scripts/full-suite-gate.sh`
Expected: XCTest failures ⊆ the 9 known-environmental failures; swift-testing = 0.

- [ ] **Step 2: Fable review**

Fable reads the complete Plan A diff (`git diff main...HEAD --stat` then per-file), checks: no literal pins remain (`NoLiteralDependencyPinsTests` green), receipt/planner/reconciler behaviors match spec 4.3 to 4.5 and 4.9, GUI verification record exists, CLI parity (`tools update --plan --json` matches the sheet's plan on the same root).

- [ ] **Step 3: Commit any review fixes and tag**

```bash
git tag deps-plan-a-complete
```

## Self-review notes

- Spec 4.1 (manifest, build strings, no mirrors, dependencySet): A1 to A6, guard test A3.
- Spec 4.2 (provenance): A7.
- Spec 4.3 (receipt, synthesis): A10.
- Spec 4.4 (reconciler policy, triggers, CLI): A11, A12, A14, A15.
- Spec 4.5 (sheet): A15.
- Spec 4.8 (compat, dead URLs, storage relocation): A1 legacy decode test, A5 `reconcileCatalogURLs`, receipt travels with root because it lives at the root (relocation code moves the whole root; verify in A15 GUI step by relocating storage in Settings after an update and confirming the receipt moved; if `StorageSettingsTab` moves only `conda/` and `databases/`, add `dependency-receipt.json` to its move list in A15).
- Spec 4.9 (errors): A12 failed-state receipt, A13 checksum mismatch, A15 disk-space warning; concurrent runs serialized by `CondaRootMutationLock` inside `CondaManager` calls (reconciler runs are also serialized by making `apply` non-reentrant: guard `isApplying` flag).
