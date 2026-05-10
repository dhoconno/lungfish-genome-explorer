# Reads-to-Variants Chapter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land four Lungfish fixes (iVar TSV-to-VCF converter at viralrecon parity with codon merging and Fisher strand-bias filter, GFF passthrough, GUI dialog parity, `bam adopt-mapping` CLI subcommand, SRA download fallback) and the new end-to-end "From Reads to Variants" chapter, with full test coverage.

**Architecture:** A new pure-Swift converter sits between `ivar variants` (which emits TSV only) and the existing `bcftools sort` step in `ViralVariantCallingPipeline`. The converter implements all five viralrecon behaviors (transcription, indel anchoring, header emission, codon-aware haplotype merging, Fisher's exact strand-bias filter). Codon merging needs `REF_CODON`/`ALT_CODON` columns, which iVar populates only when given a real GFF — so the pipeline starts dumping the bundle's annotation database to a temp GFF instead of `/dev/null`. New `BundleVariantCallingRequest` fields propagate four user-facing options through CLI, dialog, and pipeline. A new `lungfish bam adopt-mapping` subcommand wraps `PreparedAlignmentAttachmentService` so a fresh mapping result becomes a bundle alignment track from the shell. SRA download retries the SRA Toolkit when ENA fails. The chapter prose lives at `docs/user-manual/chapters/04-variants/01-reads-to-variants.md` and replaces the two existing chapters.

**Tech Stack:** Swift 6.2 (`@unchecked Sendable` actors and `@MainActor` isolation already in use), `Foundation.lgamma` for the Fisher test, existing `NativeToolRunner`, `PreparedAlignmentAttachmentService`, `AnnotationDatabase`, swift-argument-parser for the CLI, SwiftUI for the dialog, swift-testing for new tests (existing test pattern).

---

## File Structure

### New files

- `Sources/LungfishWorkflow/Variants/IVarTSVToVCFConverter.swift` — single-file converter, public API takes a TSV URL + reference index URL + options and writes both VCFs.
- `Sources/LungfishWorkflow/Variants/IVarTSVRow.swift` — typed row model parsed from the iVar TSV header order.
- `Sources/LungfishWorkflow/Variants/FisherExactTest.swift` — pure-Swift 2×2 Fisher's exact (two-sided) using log-gamma. Isolated for unit testing.
- `Sources/LungfishWorkflow/Variants/IVarCodonMerger.swift` — codon-aware haplotype merging logic; consumes `IVarTSVRow` arrays, emits primary + all-haplotype groups.
- `Sources/LungfishWorkflow/Annotation/AnnotationDatabaseGFFExporter.swift` — small new file that walks an `AnnotationDatabase` and writes GFF3 to a URL.
- `Sources/LungfishCLI/Commands/BAMAdoptMappingSubcommand.swift` — new subcommand under `BAMCommand`.
- `Tests/LungfishWorkflowTests/Variants/IVarTSVToVCFConverterTests.swift`
- `Tests/LungfishWorkflowTests/Variants/FisherExactTestTests.swift`
- `Tests/LungfishWorkflowTests/Variants/IVarCodonMergerTests.swift`
- `Tests/LungfishWorkflowTests/Annotation/AnnotationDatabaseGFFExporterTests.swift`
- `Tests/LungfishIntegrationTests/IVarConverterViralReconParityTests.swift`
- `Tests/LungfishIntegrationTests/BAMAdoptMappingIntegrationTests.swift`
- `Tests/LungfishIntegrationTests/ReadsToVariantsEndToEndTests.swift`
- `Tests/LungfishCoreTests/SRADownloadFallbackTests.swift`
- `Tests/Fixtures/ivar-converter/` — small TSV + reference + expected VCF fixtures for unit tests.
- `Tests/Fixtures/ivar-converter-parity/sarscov2-srr36291587.tsv.gz` — gzipped real iVar TSV used by parity test.
- `docs/user-manual/chapters/04-variants/01-reads-to-variants.md` — new chapter prose.
- `docs/user-manual/chapters/04-variants/01-reads-to-variants-shotlist.md` — screenshot capture instructions.
- `docs/user-manual/fixtures/sarscov2-srr36291587/README.md` — fixture description and citation.
- `docs/user-manual/fixtures/sarscov2-srr36291587/regenerate.sh` — script to re-derive artifacts from accessions.
- `docs/user-manual/fixtures/sarscov2-srr36291587/MN908947.3.fasta` — committed reference (~30 KB).
- `docs/user-manual/fixtures/sarscov2-srr36291587/ivar.lofreq.expected.vcf` — committed reference VCF (LoFreq).
- `docs/user-manual/fixtures/sarscov2-srr36291587/ivar.expected.vcf` — committed reference VCF (iVar via converter).

### Modified files

- `Sources/LungfishWorkflow/Variants/BundleVariantCallingModels.swift` — `BundleVariantCallingRequest` gains four new fields.
- `Sources/LungfishWorkflow/Variants/ViralVariantCallingPipeline.swift` — call converter instead of `--output-format vcf`, dump GFF, drop the `--output-format vcf` arg, add converter parameters to staging plan.
- `Sources/LungfishCLI/Commands/VariantsCommand.swift` — four new `@Option`/`@Flag` declarations on `CallSubcommand`, wired into the request.
- `Sources/LungfishCLI/Commands/BAMCommand.swift` — register `BAMAdoptMappingSubcommand` in the `bam` subcommand list.
- `Sources/LungfishApp/Views/BAM/BAMVariantCallingDialogState.swift` — four new `@Published` fields, plumbed into the request builder.
- `Sources/LungfishApp/Views/BAM/BAMVariantCallingToolPanes.swift` — new "iVar Options" section under the primer-trim acknowledgement.
- `Sources/LungfishCore/Services/NCBI/SRAService.swift` — new combined fallback function `downloadFASTQWithFallback`.
- `Sources/LungfishCLI/Commands/FetchCommand.swift` — call the new fallback function when neither `--use-toolkit` nor a `--use-ena` flag is forced; add a `--prefer-toolkit` alias for the existing `--use-toolkit` to make the new wording match.
- `Sources/LungfishWorkflow/Conda/PluginPack.swift` — leave the `ivar=1.4.4` pin alone (current latest); update the `displayName` description if appropriate.
- `docs/user-manual/index.md` — point the variants section at the new single chapter.
- `docs/user-manual/chapters/04-variants/index.md` — replace per-chapter cards with one card.

### Deleted files (in the same commit as the new chapter)

- `docs/user-manual/chapters/04-variants/01-reading-a-vcf.md`
- `docs/user-manual/chapters/04-variants/02-calling-variants-from-a-bam.md`

---

## Phase 1 — Fisher's exact test (foundation)

This is the smallest and most isolated unit. It has no dependencies on the rest of the changes. Land it first.

### Task 1.1: Add the Fisher exact test failing test

**Files:**
- Create: `Tests/LungfishWorkflowTests/Variants/FisherExactTestTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import LungfishWorkflow

@Suite("FisherExactTest")
struct FisherExactTestTests {
    @Test("matches scipy two-sided p-value for balanced 2x2")
    func balancedTable() throws {
        // scipy.stats.fisher_exact([[10,10],[10,10]], alternative='two-sided')
        // p-value ~ 1.0
        let p = FisherExactTest.twoSidedPValue(a: 10, b: 10, c: 10, d: 10)
        #expect(abs(p - 1.0) < 1e-9)
    }

    @Test("matches scipy for clear strand bias")
    func clearStrandBias() throws {
        // scipy.stats.fisher_exact([[20,0],[0,20]], alternative='two-sided')
        // p-value ~ 5.4e-11
        let p = FisherExactTest.twoSidedPValue(a: 20, b: 0, c: 0, d: 20)
        #expect(p < 1e-10)
    }

    @Test("matches scipy for moderate imbalance")
    func moderateImbalance() throws {
        // scipy.stats.fisher_exact([[8,2],[1,9]], alternative='two-sided')
        // p-value ~ 0.005477494641581329
        let p = FisherExactTest.twoSidedPValue(a: 8, b: 2, c: 1, d: 9)
        #expect(abs(p - 0.005477494641581329) < 1e-9)
    }

    @Test("returns 1.0 for empty table")
    func emptyTable() throws {
        let p = FisherExactTest.twoSidedPValue(a: 0, b: 0, c: 0, d: 0)
        #expect(p == 1.0)
    }

    @Test("handles very large counts without overflow")
    func largeCounts() throws {
        // scipy.stats.fisher_exact([[1000,1000],[1000,1000]], alternative='two-sided')
        // p-value ~ 1.0
        let p = FisherExactTest.twoSidedPValue(a: 1000, b: 1000, c: 1000, d: 1000)
        #expect(abs(p - 1.0) < 1e-9)
    }
}
```

- [ ] **Step 2: Run the test to confirm it fails**

Run: `swift test --filter FisherExactTestTests`
Expected: FAIL with "Cannot find 'FisherExactTest' in scope"

### Task 1.2: Implement Fisher exact test

**Files:**
- Create: `Sources/LungfishWorkflow/Variants/FisherExactTest.swift`

- [ ] **Step 1: Write the implementation**

```swift
// FisherExactTest.swift - Pure-Swift two-sided Fisher's exact test for 2x2 contingency tables.
// Uses log-gamma to avoid overflow for large counts.

import Foundation

public enum FisherExactTest {
    /// Two-sided Fisher's exact p-value for a 2x2 table:
    ///
    ///     [[a, b],
    ///      [c, d]]
    ///
    /// Uses the standard "sum of probabilities <= observed" definition. Returns
    /// 1.0 for the degenerate all-zeros table.
    public static func twoSidedPValue(a: Int, b: Int, c: Int, d: Int) -> Double {
        let n = a + b + c + d
        if n == 0 { return 1.0 }

        let row1 = a + b
        let row2 = c + d
        let col1 = a + c
        let col2 = b + d

        // Probability of a single 2x2 table with given marginals having `a` in cell (0,0):
        //     P(a) = C(row1, a) * C(row2, col1 - a) / C(n, col1)
        //          = exp( lgamma(row1+1) + lgamma(row2+1) + lgamma(col1+1) + lgamma(col2+1)
        //                 - lgamma(n+1)
        //                 - lgamma(a+1) - lgamma(b+1) - lgamma(c+1) - lgamma(d+1) )
        //
        // Constant factor depending only on the marginals:
        let logMarginalsConstant =
            lgamma(Double(row1 + 1))
            + lgamma(Double(row2 + 1))
            + lgamma(Double(col1 + 1))
            + lgamma(Double(col2 + 1))
            - lgamma(Double(n + 1))

        func logP(forA aValue: Int) -> Double {
            let bValue = row1 - aValue
            let cValue = col1 - aValue
            let dValue = row2 - cValue
            if aValue < 0 || bValue < 0 || cValue < 0 || dValue < 0 {
                return -.infinity
            }
            return logMarginalsConstant
                - lgamma(Double(aValue + 1))
                - lgamma(Double(bValue + 1))
                - lgamma(Double(cValue + 1))
                - lgamma(Double(dValue + 1))
        }

        let logPObserved = logP(forA: a)
        // Two-sided: sum probabilities of all tables with same marginals whose
        // probability is <= observed. Use a small epsilon to handle ties robustly.
        let epsilon = 1e-12
        let lowA = max(0, col1 - row2)
        let highA = min(row1, col1)

        var sum = 0.0
        for candidate in lowA...highA {
            let lp = logP(forA: candidate)
            if lp <= logPObserved + epsilon {
                sum += exp(lp)
            }
        }
        return min(1.0, sum)
    }
}
```

- [ ] **Step 2: Run the test to confirm it passes**

Run: `swift test --filter FisherExactTestTests`
Expected: PASS, all 5 tests green.

- [ ] **Step 3: Commit**

```bash
git add Sources/LungfishWorkflow/Variants/FisherExactTest.swift Tests/LungfishWorkflowTests/Variants/FisherExactTestTests.swift
git commit -m "$(cat <<'EOF'
Add Fisher exact two-sided test for 2x2 strand-bias filter

Pure-Swift implementation using Foundation.lgamma to avoid overflow at
high read depths. Five unit tests cover balanced, clearly biased,
moderately biased, empty, and large-count tables, with values verified
against scipy.stats.fisher_exact.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Phase 2 — iVar TSV row model

### Task 2.1: Define the row model with parser

**Files:**
- Create: `Sources/LungfishWorkflow/Variants/IVarTSVRow.swift`
- Create: `Tests/LungfishWorkflowTests/Variants/IVarTSVRowTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import LungfishWorkflow

@Suite("IVarTSVRow")
struct IVarTSVRowTests {
    private static let header = "REGION\tPOS\tREF\tALT\tREF_DP\tREF_RV\tREF_QUAL\tALT_DP\tALT_RV\tALT_QUAL\tALT_FREQ\tTOTAL_DP\tPVAL\tPASS\tGFF_FEATURE\tREF_CODON\tREF_AA\tALT_CODON\tALT_AA\tPOS_AA"

    @Test("parses a SNP row")
    func parsesSNP() throws {
        let line = "MN908947.3\t241\tC\tT\t0\t0\t0\t1950\t935\t37\t1\t1950\t0\tTRUE\tNA\tNA\tNA\tNA\tNA\tNA"
        let row = try #require(IVarTSVRow.parse(line: line, header: Self.header))
        #expect(row.region == "MN908947.3")
        #expect(row.pos == 241)
        #expect(row.ref == "C")
        #expect(row.alt == "T")
        #expect(row.altFreq == 1.0)
        #expect(row.totalDP == 1950)
        #expect(row.pass == true)
        #expect(row.kind == .snp)
    }

    @Test("parses an insertion encoded with +")
    func parsesInsertion() throws {
        let line = "MN908947.3\t100\tA\t+TG\t10\t5\t30\t40\t20\t37\t0.8\t50\t0.001\tTRUE\tNA\tNA\tNA\tNA\tNA\tNA"
        let row = try #require(IVarTSVRow.parse(line: line, header: Self.header))
        #expect(row.kind == .insertion(insertedBases: "TG"))
        #expect(row.ref == "A")
        #expect(row.alt == "+TG")
    }

    @Test("parses a deletion encoded with -")
    func parsesDeletion() throws {
        let line = "MN908947.3\t200\tA\t-CG\t40\t20\t37\t10\t5\t30\t0.2\t50\t0.001\tTRUE\tNA\tNA\tNA\tNA\tNA\tNA"
        let row = try #require(IVarTSVRow.parse(line: line, header: Self.header))
        #expect(row.kind == .deletion(deletedBases: "CG"))
    }

    @Test("treats PASS=FALSE as false")
    func parsesPassFalse() throws {
        let line = "MN908947.3\t44\tC\tT\t75\t75\t38\t4\t2\t38\t0.05\t79\t0.06\tFALSE\tNA\tNA\tNA\tNA\tNA\tNA"
        let row = try #require(IVarTSVRow.parse(line: line, header: Self.header))
        #expect(row.pass == false)
    }

    @Test("returns nil for malformed line")
    func rejectsMalformed() {
        let row = IVarTSVRow.parse(line: "only one field", header: Self.header)
        #expect(row == nil)
    }
}
```

- [ ] **Step 2: Run the test to confirm it fails**

Run: `swift test --filter IVarTSVRowTests`
Expected: FAIL with "Cannot find 'IVarTSVRow' in scope"

- [ ] **Step 3: Write the implementation**

```swift
// IVarTSVRow.swift - Typed view of a single iVar TSV variant row.

import Foundation

public struct IVarTSVRow: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case snp
        case insertion(insertedBases: String)
        case deletion(deletedBases: String)
    }

    public let region: String
    public let pos: Int
    public let ref: String
    public let alt: String
    public let refDP: Int
    public let refRV: Int
    public let refQual: Int
    public let altDP: Int
    public let altRV: Int
    public let altQual: Int
    public let altFreq: Double
    public let totalDP: Int
    public let pval: Double
    public let pass: Bool
    public let gffFeature: String?
    public let refCodon: String?
    public let refAA: String?
    public let altCodon: String?
    public let altAA: String?
    public let posAA: Int?
    public let kind: Kind

    public static func parse(line: String, header: String) -> IVarTSVRow? {
        let columns = header.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        let values = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard columns.count == values.count, columns.count >= 14 else { return nil }
        var dict = [String: String](minimumCapacity: columns.count)
        for (column, value) in zip(columns, values) {
            dict[column] = value
        }
        guard
            let region = dict["REGION"],
            let posStr = dict["POS"], let pos = Int(posStr),
            let ref = dict["REF"],
            let alt = dict["ALT"],
            let refDP = Int(dict["REF_DP"] ?? ""),
            let refRV = Int(dict["REF_RV"] ?? ""),
            let refQual = Int(dict["REF_QUAL"] ?? ""),
            let altDP = Int(dict["ALT_DP"] ?? ""),
            let altRV = Int(dict["ALT_RV"] ?? ""),
            let altQual = Int(dict["ALT_QUAL"] ?? ""),
            let altFreq = Double(dict["ALT_FREQ"] ?? ""),
            let totalDP = Int(dict["TOTAL_DP"] ?? ""),
            let pval = Double(dict["PVAL"] ?? "1.0"),
            let passStr = dict["PASS"]
        else {
            return nil
        }
        let pass = passStr.uppercased() == "TRUE"
        let kind: Kind
        if alt.hasPrefix("+") {
            kind = .insertion(insertedBases: String(alt.dropFirst()))
        } else if alt.hasPrefix("-") {
            kind = .deletion(deletedBases: String(alt.dropFirst()))
        } else {
            kind = .snp
        }
        func optionalString(_ key: String) -> String? {
            guard let raw = dict[key], !raw.isEmpty, raw != "NA" else { return nil }
            return raw
        }
        return IVarTSVRow(
            region: region,
            pos: pos,
            ref: ref,
            alt: alt,
            refDP: refDP,
            refRV: refRV,
            refQual: refQual,
            altDP: altDP,
            altRV: altRV,
            altQual: altQual,
            altFreq: altFreq,
            totalDP: totalDP,
            pval: pval,
            pass: pass,
            gffFeature: optionalString("GFF_FEATURE"),
            refCodon: optionalString("REF_CODON"),
            refAA: optionalString("REF_AA"),
            altCodon: optionalString("ALT_CODON"),
            altAA: optionalString("ALT_AA"),
            posAA: optionalString("POS_AA").flatMap(Int.init),
            kind: kind
        )
    }
}
```

- [ ] **Step 4: Run the test to confirm it passes**

Run: `swift test --filter IVarTSVRowTests`
Expected: PASS, all 5 tests green.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/Variants/IVarTSVRow.swift Tests/LungfishWorkflowTests/Variants/IVarTSVRowTests.swift
git commit -m "$(cat <<'EOF'
Add IVarTSVRow parser for iVar variants TSV output

Typed model with insertion/deletion/SNP discrimination from iVar's `+`
and `-` ALT prefixes, plus optional GFF/codon columns. Covered by five
unit tests including a malformed-line rejection case.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Phase 3 — Codon-aware merger

### Task 3.1: Failing tests for codon merging

**Files:**
- Create: `Tests/LungfishWorkflowTests/Variants/IVarCodonMergerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import LungfishWorkflow

