# NVD Import & Taxonomy Browser Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add NVD (Novel Virus Diagnostics) classification result import and browsing, following the NAO-MGS pattern with SQLite-backed storage, multi-sample bundles, hierarchical contig→hit display, MiniBAM viewer, and BLAST verification.

**Architecture:** CSV parser → SQLite database with blast_hits + samples tables → NSOutlineView browser with two grouping modes (by sample, by taxon) → MiniBAM detail pane using per-sample BAM files → BLAST verification via existing BlastService. Import copies BAMs and FASTAs into a self-contained bundle. Also: remove NAO-MGS min % identity slider and create shared TextBadgeIcon for "Nao"/"Nvd" sidebar icons.

**Tech Stack:** Swift 6.2, SQLite3 (direct C API), SwiftUI (import sheet, sample picker), AppKit (NSOutlineView taxonomy browser, MiniBAM), Swift Testing framework

**Spec:** `docs/superpowers/specs/2026-04-02-nvd-import-design.md`

---

## Task 1: Remove NAO-MGS Min % Identity Slider

Clean up the min-identity parameter that flows through the NAO-MGS import chain but doesn't usefully filter data.

**Files:**
- Modify: `Sources/LungfishApp/Views/Metagenomics/NaoMgsImportSheet.swift`
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`
- Modify: `Sources/LungfishApp/Services/MetagenomicsImportHelperClient.swift`
- Modify: `Sources/LungfishApp/App/MetagenomicsImportHelper.swift`
- Modify: `Sources/LungfishCLI/Commands/NaoMgsCommand.swift`
- Modify: `Sources/LungfishCLI/Commands/ImportCommand.swift`

- [ ] **Step 1: Remove slider UI and simplify onImport callback in NaoMgsImportSheet.swift**

Remove the `minIdentity` state, the `optionsSection` view, and change `onImport` from `((URL, Double) -> Void)?` to `((URL) -> Void)?`.

In `NaoMgsImportSheet.swift`:
- Delete `@State private var minIdentity: Double = 0`
- Change `var onImport: ((URL, Double) -> Void)?` to `var onImport: ((URL) -> Void)?`
- Delete the entire `optionsSection` computed property (the VStack with "Options" heading, slider, and help text)
- Remove `optionsSection` from the body layout
- Change `onImport?(url, minIdentity)` to `onImport?(url)`

- [ ] **Step 2: Update AppDelegate NAO-MGS import wiring**

In `AppDelegate.swift`:
- Change `importNaoMgsResultFromURL(_ url: URL, minIdentity: Double)` to `importNaoMgsResultFromURL(_ url: URL)`
- Remove `minIdentity` from the `NaoMgsOptions` init: change `.init(minIdentity: minIdentity, fetchReferences: true)` to `.init(fetchReferences: true)`
- Update `launchNaoMgsImport` closure: change `sheet.onImport = { [weak self] (resultsDir: URL, minIdentity: Double) in` to `sheet.onImport = { [weak self] (resultsDir: URL) in`
- Update the call inside: `self?.importNaoMgsResultFromURL(resultsDir, minIdentity: minIdentity)` to `self?.importNaoMgsResultFromURL(resultsDir)`

- [ ] **Step 3: Remove minIdentity from MetagenomicsImportHelperClient.NaoMgsOptions**

In `MetagenomicsImportHelperClient.swift`:
- Remove `public let minIdentity: Double` from `NaoMgsOptions`
- Remove `minIdentity: Double = 0,` from the init parameter list
- Remove `self.minIdentity = minIdentity` from the init body
- Remove the two lines that append `--min-identity` to args:
  ```swift
  let normalizedIdentity = max(0, min(100, options.minIdentity))
  args.append(contentsOf: ["--min-identity", String(normalizedIdentity)])
  ```

- [ ] **Step 4: Remove minIdentity from MetagenomicsImportHelper**

In `MetagenomicsImportHelper.swift`:
- Remove `let minIdentity = Double(value(for: "--min-identity", in: arguments) ?? "") ?? 0`
- Remove `minIdentity: minIdentity,` from wherever it's passed to NaoMgsOptions

- [ ] **Step 5: Remove minIdentity from AppDelegate.importClassifierResultFromURL**

In `AppDelegate.swift`, find the `importClassifierResultFromURL` method. Remove the two lines:
```swift
let identityFloor = max(0, min(100, options.minIdentity))
cliArgs.append(contentsOf: ["--min-identity", String(identityFloor)])
```

- [ ] **Step 6: Remove --min-identity from NaoMgsCommand CLI**

In `NaoMgsCommand.swift`:
- Remove the `@Option(name: .customLong("min-identity"), ...)` property and its `var minIdentity: Double = 0`
- Remove the filtering block:
  ```swift
  if minIdentity > 0 {
      filteredHits = filteredHits.filter { $0.percentIdentity >= minIdentity }
  }
  ```

In `ImportCommand.swift`, check if `--min-identity` is referenced in the NaoMgs import subcommand and remove it there too.

- [ ] **Step 7: Build and verify**

Run: `swift build --build-tests`
Expected: Clean build with no errors

- [ ] **Step 8: Run existing tests**

Run: `swift test 2>&1 | tail -20`
Expected: All tests pass (no test specifically exercised min-identity filtering)

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "remove: NAO-MGS min % identity slider and parameter chain

The slider was not useful in practice. Removes the UI control,
the callback parameter, the CLI flag, and the filtering logic
throughout the import pipeline."
```

---

## Task 2: TextBadgeIcon + NAO-MGS Icon Update

Create a shared renderer for multi-letter badge icons ("Nao", "Nvd") and replace the NAO-MGS "n.circle" SF Symbol.

**Files:**
- Create: `Sources/LungfishApp/Views/Metagenomics/TextBadgeIcon.swift`
- Modify: `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift`

- [ ] **Step 1: Write tests for TextBadgeIcon**

Create `Tests/LungfishAppTests/TextBadgeIconTests.swift`:

```swift
// TextBadgeIconTests.swift — Tests for TextBadgeIcon rendering
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Testing
@testable import LungfishApp

struct TextBadgeIconTests {

    @Test
    func rendersBadgeWithCorrectSize() {
        let image = TextBadgeIcon.image(text: "Nvd", size: NSSize(width: 16, height: 16))
        #expect(image.size.width == 16)
        #expect(image.size.height == 16)
    }

    @Test
    func rendersBadgeForNao() {
        let image = TextBadgeIcon.image(text: "Nao", size: NSSize(width: 16, height: 16))
        #expect(image.size.width == 16)
        #expect(image.size.height == 16)
    }

    @Test
    func rendersBadgeAtDifferentSizes() {
        for dimension in [12, 16, 20, 24] {
            let size = NSSize(width: dimension, height: dimension)
            let image = TextBadgeIcon.image(text: "Nvd", size: size)
            #expect(image.size.width == CGFloat(dimension))
            #expect(image.size.height == CGFloat(dimension))
        }
    }

    @Test
    func rendersWithCustomColor() {
        let image = TextBadgeIcon.image(
            text: "Nvd",
            size: NSSize(width: 16, height: 16),
            fillColor: .systemBlue
        )
        #expect(image.size.width == 16)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TextBadgeIconTests 2>&1 | tail -5`
Expected: Compilation failure — `TextBadgeIcon` not defined

- [ ] **Step 3: Implement TextBadgeIcon**

Create `Sources/LungfishApp/Views/Metagenomics/TextBadgeIcon.swift`:

```swift
// TextBadgeIcon.swift — Renders multi-letter badge icons for sidebar and import UI
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

/// Renders a small rounded-rectangle badge with centered text.
///
/// Used for classifier sidebar icons ("Nao", "Nvd") where single-letter
/// SF Symbols are unavailable or ambiguous.
enum TextBadgeIcon {

    /// The default Lungfish Orange fill color for badge icons.
    static let defaultFillColor = NSColor(
        calibratedRed: 212 / 255.0,
        green: 123 / 255.0,
        blue: 58 / 255.0,
        alpha: 1.0
    )

    /// Renders a badge icon with the given text.
    ///
    /// - Parameters:
    ///   - text: The badge label (e.g. "Nao", "Nvd"). Keep to 2-4 characters.
    ///   - size: The image size in points.
    ///   - fillColor: Background fill color. Defaults to Lungfish Orange.
    ///   - textColor: Text color. Defaults to white.
    /// - Returns: An `NSImage` containing the rendered badge.
    static func image(
        text: String,
        size: NSSize,
        fillColor: NSColor = defaultFillColor,
        textColor: NSColor = .white
    ) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            let cornerRadius = rect.height * 0.2

            // Background pill
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                     xRadius: cornerRadius, yRadius: cornerRadius)
            fillColor.setFill()
            path.fill()

            // Text
            let fontSize = rect.height * 0.48
            let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: textColor,
            ]
            let attrString = NSAttributedString(string: text, attributes: attributes)
            let textSize = attrString.size()
            let textOrigin = NSPoint(
                x: rect.midX - textSize.width / 2,
                y: rect.midY - textSize.height / 2
            )
            attrString.draw(at: textOrigin)

            return true
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TextBadgeIconTests 2>&1 | tail -5`
Expected: All 4 tests pass

- [ ] **Step 5: Update NAO-MGS sidebar icon**

In `SidebarViewController.swift`, find `collectNaoMgsResults(in:)`. Change:
```swift
icon: "n.circle",
```
to use a custom image. The `SidebarItem` likely takes a string for SF Symbols. Check how it renders icons — if it uses `NSImage(systemSymbolName:)`, we need to store the NSImage differently.

Search for how `SidebarItem.icon` is used in rendering. If it's a string passed to `NSImage(systemSymbolName:)`, add an optional `customIcon: NSImage?` property to `SidebarItem` and use `TextBadgeIcon.image(text: "Nao", size: NSSize(width: 16, height: 16))` when present.

The exact change depends on `SidebarItem`'s icon rendering — the implementing agent should read `SidebarItem` and its rendering code to determine the right approach. The goal: NAO-MGS sidebar items show the "Nao" badge instead of "n.circle".

- [ ] **Step 6: Build and verify**

Run: `swift build --build-tests`
Expected: Clean build

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "add: TextBadgeIcon for multi-letter sidebar badges, update NAO-MGS icon

Shared renderer for 'Nao' and 'Nvd' badge icons. Replaces the
n.circle SF Symbol for NAO-MGS sidebar items with a Lungfish
Orange rounded-rect badge."
```

---

## Task 3: NVD Result Parser

Parse the `*_blast_concatenated.csv` file, compute hit_rank and reads_per_billion.

**Files:**
- Create: `Sources/LungfishIO/Formats/Nvd/NvdResultParser.swift`
- Create: `Tests/LungfishIntegrationTests/NvdResultParserTests.swift`
- Create: `Tests/Fixtures/nvd/test_blast_concatenated.csv`

- [ ] **Step 1: Create test fixture CSV**

Create `Tests/Fixtures/nvd/test_blast_concatenated.csv` with 3 samples, varying contig/hit counts:

```csv
experiment,blast_task,sample_id,qseqid,qlen,sseqid,stitle,tax_rank,length,pident,evalue,bitscore,sscinames,staxids,blast_db_version,snakemake_run_id,mapped_reads,total_reads,stat_db_version,adjusted_taxid,adjustment_method,adjusted_taxid_name,adjusted_taxid_rank
100,megablast,SampleA,NODE_1_length_500_cov_10.0,500,gi|123|gb|NC_045512.2|,"SARS-CoV-2 isolate Wuhan-Hu-1, complete genome",species:SARS-CoV-2,498,99.5,0.0,920.0,SARS-CoV-2,2697049,2.5.0,test_run,50,1000000,2.5.0,2697049,dominant,SARS-CoV-2,species
100,megablast,SampleA,NODE_1_length_500_cov_10.0,500,gi|456|gb|MW123456.1|,"SARS-CoV-2 isolate Alpha variant, complete genome",species:SARS-CoV-2,495,98.2,1e-200,890.0,SARS-CoV-2,2697049,2.5.0,test_run,50,1000000,2.5.0,2697049,dominant,SARS-CoV-2,species
100,megablast,SampleA,NODE_1_length_500_cov_10.0,500,gi|789|gb|MW789012.1|,"SARS-CoV-2 isolate Delta variant, complete genome",species:SARS-CoV-2,490,97.1,1e-180,860.0,SARS-CoV-2,2697049,2.5.0,test_run,50,1000000,2.5.0,2697049,dominant,SARS-CoV-2,species
100,megablast,SampleA,NODE_2_length_300_cov_5.0,300,gi|111|gb|NC_001802.1|,"Human immunodeficiency virus 1, complete genome",species:HIV-1,295,96.0,1e-150,750.0,HIV-1,11676,2.5.0,test_run,20,1000000,2.5.0,11676,dominant,HIV-1,species
100,megablast,SampleA,NODE_2_length_300_cov_5.0,300,gi|222|gb|AB012345.1|,"HIV-1 isolate subtype B, partial genome",species:HIV-1,290,95.0,1e-140,720.0,HIV-1,11676,2.5.0,test_run,20,1000000,2.5.0,11676,dominant,HIV-1,species
100,megablast,SampleA,NODE_2_length_300_cov_5.0,300,gi|333|gb|CD678901.1|,"HIV-1 isolate subtype C, partial genome",species:HIV-1,285,94.0,1e-130,700.0,HIV-1,11676,2.5.0,test_run,20,1000000,2.5.0,11676,dominant,HIV-1,species
100,megablast,SampleA,NODE_2_length_300_cov_5.0,300,gi|444|gb|EF012345.1|,"HIV-1 isolate subtype A, partial genome",species:HIV-1,280,93.0,1e-120,680.0,HIV-1,11676,2.5.0,test_run,20,1000000,2.5.0,11676,dominant,HIV-1,species
100,megablast,SampleA,NODE_2_length_300_cov_5.0,300,gi|555|gb|GH678901.1|,"HIV-1 isolate recombinant form, partial genome",species:HIV-1,275,92.0,1e-110,660.0,HIV-1,11676,2.5.0,test_run,20,1000000,2.5.0,11676,dominant,HIV-1,species
100,megablast,SampleB,NODE_1_length_400_cov_8.0,400,gi|666|gb|NC_009334.1|,"Human herpesvirus 4, complete genome",species:HHV-4,398,99.0,0.0,750.0,Human gammaherpesvirus 4,10376,2.5.0,test_run,100,2000000,2.5.0,10376,dominant,Human gammaherpesvirus 4,species
100,blastn,SampleC,NODE_5_length_200_cov_2.0,200,gi|999|gb|KX123456.1|,"Norovirus GII, partial genome",clade:Norovirus GII,198,97.5,1e-90,380.0,Norovirus GII,122929,2.5.0,test_run,10,500000,2.5.0,122929,dominant,Norovirus GII,clade
```

This gives us:
- SampleA: NODE_1 with 3 hits (SARS-CoV-2), NODE_2 with 5 hits (HIV-1)
- SampleB: NODE_1 with 1 hit (HHV-4)
- SampleC: NODE_5 with 1 hit (Norovirus GII, blastn task)
- Total: 10 rows, 4 unique contigs, 3 samples

- [ ] **Step 2: Add fixture accessor in TestFixtures.swift**

In `Tests/LungfishIntegrationTests/TestFixtures.swift`, add:

```swift
enum nvd {
    static var blastConcatenatedCSV: URL {
        fixturesDirectory.appendingPathComponent("nvd/test_blast_concatenated.csv")
    }
}
```

Where `fixturesDirectory` is the existing base fixtures URL.

- [ ] **Step 3: Write NvdResultParser tests**

Create `Tests/LungfishIntegrationTests/NvdResultParserTests.swift`:

```swift
// NvdResultParserTests.swift — Tests for NVD blast_concatenated.csv parser
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import LungfishIO

struct NvdResultParserTests {

    // MARK: - Basic Parsing

    @Test
    func parseFixtureCSV() async throws {
        let url = TestFixtures.nvd.blastConcatenatedCSV
        let parser = NvdResultParser()
        let result = try await parser.parse(at: url)

        #expect(result.hits.count == 10)
        #expect(result.experiment == "100")
        #expect(result.sampleIds.count == 3)
        #expect(result.sampleIds.contains("SampleA"))
        #expect(result.sampleIds.contains("SampleB"))
        #expect(result.sampleIds.contains("SampleC"))
    }

    @Test
    func parsesAllColumns() async throws {
        let url = TestFixtures.nvd.blastConcatenatedCSV
        let parser = NvdResultParser()
        let result = try await parser.parse(at: url)

        let firstHit = result.hits.first!
        #expect(firstHit.experiment == "100")
        #expect(firstHit.blastTask == "megablast")
        #expect(firstHit.sampleId == "SampleA")
        #expect(firstHit.qseqid == "NODE_1_length_500_cov_10.0")
        #expect(firstHit.qlen == 500)
        #expect(firstHit.sseqid == "NC_045512.2")
        #expect(firstHit.pident == 99.5)
        #expect(firstHit.evalue == 0.0)
        #expect(firstHit.bitscore == 920.0)
        #expect(firstHit.mappedReads == 50)
        #expect(firstHit.totalReads == 1000000)
        #expect(firstHit.adjustedTaxid == 2697049)
        #expect(firstHit.adjustedTaxidName == "SARS-CoV-2")
        #expect(firstHit.adjustedTaxidRank == "species")
    }

    // MARK: - Hit Rank Computation

    @Test
    func computesHitRankByEvalue() async throws {
        let url = TestFixtures.nvd.blastConcatenatedCSV
        let parser = NvdResultParser()
        let result = try await parser.parse(at: url)

        // NODE_1 in SampleA has 3 hits — ranked by evalue ascending
        let node1Hits = result.hits.filter {
            $0.sampleId == "SampleA" && $0.qseqid == "NODE_1_length_500_cov_10.0"
        }.sorted { $0.hitRank < $1.hitRank }

        #expect(node1Hits.count == 3)
        #expect(node1Hits[0].hitRank == 1)
        #expect(node1Hits[0].evalue == 0.0)  // best
        #expect(node1Hits[1].hitRank == 2)
        #expect(node1Hits[2].hitRank == 3)
        // E-values should be non-decreasing
        #expect(node1Hits[0].evalue <= node1Hits[1].evalue)
        #expect(node1Hits[1].evalue <= node1Hits[2].evalue)

        // NODE_2 in SampleA has 5 hits
        let node2Hits = result.hits.filter {
            $0.sampleId == "SampleA" && $0.qseqid == "NODE_2_length_300_cov_5.0"
        }.sorted { $0.hitRank < $1.hitRank }

        #expect(node2Hits.count == 5)
        #expect(node2Hits[0].hitRank == 1)
        #expect(node2Hits[4].hitRank == 5)
    }

    @Test
    func singleHitContigGetsRankOne() async throws {
        let url = TestFixtures.nvd.blastConcatenatedCSV
        let parser = NvdResultParser()
        let result = try await parser.parse(at: url)

        // SampleB NODE_1 has only 1 hit
        let sampleBHits = result.hits.filter { $0.sampleId == "SampleB" }
        #expect(sampleBHits.count == 1)
        #expect(sampleBHits[0].hitRank == 1)
    }

    // MARK: - Reads Per Billion

    @Test
    func computesReadsPerBillion() async throws {
        let url = TestFixtures.nvd.blastConcatenatedCSV
        let parser = NvdResultParser()
        let result = try await parser.parse(at: url)

        // SampleA NODE_1: mapped_reads=50, total_reads=1,000,000
        // RPB = 50 / 1,000,000 * 1e9 = 50,000
        let node1 = result.hits.first { $0.sampleId == "SampleA" && $0.qseqid.contains("NODE_1") }!
        #expect(abs(node1.readsPerBillion - 50_000) < 0.01)

        // SampleC NODE_5: mapped_reads=10, total_reads=500,000
        // RPB = 10 / 500,000 * 1e9 = 20,000
        let node5 = result.hits.first { $0.sampleId == "SampleC" }!
        #expect(abs(node5.readsPerBillion - 20_000) < 0.01)
    }

    // MARK: - Blast Task Types

    @Test
    func parsesBlastnTask() async throws {
        let url = TestFixtures.nvd.blastConcatenatedCSV
        let parser = NvdResultParser()
        let result = try await parser.parse(at: url)

        let blastnHits = result.hits.filter { $0.blastTask == "blastn" }
        #expect(blastnHits.count == 1)
        #expect(blastnHits[0].sampleId == "SampleC")
    }

    // MARK: - Quoted Fields

    @Test
    func handlesQuotedStitle() async throws {
        let url = TestFixtures.nvd.blastConcatenatedCSV
        let parser = NvdResultParser()
        let result = try await parser.parse(at: url)

        let firstHit = result.hits.first!
        // stitle should be parsed correctly despite containing commas
        #expect(firstHit.stitle.contains("SARS-CoV-2"))
        #expect(firstHit.stitle.contains("complete genome"))
    }

    // MARK: - Accession Extraction

    @Test
    func extractsAccessionFromSseqid() async throws {
        let url = TestFixtures.nvd.blastConcatenatedCSV
        let parser = NvdResultParser()
        let result = try await parser.parse(at: url)

        // sseqid = "gi|123|gb|NC_045512.2|" -> extracted accession should be "NC_045512.2"
        let firstHit = result.hits.first!
        #expect(firstHit.sseqid == "NC_045512.2")
    }

    // MARK: - Edge Cases

    @Test
    func emptyFileThrows() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
        let emptyFile = tmpDir.appendingPathComponent("empty_nvd_\(UUID().uuidString).csv")
        try "".write(to: emptyFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: emptyFile) }

        let parser = NvdResultParser()
        await #expect(throws: NvdParserError.self) {
            try await parser.parse(at: emptyFile)
        }
    }

    @Test
    func headerOnlyFileReturnsEmptyResult() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
        let headerFile = tmpDir.appendingPathComponent("header_nvd_\(UUID().uuidString).csv")
        let header = "experiment,blast_task,sample_id,qseqid,qlen,sseqid,stitle,tax_rank,length,pident,evalue,bitscore,sscinames,staxids,blast_db_version,snakemake_run_id,mapped_reads,total_reads,stat_db_version,adjusted_taxid,adjustment_method,adjusted_taxid_name,adjusted_taxid_rank\n"
        try header.write(to: headerFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: headerFile) }

        let parser = NvdResultParser()
        let result = try await parser.parse(at: headerFile)
        #expect(result.hits.isEmpty)
    }

    // MARK: - Progress Callback

    @Test
    func reportsLineProgress() async throws {
        let url = TestFixtures.nvd.blastConcatenatedCSV
        let parser = NvdResultParser()
        var progressCalls = 0
        _ = try await parser.parse(at: url) { _ in
            progressCalls += 1
        }
        #expect(progressCalls > 0)
    }
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `swift test --filter NvdResultParserTests 2>&1 | tail -5`
Expected: Compilation failure — `NvdResultParser` not defined