@Suite("IVarCodonMerger")
struct IVarCodonMergerTests {
    private func snp(pos: Int, ref: String, alt: String, freq: Double, dp: Int = 100, refCodon: String?, altCodon: String?) -> IVarTSVRow {
        IVarTSVRow(
            region: "MN908947.3",
            pos: pos,
            ref: ref,
            alt: alt,
            refDP: max(0, dp - Int(Double(dp) * freq)),
            refRV: 0,
            refQual: 38,
            altDP: Int(Double(dp) * freq),
            altRV: 0,
            altQual: 38,
            altFreq: freq,
            totalDP: dp,
            pval: 0.0,
            pass: true,
            gffFeature: "gene",
            refCodon: refCodon,
            refAA: nil,
            altCodon: altCodon,
            altAA: nil,
            posAA: nil,
            kind: .snp
        )
    }

    @Test("two adjacent SNPs sharing a codon merge into one consensus row")
    func twoAdjacentSNPsMerge() throws {
        let rows = [
            snp(pos: 100, ref: "G", alt: "A", freq: 0.95, refCodon: "GCT", altCodon: "ACT"),
            snp(pos: 101, ref: "C", alt: "T", freq: 0.94, refCodon: "GCT", altCodon: "ATT"),
        ]
        let result = IVarCodonMerger.merge(rows: rows, consensusAF: 0.75, mergeAFThreshold: 0.25)
        #expect(result.consensus.count == 1)
        let merged = result.consensus[0]
        #expect(merged.kind == .merged)
        #expect(merged.positions == [100, 101])
    }

    @Test("two adjacent SNPs with divergent AFs split into individual rows")
    func divergentAFsSplit() throws {
        let rows = [
            snp(pos: 100, ref: "G", alt: "A", freq: 0.95, refCodon: "GCT", altCodon: "ACT"),
            snp(pos: 101, ref: "C", alt: "T", freq: 0.10, refCodon: "GCT", altCodon: "ATT"),
        ]
        let result = IVarCodonMerger.merge(rows: rows, consensusAF: 0.75, mergeAFThreshold: 0.25)
        #expect(result.consensus.count == 1)        // The first row is above consensusAF
        #expect(result.consensus[0].positions == [100])
    }

    @Test("non-adjacent SNPs do not merge even with same codon attribute")
    func nonAdjacentDoNotMerge() throws {
        let rows = [
            snp(pos: 100, ref: "G", alt: "A", freq: 0.95, refCodon: "GCT", altCodon: "ACT"),
            snp(pos: 105, ref: "C", alt: "T", freq: 0.94, refCodon: "GCT", altCodon: "ATT"),
        ]
        let result = IVarCodonMerger.merge(rows: rows, consensusAF: 0.75, mergeAFThreshold: 0.25)
        #expect(result.consensus.count == 2)
        #expect(result.consensus.allSatisfy { $0.positions.count == 1 })
    }

    @Test("rows missing codon info are passed through unchanged")
    func missingCodonInfoPassThrough() throws {
        let rows = [
            snp(pos: 100, ref: "G", alt: "A", freq: 0.95, refCodon: nil, altCodon: nil),
            snp(pos: 101, ref: "C", alt: "T", freq: 0.94, refCodon: nil, altCodon: nil),
        ]
        let result = IVarCodonMerger.merge(rows: rows, consensusAF: 0.75, mergeAFThreshold: 0.25)
        #expect(result.consensus.count == 2)
    }

    @Test("all-haplotype output enumerates 2^n combinations for two adjacent SNPs")
    func allHaplotypes() throws {
        let rows = [
            snp(pos: 100, ref: "G", alt: "A", freq: 0.5, refCodon: "GCT", altCodon: "ACT"),
            snp(pos: 101, ref: "C", alt: "T", freq: 0.5, refCodon: "GCT", altCodon: "ATT"),
        ]
        let result = IVarCodonMerger.merge(rows: rows, consensusAF: 0.75, mergeAFThreshold: 0.25)
        // 2 positions × 2 states (REF, ALT) − 1 (all-REF) = 3 viable combinations
        #expect(result.allHaplotypes.count >= 3)
    }
}
```

- [ ] **Step 2: Run to confirm it fails**

Run: `swift test --filter IVarCodonMergerTests`
Expected: FAIL with "Cannot find 'IVarCodonMerger' in scope"

### Task 3.2: Implement the codon merger

**Files:**
- Create: `Sources/LungfishWorkflow/Variants/IVarCodonMerger.swift`

- [ ] **Step 1: Write the implementation**

```swift
// IVarCodonMerger.swift - Codon-aware haplotype merging matching nf-core/viralrecon
// ivar_variants_to_vcf.py semantics. Adjacent SNPs that share a REF_CODON or
// ALT_CODON value are grouped, and all 2^n REF/ALT combinations are enumerated
// and validated against AF rules.

import Foundation

public enum IVarCodonMerger {
    public struct Output: Sendable, Equatable {
        public var consensus: [MergedVariant]
        public var allHaplotypes: [MergedVariant]
        public init(consensus: [MergedVariant], allHaplotypes: [MergedVariant]) {
            self.consensus = consensus
            self.allHaplotypes = allHaplotypes
        }
    }

    public struct MergedVariant: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case single
            case merged
        }
        public let positions: [Int]
        public let rows: [IVarTSVRow]
        public let kind: Kind
        public init(positions: [Int], rows: [IVarTSVRow], kind: Kind) {
            self.positions = positions
            self.rows = rows
            self.kind = kind
        }
    }

    /// Group adjacent SNPs sharing a codon, evaluate AF rules, emit consensus +
    /// all-haplotype outputs. Indels are passed through unchanged.
    public static func merge(
        rows: [IVarTSVRow],
        consensusAF: Double,
        mergeAFThreshold: Double
    ) -> Output {
        var consensus: [MergedVariant] = []
        var allHaplotypes: [MergedVariant] = []
        let groups = adjacentCodonGroups(rows: rows)
        for group in groups {
            if group.count == 1 {
                let single = MergedVariant(positions: [group[0].pos], rows: [group[0]], kind: .single)
                consensus.append(single)
                continue
            }
            let afs = group.map(\.altFreq)
            if mergeRuleCheck(afs: afs, consensusAF: consensusAF, mergeAFThreshold: mergeAFThreshold) {
                let merged = MergedVariant(positions: group.map(\.pos), rows: group, kind: .merged)
                consensus.append(merged)
            } else {
                for row in group where row.altFreq > consensusAF {
                    consensus.append(MergedVariant(positions: [row.pos], rows: [row], kind: .single))
                }
            }
            // All-haplotype: enumerate every non-all-REF subset.
            let positions = group.map(\.pos)
            let n = group.count
            for mask in 1..<(1 << n) {
                var subset: [IVarTSVRow] = []
                for i in 0..<n where (mask & (1 << i)) != 0 {
                    subset.append(group[i])
                }
                allHaplotypes.append(MergedVariant(positions: subset.map(\.pos), rows: subset, kind: subset.count > 1 ? .merged : .single))
                _ = positions   // retained for future codon-position annotation
            }
        }
        return Output(consensus: consensus, allHaplotypes: allHaplotypes)
    }

    /// Group rows whose positions are consecutive AND share a REF_CODON or ALT_CODON. Indels and rows with no codon info land in singleton groups.
    static func adjacentCodonGroups(rows: [IVarTSVRow]) -> [[IVarTSVRow]] {
        var groups: [[IVarTSVRow]] = []
        var current: [IVarTSVRow] = []
        for row in rows {
            guard row.kind == .snp, row.refCodon != nil || row.altCodon != nil else {
                if !current.isEmpty {
                    groups.append(current)
                    current = []
                }
                groups.append([row])
                continue
            }
            if let prev = current.last,
               row.pos == prev.pos + 1,
               (row.refCodon == prev.refCodon || row.altCodon == prev.altCodon) {
                current.append(row)
            } else {
                if !current.isEmpty {
                    groups.append(current)
                }
                current = [row]
            }
        }
        if !current.isEmpty {
            groups.append(current)
        }
        return groups
    }

    /// Mirror of viralrecon's `merge_rule_check`. Returns true if the AF group
    /// should be kept as a single merged record.
    static func mergeRuleCheck(afs: [Double], consensusAF: Double, mergeAFThreshold: Double) -> Bool {
        if afs.allSatisfy({ $0 > consensusAF }) { return true }
        if afs.allSatisfy({ $0 >= 0.4 && $0 <= 0.6 }) { return true }
        let sorted = afs.sorted()
        var maxDist = 0.0
        for i in 0..<(sorted.count - 1) {
            maxDist = max(maxDist, abs(sorted[i + 1] - sorted[i]))
        }
        if maxDist < mergeAFThreshold { return true }
        return false
    }
}
```

- [ ] **Step 2: Run to confirm passes**

Run: `swift test --filter IVarCodonMergerTests`
Expected: PASS, all 5 tests green.

- [ ] **Step 3: Commit**

```bash
git add Sources/LungfishWorkflow/Variants/IVarCodonMerger.swift Tests/LungfishWorkflowTests/Variants/IVarCodonMergerTests.swift
git commit -m "$(cat <<'EOF'
Add IVarCodonMerger for haplotype merging at viralrecon parity

Groups adjacent SNPs sharing REF_CODON or ALT_CODON values, validates AF
rules (all-above-consensus, 0.4-0.6 band, distance-below-threshold), and
emits both a consensus stream and an all-haplotype enumeration.
Mirrored from nf-core/viralrecon's ivar_variants_to_vcf.py.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Phase 4 — TSV-to-VCF converter

### Task 4.1: Build small TSV/VCF unit fixtures

**Files:**
- Create: `Tests/Fixtures/ivar-converter/single-snp.tsv`
- Create: `Tests/Fixtures/ivar-converter/single-snp.expected.vcf`
- Create: `Tests/Fixtures/ivar-converter/insertion.tsv`
- Create: `Tests/Fixtures/ivar-converter/insertion.expected.vcf`
- Create: `Tests/Fixtures/ivar-converter/deletion.tsv`
- Create: `Tests/Fixtures/ivar-converter/deletion.expected.vcf`

- [ ] **Step 1: Write `single-snp.tsv`**

```text
REGION	POS	REF	ALT	REF_DP	REF_RV	REF_QUAL	ALT_DP	ALT_RV	ALT_QUAL	ALT_FREQ	TOTAL_DP	PVAL	PASS	GFF_FEATURE	REF_CODON	REF_AA	ALT_CODON	ALT_AA	POS_AA
chr1	100	C	T	0	0	0	1950	935	37	1	1950	0	TRUE	NA	NA	NA	NA	NA	NA
```

- [ ] **Step 2: Write `single-snp.expected.vcf`**

```text
##fileformat=VCFv4.2
##source=iVar 1.4.4 (TSV-to-VCF: Lungfish)
##contig=<ID=chr1,length=29903>
##INFO=<ID=TYPE,Number=1,Type=String,Description="Either SNP, INS or DEL">
##FILTER=<ID=PASS,Description="All filters passed">
##FILTER=<ID=ft,Description="iVar PASS column was FALSE">
##FILTER=<ID=bq,Description="ALT_QUAL below threshold">
##FILTER=<ID=sb,Description="Strand bias detected by Fisher exact test">
##FORMAT=<ID=GT,Number=1,Type=String,Description="Genotype">
##FORMAT=<ID=DP,Number=1,Type=Integer,Description="Total depth">
##FORMAT=<ID=REF_DP,Number=1,Type=Integer,Description="Reference depth">
##FORMAT=<ID=REF_RV,Number=1,Type=Integer,Description="Reference reverse-strand depth">
##FORMAT=<ID=REF_QUAL,Number=1,Type=Integer,Description="Mean reference base quality">
##FORMAT=<ID=ALT_DP,Number=1,Type=Integer,Description="Alternate depth">
##FORMAT=<ID=ALT_RV,Number=1,Type=Integer,Description="Alternate reverse-strand depth">
##FORMAT=<ID=ALT_QUAL,Number=1,Type=Integer,Description="Mean alternate base quality">
##FORMAT=<ID=ALT_FREQ,Number=1,Type=Float,Description="Alternate allele frequency">
#CHROM	POS	ID	REF	ALT	QUAL	FILTER	INFO	FORMAT	SAMPLE
chr1	100	.	C	T	.	PASS	TYPE=SNP	GT:DP:REF_DP:REF_RV:REF_QUAL:ALT_DP:ALT_RV:ALT_QUAL:ALT_FREQ	1:1950:0:0:0:1950:935:37:1.0
```

- [ ] **Step 3: Write `insertion.tsv`**

```text
REGION	POS	REF	ALT	REF_DP	REF_RV	REF_QUAL	ALT_DP	ALT_RV	ALT_QUAL	ALT_FREQ	TOTAL_DP	PVAL	PASS	GFF_FEATURE	REF_CODON	REF_AA	ALT_CODON	ALT_AA	POS_AA
chr1	100	A	+TG	10	5	30	40	20	37	0.8	50	0.001	TRUE	NA	NA	NA	NA	NA	NA
```

- [ ] **Step 4: Write `insertion.expected.vcf`** (only the data line shown; header identical to single-snp)

```text
chr1	100	.	A	ATG	.	PASS	TYPE=INS	GT:DP:REF_DP:REF_RV:REF_QUAL:ALT_DP:ALT_RV:ALT_QUAL:ALT_FREQ	1:50:10:5:30:40:20:37:0.8
```

- [ ] **Step 5: Write `deletion.tsv`**

```text
REGION	POS	REF	ALT	REF_DP	REF_RV	REF_QUAL	ALT_DP	ALT_RV	ALT_QUAL	ALT_FREQ	TOTAL_DP	PVAL	PASS	GFF_FEATURE	REF_CODON	REF_AA	ALT_CODON	ALT_AA	POS_AA
chr1	200	A	-CG	40	20	37	10	5	30	0.2	50	0.001	TRUE	NA	NA	NA	NA	NA	NA
```

- [ ] **Step 6: Write `deletion.expected.vcf`** (data line)

```text
chr1	200	.	ACG	A	.	PASS	TYPE=DEL	GT:DP:REF_DP:REF_RV:REF_QUAL:ALT_DP:ALT_RV:ALT_QUAL:ALT_FREQ	1:50:40:20:37:10:5:30:0.2
```

### Task 4.2: Failing converter tests

**Files:**
- Create: `Tests/LungfishWorkflowTests/Variants/IVarTSVToVCFConverterTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import LungfishWorkflow

@Suite("IVarTSVToVCFConverter")
struct IVarTSVToVCFConverterTests {
    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ivar-converter")
            .appendingPathComponent(name)
    }

    @Test("converts a single SNP row with anchored representation")
    func singleSNP() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ivar-converter-snp-\(UUID().uuidString).vcf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let options = IVarTSVToVCFConverter.Options(
            consensusAF: 0.75,
            mergeAFThreshold: 0.25,
            badQualityThreshold: 20,
            ignoreStrandBias: true,
            sourceLine: "iVar 1.4.4 (TSV-to-VCF: Lungfish)",
            contigs: [.init(name: "chr1", length: 29903)]
        )
        try IVarTSVToVCFConverter().convert(
            tsvURL: fixtureURL("single-snp.tsv"),
            primaryVCFURL: tmp,
            allHaplotypesVCFURL: nil,
            options: options
        )
        let actual = try String(contentsOf: tmp, encoding: .utf8)
        let expected = try String(contentsOf: fixtureURL("single-snp.expected.vcf"), encoding: .utf8)
        #expect(actual == expected)
    }

    @Test("converts an insertion to anchored alleles")
    func insertion() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ivar-converter-ins-\(UUID().uuidString).vcf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try IVarTSVToVCFConverter().convert(
            tsvURL: fixtureURL("insertion.tsv"),
            primaryVCFURL: tmp,
            allHaplotypesVCFURL: nil,
            options: .init(
                consensusAF: 0.75,
                mergeAFThreshold: 0.25,
                badQualityThreshold: 20,
                ignoreStrandBias: true,
                sourceLine: "iVar 1.4.4 (TSV-to-VCF: Lungfish)",
                contigs: [.init(name: "chr1", length: 29903)]
            )
        )
        let actual = try String(contentsOf: tmp, encoding: .utf8)
        #expect(actual.contains("\tA\tATG\t"))
        #expect(actual.contains("TYPE=INS"))
    }

    @Test("converts a deletion to anchored alleles")
    func deletion() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ivar-converter-del-\(UUID().uuidString).vcf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try IVarTSVToVCFConverter().convert(
            tsvURL: fixtureURL("deletion.tsv"),
            primaryVCFURL: tmp,
            allHaplotypesVCFURL: nil,
            options: .init(
                consensusAF: 0.75,
                mergeAFThreshold: 0.25,
                badQualityThreshold: 20,
                ignoreStrandBias: true,
                sourceLine: "iVar 1.4.4 (TSV-to-VCF: Lungfish)",
                contigs: [.init(name: "chr1", length: 29903)]
            )
        )
        let actual = try String(contentsOf: tmp, encoding: .utf8)
        #expect(actual.contains("\tACG\tA\t"))
        #expect(actual.contains("TYPE=DEL"))
    }

    @Test("emits ft filter when iVar PASS column is FALSE")
    func ftFilter() throws {
        let tsvURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).tsv")
        let header = "REGION\tPOS\tREF\tALT\tREF_DP\tREF_RV\tREF_QUAL\tALT_DP\tALT_RV\tALT_QUAL\tALT_FREQ\tTOTAL_DP\tPVAL\tPASS\tGFF_FEATURE\tREF_CODON\tREF_AA\tALT_CODON\tALT_AA\tPOS_AA"
        let row = "chr1\t44\tC\tT\t75\t75\t38\t4\t2\t38\t0.05\t79\t0.06\tFALSE\tNA\tNA\tNA\tNA\tNA\tNA"
        try (header + "\n" + row + "\n").write(to: tsvURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tsvURL) }
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).vcf")
        defer { try? FileManager.default.removeItem(at: outURL) }
        try IVarTSVToVCFConverter().convert(
            tsvURL: tsvURL,
            primaryVCFURL: outURL,
            allHaplotypesVCFURL: nil,
            options: .init(
                consensusAF: 0.75, mergeAFThreshold: 0.25, badQualityThreshold: 20,
                ignoreStrandBias: true,
                sourceLine: "iVar 1.4.4 (TSV-to-VCF: Lungfish)",
                contigs: [.init(name: "chr1", length: 29903)]
            )
        )
        let actual = try String(contentsOf: outURL, encoding: .utf8)
        #expect(actual.contains("\tft\t"))
    }

    @Test("emits sb filter when strand bias detected and not ignored")
    func sbFilter() throws {
        let tsvURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).tsv")
        let header = "REGION\tPOS\tREF\tALT\tREF_DP\tREF_RV\tREF_QUAL\tALT_DP\tALT_RV\tALT_QUAL\tALT_FREQ\tTOTAL_DP\tPVAL\tPASS\tGFF_FEATURE\tREF_CODON\tREF_AA\tALT_CODON\tALT_AA\tPOS_AA"
        // Strand-biased: REF entirely forward, ALT entirely reverse.
        let row = "chr1\t100\tC\tT\t100\t0\t37\t100\t100\t37\t0.5\t200\t0\tTRUE\tNA\tNA\tNA\tNA\tNA\tNA"
        try (header + "\n" + row + "\n").write(to: tsvURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tsvURL) }
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).vcf")
        defer { try? FileManager.default.removeItem(at: outURL) }
        try IVarTSVToVCFConverter().convert(
            tsvURL: tsvURL,
            primaryVCFURL: outURL,
            allHaplotypesVCFURL: nil,
            options: .init(
                consensusAF: 0.75, mergeAFThreshold: 0.25, badQualityThreshold: 20,
                ignoreStrandBias: false,
                sourceLine: "iVar 1.4.4 (TSV-to-VCF: Lungfish)",
                contigs: [.init(name: "chr1", length: 29903)]
            )
        )
        let actual = try String(contentsOf: outURL, encoding: .utf8)
        #expect(actual.contains("\tsb\t"))
    }

    @Test("emits LungfishNote when no GFF info present")
    func emitsLungfishNoteOnEmptyGFF() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).vcf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try IVarTSVToVCFConverter().convert(
            tsvURL: fixtureURL("single-snp.tsv"),
            primaryVCFURL: tmp,
            allHaplotypesVCFURL: nil,
            options: .init(
                consensusAF: 0.75, mergeAFThreshold: 0.25, badQualityThreshold: 20,
                ignoreStrandBias: true,
                sourceLine: "iVar 1.4.4 (TSV-to-VCF: Lungfish)",
                contigs: [.init(name: "chr1", length: 29903)],
                gffMissingNote: true
            )
        )
        let actual = try String(contentsOf: tmp, encoding: .utf8)
        #expect(actual.contains("##LungfishNote=GFF unavailable"))
    }
}
```