- [ ] **Step 5: Implement NvdResultParser**

Create `Sources/LungfishIO/Formats/Nvd/NvdResultParser.swift`:

```swift
// NvdResultParser.swift — Parser for NVD blast_concatenated.csv files
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Error

public enum NvdParserError: Error, LocalizedError, Sendable {
    case fileNotFound(URL)
    case invalidHeader(String)
    case malformedRow(lineNumber: Int, reason: String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url): return "File not found: \(url.lastPathComponent)"
        case .invalidHeader(let msg): return "Invalid CSV header: \(msg)"
        case .malformedRow(let line, let reason): return "Malformed row at line \(line): \(reason)"
        }
    }
}

// MARK: - Model

public struct NvdBlastHit: Sendable, Codable, Equatable {
    public let experiment: String
    public let blastTask: String
    public let sampleId: String
    public let qseqid: String
    public let qlen: Int
    public let sseqid: String      // Cleaned accession (e.g. "NC_045512.2")
    public let stitle: String
    public let taxRank: String
    public let length: Int          // alignment length
    public let pident: Double
    public let evalue: Double
    public let bitscore: Double
    public let sscinames: String
    public let staxids: String
    public let blastDbVersion: String
    public let snakemakeRunId: String
    public let mappedReads: Int
    public let totalReads: Int
    public let statDbVersion: String
    public let adjustedTaxid: Int
    public let adjustmentMethod: String
    public let adjustedTaxidName: String
    public let adjustedTaxidRank: String
    public let hitRank: Int         // 1-5, computed by parser
    public let readsPerBillion: Double  // computed: mappedReads / totalReads * 1e9
}

public struct NvdParseResult: Sendable {
    public let hits: [NvdBlastHit]
    public let experiment: String
    public let sampleIds: Set<String>
}

// MARK: - Parser

public final class NvdResultParser: Sendable {

    public init() {}

    /// Parses a `*_blast_concatenated.csv` file.
    ///
    /// Computes `hitRank` (1-based, ordered by evalue ascending within each
    /// sample+contig group) and `readsPerBillion` for every row.
    ///
    /// - Parameters:
    ///   - url: Path to the CSV file.
    ///   - lineProgress: Optional callback invoked with the current line number.
    /// - Returns: Parsed result with all hits and metadata.
    public func parse(
        at url: URL,
        lineProgress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> NvdParseResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NvdParserError.fileNotFound(url)
        }

        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            throw NvdParserError.fileNotFound(url)
        }

        let lines = contents.components(separatedBy: .newlines)
        guard let headerLine = lines.first, !headerLine.isEmpty else {
            throw NvdParserError.invalidHeader("Empty file")
        }

        let headerFields = parseCSVLine(headerLine)
        let columnIndex = buildColumnIndex(from: headerFields)

        // Validate required columns exist
        let required = ["experiment", "blast_task", "sample_id", "qseqid", "qlen",
                        "sseqid", "stitle", "tax_rank", "length", "pident", "evalue",
                        "bitscore", "sscinames", "staxids", "mapped_reads", "total_reads",
                        "adjusted_taxid", "adjusted_taxid_name", "adjusted_taxid_rank"]
        for col in required {
            guard columnIndex[col] != nil else {
                throw NvdParserError.invalidHeader("Missing column: \(col)")
            }
        }

        // Parse all rows
        var rawHits: [(hit: NvdBlastHit, groupKey: String)] = []  // groupKey for ranking
        var experiment = ""
        var sampleIds = Set<String>()

        for (lineIdx, line) in lines.dropFirst().enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            lineProgress?(lineIdx + 1)

            let fields = parseCSVLine(trimmed)
            let hit = try buildHit(from: fields, columnIndex: columnIndex,
                                   lineNumber: lineIdx + 2, hitRank: 0, readsPerBillion: 0)

            if experiment.isEmpty { experiment = hit.experiment }
            sampleIds.insert(hit.sampleId)

            let groupKey = "\(hit.sampleId)\t\(hit.qseqid)"
            rawHits.append((hit: hit, groupKey: groupKey))
        }

        // Compute hit_rank per (sample_id, qseqid) group ordered by evalue ASC
        var grouped: [String: [(Int, NvdBlastHit)]] = [:]  // key -> [(originalIndex, hit)]
        for (idx, entry) in rawHits.enumerated() {
            grouped[entry.groupKey, default: []].append((idx, entry.hit))
        }

        var rankedHits = Array(repeating: Optional<NvdBlastHit>.none, count: rawHits.count)
        for (_, entries) in grouped {
            let sorted = entries.sorted { $0.1.evalue < $1.1.evalue }
            for (rank, (originalIdx, hit)) in sorted.enumerated() {
                let rpb = hit.totalReads > 0
                    ? Double(hit.mappedReads) / Double(hit.totalReads) * 1e9
                    : 0.0
                let rankedHit = NvdBlastHit(
                    experiment: hit.experiment,
                    blastTask: hit.blastTask,
                    sampleId: hit.sampleId,
                    qseqid: hit.qseqid,
                    qlen: hit.qlen,
                    sseqid: hit.sseqid,
                    stitle: hit.stitle,
                    taxRank: hit.taxRank,
                    length: hit.length,
                    pident: hit.pident,
                    evalue: hit.evalue,
                    bitscore: hit.bitscore,
                    sscinames: hit.sscinames,
                    staxids: hit.staxids,
                    blastDbVersion: hit.blastDbVersion,
                    snakemakeRunId: hit.snakemakeRunId,
                    mappedReads: hit.mappedReads,
                    totalReads: hit.totalReads,
                    statDbVersion: hit.statDbVersion,
                    adjustedTaxid: hit.adjustedTaxid,
                    adjustmentMethod: hit.adjustmentMethod,
                    adjustedTaxidName: hit.adjustedTaxidName,
                    adjustedTaxidRank: hit.adjustedTaxidRank,
                    hitRank: rank + 1,
                    readsPerBillion: rpb
                )
                rankedHits[originalIdx] = rankedHit
            }
        }

        return NvdParseResult(
            hits: rankedHits.compactMap { $0 },
            experiment: experiment,
            sampleIds: sampleIds
        )
    }

    // MARK: - CSV Parsing Helpers

    /// Parses a CSV line respecting quoted fields (handles commas inside quotes).
    private func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false

        for char in line {
            if char == "\"" {
                inQuotes.toggle()
            } else if char == "," && !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        fields.append(current)
        return fields
    }

    private func buildColumnIndex(from headers: [String]) -> [String: Int] {
        var index: [String: Int] = [:]
        for (i, header) in headers.enumerated() {
            index[header.trimmingCharacters(in: .whitespacesAndNewlines)] = i
        }
        return index
    }

    /// Extracts a clean accession from the sseqid field.
    ///
    /// NVD sseqid format: `gi|123456|gb|NC_045512.2|` → returns `NC_045512.2`
    /// Falls back to returning the raw value if the gi|...|gb|...| pattern doesn't match.
    private func cleanAccession(_ raw: String) -> String {
        let parts = raw.split(separator: "|")
        // Pattern: gi|number|db|accession|
        if parts.count >= 4 {
            return String(parts[3])
        }
        return raw
    }

    private func buildHit(
        from fields: [String],
        columnIndex: [String: Int],
        lineNumber: Int,
        hitRank: Int,
        readsPerBillion: Double
    ) throws -> NvdBlastHit {
        func field(_ name: String) -> String {
            guard let idx = columnIndex[name], idx < fields.count else { return "" }
            return fields[idx]
        }

        func intField(_ name: String) -> Int {
            Int(field(name)) ?? 0
        }

        func doubleField(_ name: String) -> Double {
            Double(field(name)) ?? 0.0
        }

        return NvdBlastHit(
            experiment: field("experiment"),
            blastTask: field("blast_task"),
            sampleId: field("sample_id"),
            qseqid: field("qseqid"),
            qlen: intField("qlen"),
            sseqid: cleanAccession(field("sseqid")),
            stitle: field("stitle"),
            taxRank: field("tax_rank"),
            length: intField("length"),
            pident: doubleField("pident"),
            evalue: doubleField("evalue"),
            bitscore: doubleField("bitscore"),
            sscinames: field("sscinames"),
            staxids: field("staxids"),
            blastDbVersion: field("blast_db_version"),
            snakemakeRunId: field("snakemake_run_id"),
            mappedReads: intField("mapped_reads"),
            totalReads: intField("total_reads"),
            statDbVersion: field("stat_db_version"),
            adjustedTaxid: intField("adjusted_taxid"),
            adjustmentMethod: field("adjustment_method"),
            adjustedTaxidName: field("adjusted_taxid_name"),
            adjustedTaxidRank: field("adjusted_taxid_rank"),
            hitRank: hitRank,
            readsPerBillion: readsPerBillion
        )
    }
}
```