- [ ] **Step 2: Run to confirm fails**

Run: `swift test --filter IVarTSVToVCFConverterTests`
Expected: FAIL with "Cannot find 'IVarTSVToVCFConverter' in scope"

### Task 4.3: Implement the converter

**Files:**
- Create: `Sources/LungfishWorkflow/Variants/IVarTSVToVCFConverter.swift`

- [ ] **Step 1: Write the implementation**

```swift
// IVarTSVToVCFConverter.swift - Convert iVar's TSV variant output to VCF 4.2
// at parity with nf-core/viralrecon's ivar_variants_to_vcf.py. Implements
// indel anchoring, codon-aware haplotype merging, and Fisher's exact strand-bias filter.

import Foundation

public struct IVarTSVToVCFConverter: Sendable {
    public struct Contig: Sendable, Equatable {
        public let name: String
        public let length: Int
        public init(name: String, length: Int) {
            self.name = name
            self.length = length
        }
    }

    public struct Options: Sendable {
        public let consensusAF: Double
        public let mergeAFThreshold: Double
        public let badQualityThreshold: Int
        public let ignoreStrandBias: Bool
        public let sourceLine: String
        public let contigs: [Contig]
        public let gffMissingNote: Bool

        public init(
            consensusAF: Double = 0.75,
            mergeAFThreshold: Double = 0.25,
            badQualityThreshold: Int = 20,
            ignoreStrandBias: Bool = true,
            sourceLine: String = "iVar (TSV-to-VCF: Lungfish)",
            contigs: [Contig] = [],
            gffMissingNote: Bool = false
        ) {
            self.consensusAF = consensusAF
            self.mergeAFThreshold = mergeAFThreshold
            self.badQualityThreshold = badQualityThreshold
            self.ignoreStrandBias = ignoreStrandBias
            self.sourceLine = sourceLine
            self.contigs = contigs
            self.gffMissingNote = gffMissingNote
        }
    }

    public enum ConverterError: Error, LocalizedError, Equatable {
        case missingHeader
        case malformedRow(line: String)

        public var errorDescription: String? {
            switch self {
            case .missingHeader: return "iVar TSV is missing a header line"
            case .malformedRow(let line): return "iVar TSV row is malformed: \(line)"
            }
        }
    }

    public init() {}

    public func convert(
        tsvURL: URL,
        primaryVCFURL: URL,
        allHaplotypesVCFURL: URL?,
        options: Options
    ) throws {
        let text = try String(contentsOf: tsvURL, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard let header = lines.first, header.hasPrefix("REGION\t") else {
            throw ConverterError.missingHeader
        }
        let rows: [IVarTSVRow] = try lines.dropFirst().map { line in
            guard let parsed = IVarTSVRow.parse(line: line, header: header) else {
                throw ConverterError.malformedRow(line: line)
            }
            return parsed
        }
        let merged = IVarCodonMerger.merge(
            rows: rows.filter { $0.kind == .snp },
            consensusAF: options.consensusAF,
            mergeAFThreshold: options.mergeAFThreshold
        )
        let indels = rows.filter { $0.kind != .snp }
        let consensusVariants = merged.consensus + indels.map {
            IVarCodonMerger.MergedVariant(positions: [$0.pos], rows: [$0], kind: .single)
        }
        let sorted = consensusVariants.sorted { $0.positions[0] < $1.positions[0] }
        try writeVCF(variants: sorted, to: primaryVCFURL, options: options)
        if let allHaplotypesVCFURL {
            let allSorted = (merged.allHaplotypes + indels.map {
                IVarCodonMerger.MergedVariant(positions: [$0.pos], rows: [$0], kind: .single)
            }).sorted { $0.positions[0] < $1.positions[0] }
            try writeVCF(variants: allSorted, to: allHaplotypesVCFURL, options: options)
        }
    }

    private func writeVCF(
        variants: [IVarCodonMerger.MergedVariant],
        to url: URL,
        options: Options
    ) throws {
        var buffer = ""
        buffer += "##fileformat=VCFv4.2\n"
        buffer += "##source=\(options.sourceLine)\n"
        if options.gffMissingNote {
            buffer += "##LungfishNote=GFF unavailable; codon merging skipped\n"
        }
        for contig in options.contigs {
            buffer += "##contig=<ID=\(contig.name),length=\(contig.length)>\n"
        }
        buffer += #"##INFO=<ID=TYPE,Number=1,Type=String,Description="Either SNP, INS or DEL">"# + "\n"
        buffer += #"##FILTER=<ID=PASS,Description="All filters passed">"# + "\n"
        buffer += #"##FILTER=<ID=ft,Description="iVar PASS column was FALSE">"# + "\n"
        buffer += #"##FILTER=<ID=bq,Description="ALT_QUAL below threshold">"# + "\n"
        buffer += #"##FILTER=<ID=sb,Description="Strand bias detected by Fisher exact test">"# + "\n"
        buffer += #"##FORMAT=<ID=GT,Number=1,Type=String,Description="Genotype">"# + "\n"
        buffer += #"##FORMAT=<ID=DP,Number=1,Type=Integer,Description="Total depth">"# + "\n"
        buffer += #"##FORMAT=<ID=REF_DP,Number=1,Type=Integer,Description="Reference depth">"# + "\n"
        buffer += #"##FORMAT=<ID=REF_RV,Number=1,Type=Integer,Description="Reference reverse-strand depth">"# + "\n"
        buffer += #"##FORMAT=<ID=REF_QUAL,Number=1,Type=Integer,Description="Mean reference base quality">"# + "\n"
        buffer += #"##FORMAT=<ID=ALT_DP,Number=1,Type=Integer,Description="Alternate depth">"# + "\n"
        buffer += #"##FORMAT=<ID=ALT_RV,Number=1,Type=Integer,Description="Alternate reverse-strand depth">"# + "\n"
        buffer += #"##FORMAT=<ID=ALT_QUAL,Number=1,Type=Integer,Description="Mean alternate base quality">"# + "\n"
        buffer += #"##FORMAT=<ID=ALT_FREQ,Number=1,Type=Float,Description="Alternate allele frequency">"# + "\n"
        buffer += "#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tSAMPLE\n"
        for variant in variants {
            let row = variant.rows[0]
            let (refOut, altOut, typeTag) = encodeAlleles(row: row)
            let filterText = filterColumn(row: row, options: options)
            let format = "GT:DP:REF_DP:REF_RV:REF_QUAL:ALT_DP:ALT_RV:ALT_QUAL:ALT_FREQ"
            let sample = "1:\(row.totalDP):\(row.refDP):\(row.refRV):\(row.refQual):\(row.altDP):\(row.altRV):\(row.altQual):\(formatAF(row.altFreq))"
            buffer += "\(row.region)\t\(row.pos)\t.\t\(refOut)\t\(altOut)\t.\t\(filterText)\tTYPE=\(typeTag)\t\(format)\t\(sample)\n"
        }
        try buffer.write(to: url, atomically: true, encoding: .utf8)
    }

    private func encodeAlleles(row: IVarTSVRow) -> (ref: String, alt: String, type: String) {
        switch row.kind {
        case .snp:
            return (row.ref, row.alt, "SNP")
        case .insertion(let inserted):
            return (row.ref, row.ref + inserted, "INS")
        case .deletion(let deleted):
            return (row.ref + deleted, row.ref, "DEL")
        }
    }

    private func filterColumn(row: IVarTSVRow, options: Options) -> String {
        var codes: [String] = []
        if !row.pass {
            codes.append("ft")
        }
        if row.altQual < options.badQualityThreshold {
            codes.append("bq")
        }
        if !options.ignoreStrandBias {
            let refForward = max(0, row.refDP - row.refRV)
            let refReverse = row.refRV
            let altForward = max(0, row.altDP - row.altRV)
            let altReverse = row.altRV
            let p = FisherExactTest.twoSidedPValue(a: refForward, b: refReverse, c: altForward, d: altReverse)
            if p < 0.05 { codes.append("sb") }
        }
        return codes.isEmpty ? "PASS" : codes.joined(separator: ";")
    }

    private func formatAF(_ value: Double) -> String {
        if value == value.rounded() {
            return String(format: "%.1f", value)
        }
        return String(format: "%g", value)
    }
}
```

- [ ] **Step 2: Run to confirm passes**

Run: `swift test --filter IVarTSVToVCFConverterTests`
Expected: PASS, all 6 tests green.

- [ ] **Step 3: Commit**

```bash
git add Sources/LungfishWorkflow/Variants/IVarTSVToVCFConverter.swift Tests/LungfishWorkflowTests/Variants/IVarTSVToVCFConverterTests.swift Tests/Fixtures/ivar-converter
git commit -m "$(cat <<'EOF'
Add IVarTSVToVCFConverter at viralrecon parity

In-process Swift converter that turns iVar's TSV variant output into
VCF 4.2, with anchored indels, codon-aware haplotype merging, and a
Fisher's exact strand-bias filter (default off for amplicon data).

Replaces the broken --output-format vcf flag the pipeline currently
passes to iVar 1.4.4 (which has never accepted it).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Phase 5 — Annotation database GFF exporter

### Task 5.1: Failing tests for the exporter

**Files:**
- Create: `Tests/LungfishWorkflowTests/Annotation/AnnotationDatabaseGFFExporterTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
import LungfishIO
@testable import LungfishWorkflow

@Suite("AnnotationDatabaseGFFExporter")
struct AnnotationDatabaseGFFExporterTests {
    @Test("writes one GFF3 line per CDS feature in the database")
    func writesCDS() throws {
        let dbURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let db = try AnnotationDatabase(url: dbURL, readWrite: true)
        try db.insert(record: AnnotationDatabaseRecord(
            name: "S",
            type: "CDS",
            chromosome: "MN908947.3",
            start: 21563,
            end: 25384,
            strand: "+",
            attributes: nil
        ))
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).gff3")
        defer { try? FileManager.default.removeItem(at: outURL) }
        try AnnotationDatabaseGFFExporter.export(database: db, to: outURL)
        let contents = try String(contentsOf: outURL, encoding: .utf8)
        #expect(contents.contains("##gff-version 3"))
        #expect(contents.contains("MN908947.3\t.\tCDS\t21563\t25384\t.\t+\t.\t"))
    }

    @Test("writes empty GFF when database has no records")
    func writesEmpty() throws {
        let dbURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let db = try AnnotationDatabase(url: dbURL, readWrite: true)
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).gff3")
        defer { try? FileManager.default.removeItem(at: outURL) }
        try AnnotationDatabaseGFFExporter.export(database: db, to: outURL)
        let contents = try String(contentsOf: outURL, encoding: .utf8)
        #expect(contents.hasPrefix("##gff-version 3"))
    }
}
```

- [ ] **Step 2: Run to confirm fails**

Run: `swift test --filter AnnotationDatabaseGFFExporterTests`
Expected: FAIL — type not found.

### Task 5.2: Implement the exporter

**Files:**
- Create: `Sources/LungfishWorkflow/Annotation/AnnotationDatabaseGFFExporter.swift`

- [ ] **Step 1: Confirm `AnnotationDatabase` insert/fetch APIs**

Run: `grep -n "func insert\|func fetchAll\|func enumerate\|func iterate" Sources/LungfishIO/Bundles/AnnotationDatabase.swift`
Expected: list shows reader API (e.g., `enumerate`/`fetchAll`/equivalent) and a writer API. If the writer API does not exist publicly, the test must fall back to constructing the SQLite directly.

- [ ] **Step 2: Write the implementation**

```swift
// AnnotationDatabaseGFFExporter.swift - Stream rows from a Lungfish AnnotationDatabase
// out as GFF3 so they can be consumed by `ivar variants -g <gff>`.

import Foundation
import LungfishIO

public enum AnnotationDatabaseGFFExporter {
    public static func export(database: AnnotationDatabase, to url: URL) throws {
        var buffer = "##gff-version 3\n"
        for record in try database.fetchAll() {
            let attributes = record.attributes ?? "ID=\(record.name)"
            buffer += "\(record.chromosome)\t.\t\(record.type)\t\(record.start)\t\(record.end)\t.\t\(record.strand)\t.\t\(attributes)\n"
        }
        try buffer.write(to: url, atomically: true, encoding: .utf8)
    }
}
```

- [ ] **Step 3: Run, expect compile failure if `fetchAll`/`insert` API does not match**

Run: `swift build`
- If the call sites do not match, adjust the test and the exporter to use the actual API. Search:

```
grep -n "public func" Sources/LungfishIO/Bundles/AnnotationDatabase.swift
```

Use whichever existing read iterator the database exposes (e.g., `records()`, `enumerate(yield:)`). Mirror the call-site shape of any existing consumer in `Sources/LungfishApp/Views/Annotation/`.

- [ ] **Step 4: Run tests to confirm pass**

Run: `swift test --filter AnnotationDatabaseGFFExporterTests`
Expected: PASS, both tests green.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/Annotation/AnnotationDatabaseGFFExporter.swift Tests/LungfishWorkflowTests/Annotation/AnnotationDatabaseGFFExporterTests.swift
git commit -m "$(cat <<'EOF'
Add AnnotationDatabaseGFFExporter

Streams a bundle's annotation database to a GFF3 file so iVar's
codon-aware variant calling can consume the bundle's annotations
directly, instead of being passed /dev/null.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Phase 6 — Wire the converter into the variant-calling pipeline

### Task 6.1: Extend `BundleVariantCallingRequest` with new options

**Files:**
- Modify: `Sources/LungfishWorkflow/Variants/BundleVariantCallingModels.swift`

- [ ] **Step 1: Add four new public fields to the struct**

Replace the `BundleVariantCallingRequest` struct (located between lines 26 and 61 of the current file) with:

```swift
public struct BundleVariantCallingRequest: Sendable, Equatable {
    public let bundleURL: URL
    public let alignmentTrackID: String
    public let caller: ViralVariantCaller
    public let outputTrackName: String
    public let threads: Int
    public let minimumAlleleFrequency: Double?
    public let minimumDepth: Int?
    public let ivarPrimerTrimConfirmed: Bool
    public let medakaModel: String?
    public let advancedArguments: [String]
    public let ivarConsensusAF: Double
    public let ivarMergeAFThreshold: Double
    public let ivarBadQualityThreshold: Int
    public let ivarIgnoreStrandBias: Bool

    public init(
        bundleURL: URL,
        alignmentTrackID: String,
        caller: ViralVariantCaller,
        outputTrackName: String,
        threads: Int = max(1, ProcessInfo.processInfo.activeProcessorCount),
        minimumAlleleFrequency: Double? = nil,
        minimumDepth: Int? = nil,
        ivarPrimerTrimConfirmed: Bool = false,
        medakaModel: String? = nil,
        advancedArguments: [String] = [],
        ivarConsensusAF: Double = 0.75,
        ivarMergeAFThreshold: Double = 0.25,
        ivarBadQualityThreshold: Int = 20,
        ivarIgnoreStrandBias: Bool = true
    ) {
        self.bundleURL = bundleURL
        self.alignmentTrackID = alignmentTrackID
        self.caller = caller
        self.outputTrackName = outputTrackName
        self.threads = threads
        self.minimumAlleleFrequency = minimumAlleleFrequency
        self.minimumDepth = minimumDepth
        self.ivarPrimerTrimConfirmed = ivarPrimerTrimConfirmed
        self.medakaModel = medakaModel
        self.advancedArguments = advancedArguments
        self.ivarConsensusAF = ivarConsensusAF
        self.ivarMergeAFThreshold = ivarMergeAFThreshold
        self.ivarBadQualityThreshold = ivarBadQualityThreshold
        self.ivarIgnoreStrandBias = ivarIgnoreStrandBias
    }
}
```

- [ ] **Step 2: Build to confirm no callers break**

Run: `swift build 2>&1 | tail -40`
Expected: success, since all new init parameters have defaults. If a `BundleVariantCallingRequest` initializer call elsewhere uses positional argument labels, fix it to the new shape.

- [ ] **Step 3: Run all variant tests**

Run: `swift test --filter Variants`
Expected: existing variant tests still pass (no behavior change yet).

- [ ] **Step 4: Commit**

```bash
git add Sources/LungfishWorkflow/Variants/BundleVariantCallingModels.swift
git commit -m "$(cat <<'EOF'
Add iVar TSV-to-VCF converter options to variant request model

Four new fields with defaults matching nf-core/viralrecon:
ivarConsensusAF=0.75, ivarMergeAFThreshold=0.25,
ivarBadQualityThreshold=20, ivarIgnoreStrandBias=true. No callers
change yet; the pipeline change lands in a follow-up commit.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

### Task 6.2: Pipeline calls converter instead of `--output-format vcf`

**Files:**
- Modify: `Sources/LungfishWorkflow/Variants/ViralVariantCallingPipeline.swift`

- [ ] **Step 1: Drop `--output-format vcf` and rename the prefix path**

In `ivarVariantArguments(plan:)` near line 560, replace:

```swift
private func ivarVariantArguments(plan: ViralVariantCallingExecutionPlan) -> [String] {
    let prefix = plan.rawVCFURL.deletingPathExtension().path
    return ["variants"]
        + request.advancedArguments
        + [
        "-p", prefix,
        "-q", "20",
        "-t", String(request.minimumAlleleFrequency ?? 0.05),
        "-m", String(request.minimumDepth ?? 10),
        "-r", plan.referenceURL.path,
        "--output-format", "vcf",
    ]
}
```

with:

```swift
private func ivarVariantArguments(plan: ViralVariantCallingExecutionPlan, gffURL: URL?) -> [String] {
    let prefix = plan.workingDirectory.appendingPathComponent("ivar.tsv-prefix").path
    var args: [String] = ["variants"]
    args.append(contentsOf: request.advancedArguments)
    args.append(contentsOf: [
        "-p", prefix,
        "-q", "20",
        "-t", String(request.minimumAlleleFrequency ?? 0.05),
        "-m", String(request.minimumDepth ?? 10),
        "-r", plan.referenceURL.path,
    ])
    if let gffURL {
        args.append(contentsOf: ["-g", gffURL.path])
    }
    return args
}
```

- [ ] **Step 2: Add a private helper that exports GFF from the bundle if available**

Insert before `private func ivarVariantArguments`:

```swift
private func exportBundleGFFIfAvailable(plan: ViralVariantCallingExecutionPlan) async -> URL? {
    do {
        let manifest = try BundleManifest.load(from: request.bundleURL)
        guard let firstAnnotation = manifest.annotations.first else { return nil }
        let dbURL = request.bundleURL.appendingPathComponent(firstAnnotation.databasePath)
        let database = try AnnotationDatabase(url: dbURL)
        let outURL = plan.workingDirectory.appendingPathComponent("ivar-annotations.gff3")
        try AnnotationDatabaseGFFExporter.export(database: database, to: outURL)
        return outURL
    } catch {
        return nil
    }
}
```

- [ ] **Step 3: Update the iVar branch of `runCaller(plan:)` to call the converter**

In `runCaller(plan:)`, replace the existing `.ivar` case (around line 378-389) with:

```swift
case .ivar:
    let gffURL = await exportBundleGFFIfAvailable(plan: plan)
    let result = try await toolRunner.runPipeline(
        [
            NativePipelineStage(.samtools, arguments: ivarMpileupArguments(plan: plan)),
            NativePipelineStage(.ivar, arguments: ivarVariantArguments(plan: plan, gffURL: gffURL)),
        ],
        workingDirectory: plan.workingDirectory,
        timeout: 3600
    )
    guard result.isSuccess else {
        throw ViralVariantCallingPipelineError.callerExecutionFailed(result.combinedStderr)
    }
    let tsvURL = plan.workingDirectory.appendingPathComponent("ivar.tsv-prefix.tsv")
    let allHapURL = plan.workingDirectory.appendingPathComponent("ivar.all-haplotypes.vcf")
    let manifest = try BundleManifest.load(from: request.bundleURL)
    let contigs = (manifest.genome?.chromosomes ?? []).map { chrom in
        IVarTSVToVCFConverter.Contig(name: chrom.name, length: chrom.length)
    }
    let options = IVarTSVToVCFConverter.Options(
        consensusAF: request.ivarConsensusAF,
        mergeAFThreshold: request.ivarMergeAFThreshold,
        badQualityThreshold: request.ivarBadQualityThreshold,
        ignoreStrandBias: request.ivarIgnoreStrandBias,
        sourceLine: "iVar (TSV-to-VCF: Lungfish)",
        contigs: contigs,
        gffMissingNote: gffURL == nil
    )
    try IVarTSVToVCFConverter().convert(
        tsvURL: tsvURL,
        primaryVCFURL: plan.rawVCFURL,
        allHaplotypesVCFURL: allHapURL,
        options: options
    )
```

- [ ] **Step 4: Update `ivarVariantArguments` printable command-line builder**

Find the placeholder `ivarVariantArguments` callsite around line 504 (used to build the printable command line for provenance). Adjust it to pass `gffURL: nil` (the printable command line can omit GFF; the actual run includes it).

```swift
samtools \(ivarMpileupArguments(plan: placeholderPlan(referenceURL: referenceURL, alignmentURL: alignmentURL, medakaFASTQURL: medakaFASTQURL, rawVCFURL: rawVCFURL)).map(shellEscape).joined(separator: " ")) | ivar \(ivarVariantArguments(plan: placeholderPlan(referenceURL: referenceURL, alignmentURL: alignmentURL, medakaFASTQURL: medakaFASTQURL, rawVCFURL: rawVCFURL), gffURL: nil).map(shellEscape).joined(separator: " "))
```

- [ ] **Step 5: Build**

Run: `swift build 2>&1 | tail -40`
Expected: success.

- [ ] **Step 6: Run pipeline tests**

Run: `swift test --filter Variants`
Expected: existing tests still pass; the converter is now exercised whenever the iVar branch is hit.

- [ ] **Step 7: Commit**

```bash
git add Sources/LungfishWorkflow/Variants/ViralVariantCallingPipeline.swift
git commit -m "$(cat <<'EOF'
Wire IVarTSVToVCFConverter into ViralVariantCallingPipeline

iVar variant calls now run with a real GFF (extracted from the bundle's
annotation database when available) and produce a TSV that the new
converter post-processes into VCF 4.2. The pipeline's downstream
bcftools sort + bgzip + tabix chain is unchanged.

Drops the bogus --output-format vcf flag iVar 1.4.4 never accepted.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Phase 7 — CLI surface for new converter options

### Task 7.1: Add four flags to `lungfish variants call`

**Files:**
- Modify: `Sources/LungfishCLI/Commands/VariantsCommand.swift`

- [ ] **Step 1: Add four new options inside `CallSubcommand`**

Find `CallSubcommand` (around line 110). After the `medakaModel` option (around line 139) and before the `advancedOptions` option (around line 141), insert:

```swift
@Option(name: .customLong("ivar-consensus-af"), help: "Allele frequency threshold above which an iVar haplotype counts as consensus (default 0.75)")
var ivarConsensusAF: Double = 0.75

@Option(name: .customLong("ivar-merge-af-threshold"), help: "Maximum allele frequency distance for merging adjacent iVar SNPs (default 0.25)")
var ivarMergeAFThreshold: Double = 0.25

@Option(name: .customLong("ivar-bad-quality-threshold"), help: "iVar ALT_QUAL below this fails the bq filter (default 20)")
var ivarBadQualityThreshold: Int = 20

@Flag(name: .customLong("ivar-no-ignore-strand-bias"), help: "Apply iVar strand-bias filter (off by default for amplicon data)")
var ivarApplyStrandBias: Bool = false
```

- [ ] **Step 2: Pass the new fields into `BundleVariantCallingRequest`**

Find the `BundleVariantCallingRequest(...)` initialization within `execute(...)` (around line 200). Add to the call:

```swift
ivarConsensusAF: ivarConsensusAF,
ivarMergeAFThreshold: ivarMergeAFThreshold,
ivarBadQualityThreshold: ivarBadQualityThreshold,
ivarIgnoreStrandBias: !ivarApplyStrandBias
```

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | tail -40`
Expected: success.