- [ ] **Step 6: Run tests**

Run: `swift test --filter NvdResultParserTests 2>&1 | tail -10`
Expected: All 10 tests pass

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "add: NVD result parser with hit ranking and reads-per-billion

Parses blast_concatenated.csv with quoted field handling, computes
hit_rank per contig group by evalue, and calculates reads per billion
normalization. Includes 10 tests covering parsing, ranking, edge cases."
```

---

## Task 4: NVD SQLite Database

Create the SQLite database layer for NVD results.

**Files:**
- Create: `Sources/LungfishIO/Formats/Nvd/NvdDatabase.swift`
- Create: `Tests/LungfishIntegrationTests/NvdDatabaseTests.swift`

- [ ] **Step 1: Write NvdDatabase tests**

Create `Tests/LungfishIntegrationTests/NvdDatabaseTests.swift`:

```swift
// NvdDatabaseTests.swift — Tests for NVD SQLite database schema and queries
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import LungfishIO

struct NvdDatabaseTests {

    // MARK: - Helpers

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("nvd_test_\(UUID().uuidString).sqlite")
    }

    private func makeSyntheticHits() -> [NvdBlastHit] {
        // 2 samples, 3 contigs total, varying hit counts
        var hits: [NvdBlastHit] = []

        // SampleA: NODE_1 with 3 hits, NODE_2 with 2 hits
        let sampleAContigs: [(String, Int, [(String, Double, Double)])] = [
            ("NODE_1_length_500_cov_10.0", 500, [
                ("NC_045512.2", 0.0, 920.0),
                ("MW123456.1", 1e-200, 890.0),
                ("MW789012.1", 1e-180, 860.0),
            ]),
            ("NODE_2_length_300_cov_5.0", 300, [
                ("NC_001802.1", 1e-150, 750.0),
                ("AB012345.1", 1e-140, 720.0),
            ]),
        ]

        for (contig, qlen, accessions) in sampleAContigs {
            for (rank, (acc, evalue, bitscore)) in accessions.enumerated() {
                hits.append(NvdBlastHit(
                    experiment: "100", blastTask: "megablast", sampleId: "SampleA",
                    qseqid: contig, qlen: qlen, sseqid: acc,
                    stitle: "Test subject \(acc)", taxRank: "species:Test",
                    length: qlen - 2, pident: 99.0 - Double(rank),
                    evalue: evalue, bitscore: bitscore,
                    sscinames: "Test virus", staxids: "12345",
                    blastDbVersion: "2.5.0", snakemakeRunId: "test",
                    mappedReads: 50, totalReads: 1_000_000,
                    statDbVersion: "2.5.0", adjustedTaxid: 12345,
                    adjustmentMethod: "dominant",
                    adjustedTaxidName: "Test virus", adjustedTaxidRank: "species",
                    hitRank: rank + 1,
                    readsPerBillion: 50.0 / 1_000_000.0 * 1e9
                ))
            }
        }

        // SampleB: NODE_3 with 1 hit
        hits.append(NvdBlastHit(
            experiment: "100", blastTask: "megablast", sampleId: "SampleB",
            qseqid: "NODE_3_length_400_cov_8.0", qlen: 400, sseqid: "NC_009334.1",
            stitle: "HHV-4 genome", taxRank: "species:HHV-4",
            length: 398, pident: 99.0, evalue: 0.0, bitscore: 750.0,
            sscinames: "Human gammaherpesvirus 4", staxids: "10376",
            blastDbVersion: "2.5.0", snakemakeRunId: "test",
            mappedReads: 100, totalReads: 2_000_000,
            statDbVersion: "2.5.0", adjustedTaxid: 10376,
            adjustmentMethod: "dominant",
            adjustedTaxidName: "Human gammaherpesvirus 4", adjustedTaxidRank: "species",
            hitRank: 1,
            readsPerBillion: 100.0 / 2_000_000.0 * 1e9
        ))

        return hits
    }

    private func makeSampleMetadata() -> [NvdSampleMetadata] {
        [
            NvdSampleMetadata(sampleId: "SampleA", bamPath: "bam/SampleA.filtered.bam",
                              fastaPath: "fasta/SampleA.human_virus.fasta",
                              totalReads: 1_000_000, contigCount: 2, hitCount: 5),
            NvdSampleMetadata(sampleId: "SampleB", bamPath: "bam/SampleB.filtered.bam",
                              fastaPath: "fasta/SampleB.human_virus.fasta",
                              totalReads: 2_000_000, contigCount: 1, hitCount: 1),
        ]
    }

    // MARK: - Schema Tests

    @Test
    func createDatabaseInsertsAllHits() throws {
        let hits = makeSyntheticHits()
        let samples = makeSampleMetadata()
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let db = try NvdDatabase.create(at: url, hits: hits, samples: samples)
        let count = try db.totalHitCount()
        #expect(count == 6, "All 6 hits should be in the database")
    }

    @Test
    func createDatabaseInsertsSampleMetadata() throws {
        let hits = makeSyntheticHits()
        let samples = makeSampleMetadata()
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let db = try NvdDatabase.create(at: url, hits: hits, samples: samples)
        let allSamples = try db.allSamples()
        #expect(allSamples.count == 2)
        #expect(allSamples.contains { $0.sampleId == "SampleA" })
        #expect(allSamples.contains { $0.sampleId == "SampleB" })
    }

    // MARK: - Query Tests

    @Test
    func queryBestHitsReturnsRankOne() throws {
        let hits = makeSyntheticHits()
        let samples = makeSampleMetadata()
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let db = try NvdDatabase.create(at: url, hits: hits, samples: samples)
        let bestHits = try db.bestHits(forSamples: ["SampleA"])

        #expect(bestHits.count == 2, "SampleA has 2 contigs")
        for hit in bestHits {
            #expect(hit.hitRank == 1, "bestHits should only return rank 1")
        }
    }

    @Test
    func queryChildHitsForContig() throws {
        let hits = makeSyntheticHits()
        let samples = makeSampleMetadata()
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let db = try NvdDatabase.create(at: url, hits: hits, samples: samples)
        let children = try db.childHits(
            sampleId: "SampleA",
            qseqid: "NODE_1_length_500_cov_10.0"
        )

        #expect(children.count == 3)
        // Should be ordered by evalue
        #expect(children[0].evalue <= children[1].evalue)
    }

    @Test
    func querySampleFiltering() throws {
        let hits = makeSyntheticHits()
        let samples = makeSampleMetadata()
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let db = try NvdDatabase.create(at: url, hits: hits, samples: samples)

        let countA = try db.totalHitCount(samples: ["SampleA"])
        #expect(countA == 5)

        let countB = try db.totalHitCount(samples: ["SampleB"])
        #expect(countB == 1)
    }

    @Test
    func queryTaxonGrouping() throws {
        let hits = makeSyntheticHits()
        let samples = makeSampleMetadata()
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let db = try NvdDatabase.create(at: url, hits: hits, samples: samples)
        let groups = try db.taxonGroups(forSamples: ["SampleA", "SampleB"])

        #expect(groups.count == 2, "Two distinct taxa: Test virus + HHV-4")
    }

    @Test
    func searchByTaxonName() throws {
        let hits = makeSyntheticHits()
        let samples = makeSampleMetadata()
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let db = try NvdDatabase.create(at: url, hits: hits, samples: samples)
        let results = try db.searchBestHits(
            query: "herpesvirus",
            samples: ["SampleA", "SampleB"]
        )

        #expect(results.count == 1)
        #expect(results[0].adjustedTaxidName == "Human gammaherpesvirus 4")
    }

    @Test
    func searchByAccession() throws {
        let hits = makeSyntheticHits()
        let samples = makeSampleMetadata()
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let db = try NvdDatabase.create(at: url, hits: hits, samples: samples)
        let results = try db.searchBestHits(
            query: "NC_045512",
            samples: ["SampleA"]
        )

        #expect(results.count == 1)
        #expect(results[0].sseqid == "NC_045512.2")
    }

    @Test
    func searchByContigName() throws {
        let hits = makeSyntheticHits()
        let samples = makeSampleMetadata()
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let db = try NvdDatabase.create(at: url, hits: hits, samples: samples)
        let results = try db.searchBestHits(
            query: "NODE_3",
            samples: ["SampleA", "SampleB"]
        )

        #expect(results.count == 1)
        #expect(results[0].sampleId == "SampleB")
    }

    @Test
    func sampleBamPath() throws {
        let hits = makeSyntheticHits()
        let samples = makeSampleMetadata()
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let db = try NvdDatabase.create(at: url, hits: hits, samples: samples)
        let bamPath = try db.bamPath(forSample: "SampleA")
        #expect(bamPath == "bam/SampleA.filtered.bam")
    }

    @Test
    func readsPerBillionStoredCorrectly() throws {
        let hits = makeSyntheticHits()
        let samples = makeSampleMetadata()
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let db = try NvdDatabase.create(at: url, hits: hits, samples: samples)
        let bestHits = try db.bestHits(forSamples: ["SampleA"])

        for hit in bestHits {
            #expect(hit.readsPerBillion > 0)
            let expected = Double(hit.mappedReads) / Double(hit.totalReads) * 1e9
            #expect(abs(hit.readsPerBillion - expected) < 0.01)
        }
    }

    @Test
    func reopensDatabaseReadOnly() throws {
        let hits = makeSyntheticHits()
        let samples = makeSampleMetadata()
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try NvdDatabase.create(at: url, hits: hits, samples: samples)
        let reopened = try NvdDatabase(at: url)
        let count = try reopened.totalHitCount()
        #expect(count == 6)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter NvdDatabaseTests 2>&1 | tail -5`
Expected: Compilation failure — types not defined

- [ ] **Step 3: Implement NvdDatabase**

Create `Sources/LungfishIO/Formats/Nvd/NvdDatabase.swift`. The implementing agent should model this closely on `NaoMgsDatabase.swift`, using the same SQLite C API patterns (FULLMUTEX, WAL mode, pragmas). Key interfaces:

```swift
// NvdDatabase.swift — SQLite database for NVD classification results
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3

public enum NvdDatabaseError: Error, LocalizedError, Sendable {
    case openFailed(String)
    case createFailed(String)
    case queryFailed(String)
    case insertFailed(String)

    public var errorDescription: String? { ... }
}

public struct NvdSampleMetadata: Sendable, Codable {
    public let sampleId: String
    public let bamPath: String
    public let fastaPath: String
    public let totalReads: Int
    public let contigCount: Int
    public let hitCount: Int

    public init(sampleId: String, bamPath: String, fastaPath: String,
                totalReads: Int, contigCount: Int, hitCount: Int)
}

public struct NvdTaxonGroup: Sendable {
    public let adjustedTaxidName: String
    public let adjustedTaxidRank: String
    public let contigCount: Int
    public let totalMappedReads: Int
}

public final class NvdDatabase: @unchecked Sendable {
    private var db: OpaquePointer?
    private let url: URL

    public var databaseURL: URL { url }

    /// Opens an existing database (read-only).
    public init(at url: URL) throws

    /// Creates a new database with all hits and sample metadata.
    @discardableResult
    public static func create(
        at url: URL,
        hits: [NvdBlastHit],
        samples: [NvdSampleMetadata],
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) throws -> NvdDatabase

    // MARK: - Queries

    /// Total hit count, optionally filtered by samples.
    public func totalHitCount(samples: [String]? = nil) throws -> Int

    /// Returns best hits (hit_rank=1) for selected samples, ordered by evalue.
    public func bestHits(forSamples samples: [String]) throws -> [NvdBlastHit]

    /// Returns all hits for a specific contig in a sample, ordered by evalue.
    public func childHits(sampleId: String, qseqid: String) throws -> [NvdBlastHit]

    /// Returns taxon groups (aggregated by adjusted_taxid_name) for selected samples.
    public func taxonGroups(forSamples samples: [String]) throws -> [NvdTaxonGroup]

    /// Searches best hits by query string across taxon name, stitle, sseqid, qseqid.
    public func searchBestHits(query: String, samples: [String]) throws -> [NvdBlastHit]

    /// Returns all sample metadata rows.
    public func allSamples() throws -> [NvdSampleMetadata]

    /// Returns the BAM relative path for a sample.
    public func bamPath(forSample sampleId: String) throws -> String?

    /// Returns the FASTA relative path for a sample.
    public func fastaPath(forSample sampleId: String) throws -> String?

    deinit
}
```

**Schema creation SQL:**

```sql
CREATE TABLE blast_hits (
    rowid INTEGER PRIMARY KEY,
    experiment TEXT NOT NULL,
    blast_task TEXT NOT NULL,
    sample_id TEXT NOT NULL,
    qseqid TEXT NOT NULL,
    qlen INTEGER NOT NULL,
    sseqid TEXT NOT NULL,
    stitle TEXT NOT NULL,
    tax_rank TEXT NOT NULL,
    length INTEGER NOT NULL,
    pident REAL NOT NULL,
    evalue REAL NOT NULL,
    bitscore REAL NOT NULL,
    sscinames TEXT NOT NULL,
    staxids TEXT NOT NULL,
    blast_db_version TEXT NOT NULL,
    snakemake_run_id TEXT NOT NULL,
    mapped_reads INTEGER NOT NULL,
    total_reads INTEGER NOT NULL,
    stat_db_version TEXT NOT NULL,
    adjusted_taxid INTEGER NOT NULL,
    adjustment_method TEXT NOT NULL,
    adjusted_taxid_name TEXT NOT NULL,
    adjusted_taxid_rank TEXT NOT NULL,
    hit_rank INTEGER NOT NULL,
    reads_per_billion REAL NOT NULL
);

CREATE TABLE samples (
    sample_id TEXT PRIMARY KEY,
    bam_path TEXT NOT NULL,
    fasta_path TEXT NOT NULL,
    total_reads INTEGER NOT NULL,
    contig_count INTEGER NOT NULL,
    hit_count INTEGER NOT NULL
);

CREATE INDEX idx_hits_sample ON blast_hits(sample_id);
CREATE INDEX idx_hits_contig ON blast_hits(sample_id, qseqid);
CREATE INDEX idx_hits_taxon ON blast_hits(adjusted_taxid_name);
CREATE INDEX idx_hits_experiment ON blast_hits(experiment);
CREATE INDEX idx_hits_rank ON blast_hits(adjusted_taxid_rank);
CREATE INDEX idx_hits_evalue ON blast_hits(sample_id, qseqid, evalue);
CREATE INDEX idx_hits_stitle ON blast_hits(stitle);
CREATE INDEX idx_hits_best ON blast_hits(hit_rank, sample_id);
```

Use the same SQLite C API patterns as `NaoMgsDatabase.swift`: `sqlite3_open_v2` with `SQLITE_OPEN_FULLMUTEX`, WAL mode, prepared statements, `sqlite3_bind_*` for parameters, `sqlite3_step`/`sqlite3_column_*` for reading rows.

- [ ] **Step 4: Run tests**

Run: `swift test --filter NvdDatabaseTests 2>&1 | tail -10`
Expected: All 12 tests pass

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "add: NVD SQLite database with schema, indices, and query methods

Tables: blast_hits (all BLAST results with computed hit_rank and
reads_per_billion) and samples (BAM/FASTA paths and counts).
7 indices for fast filtering. 12 tests covering creation, queries,
search, and sample metadata."
```

---

## Task 5: NVD Manifest

**Files:**
- Create: `Sources/LungfishIO/Formats/Nvd/NvdManifest.swift`

- [ ] **Step 1: Implement NvdManifest**

Create `Sources/LungfishIO/Formats/Nvd/NvdManifest.swift`:

```swift
// NvdManifest.swift — Bundle manifest for NVD classification results
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Manifest for an NVD result bundle stored as `nvd-{experiment}/manifest.json`.
public struct NvdManifest: Codable, Sendable {
    public let formatVersion: String
    public let experiment: String
    public let importDate: Date
    public let sampleCount: Int
    public let contigCount: Int
    public let hitCount: Int
    public let blastDbVersion: String?
    public let snakemakeRunId: String?
    public let sourceDirectoryPath: String
    public let samples: [NvdSampleSummary]
    public var cachedTopContigs: [NvdContigRow]?

    public init(
        experiment: String,
        importDate: Date = Date(),
        sampleCount: Int,
        contigCount: Int,
        hitCount: Int,
        blastDbVersion: String? = nil,
        snakemakeRunId: String? = nil,
        sourceDirectoryPath: String,
        samples: [NvdSampleSummary],
        cachedTopContigs: [NvdContigRow]? = nil
    ) {
        self.formatVersion = "1.0"
        self.experiment = experiment
        self.importDate = importDate
        self.sampleCount = sampleCount
        self.contigCount = contigCount
        self.hitCount = hitCount
        self.blastDbVersion = blastDbVersion
        self.snakemakeRunId = snakemakeRunId
        self.sourceDirectoryPath = sourceDirectoryPath
        self.samples = samples
        self.cachedTopContigs = cachedTopContigs
    }
}

/// Per-sample summary stored in the manifest for instant display.
public struct NvdSampleSummary: Codable, Sendable {
    public let sampleId: String
    public let contigCount: Int
    public let hitCount: Int
    public let totalReads: Int
    public let bamRelativePath: String
    public let fastaRelativePath: String

    public init(
        sampleId: String,
        contigCount: Int,
        hitCount: Int,
        totalReads: Int,
        bamRelativePath: String,
        fastaRelativePath: String
    ) {
        self.sampleId = sampleId
        self.contigCount = contigCount
        self.hitCount = hitCount
        self.totalReads = totalReads
        self.bamRelativePath = bamRelativePath
        self.fastaRelativePath = fastaRelativePath
    }
}

/// Cached contig row for instant table display before SQLite loads.
public struct NvdContigRow: Codable, Sendable {
    public let sampleId: String
    public let qseqid: String
    public let qlen: Int
    public let adjustedTaxidName: String
    public let adjustedTaxidRank: String
    public let sseqid: String
    public let stitle: String
    public let pident: Double
    public let evalue: Double
    public let bitscore: Double
    public let mappedReads: Int
    public let readsPerBillion: Double

    public init(
        sampleId: String, qseqid: String, qlen: Int,
        adjustedTaxidName: String, adjustedTaxidRank: String,
        sseqid: String, stitle: String,
        pident: Double, evalue: Double, bitscore: Double,
        mappedReads: Int, readsPerBillion: Double
    ) {
        self.sampleId = sampleId
        self.qseqid = qseqid
        self.qlen = qlen
        self.adjustedTaxidName = adjustedTaxidName
        self.adjustedTaxidRank = adjustedTaxidRank
        self.sseqid = sseqid
        self.stitle = stitle
        self.pident = pident
        self.evalue = evalue
        self.bitscore = bitscore
        self.mappedReads = mappedReads
        self.readsPerBillion = readsPerBillion
    }
}
```

- [ ] **Step 2: Build and verify**

Run: `swift build --build-tests`
Expected: Clean build

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "add: NVD manifest model for bundle metadata and cached rows"
```

---

## Task 6: NVD Import Sheet + Import Center Registration

**Files:**
- Create: `Sources/LungfishApp/Views/Metagenomics/NvdImportSheet.swift`
- Modify: `Sources/LungfishApp/Views/ImportCenter/ImportCenterView.swift`
- Modify: `Sources/LungfishApp/Views/ImportCenter/ImportCenterViewModel.swift`

- [ ] **Step 1: Implement NvdImportSheet**

Create `Sources/LungfishApp/Views/Metagenomics/NvdImportSheet.swift`. Model closely on `NaoMgsImportSheet.swift` but:
- Header icon: `TextBadgeIcon.image(text: "Nvd", ...)` rendered as SwiftUI `Image(nsImage:)`
- Title: "NVD Import", subtitle: "Novel Virus Diagnostics"
- Browse for directory (the `nvd/` folder)
- Auto-discover: `05_labkey_bundling/*_blast_concatenated.csv`
- Also verify presence of `02_human_viruses/03_human_virus_results/` with FASTA and BAM files
- Preview: experiment ID, sample count, contig count, hit count, BAM total size
- No min % identity slider
- `var onImport: ((URL) -> Void)?` — passes the NVD run directory URL
- `var onCancel: (() -> Void)?`
- Frame: ~500x450

The implementing agent should read `NaoMgsImportSheet.swift` for the exact SwiftUI layout pattern and replicate it with NVD-specific content.

- [ ] **Step 2: Register NVD in ImportCenterViewModel**

In `ImportCenterViewModel.swift`:
- Add `.nvd` case to `ImportCardInfo.ImportAction` enum
- Add NVD card to `allCards`:
  ```swift
  ImportCardInfo(
      id: "nvd",
      title: "NVD Results",
      description: "Import Novel Virus Diagnostics (NVD) classification results. Parses blast_concatenated.csv with BLAST hit rankings and mapped reads.",
      sfSymbol: "n.circle",  // Will be replaced with TextBadgeIcon
      fileHint: "*_blast_concatenated.csv",
      tab: .classificationResults,
      importKind: .wizardSheet(action: .nvd)
  )
  ```
- Add `case .nvd: return "NVD"` to `historyLabel(for:)` method
- Add `.nvd` case to `openWizardSheet(action:)` to present `NvdImportSheet`

- [ ] **Step 3: Update ImportCenterView if needed**

Check if `ImportCenterView.swift` needs changes to render the NVD card. If it renders cards generically from `allCards`, no change needed. If it has hardcoded card sections, add NVD.

- [ ] **Step 4: Build and verify**

Run: `swift build --build-tests`
Expected: Clean build

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "add: NVD import sheet and Import Center registration

SwiftUI import wizard with directory browsing, auto-discovery of
blast_concatenated.csv/FASTA/BAM files, and preview display.
Registered in Import Center Classification Results tab."
```

---

## Task 7: NVD Import Pipeline (AppDelegate + CLI)

Wire the import sheet to the actual import logic and add CLI support.

**Files:**
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`
- Create: `Sources/LungfishCLI/Commands/NvdCommand.swift`
- Modify: `Sources/LungfishCLI/Commands/ImportCommand.swift`
- Modify: `Sources/LungfishWorkflow/Metagenomics/MetagenomicsImportService.swift`

- [ ] **Step 1: Add NVD to MetagenomicsImportKind**

In `MetagenomicsImportService.swift`, add:
```swift
case nvd
```
to `MetagenomicsImportKind` enum, with:
```swift
case .nvd: return "nvd-"
```
in `directoryPrefix`.

- [ ] **Step 2: Add AppDelegate import method**

In `AppDelegate.swift`, add `importNvdResultFromURL(_ url: URL)` following the pattern of `importNaoMgsResultFromURL`. This method should:
1. Ensure a project is open
2. Create the `nvd-{experiment}/` bundle directory in `Imports/`
3. Parse the CSV with `NvdResultParser`
4. Create SQLite database with `NvdDatabase.create`
5. Copy BAM + BAI files into `bam/` subdirectory
6. Copy FASTA files into `fasta/` subdirectory
7. Compute sample metadata from parsed results
8. Write `manifest.json`
9. Report progress via OperationCenter
10. Refresh sidebar on completion

The implementing agent should read the `importNaoMgsResultFromURL` and `importClassifierResultFromURL` methods in `AppDelegate.swift` to understand the exact pattern, then adapt for NVD (which does the import in-process rather than via CLI helper, since NVD import is straightforward file operations + CSV parsing).

- [ ] **Step 3: Wire NvdImportSheet in AppDelegate**

Add `launchNvdImport(_ sender: Any?)` method and wire `NvdImportSheet.onImport` to call `importNvdResultFromURL`.

- [ ] **Step 4: Create NvdCommand CLI**

Create `Sources/LungfishCLI/Commands/NvdCommand.swift` with an import subcommand:

```swift
struct NvdCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "nvd",
        abstract: "Import and view NVD classification results",
        subcommands: [ImportSubcommand.self, SummarySubcommand.self],
        defaultSubcommand: SummarySubcommand.self
    )
}
```

The import subcommand takes the NVD directory path and `--output-dir` option. The summary subcommand shows a table of top contigs/taxa.

- [ ] **Step 5: Register NvdCommand in ImportCommand**

In `ImportCommand.swift`, add `NvdCommand.ImportSubcommand.self` (or however the subcommand is structured) to the `subcommands` array.

- [ ] **Step 6: Build and verify**

Run: `swift build --build-tests`
Expected: Clean build

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "add: NVD import pipeline and CLI command

AppDelegate import method parses CSV, creates SQLite database,
copies BAM/FASTA files into bundle, writes manifest. CLI support
via 'lungfish import nvd' subcommand."
```

---

## Task 8: NVD Result View Controller (Taxonomy Browser)

The largest task — the NSOutlineView taxonomy browser with two grouping modes.

**Files:**
- Create: `Sources/LungfishApp/Views/Metagenomics/NvdResultViewController.swift`
- Create: `Sources/LungfishApp/Views/Metagenomics/NvdSamplePickerView.swift`
- Create: `Sources/LungfishApp/Views/Metagenomics/NvdDataConverter.swift`

- [ ] **Step 1: Create NvdSamplePickerView**

Create `Sources/LungfishApp/Views/Metagenomics/NvdSamplePickerView.swift`. Model directly on `NaoMgsSamplePickerView.swift`:

```swift
public struct NvdSampleEntry: Identifiable, Sendable {
    public let id: String  // sample_id
    public let displayName: String
    public let contigCount: Int
    public let hitCount: Int
}

@Observable
public final class NvdSamplePickerState: @unchecked Sendable {
    public var selectedSamples: Set<String> = []
    public init() {}
}
```

SwiftUI view with Select All toggle and per-sample checkboxes showing contig/hit counts.

- [ ] **Step 2: Create NvdDataConverter**

Create `Sources/LungfishApp/Views/Metagenomics/NvdDataConverter.swift` with utility methods:

```swift
enum NvdDataConverter {
    /// Extracts a contig sequence from a multi-FASTA file by matching the header.
    static func extractContigSequence(from fastaURL: URL, contigName: String) -> String?

    /// Formats a contig display name: "NODE_1183 (227bp)" from "NODE_1183_length_227_cov_1.116279"
    static func displayName(for qseqid: String, qlen: Int) -> String

    /// Strips the common prefix from sample IDs for compact display.
    static func commonPrefix(of names: [String]) -> String
}
```

- [ ] **Step 3: Create NvdResultViewController**

Create `Sources/LungfishApp/Views/Metagenomics/NvdResultViewController.swift`. This is the core UI — model on `NaoMgsResultViewController.swift` but with NSOutlineView instead of NSTableView.

**Key architecture:**
- `NSViewController` subclass, `@MainActor`
- Summary bar at top (48pt) showing experiment/sample/contig counts
- NSSplitView: detail pane (40%) + NSOutlineView (60%)
- Search field above the outline view
- Detail pane: summary card + MiniBAM viewer for selected contig
- Action bar at bottom (36pt) with BLAST Verify / Export buttons

**Outline view data model:**
```swift
enum NvdOutlineItem {
    case contig(NvdBlastHit)      // Best hit (hit_rank=1) — expandable to show children
    case childHit(NvdBlastHit)    // Secondary hit (hit_rank 2-5)
    case taxonGroup(NvdTaxonGroup) // Taxon grouping mode — expandable to show contigs
}
```

**Grouping mode:**
- `enum GroupingMode { case bySample, byTaxon }` — property on the VC
- `bySample`: flat list of contigs (best hits), expand to show child hits
- `byTaxon`: taxon group rows, expand to contigs, expand to child hits

**NSOutlineViewDataSource/Delegate:**
- `outlineView(_:numberOfChildrenOfItem:)` — root items are contigs or taxon groups
- `outlineView(_:child:ofItem:)` — children are child hits (or contigs under taxon groups)
- `outlineView(_:isItemExpandable:)` — contigs with >1 hit, taxon groups always
- Column identifiers matching the 12 default columns
- Child hit rows styled with `.secondaryLabelColor`

**MiniBAM integration:**
- On contig selection, look up BAM path from SQLite: `db.bamPath(forSample:)`
- Open BAM at `bundleURL/bamPath` and display region for the selected contig name
- Reuse existing `MiniBAMViewController` from NAO-MGS

**BLAST verification callback:**
```swift
public var onBlastVerification: ((NvdBlastHit, String) -> Void)?
// (selected hit, contig FASTA sequence)
```

**Public configure methods:**
```swift
func configureWithCachedRows(_ rows: [NvdContigRow], manifest: NvdManifest, bundleURL: URL)
func configure(database: NvdDatabase, manifest: NvdManifest, bundleURL: URL)
```

**Public properties for Inspector sync:**
```swift
public var samplePickerState: NvdSamplePickerState
public var sampleEntries: [NvdSampleEntry]
public var strippedPrefix: String
public var groupingMode: GroupingMode
```

The implementing agent should read `NaoMgsResultViewController.swift` thoroughly to understand the exact layout, loading, filtering, and selection patterns, then adapt for NVD's outline-view hierarchy.

- [ ] **Step 4: Build and verify**

Run: `swift build --build-tests`
Expected: Clean build

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "add: NVD taxonomy browser with NSOutlineView, MiniBAM, and search

NSOutlineView with two grouping modes (by sample, by taxon), 12 default
columns, hierarchical contig->hit display, MiniBAM detail pane, debounced
search, and sample picker. Follows NAO-MGS result viewer pattern."
```

---

## Task 9: Viewer + Sidebar + Inspector Integration

Wire NVD into the main window, sidebar, and inspector.

**Files:**
- Create: `Sources/LungfishApp/Views/Viewer/ViewerViewController+Nvd.swift`
- Modify: `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/Sections/DocumentSection.swift`

- [ ] **Step 1: Create ViewerViewController+Nvd.swift**

Model directly on `ViewerViewController+NaoMgs.swift` (193 lines). Create `Sources/LungfishApp/Views/Viewer/ViewerViewController+Nvd.swift`:

- `displayNvdResult(_ controller: NvdResultViewController)` — hides all overlays (including `hideNaoMgsView()`), sets `.metagenomics` content mode, adds child VC, wires `onBlastVerification` callback. For BLAST, extract the contig FASTA sequence from the bundle using `NvdDataConverter.extractContigSequence`, then submit to BlastService.
- `hideNvdView()` — removes NvdResultViewController children, restores normal components (same guard pattern as NAO-MGS)

The BLAST callback differs from NAO-MGS: instead of subsampling reads, we submit the full contig sequence as a single FASTA entry to BLAST.

- [ ] **Step 2: Add sidebar discovery**

In `SidebarViewController.swift`:
- Add `case nvdResult` to `SidebarItemType` enum
- Add `collectNvdResults(in:)` method (same pattern as `collectNaoMgsResults`):
  - Scan for `nvd-*/` directories with `manifest.json`
  - Read manifest to get experiment ID for display title
  - Icon: `TextBadgeIcon.image(text: "Nvd", ...)` (use the same mechanism chosen in Task 2 for custom icons)
  - Display: "NVD: {experiment}"
- Call `collectNvdResults(in:)` alongside `collectNaoMgsResults` during sidebar refresh
- Add `.nvdResult` handling in sidebar selection dispatch

- [ ] **Step 3: Add MainSplitViewController display method**

In `MainSplitViewController.swift`:
- Add `.nvdResult` case in the sidebar selection dispatch (same location as `.naoMgsResult`)
- Add `displayNvdResultFromSidebar(at:)` — two-phase loading:
  1. Create placeholder `NvdResultViewController()`
  2. Display via `viewerController.displayNvdResult()`
  3. Async: read `manifest.json` → `configureWithCachedRows` if available
  4. Async: open `hits.sqlite` → `configure(database:manifest:bundleURL:)`
  5. Update inspector with NVD manifest and sample picker state

Model directly on `displayNaoMgsResultFromSidebar(at:)`.

- [ ] **Step 4: Add Inspector support**

In `InspectorViewController.swift`:
- Add `case .nvdResult: return "NVD Classification Result"` to the type name mapping
- Add `updateNvdManifest(_ manifest: NvdManifest?)` method
- Add `updateNvdSampleState(pickerState:entries:strippedPrefix:groupingMode:)` method
- Add "Group by" segmented control in the NVD section: `Sample | Taxon`

In `DocumentSection.swift`:
- Add NVD-specific section displaying: experiment, sample count, contig count, hit count, import date, BLAST DB version, Snakemake run ID
- Add sample picker (reusing the NvdSamplePickerView as inline)
- Add grouping mode segmented control

- [ ] **Step 5: Build and verify**

Run: `swift build --build-tests`
Expected: Clean build

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "add: NVD sidebar discovery, viewer integration, and inspector support

Sidebar scans for nvd-* bundles with manifest.json. Two-phase loading
in MainSplitViewController. Inspector shows metadata, sample picker,
and Group by toggle. ViewerViewController+Nvd wires BLAST verification."
```

---

## Task 10: About Window + Acknowledgement

**Files:**
- Modify: `Sources/LungfishApp/App/AboutWindowController.swift`

- [ ] **Step 1: Add NVD to acknowledgements**

In `AboutWindowController.swift`, add NVD to the "Classification & Metagenomics" section in `appendToolEntries`:

```swift
("NVD", "O'Connor DH, Ramuta MD, et al.", "MIT",
 "https://github.com/dholab/nvd"),
```

Add it after the existing classification tools.

- [ ] **Step 2: Build and verify**

Run: `swift build --build-tests`
Expected: Clean build

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "add: NVD to About window acknowledgements"
```

---

## Task 11: Final Integration Test + Push

- [ ] **Step 1: Run full test suite**

Run: `swift test 2>&1 | tail -20`
Expected: All tests pass (including new NvdResultParserTests and NvdDatabaseTests)

- [ ] **Step 2: Build the full app**

Run: `swift build 2>&1 | tail -5`
Expected: Clean build

- [ ] **Step 3: Push the branch**

```bash
git push -u origin NVD
```