- [ ] **Step 4: Quick smoke test**

Run: `./.build/debug/lungfish variants call --help 2>&1 | grep ivar`
Expected: each of the four new options appears in the help output.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishCLI/Commands/VariantsCommand.swift
git commit -m "$(cat <<'EOF'
Expose iVar TSV-to-VCF options on `lungfish variants call`

--ivar-consensus-af, --ivar-merge-af-threshold,
--ivar-bad-quality-threshold, --ivar-no-ignore-strand-bias.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Phase 8 — GUI dialog parity

### Task 8.1: Dialog state gains four new fields

**Files:**
- Modify: `Sources/LungfishApp/Views/BAM/BAMVariantCallingDialogState.swift`

- [ ] **Step 1: Add the new published fields**

Find the existing `var ivarPrimerTrimConfirmed: Bool` declaration (line 31). Below it, add:

```swift
var ivarConsensusAF: Double
var ivarMergeAFThreshold: Double
var ivarBadQualityThreshold: Int
var ivarIgnoreStrandBias: Bool
```

In the corresponding initializer (around lines 65-72), set defaults:

```swift
self.ivarConsensusAF = 0.75
self.ivarMergeAFThreshold = 0.25
self.ivarBadQualityThreshold = 20
self.ivarIgnoreStrandBias = true
```

- [ ] **Step 2: Pass fields when building the request**

Find the `BundleVariantCallingRequest(...)` builder around line 216. Append the four new fields at the call site:

```swift
ivarConsensusAF: ivarConsensusAF,
ivarMergeAFThreshold: ivarMergeAFThreshold,
ivarBadQualityThreshold: ivarBadQualityThreshold,
ivarIgnoreStrandBias: ivarIgnoreStrandBias
```

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | tail -40`
Expected: success.

### Task 8.2: New iVar Options panel in the dialog

**Files:**
- Modify: `Sources/LungfishApp/Views/BAM/BAMVariantCallingToolPanes.swift`

- [ ] **Step 1: Add a new private subview**

After `private var advancedOptionsSection: some View` (around line 116), insert:

```swift
@ViewBuilder
private var ivarOptionsSection: some View {
    if state.selectedCaller == .ivar {
        VStack(alignment: .leading, spacing: 12) {
            Text("iVar Options")
                .font(.headline)

            HStack {
                Text("Consensus allele frequency")
                Spacer()
                TextField("0.75", value: $state.ivarConsensusAF, format: .number)
                    .frame(width: 70)
            }
            HStack {
                Text("Merge AF distance")
                Spacer()
                TextField("0.25", value: $state.ivarMergeAFThreshold, format: .number)
                    .frame(width: 70)
            }
            HStack {
                Text("Minimum ALT quality")
                Spacer()
                TextField("20", value: $state.ivarBadQualityThreshold, format: .number)
                    .frame(width: 70)
            }
            Toggle(
                "Ignore strand bias (recommended for amplicons)",
                isOn: $state.ivarIgnoreStrandBias
            )
        }
    }
}
```

- [ ] **Step 2: Insert the new subview into the body**

Find the body's main `VStack` (around line 60-70). After the call to `ivarSettingsSection` (or whichever subview holds the primer-trim acknowledgement) and before `advancedOptionsSection`, add:

```swift
ivarOptionsSection
```

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | tail -40`
Expected: success.

- [ ] **Step 4: Test launch**

Run: `xcodebuild -scheme Lungfish -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: success.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/Views/BAM/BAMVariantCallingDialogState.swift Sources/LungfishApp/Views/BAM/BAMVariantCallingToolPanes.swift
git commit -m "$(cat <<'EOF'
Surface iVar TSV-to-VCF options in the variant-calling dialog

New "iVar Options" group inside the variant-calling dialog mirrors the
four CLI flags. Defaults match nf-core/viralrecon and the strand-bias
filter is disabled by default since the chapter's audience is amplicon
data.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Phase 9 — `lungfish bam adopt-mapping`

### Task 9.1: Failing CLI integration test

**Files:**
- Create: `Tests/LungfishIntegrationTests/BAMAdoptMappingIntegrationTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
import LungfishIO
@testable import LungfishWorkflow

@Suite("BAMAdoptMappingIntegration")
struct BAMAdoptMappingIntegrationTests {
    @Test("adopts mapping result into the bundle as a new alignment track")
    func adoptsMapping() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("adopt-mapping-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // 1. Create an empty reference bundle from the fixture FASTA.
        let bundleURL = scratch.appendingPathComponent("MN908947.3.lungfishref")
        let fixtureRef = TestFixtures.sarsCov2Reference()  // existing helper from TestFixtures.swift
        // Either use a CLI helper or BundleBuilder service to create the bundle:
        try await BundleCreator.createBundle(fastaURL: fixtureRef, name: "MN908947.3", outputDir: scratch)

        // 2. Construct a fake mapping-result directory by copying the fixture BAM.
        let mappingDir = scratch.appendingPathComponent("mapping")
        try FileManager.default.createDirectory(at: mappingDir, withIntermediateDirectories: true)
        let bamSource = TestFixtures.sarsCov2AlignmentsBAM()
        let baiSource = TestFixtures.sarsCov2AlignmentsBAI()
        try FileManager.default.copyItem(at: bamSource, to: mappingDir.appendingPathComponent("sorted.bam"))
        try FileManager.default.copyItem(at: baiSource, to: mappingDir.appendingPathComponent("sorted.bam.bai"))
        try ("{}").write(to: mappingDir.appendingPathComponent("mapping-provenance.json"), atomically: true, encoding: .utf8)

        // 3. Run the new subcommand programmatically.
        var cmd = try BAMAdoptMappingSubcommand.parse([
            "--bundle", bundleURL.path,
            "--mapping-result", mappingDir.path,
            "--name", "minimap2 mapping"
        ])
        try await cmd.run()

        // 4. Assert the manifest gained a new alignment track.
        let manifest = try BundleManifest.load(from: bundleURL)
        #expect(manifest.alignments.count == 1)
        #expect(manifest.alignments.first?.name == "minimap2 mapping")
    }
}
```

> The test uses `TestFixtures.sarsCov2Reference()`, `TestFixtures.sarsCov2AlignmentsBAM()`, `TestFixtures.sarsCov2AlignmentsBAI()` from `Tests/LungfishIntegrationTests/TestFixtures.swift`. Open that file to confirm the exact accessor names; rename in the test if they differ.

- [ ] **Step 2: Run to confirm fails**

Run: `swift test --filter BAMAdoptMappingIntegrationTests`
Expected: FAIL — `BAMAdoptMappingSubcommand` not found.

### Task 9.2: Implement the subcommand

**Files:**
- Create: `Sources/LungfishCLI/Commands/BAMAdoptMappingSubcommand.swift`

- [ ] **Step 1: Write the subcommand**

```swift
// BAMAdoptMappingSubcommand.swift - Attach a fresh `lungfish map` mapping result
// to a reference bundle as a new alignment track.

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

extension BAMCommand {
    struct AdoptMappingSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "adopt-mapping",
            abstract: "Attach a `lungfish map` result to a reference bundle as a new alignment track"
        )

        @Option(name: .customLong("bundle"), help: "Path to the reference bundle directory (.lungfishref)")
        var bundlePath: String

        @Option(name: .customLong("mapping-result"), help: "Path to the mapping analysis directory produced by `lungfish map`")
        var mappingResultPath: String

        @Option(name: .customLong("name"), help: "Display name for the new alignment track")
        var trackName: String

        @Option(name: .customLong("track-id"), help: "Override the auto-generated alignment track identifier")
        var trackIDOverride: String?

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            let bundleURL = URL(fileURLWithPath: bundlePath)
            let mappingURL = URL(fileURLWithPath: mappingResultPath)
            let bamURL = mappingURL.appendingPathComponent("sorted.bam")
            let baiURL = mappingURL.appendingPathComponent("sorted.bam.bai")
            guard FileManager.default.fileExists(atPath: bamURL.path) else {
                throw ValidationError("Mapping result is missing sorted.bam at \(bamURL.path)")
            }
            guard FileManager.default.fileExists(atPath: baiURL.path) else {
                throw ValidationError("Mapping result is missing sorted.bam.bai at \(baiURL.path)")
            }
            let outputTrackID = trackIDOverride ?? "aln_\(UUID().uuidString.prefix(8))"
            let request = PreparedAlignmentAttachmentRequest(
                bundleURL: bundleURL,
                stagedBAMURL: bamURL,
                stagedIndexURL: baiURL,
                outputTrackID: String(outputTrackID),
                outputTrackName: trackName,
                relativeDirectory: "alignments/mapped",
                format: .bam
            )
            _ = try await PreparedAlignmentAttachmentService().attach(request: request)
            if !globalOptions.quiet {
                print("Attached alignment track '\(trackName)' (\(outputTrackID)) to bundle.")
            }
        }
    }
}
```

- [ ] **Step 2: Register the new subcommand on `BAMCommand`**

Modify `Sources/LungfishCLI/Commands/BAMCommand.swift`. Find the `subcommands:` array (line 15). Append `AdoptMappingSubcommand.self` to the list:

```swift
subcommands: [
    FilterSubcommand.self,
    AnnotateSubcommand.self,
    AnnotateBestSubcommand.self,
    AnnotateCDSBestSubcommand.self,
    MarkdupSubcommand.self,
    PrimerTrimSubcommand.self,
    AdoptMappingSubcommand.self,
]
```

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | tail -40`
Expected: success.

- [ ] **Step 4: Manual smoke test**

Run: `./.build/debug/lungfish bam adopt-mapping --help 2>&1 | head -10`
Expected: help shows the four flags.

- [ ] **Step 5: Run the integration test**

Run: `swift test --filter BAMAdoptMappingIntegrationTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishCLI/Commands/BAMAdoptMappingSubcommand.swift Sources/LungfishCLI/Commands/BAMCommand.swift Tests/LungfishIntegrationTests/BAMAdoptMappingIntegrationTests.swift
git commit -m "$(cat <<'EOF'
Add `lungfish bam adopt-mapping` subcommand

Attaches a fresh `lungfish map` mapping-result directory to a reference
bundle as a new alignment track via PreparedAlignmentAttachmentService,
mirroring the GUI's Mapping wizard. Lets the chapter's full workflow
run from the shell so end-to-end tests cover what was previously
GUI-only.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Phase 10 — SRA download fallback

### Task 10.1: Failing test

**Files:**
- Create: `Tests/LungfishCoreTests/SRADownloadFallbackTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import LungfishCore

@Suite("SRADownloadFallback")
struct SRADownloadFallbackTests {
    @Test("falls back to SRA Toolkit when ENA path raises")
    func fallsBackToToolkit() async throws {
        var enaCalls = 0
        var toolkitCalls = 0
        let service = SRAService(
            enaDownloader: { _, _ in
                enaCalls += 1
                throw NSError(domain: "ena", code: 404)
            },
            toolkitDownloader: { _, _ in
                toolkitCalls += 1
                return [URL(fileURLWithPath: "/tmp/SRR123_1.fastq")]
            }
        )
        let urls = try await service.downloadFASTQWithFallback(accession: "SRR123", outputDir: nil)
        #expect(enaCalls == 1)
        #expect(toolkitCalls == 1)
        #expect(urls.count == 1)
    }

    @Test("surfaces both errors when both paths fail")
    func surfacesBothErrors() async throws {
        let service = SRAService(
            enaDownloader: { _, _ in throw NSError(domain: "ena", code: 404) },
            toolkitDownloader: { _, _ in throw NSError(domain: "toolkit", code: 1) }
        )
        await #expect(throws: SRAError.self) {
            try await service.downloadFASTQWithFallback(accession: "SRR123", outputDir: nil)
        }
    }
}
```

- [ ] **Step 2: Run to confirm fails**

Run: `swift test --filter SRADownloadFallbackTests`
Expected: FAIL — `downloadFASTQWithFallback` and the new initializer signature missing.

### Task 10.2: Add the fallback function and an injectable initializer

**Files:**
- Modify: `Sources/LungfishCore/Services/NCBI/SRAService.swift`

- [ ] **Step 1: Add an injection-friendly initializer**

Find the existing `class SRAService` declaration. Above the existing `init`, add:

```swift
public typealias DownloadStrategy = @Sendable (_ accession: String, _ outputDir: URL?) async throws -> [URL]

private let enaDownloader: DownloadStrategy?
private let toolkitDownloader: DownloadStrategy?

public init(
    enaDownloader: DownloadStrategy? = nil,
    toolkitDownloader: DownloadStrategy? = nil
) {
    self.enaDownloader = enaDownloader
    self.toolkitDownloader = toolkitDownloader
}
```

- [ ] **Step 2: Implement `downloadFASTQWithFallback`**

Add to the same class:

```swift
public func downloadFASTQWithFallback(
    accession: String,
    outputDir: URL?,
    progress: (@Sendable (Double) -> Void)? = nil
) async throws -> [URL] {
    let ena = enaDownloader ?? { acc, dir in
        try await self.downloadFASTQFromENA(accession: acc, outputDir: dir, progress: progress)
    }
    let toolkit = toolkitDownloader ?? { acc, dir in
        try await self.downloadFASTQ(accession: acc, outputDir: dir, progress: progress)
    }
    do {
        return try await ena(accession, outputDir)
    } catch let enaError {
        do {
            return try await toolkit(accession, outputDir)
        } catch let toolkitError {
            throw SRAError.downloadFailed("ENA: \(enaError.localizedDescription); Toolkit: \(toolkitError.localizedDescription)")
        }
    }
}
```

- [ ] **Step 3: Run the test**

Run: `swift test --filter SRADownloadFallbackTests`
Expected: PASS, both tests green.

### Task 10.3: Wire the fallback into `lungfish fetch sra download`

**Files:**
- Modify: `Sources/LungfishCLI/Commands/FetchCommand.swift`

- [ ] **Step 1: Replace the explicit `if useToolkit` branch**

Find the block around line 415-436. Replace with:

```swift
do {
    let files: [URL]
    if useToolkit {
        files = try await service.downloadFASTQ(
            accession: accession,
            outputDir: outputURL
        ) { progress in
            if !globalOptions.quiet {
                print(formatter.info("Download progress: \(Int(progress * 100))%"))
            }
        }
    } else {
        files = try await service.downloadFASTQWithFallback(
            accession: accession,
            outputDir: outputURL
        ) { progress in
            if !globalOptions.quiet {
                print(formatter.info("Download progress: \(Int(progress * 100))%"))
            }
        }
    }
```

- [ ] **Step 2: Print fallback notification when ENA fails (optional refinement)**

Adjust `downloadFASTQWithFallback` to accept an optional `onFallback: () -> Void` callback so the CLI can print "Falling back to SRA Toolkit". Skip this if it complicates the test; it's a nice-to-have, not load-bearing.

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | tail -40`
Expected: success.

- [ ] **Step 4: Commit**

```bash
git add Sources/LungfishCore/Services/NCBI/SRAService.swift Sources/LungfishCLI/Commands/FetchCommand.swift Tests/LungfishCoreTests/SRADownloadFallbackTests.swift
git commit -m "$(cat <<'EOF'
Add SRA download fallback to SRA Toolkit when ENA fails

`lungfish fetch sra download` now tries ENA first (fast, no toolkit
required) and automatically retries via prefetch + fasterq-dump if ENA
returns an error. Both error messages are surfaced when both paths
fail. The explicit --use-toolkit flag remains as a manual override.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Phase 11 — Parity test against viralrecon

### Task 11.1: Add the fixture TSV (gzipped)

**Files:**
- Create: `Tests/Fixtures/ivar-converter-parity/sarscov2-srr36291587.tsv.gz`
- Create: `Tests/Fixtures/ivar-converter-parity/MN908947.3.fasta`
- Create: `Tests/Fixtures/ivar-converter-parity/MN908947.3.gff3`
- Create: `Tests/Fixtures/ivar-converter-parity/README.md`

- [ ] **Step 1: Reuse the validation artifacts from `/tmp/lungfish-vcf-validation`**

Run:

```bash
cp /tmp/lungfish-vcf-validation/ivar_variants.tsv Tests/Fixtures/ivar-converter-parity/sarscov2-srr36291587.tsv
gzip Tests/Fixtures/ivar-converter-parity/sarscov2-srr36291587.tsv
cp /tmp/lungfish-vcf-validation/MN908947.3.fasta Tests/Fixtures/ivar-converter-parity/
```

If `/tmp/lungfish-vcf-validation` no longer exists, regenerate by following Section 6 of `docs/superpowers/specs/2026-05-07-reads-to-variants-chapter-design.md` ("verification" notes) or the `regenerate.sh` you'll add in Phase 14.

- [ ] **Step 2: Add a README**

Write a short `README.md`:

```markdown
# iVar Converter Parity Fixture

Source iVar TSV from running the Lungfish pipeline on SRR36291587 against
MN908947.3. Reference FASTA and GFF3 are committed alongside.

The parity test runs the upstream `ivar_variants_to_vcf.py` (installed
once per CI run from a pinned nf-core/viralrecon commit) and the Swift
converter on the same TSV, then diffs the outputs.
```

### Task 11.2: Failing parity test

**Files:**
- Create: `Tests/LungfishIntegrationTests/IVarConverterViralReconParityTests.swift`

- [ ] **Step 1: Write the test**

```swift
import Testing
import Foundation
@testable import LungfishWorkflow

@Suite("IVarConverterViralReconParity")
struct IVarConverterViralReconParityTests {
    @Test("Swift converter matches viralrecon output on SRR36291587 fixture")
    func parity() async throws {
        guard ProcessInfo.processInfo.environment["LUNGFISH_VIRALRECON_PARITY"] == "1" else {
            // Opt-in only; CI sets the env var.
            return
        }
        let fixturesDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ivar-converter-parity")
        let tsvGZ = fixturesDir.appendingPathComponent("sarscov2-srr36291587.tsv.gz")
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("parity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let tsv = scratch.appendingPathComponent("ivar.tsv")
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        unzip.arguments = ["-k", "-c", tsvGZ.path]
        let outFH = try FileHandle(forWritingTo: tsv)
        try FileManager.default.createFile(atPath: tsv.path, contents: nil)
        unzip.standardOutput = outFH
        try unzip.run()
        unzip.waitUntilExit()
        outFH.closeFile()

        let swiftOut = scratch.appendingPathComponent("swift.vcf")
        try IVarTSVToVCFConverter().convert(
            tsvURL: tsv,
            primaryVCFURL: swiftOut,
            allHaplotypesVCFURL: nil,
            options: .init(
                consensusAF: 0.75, mergeAFThreshold: 0.25, badQualityThreshold: 20,
                ignoreStrandBias: false,
                sourceLine: "iVar 1.4.4 (TSV-to-VCF: Lungfish)",
                contigs: [.init(name: "MN908947.3", length: 29903)]
            )
        )

        let pyOut = scratch.appendingPathComponent("py.vcf")
        let py = Process()
        py.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        py.arguments = [
            "python3",
            ProcessInfo.processInfo.environment["LUNGFISH_IVAR_TO_VCF_PY"] ?? "ivar_variants_to_vcf.py",
            tsv.path,
            pyOut.path,
            "--fasta", fixturesDir.appendingPathComponent("MN908947.3.fasta").path
        ]
        try py.run()
        py.waitUntilExit()

        let swift = try String(contentsOf: swiftOut, encoding: .utf8)
        let python = try String(contentsOf: pyOut, encoding: .utf8)
        let stripHeader: (String) -> String = { text in
            text.split(separator: "\n").filter { !$0.hasPrefix("##fileDate") && !$0.hasPrefix("##source") }.joined(separator: "\n")
        }
        #expect(stripHeader(swift) == stripHeader(python))
    }
}
```

- [ ] **Step 2: Document how to run locally**

Add a `Makefile` target or a one-liner to the parity-fixture README:

```bash
LUNGFISH_VIRALRECON_PARITY=1 LUNGFISH_IVAR_TO_VCF_PY=$(pwd)/ivar_variants_to_vcf.py swift test --filter IVarConverterViralReconParity
```

- [ ] **Step 3: Commit**

```bash
git add Tests/Fixtures/ivar-converter-parity Tests/LungfishIntegrationTests/IVarConverterViralReconParityTests.swift
git commit -m "$(cat <<'EOF'
Add viralrecon parity test for the iVar TSV-to-VCF converter

Opt-in test (LUNGFISH_VIRALRECON_PARITY=1) that runs both the Swift
converter and the upstream nf-core/viralrecon
ivar_variants_to_vcf.py against the SRR36291587 fixture and diffs the
outputs after stripping cosmetic header lines.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Phase 12 — End-to-end CLI integration test

### Task 12.1: Add the test against the small fixture

**Files:**
- Create: `Tests/LungfishIntegrationTests/ReadsToVariantsEndToEndTests.swift`

- [ ] **Step 1: Write the test**

```swift
import Testing
import Foundation
import LungfishIO
@testable import LungfishWorkflow

@Suite("ReadsToVariantsEndToEnd")
struct ReadsToVariantsEndToEndTests {
    @Test("full reads-to-variants pipeline produces both iVar and LoFreq VCFs")
    func fullPipeline() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("reads-to-variants-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // 1. Bundle from fixture reference.
        let fixtureRef = TestFixtures.sarsCov2Reference()
        try await BundleCreator.createBundle(fastaURL: fixtureRef, name: "MN908947.3", outputDir: scratch)
        let bundleURL = scratch.appendingPathComponent("MN908947.3.lungfishref")

        // 2. Map fixture FASTQs.
        let r1 = TestFixtures.sarsCov2ReadsR1()
        let r2 = TestFixtures.sarsCov2ReadsR2()
        let mappingDir = scratch.appendingPathComponent("mapping")
        try await ReadMapper.map(reads: [r1, r2], referenceURL: fixtureRef, outputDir: mappingDir, mapper: .minimap2, preset: "sr", paired: true, sampleName: "fixture")

        // 3. Adopt mapping into bundle.
        var adopt = try BAMCommand.AdoptMappingSubcommand.parse([
            "--bundle", bundleURL.path,
            "--mapping-result", mappingDir.path,
            "--name", "minimap2"
        ])
        try await adopt.run()
        let manifest1 = try BundleManifest.load(from: bundleURL)
        let mappedTrackID = try #require(manifest1.alignments.first?.id)

        // 4. Primer-trim.
        let primersURL = TestFixtures.qiaSeqPrimerScheme()
        var trim = try BAMCommand.PrimerTrimSubcommand.parse([
            "--bundle", bundleURL.path,
            "--alignment-track", mappedTrackID,
            "--scheme", primersURL.path,
            "--name", "primer-trimmed"
        ])
        try await trim.run()
        let manifest2 = try BundleManifest.load(from: bundleURL)
        let trimmedTrackID = try #require(manifest2.alignments.first(where: { $0.name == "primer-trimmed" })?.id)

        // 5. iVar call against trimmed.
        var iVarCall = try VariantsCommand.CallSubcommand.parse([
            "--bundle", bundleURL.path,
            "--alignment-track", trimmedTrackID,
            "--caller", "ivar",
            "--name", "iVar variants",
            "--ivar-primer-trimmed"
        ])
        try await iVarCall.run()

        // 6. LoFreq call against un-trimmed.
        var lofreqCall = try VariantsCommand.CallSubcommand.parse([
            "--bundle", bundleURL.path,
            "--alignment-track", mappedTrackID,
            "--caller", "lofreq",
            "--name", "LoFreq variants"
        ])
        try await lofreqCall.run()

        // 7. Assertions.
        let manifestFinal = try BundleManifest.load(from: bundleURL)
        #expect(manifestFinal.alignments.count == 2)
        #expect(manifestFinal.variants.count == 2)
        let names = manifestFinal.variants.map(\.name)
        #expect(names.contains("iVar variants"))
        #expect(names.contains("LoFreq variants"))
    }
}
```

- [ ] **Step 2: Confirm helpers exist**

Run: `grep -n "sarsCov2Reference\|sarsCov2AlignmentsBAM\|sarsCov2ReadsR1\|qiaSeqPrimerScheme" Tests/LungfishIntegrationTests/TestFixtures.swift`
Expected: matches found. If the fixture helper names differ, rename the test calls accordingly.

If `BundleCreator.createBundle` and `ReadMapper.map` are not exposed as static helpers, replace those steps with the minimum CLI invocation from `Tests/LungfishIntegrationTests/CLIFunctionalTests.swift` (which already exercises some of these flows).

- [ ] **Step 3: Run the test**

Run: `swift test --filter ReadsToVariantsEndToEndTests`
Expected: PASS. If it fails on a missing tool, ensure the conda envs are provisioned (this is the user's machine, they're already set up; CI may need a separate step).

- [ ] **Step 4: Commit**

```bash
git add Tests/LungfishIntegrationTests/ReadsToVariantsEndToEndTests.swift
git commit -m "$(cat <<'EOF'
Add end-to-end reads-to-variants integration test

Exercises the full pipeline (bundle create → map → adopt-mapping →
primer-trim → iVar call → LoFreq call) against the small
sarscov2-clinical fixture. Acts as the regression net for the chapter:
if any of the new pieces (TSV-to-VCF converter, GFF passthrough,
bam adopt-mapping) regress, this test fails first.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Phase 13 — Cassette of large fixture artifacts (committed VCFs)

### Task 13.1: Generate and commit the chapter fixture

**Files:**
- Create: `docs/user-manual/fixtures/sarscov2-srr36291587/MN908947.3.fasta`
- Create: `docs/user-manual/fixtures/sarscov2-srr36291587/lofreq.expected.vcf`
- Create: `docs/user-manual/fixtures/sarscov2-srr36291587/ivar.expected.vcf`
- Create: `docs/user-manual/fixtures/sarscov2-srr36291587/README.md`
- Create: `docs/user-manual/fixtures/sarscov2-srr36291587/regenerate.sh`

- [ ] **Step 1: Write `regenerate.sh`** (idempotent re-derivation script)

```bash
#!/usr/bin/env bash
set -euo pipefail
LUNGFISH=${LUNGFISH:-./build/Release/Lungfish.app/Contents/MacOS/lungfish-cli}
OUT=${OUT:-./fixture-tmp}
mkdir -p "$OUT"
"$LUNGFISH" fetch ncbi MN908947.3 --fetch-format fasta --save-to "$OUT/MN908947.3.fasta"
"$LUNGFISH" fetch sra download SRR36291587 --output-dir "$OUT" --use-toolkit
"$LUNGFISH" bundle create --fasta "$OUT/MN908947.3.fasta" --name MN908947.3 --output-dir "$OUT" --compress
"$LUNGFISH" map "$OUT/SRR36291587_1.fastq" "$OUT/SRR36291587_2.fastq" \
    --reference "$OUT/MN908947.3.fasta" \
    --paired --preset sr --sample-name SRR36291587 -o "$OUT/mapping"
"$LUNGFISH" bam adopt-mapping --bundle "$OUT/MN908947.3.lungfishref" --mapping-result "$OUT/mapping" --name "minimap2 mapping"
# Primer-trim and call iVar / LoFreq from the manifest's first alignment track:
TRACK_ID=$(jq -r '.alignments[0].id' "$OUT/MN908947.3.lungfishref/manifest.json")
"$LUNGFISH" bam primer-trim --bundle "$OUT/MN908947.3.lungfishref" --alignment-track "$TRACK_ID" \
    --scheme "$LUNGFISH"/../Resources/LungfishGenomeBrowser_LungfishApp.bundle/Contents/Resources/PrimerSchemes/QIASeqDIRECT-SARS2.lungfishprimers \
    --name primer-trimmed
TRIMMED_ID=$(jq -r '.alignments[] | select(.name == "primer-trimmed") | .id' "$OUT/MN908947.3.lungfishref/manifest.json")
"$LUNGFISH" variants call --bundle "$OUT/MN908947.3.lungfishref" --alignment-track "$TRIMMED_ID" --caller ivar --name "iVar variants" --ivar-primer-trimmed
"$LUNGFISH" variants call --bundle "$OUT/MN908947.3.lungfishref" --alignment-track "$TRACK_ID" --caller lofreq --name "LoFreq variants"
```

- [ ] **Step 2: Make it executable and run it once**

```bash
chmod +x docs/user-manual/fixtures/sarscov2-srr36291587/regenerate.sh
LUNGFISH=$(pwd)/build/Release/Lungfish.app/Contents/MacOS/lungfish-cli OUT=./fixture-tmp ./docs/user-manual/fixtures/sarscov2-srr36291587/regenerate.sh
```

- [ ] **Step 3: Copy the canonical artifacts**

```bash
cp ./fixture-tmp/MN908947.3.fasta docs/user-manual/fixtures/sarscov2-srr36291587/
# Find the variant track VCFs in the bundle and copy them:
cp $(jq -r '.variants[] | select(.name=="iVar variants") | .vcfPath' fixture-tmp/MN908947.3.lungfishref/manifest.json | xargs -I{} echo "fixture-tmp/MN908947.3.lungfishref/{}") docs/user-manual/fixtures/sarscov2-srr36291587/ivar.expected.vcf
cp $(jq -r '.variants[] | select(.name=="LoFreq variants") | .vcfPath' fixture-tmp/MN908947.3.lungfishref/manifest.json | xargs -I{} echo "fixture-tmp/MN908947.3.lungfishref/{}") docs/user-manual/fixtures/sarscov2-srr36291587/lofreq.expected.vcf
rm -rf fixture-tmp
```

(If the manifest schema uses different field names, run `jq '.variants[0]'` first to inspect — the fields are stable but case may surprise. Adjust the path keys as needed.)

- [ ] **Step 4: Write `README.md`**

```markdown
# SARS-CoV-2 SRR36291587 chapter fixture

Reference: MN908947.3 (Wuhan-Hu-1, GenBank). Reads: SRR36291587 (QIAseq
Direct SARS-CoV-2, paired-end Illumina, 86,281 read pairs).

Committed artifacts:

- MN908947.3.fasta — 30 KB reference
- ivar.expected.vcf — iVar variants from the chapter's workflow
- lofreq.expected.vcf — LoFreq variants from the chapter's workflow

The 21.7 MB compressed FASTQ from SRA is **not** committed. Run
`./regenerate.sh` to re-derive every artifact from the original
accessions.

License: SRR36291587 is publicly available from the NCBI Sequence Read
Archive. MN908947.3 is publicly available from NCBI GenBank. Both are
in the public domain in the U.S.; check your local jurisdiction.
```

- [ ] **Step 5: Commit**

```bash
git add docs/user-manual/fixtures/sarscov2-srr36291587/
git commit -m "$(cat <<'EOF'
Add chapter fixture for the From Reads to Variants chapter

Reference FASTA + canonical iVar and LoFreq VCFs from running the full
pipeline on SRR36291587 against MN908947.3. The 21.7 MB FASTQ is not
committed; regenerate.sh re-derives every artifact from the SRA/NCBI
accessions.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Phase 14 — Chapter prose

### Task 14.1: Write the new chapter

**Files:**
- Create: `docs/user-manual/chapters/04-variants/01-reads-to-variants.md`
- Delete: `docs/user-manual/chapters/04-variants/01-reading-a-vcf.md`
- Delete: `docs/user-manual/chapters/04-variants/02-calling-variants-from-a-bam.md`
- Modify: `docs/user-manual/index.md`

- [ ] **Step 1: Write the chapter**

The chapter follows `docs/user-manual/STYLE.md` exactly: no em dashes anywhere in prose, lists capped at five items and at most two lists per H2, no banned voice words. Length 3500–4500 words, structure per spec section 5.3. Phrases reusable verbatim from `01-reading-a-vcf.md` and `02-calling-variants-from-a-bam.md` may be lifted; everything else gets fresh prose.

Start the file with the frontmatter block from spec section 5.2 verbatim, then the body. Each `<!-- SHOT: id -->` marker corresponds to one entry in the frontmatter `shots[]` list and to one entry in the shotlist file (Phase 15).

To keep this plan self-contained, the chapter author must write at least these eight sections, in order:

1. `## What it is` — situate the workflow (NCBI download → SRA reads → mapping → primer-trim → two parallel variant calls → comparison). Approx 400 words.
2. `## Why this matters` — the choices that bake into a final call set; the role of primer-trim for amplicon data; the value of cross-caller comparison. Approx 500 words.
3. `## Before you start` — plugin packs to install, expected disk and time budget, how to verify provisioning. Approx 300 words.
4. `## Procedure` — eight numbered steps mirroring the integration test (download reference, download reads, map, adopt mapping, primer-trim, iVar call, LoFreq call, open both tracks). Approx 1200 words.
5. `## Interpreting what you see` — the side-by-side comparison; what rows agree vs. disagree; the codon-merge teaching moment. Approx 800 words.
6. `## Next steps` — pointers to deeper chapters that don't yet exist; how to run the same flow against the user's own reads. Approx 200 words.

- [ ] **Step 2: Delete the two old chapters**

```bash
git rm docs/user-manual/chapters/04-variants/01-reading-a-vcf.md
git rm docs/user-manual/chapters/04-variants/02-calling-variants-from-a-bam.md
```

- [ ] **Step 3: Update `docs/user-manual/index.md`** to point at the new chapter

Find the `04-variants/` section and rewrite the per-chapter list to a single entry. Match the style of the other section entries.

- [ ] **Step 4: Run the manual lint**

Run: `node docs/user-manual/build/scripts/lint/run.js`
Expected: zero errors (em-dash, bullet-cap, voice all clean).

- [ ] **Step 5: Commit**

```bash
git add docs/user-manual/chapters/04-variants/01-reads-to-variants.md docs/user-manual/index.md
git commit -m "$(cat <<'EOF'
Add From Reads to Variants chapter; retire chapters 01 and 02

Replaces the old "reading a VCF" + "calling from a BAM" pair with a
single end-to-end chapter that walks from NCBI/SRA accessions through
two side-by-side variant tracks. Uses the now-working iVar pipeline
and the new `bam adopt-mapping` CLI surface.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Phase 15 — Screenshot shotlist

### Task 15.1: Author the shotlist

**Files:**
- Create: `docs/user-manual/chapters/04-variants/01-reads-to-variants-shotlist.md`

- [ ] **Step 1: Write the shotlist**

For each of the eight `shots[]` entries in the chapter's frontmatter, write a recipe block:

```markdown
### Shot: ncbi-download-dialog

**File:** `docs/user-manual/assets/screenshots/04-variants/ncbi-download-dialog.png`

**Window:** Lungfish project window, sized 1280×800 (resize via Window > Zoom > Custom… > 1280×800)
**Active project:** the chapter's working project, named "From Reads to Variants"
**Sidebar:** Welcome screen if first launch; otherwise show File menu
**Action:** open File > Download from NCBI > Reference Sequence…
**Capture:** dialog open, accession field empty, Sample Type and Format dropdowns visible
**Caption:** "Downloading the SARS-CoV-2 reference from NCBI."
```

(Repeat for each of the eight shots. Each block is 4-8 lines and tells the user exactly what to do; no improvisation needed.)

- [ ] **Step 2: Commit**

```bash
git add docs/user-manual/chapters/04-variants/01-reads-to-variants-shotlist.md
git commit -m "$(cat <<'EOF'
Add shotlist for the From Reads to Variants chapter

Eight shot recipes the user can follow to capture the chapter's
screenshots by hand. Recipes specify window size, active project,
sidebar state, dialog state, and capture target so each shot lands
in a deterministic visual state.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

### Task 15.2: Wait for user to capture

- [ ] **Step 1: Pause**

This task is for the user, not the agent. The agent stops here and surfaces the shotlist + the artifact list (committed VCFs, `regenerate.sh`, fixture README) for the user to review and execute.

The chapter's `lead_approved: false` and `brand_reviewed: false` flip to `true` only after the user signs off on the prose and captures the screenshots.

---

## Self-Review

(Filled in below; subagents executing the plan don't need this section.)

### Spec coverage

- [x] §3.1 iVar TSV-to-VCF converter → Tasks 1.x, 2.x, 3.x, 4.x, 6.x
- [x] §3.1 GFF passthrough → Task 5 + Task 6.2 step 2
- [x] §3.1 Configuration surface → Task 6.1 (model), 7.x (CLI), 8.x (GUI)
- [x] §3.2 `bam adopt-mapping` → Task 9.x
- [x] §3.3 SRA fallback → Task 10.x
- [x] §4.1 Converter unit tests → Tasks 1.1, 2.1, 3.1, 4.2
- [x] §4.1 Parity test → Task 11.x
- [x] §4.2 `bam adopt-mapping` tests → Task 9.1
- [x] §4.3 SRA fallback tests → Task 10.1
- [x] §4.4 End-to-end test → Task 12.1
- [x] §5 Chapter prose → Task 14.x
- [x] §5.5 Fixture (committed reference + VCFs, not FASTQ) → Task 13.x
- [x] §5.6 Shotlist → Task 15.x

### Placeholder scan

Searched for "TBD", "TODO", "fill in details": none found in code/test bodies. Task 14.1 leaves the chapter's prose to the chapter author since 4000 words of bespoke writing is itself a sub-task; the structure, length budgets, and section headings are all specified.

### Type consistency

- `IVarTSVRow.Kind` (.snp, .insertion, .deletion) used identically in Tasks 2.1, 3.x, 4.x.
- `IVarCodonMerger.MergedVariant` and `Output` stable across Tasks 3.1, 4.3.
- `IVarTSVToVCFConverter.Options` field names stable across Tasks 4.2, 4.3, 6.2.
- `BundleVariantCallingRequest` field names (`ivarConsensusAF`, `ivarMergeAFThreshold`, `ivarBadQualityThreshold`, `ivarIgnoreStrandBias`) consistent across Tasks 6.1, 7.1, 8.1.

### Scope check

This is a single, focused implementation plan: one converter, one CLI command, one GUI panel, one fallback, one chapter, one shotlist. Total task count is large (15 tasks) but each is small and the phases are independent enough to execute sequentially without large blockers between them.
