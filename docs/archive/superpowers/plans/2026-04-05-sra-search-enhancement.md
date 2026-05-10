# SRA Search Enhancement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix broken SRA title/organism/keyword search, add multi-accession paste and CSV import, add BioProject/Author scopes, and add SRA-specific advanced filters.

**Architecture:** Two-step search (NCBI ESearch → ENA filereport) for non-accession SRA queries. Batch ENA lookup engine for multi-accession input. New search scopes and advanced filters wired into existing `buildSearchTerm()` and `advancedFiltersGrid` patterns.

**Tech Stack:** Swift 6.2, SwiftUI, NCBI Entrez E-utilities, ENA Portal API, XCTest

**Spec:** `docs/superpowers/specs/2026-04-05-sra-search-enhancement-design.md`

**Branch:** `sra-search-enhancement` (create before starting Task 1)

---

## Pre-work: Create Branch

- [ ] **Create the feature branch**

```bash
git checkout -b sra-search-enhancement
```

---

## Task 1: Accession Pattern Detection Utility

Pure utility functions for detecting SRA accession patterns. No network, no UI — just string parsing.

**Files:**
- Create: `Sources/LungfishCore/Services/SRA/SRAAccessionParser.swift`
- Create: `Tests/LungfishCoreTests/SRAAccessionParserTests.swift`

- [ ] **Step 1: Write failing tests for accession pattern detection**

Create `Tests/LungfishCoreTests/SRAAccessionParserTests.swift`:

```swift
// SRAAccessionParserTests.swift - Tests for SRA accession pattern detection
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

final class SRAAccessionParserTests: XCTestCase {

    // MARK: - Single Accession Detection

    func testDetectsSingleRunAccession() {
        XCTAssertTrue(SRAAccessionParser.isSRAAccession("SRR35517702"))
        XCTAssertTrue(SRAAccessionParser.isSRAAccession("ERR1234567"))
        XCTAssertTrue(SRAAccessionParser.isSRAAccession("DRR028938"))
    }

    func testDetectsExperimentAccession() {
        XCTAssertTrue(SRAAccessionParser.isSRAAccession("SRX123456"))
        XCTAssertTrue(SRAAccessionParser.isSRAAccession("ERX789012"))
    }

    func testDetectsSampleAccession() {
        XCTAssertTrue(SRAAccessionParser.isSRAAccession("SRS123456"))
        XCTAssertTrue(SRAAccessionParser.isSRAAccession("ERS789012"))
    }

    func testDetectsStudyAccession() {
        XCTAssertTrue(SRAAccessionParser.isSRAAccession("SRP123456"))
        XCTAssertTrue(SRAAccessionParser.isSRAAccession("ERP789012"))
    }

    func testDetectsBioProjectAccession() {
        XCTAssertTrue(SRAAccessionParser.isSRAAccession("PRJNA989177"))
        XCTAssertTrue(SRAAccessionParser.isSRAAccession("PRJEB12345"))
        XCTAssertTrue(SRAAccessionParser.isSRAAccession("PRJDB67890"))
    }

    func testRejectsNonAccessionText() {
        XCTAssertFalse(SRAAccessionParser.isSRAAccession("SARS-CoV-2"))
        XCTAssertFalse(SRAAccessionParser.isSRAAccession("influenza"))
        XCTAssertFalse(SRAAccessionParser.isSRAAccession("air monitoring"))
        XCTAssertFalse(SRAAccessionParser.isSRAAccession("NC_045512"))  // GenBank, not SRA
        XCTAssertFalse(SRAAccessionParser.isSRAAccession(""))
    }

    func testDetectsRunAccessionType() {
        XCTAssertEqual(SRAAccessionParser.accessionType("SRR35517702"), .run)
        XCTAssertEqual(SRAAccessionParser.accessionType("ERR1234567"), .run)
        XCTAssertEqual(SRAAccessionParser.accessionType("DRR028938"), .run)
    }

    func testDetectsStudyAccessionType() {
        XCTAssertEqual(SRAAccessionParser.accessionType("SRP123456"), .study)
        XCTAssertEqual(SRAAccessionParser.accessionType("PRJNA989177"), .bioProject)
    }

    func testNonAccessionReturnsNilType() {
        XCTAssertNil(SRAAccessionParser.accessionType("influenza"))
    }

    // MARK: - Multi-Accession Parsing

    func testParseNewlineSeparatedAccessions() {
        let input = "SRR35517702\nSRR35517703\nSRR35517705"
        let result = SRAAccessionParser.parseAccessionList(input)
        XCTAssertEqual(result, ["SRR35517702", "SRR35517703", "SRR35517705"])
    }

    func testParseCommaSeparatedAccessions() {
        let input = "SRR35517702, SRR35517703, SRR35517705"
        let result = SRAAccessionParser.parseAccessionList(input)
        XCTAssertEqual(result, ["SRR35517702", "SRR35517703", "SRR35517705"])
    }

    func testParseTabSeparatedAccessions() {
        let input = "SRR35517702\tSRR35517703\tSRR35517705"
        let result = SRAAccessionParser.parseAccessionList(input)
        XCTAssertEqual(result, ["SRR35517702", "SRR35517703", "SRR35517705"])
    }

    func testParseMixedSeparators() {
        let input = "SRR35517702\nSRR35517703, SRR35517705\tSRR35517706"
        let result = SRAAccessionParser.parseAccessionList(input)
        XCTAssertEqual(result, ["SRR35517702", "SRR35517703", "SRR35517705", "SRR35517706"])
    }

    func testParseIgnoresNonAccessionLines() {
        let input = "acc\nSRR35517702\nsome junk\nSRR35517703\n"
        let result = SRAAccessionParser.parseAccessionList(input)
        XCTAssertEqual(result, ["SRR35517702", "SRR35517703"])
    }

    func testParseDeduplicates() {
        let input = "SRR35517702\nSRR35517702\nSRR35517703"
        let result = SRAAccessionParser.parseAccessionList(input)
        XCTAssertEqual(result, ["SRR35517702", "SRR35517703"])
    }

    func testParseEmptyString() {
        let result = SRAAccessionParser.parseAccessionList("")
        XCTAssertTrue(result.isEmpty)
    }

    func testParseTrimsWhitespace() {
        let input = "  SRR35517702  \n  SRR35517703  "
        let result = SRAAccessionParser.parseAccessionList(input)
        XCTAssertEqual(result, ["SRR35517702", "SRR35517703"])
    }

    func testIsMultiAccessionInput() {
        XCTAssertTrue(SRAAccessionParser.isMultiAccessionInput("SRR111\nSRR222"))
        XCTAssertTrue(SRAAccessionParser.isMultiAccessionInput("SRR111, SRR222"))
        XCTAssertFalse(SRAAccessionParser.isMultiAccessionInput("SRR111"))
        XCTAssertFalse(SRAAccessionParser.isMultiAccessionInput("SARS-CoV-2"))
    }

    // MARK: - CSV Parsing

    func testParseCSVWithHeader() {
        let csv = "acc\nSRR35517702\nSRR35517703\nSRR35517705\n"
        let result = SRAAccessionParser.parseCSV(csv)
        XCTAssertEqual(result, ["SRR35517702", "SRR35517703", "SRR35517705"])
    }

    func testParseCSVWithoutHeader() {
        let csv = "SRR35517702\nSRR35517703\n"
        let result = SRAAccessionParser.parseCSV(csv)
        XCTAssertEqual(result, ["SRR35517702", "SRR35517703"])
    }

    func testParseCSVWithEmptyLines() {
        let csv = "acc\n\nSRR35517702\n\nSRR35517703\n\n"
        let result = SRAAccessionParser.parseCSV(csv)
        XCTAssertEqual(result, ["SRR35517702", "SRR35517703"])
    }

    func testParseCSVFromFileURL() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let csvFile = tempDir.appendingPathComponent("test-accessions.csv")
        try "acc\nDRR028938\nDRR051810\n".write(to: csvFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: csvFile) }

        let result = try SRAAccessionParser.parseCSVFile(at: csvFile)
        XCTAssertEqual(result, ["DRR028938", "DRR051810"])
    }

    func testParseCSVFileWithInvalidAccessions() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let csvFile = tempDir.appendingPathComponent("test-mixed.csv")
        try "acc\nSRR123\njunk\nERR456\n".write(to: csvFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: csvFile) }

        let result = try SRAAccessionParser.parseCSVFile(at: csvFile)
        XCTAssertEqual(result, ["SRR123", "ERR456"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SRAAccessionParserTests 2>&1 | tail -5`
Expected: Build error — `SRAAccessionParser` not defined.

- [ ] **Step 3: Implement SRAAccessionParser**

Create `Sources/LungfishCore/Services/SRA/SRAAccessionParser.swift`:

```swift
// SRAAccessionParser.swift - SRA accession pattern detection and parsing
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Type of SRA-related accession.
public enum SRAAccessionType: Sendable {
    case run         // SRR, ERR, DRR
    case experiment  // SRX, ERX, DRX
    case sample      // SRS, ERS, DRS
    case study       // SRP, ERP, DRP
    case bioProject  // PRJNA, PRJEB, PRJDB
}

/// Utility for detecting and parsing SRA accession patterns.
public enum SRAAccessionParser {

    // Run: SRR/ERR/DRR + digits
    private static let runPattern = /^[SED]RR\d+$/
    // Experiment: SRX/ERX/DRX + digits
    private static let experimentPattern = /^[SED]RX\d+$/
    // Sample: SRS/ERS/DRS + digits
    private static let samplePattern = /^[SED]RS\d+$/
    // Study: SRP/ERP/DRP + digits
    private static let studyPattern = /^[SED]RP\d+$/
    // BioProject: PRJNA/PRJEB/PRJDB + digits
    private static let bioProjectPattern = /^PRJ[A-Z]{2}\d+$/

    /// Returns true if the string is a recognized SRA-related accession.
    public static func isSRAAccession(_ string: String) -> Bool {
        accessionType(string) != nil
    }

    /// Returns the accession type, or nil if not recognized.
    public static func accessionType(_ string: String) -> SRAAccessionType? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        if trimmed.wholeMatch(of: runPattern) != nil { return .run }
        if trimmed.wholeMatch(of: experimentPattern) != nil { return .experiment }
        if trimmed.wholeMatch(of: samplePattern) != nil { return .sample }
        if trimmed.wholeMatch(of: studyPattern) != nil { return .study }
        if trimmed.wholeMatch(of: bioProjectPattern) != nil { return .bioProject }
        return nil
    }

    /// Parses a string containing multiple accessions separated by newlines, commas, or tabs.
    /// Returns deduplicated accessions in order of first appearance.
    public static func parseAccessionList(_ input: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        let tokens = input.components(separatedBy: CharacterSet(charactersIn: "\n\r,\t "))
        for token in tokens {
            let trimmed = token.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, isSRAAccession(trimmed), !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result
    }

    /// Returns true if the input contains 2 or more SRA accessions.
    public static func isMultiAccessionInput(_ input: String) -> Bool {
        parseAccessionList(input).count >= 2
    }

    /// Parses CSV text in NCBI SraAccList.csv format.
    /// Handles files with or without an "acc" header line.
    public static func parseCSV(_ csvText: String) -> [String] {
        var lines = csvText.components(separatedBy: .newlines)
        // Remove header if present
        if let first = lines.first?.trimmingCharacters(in: .whitespaces).lowercased(),
           first == "acc" || first == "accession" || first == "run" {
            lines.removeFirst()
        }
        var seen = Set<String>()
        var result: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, isSRAAccession(trimmed), !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result
    }

    /// Reads and parses a CSV file at the given URL.
    public static func parseCSVFile(at url: URL) throws -> [String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return parseCSV(text)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SRAAccessionParserTests 2>&1 | tail -5`
Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishCore/Services/SRA/SRAAccessionParser.swift Tests/LungfishCoreTests/SRAAccessionParserTests.swift
git commit -m "feat: add SRA accession pattern detection and CSV parsing"
```

---

## Task 2: Add SearchScope Cases for BioProject and Author

Extend the `SearchScope` enum with new cases and update `buildSearchTerm()` to handle them.

**Files:**
- Modify: `Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserViewController.swift` (lines 232-258 for `SearchScope`, lines 1515-1601 for `buildSearchTerm`)
- Modify: `Tests/LungfishAppTests/DatabaseBrowserViewModelTests.swift`

- [ ] **Step 1: Write failing tests for new scopes**

Add to `Tests/LungfishAppTests/DatabaseBrowserViewModelTests.swift`:

```swift
// MARK: - New Search Scopes

func testSearchScopeIncludesBioProject() {
    XCTAssertNotNil(SearchScope.allCases.first(where: { $0 == .bioProject }))
    XCTAssertEqual(SearchScope.bioProject.rawValue, "BioProject")
}

func testSearchScopeIncludesAuthor() {
    XCTAssertNotNil(SearchScope.allCases.first(where: { $0 == .author }))
    XCTAssertEqual(SearchScope.author.rawValue, "Author")
}

func testBioProjectScopeHasIcon() {
    XCTAssertFalse(SearchScope.bioProject.icon.isEmpty)
}

func testAuthorScopeHasIcon() {
    XCTAssertFalse(SearchScope.author.icon.isEmpty)
}

func testBioProjectScopeHasHelpText() {
    XCTAssertFalse(SearchScope.bioProject.helpText.isEmpty)
}

func testAuthorScopeHasHelpText() {
    XCTAssertFalse(SearchScope.author.helpText.isEmpty)
}

func testAllScopesCount() {
    // all, accession, organism, title, bioProject, author = 6
    XCTAssertEqual(SearchScope.allCases.count, 6)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter DatabaseBrowserViewModelTests/testSearchScopeIncludesBioProject 2>&1 | tail -5`
Expected: Build error — `SearchScope.bioProject` not defined.

- [ ] **Step 3: Add bioProject and author cases to SearchScope**

In `DatabaseBrowserViewController.swift`, modify the `SearchScope` enum (around line 232):

Change:
```swift
public enum SearchScope: String, CaseIterable, Identifiable {
    case all = "All Fields"
    case accession = "Accession"
    case organism = "Organism"
    case title = "Title"

    public var id: String { rawValue }

    /// SF Symbol for the scope
    var icon: String {
        switch self {
        case .all: return "magnifyingglass"
        case .accession: return "number"
        case .organism: return "leaf"
        case .title: return "text.alignleft"
        }
    }

    /// Help text explaining what this scope searches
    var helpText: String {
        switch self {
        case .all: return "Searches accession numbers, organism names, titles, and descriptions"
        case .accession: return "Search by accession number (e.g., NC_002549, MN908947)"
        case .organism: return "Search by organism or species name"
        case .title: return "Search within sequence titles and descriptions"
        }
    }
}
```

To:
```swift
public enum SearchScope: String, CaseIterable, Identifiable {
    case all = "All Fields"
    case accession = "Accession"
    case organism = "Organism"
    case title = "Title"
    case bioProject = "BioProject"
    case author = "Author"

    public var id: String { rawValue }

    /// SF Symbol for the scope
    var icon: String {
        switch self {
        case .all: return "magnifyingglass"
        case .accession: return "number"
        case .organism: return "leaf"
        case .title: return "text.alignleft"
        case .bioProject: return "folder"
        case .author: return "person.text.rectangle"
        }
    }

    /// Help text explaining what this scope searches
    var helpText: String {
        switch self {
        case .all: return "Searches accession numbers, organism names, titles, and descriptions"
        case .accession: return "Search by accession number (e.g., NC_002549, MN908947, SRR35517702)"
        case .organism: return "Search by organism or species name"
        case .title: return "Search within sequence titles and descriptions"
        case .bioProject: return "Search by BioProject accession (e.g., PRJNA989177)"
        case .author: return "Search by submitter or author name"
        }
    }
}
```

- [ ] **Step 4: Update buildSearchTerm for new scopes**

In `buildSearchTerm()` (around line 1525), add cases for `.bioProject` and `.author`:

After the existing `.title` case:
```swift
        case .title:
            let result = "\(term)[Title]"
            logger.debug("buildSearchTerm: Built title query='\(result, privacy: .public)'")
            scopedTerm = result
```

Add:
```swift
        case .bioProject:
            let result = "\(term)[BioProject]"
            logger.debug("buildSearchTerm: Built BioProject query='\(result, privacy: .public)'")
            scopedTerm = result
        case .author:
            let result = "\(term)[Author]"
            logger.debug("buildSearchTerm: Built author query='\(result, privacy: .public)'")
            scopedTerm = result
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter DatabaseBrowserViewModelTests 2>&1 | tail -5`
Expected: All tests PASS (including new scope tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserViewController.swift Tests/LungfishAppTests/DatabaseBrowserViewModelTests.swift
git commit -m "feat: add BioProject and Author search scopes"
```

---

## Task 3: SRA-Specific Advanced Filter Properties

Add ViewModel properties for SRA Platform, Strategy, and Layout filters. Wire into `activeFilterCount` and `clearFilters`.

**Files:**
- Modify: `Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserViewController.swift`
- Modify: `Tests/LungfishAppTests/DatabaseBrowserViewModelTests.swift`

- [ ] **Step 1: Write failing tests for SRA filter properties**

Add to `Tests/LungfishAppTests/DatabaseBrowserViewModelTests.swift`:

```swift
// MARK: - SRA Filter Properties

func testSRAFilterDefaults() {
    let enaViewModel = DatabaseBrowserViewModel(source: .ena)
    XCTAssertEqual(enaViewModel.sraPlatformFilter, .any)
    XCTAssertEqual(enaViewModel.sraStrategyFilter, .any)
    XCTAssertEqual(enaViewModel.sraLayoutFilter, .any)
    XCTAssertEqual(enaViewModel.sraMinMbases, "")
    XCTAssertEqual(enaViewModel.sraPubDateFrom, "")
    XCTAssertEqual(enaViewModel.sraPubDateTo, "")
}

func testSRAFilterCountPlatform() {
    let enaViewModel = DatabaseBrowserViewModel(source: .ena)
    enaViewModel.sraPlatformFilter = .illumina
    XCTAssertEqual(enaViewModel.activeFilterCount, 1)
}

func testSRAFilterCountMultiple() {
    let enaViewModel = DatabaseBrowserViewModel(source: .ena)
    enaViewModel.sraPlatformFilter = .illumina
    enaViewModel.sraStrategyFilter = .wgs
    enaViewModel.sraLayoutFilter = .paired
    XCTAssertEqual(enaViewModel.activeFilterCount, 3)
}

func testClearFiltersClearsSRAFilters() {
    let enaViewModel = DatabaseBrowserViewModel(source: .ena)
    enaViewModel.sraPlatformFilter = .illumina
    enaViewModel.sraStrategyFilter = .wgs
    enaViewModel.sraLayoutFilter = .paired
    enaViewModel.sraMinMbases = "100"
    enaViewModel.clearFilters()
    XCTAssertEqual(enaViewModel.sraPlatformFilter, .any)
    XCTAssertEqual(enaViewModel.sraStrategyFilter, .any)
    XCTAssertEqual(enaViewModel.sraLayoutFilter, .any)
    XCTAssertEqual(enaViewModel.sraMinMbases, "")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter DatabaseBrowserViewModelTests/testSRAFilterDefaults 2>&1 | tail -5`
Expected: Build error — `sraPlatformFilter` not defined.

- [ ] **Step 3: Add SRA filter enums and properties**

In `DatabaseBrowserViewController.swift`, add these enums before the `DatabaseBrowserViewModel` class (around line 260):

```swift
// MARK: - SRA Filter Enums

/// SRA sequencing platform filter.
public enum SRAPlatformFilter: String, CaseIterable, Identifiable, Sendable {
    case any = "Any"
    case illumina = "ILLUMINA"
    case oxfordNanopore = "OXFORD_NANOPORE"
    case pacbio = "PACBIO_SMRT"
    case ionTorrent = "ION_TORRENT"
    case ultima = "ULTIMA"
    case element = "ELEMENT"
    case bgiseq = "BGISEQ"

    public var id: String { rawValue }

    /// The value to use in NCBI ESearch `[Platform]` queries.
    var entrezValue: String? {
        self == .any ? nil : rawValue
    }
}

/// SRA library strategy filter.
public enum SRAStrategyFilter: String, CaseIterable, Identifiable, Sendable {
    case any = "Any"
    case wgs = "WGS"
    case amplicon = "AMPLICON"
    case rnaSeq = "RNA-Seq"
    case wxs = "WXS"
    case targetedCapture = "Targeted-Capture"
    case other = "OTHER"

    public var id: String { rawValue }

    var entrezValue: String? {
        self == .any ? nil : rawValue
    }
}

/// SRA library layout filter.
public enum SRALayoutFilter: String, CaseIterable, Identifiable, Sendable {
    case any = "Any"
    case paired = "PAIRED"
    case single = "SINGLE"

    public var id: String { rawValue }

    var entrezValue: String? {
        self == .any ? nil : rawValue
    }
}
```

Add properties to `DatabaseBrowserViewModel` (after the Virus-Specific Filters section, around line 520):

```swift
    // MARK: SRA-Specific Filters

    /// Platform filter for SRA searches (e.g., ILLUMINA, OXFORD_NANOPORE)
    @Published var sraPlatformFilter: SRAPlatformFilter = .any

    /// Library strategy filter for SRA searches (e.g., WGS, AMPLICON)
    @Published var sraStrategyFilter: SRAStrategyFilter = .any

    /// Library layout filter for SRA searches (e.g., PAIRED, SINGLE)
    @Published var sraLayoutFilter: SRALayoutFilter = .any

    /// Minimum dataset size in megabases for SRA searches
    @Published var sraMinMbases: String = ""

    /// Publication date range for SRA searches: start date
    @Published var sraPubDateFrom: String = ""

    /// Publication date range for SRA searches: end date
    @Published var sraPubDateTo: String = ""
```

Update `activeFilterCount` (around line 744) — add an SRA branch. Change the `else` block:

```swift
        } else if isSRASearch {
            // SRA-specific filters
            if sraPlatformFilter != .any { count += 1 }
            if sraStrategyFilter != .any { count += 1 }
            if sraLayoutFilter != .any { count += 1 }
            if !sraMinMbases.isEmpty { count += 1 }
            if !sraPubDateFrom.isEmpty || !sraPubDateTo.isEmpty { count += 1 }
        } else {
```

Update `clearFilters()` (around line 947) — add SRA filter resets before the Pathoplexus section:

```swift
        // SRA filters
        sraPlatformFilter = .any
        sraStrategyFilter = .any
        sraLayoutFilter = .any
        sraMinMbases = ""
        sraPubDateFrom = ""
        sraPubDateTo = ""
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter DatabaseBrowserViewModelTests 2>&1 | tail -5`
Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserViewController.swift Tests/LungfishAppTests/DatabaseBrowserViewModelTests.swift
git commit -m "feat: add SRA platform, strategy, and layout filter properties"
```

---

## Task 4: NCBI SRA ESearch and EFetch Methods

Add methods to NCBIService for searching SRA and converting UIDs to run accessions.

**Files:**
- Modify: `Sources/LungfishCore/Services/NCBI/NCBIService.swift`
- Create: `Tests/LungfishCoreTests/SRAEFetchParsingTests.swift`

- [ ] **Step 1: Write failing tests for SRA EFetch CSV parsing**

Create `Tests/LungfishCoreTests/SRAEFetchParsingTests.swift`:

```swift
// SRAEFetchParsingTests.swift - Tests for parsing SRA EFetch runinfo CSV
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

final class SRAEFetchParsingTests: XCTestCase {

    func testParseRunInfoCSV() {
        // Minimal runinfo CSV with header and two data rows
        let csv = """
        Run,ReleaseDate,LoadDate,spots,bases,spots_with_mates,avgLength,size_MB,AssemblyName,download_path,Experiment,LibraryName,LibraryStrategy,LibrarySelection,LibrarySource,LibraryLayout,InsertSize,InsertDev,Platform,Model,SRAStudy,BioProject,Study_Pubmed_id,ProjectID,Sample,BioSample,SampleType,TaxID,ScientificName,SampleName,g1k_pop_code,source,g1k_analysis_group,Subject_ID,Sex,Disease,Tumor,Affection_Status,Analyte_Type,Histological_Type,Body_Site,CenterName,Submission,dbgap_study_accession,Consent,RunHash,ReadHash
        DRR028938,2015-01-14,2015-01-14,631,190562,631,302,0,na,https://sra-downloadb.be-md.ncbi.nlm.nih.gov/sos3/sra-pub-zq-14/DRR028/DRR028938/DRR028938.sra,DRX026575,,,WGS,RANDOM,GENOMIC,PAIRED,0,0,ILLUMINA,Illumina HiSeq 2500,DRP002739,PRJDB3502,,281982,DRS022844,SAMD00024406,simple,1386,Bacillus cereus,NBRC 15305,,,,,,,,,,DDBJ,DRA002883,,public,ABC123,DEF456
        DRR051810,2016-05-18,2016-05-18,270,81000,270,300,0,na,https://example.com/DRR051810.sra,DRX046950,,,WGS,RANDOM,GENOMIC,PAIRED,0,0,ILLUMINA,Illumina HiSeq 2000,DRP003850,PRJDB4000,,300000,DRS040000,SAMD00044332,simple,9606,Homo sapiens,Sample1,,,,,,,,,,DDBJ,DRA004000,,public,GHI789,JKL012
        """
        let accessions = NCBIService.parseRunInfoCSV(csv)
        XCTAssertEqual(accessions, ["DRR028938", "DRR051810"])
    }

    func testParseRunInfoCSVEmptyResponse() {
        let csv = ""
        let accessions = NCBIService.parseRunInfoCSV(csv)
        XCTAssertTrue(accessions.isEmpty)
    }

    func testParseRunInfoCSVHeaderOnly() {
        let csv = "Run,ReleaseDate,LoadDate,spots,bases\n"
        let accessions = NCBIService.parseRunInfoCSV(csv)
        XCTAssertTrue(accessions.isEmpty)
    }

    func testParseRunInfoCSVSkipsEmptyRunColumn() {
        let csv = """
        Run,ReleaseDate
        DRR028938,2015-01-14
        ,2016-05-18
        DRR051810,2016-05-18
        """
        let accessions = NCBIService.parseRunInfoCSV(csv)
        XCTAssertEqual(accessions, ["DRR028938", "DRR051810"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SRAEFetchParsingTests 2>&1 | tail -5`
Expected: Build error — `NCBIService.parseRunInfoCSV` not defined.

- [ ] **Step 3: Add SRA ESearch, EFetch, and CSV parsing to NCBIService**

In `Sources/LungfishCore/Services/NCBI/NCBIService.swift`, add these methods (after the existing `efetch` method, around line 936):

```swift
    // MARK: - SRA Search

    /// Searches the SRA database via ESearch, returning UIDs and total count.
    ///
    /// - Parameters:
    ///   - term: The search term with optional field qualifiers (e.g., "SARS-CoV-2[Organism]")
    ///   - retmax: Maximum results per page
    ///   - retstart: Offset for pagination
    /// - Returns: UIDs and total count from the SRA database
    public func sraESearch(term: String, retmax: Int = 200, retstart: Int = 0) async throws -> ESearchSearchResult {
        try await esearchWithCount(database: .sra, term: term, retmax: retmax, retstart: retstart)
    }

    /// Fetches SRR run accessions from SRA UIDs via EFetch runinfo CSV.
    ///
    /// - Parameter uids: SRA UIDs from ESearch
    /// - Returns: Array of SRR/ERR/DRR run accession strings
    public func sraEFetchRunAccessions(uids: [String]) async throws -> [String] {
        guard !uids.isEmpty else { return [] }

        var allAccessions: [String] = []
        // EFetch accepts max ~200 UIDs per request
        let chunkSize = 200
        for chunkStart in stride(from: 0, to: uids.count, by: chunkSize) {
            let chunkEnd = min(chunkStart + chunkSize, uids.count)
            let chunk = Array(uids[chunkStart..<chunkEnd])

            var components = URLComponents(url: baseURL.appendingPathComponent("efetch.fcgi"), resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "db", value: "sra"),
                URLQueryItem(name: "id", value: chunk.joined(separator: ",")),
                URLQueryItem(name: "rettype", value: "runinfo"),
                URLQueryItem(name: "retmode", value: "csv")
            ]
            if let apiKey = apiKey {
                components.queryItems?.append(URLQueryItem(name: "api_key", value: apiKey))
            }

            let data = try await makeRequest(url: components.url!)
            let csvText = String(data: data, encoding: .utf8) ?? ""
            allAccessions.append(contentsOf: Self.parseRunInfoCSV(csvText))
        }
        return allAccessions
    }

    /// Parses NCBI SRA EFetch runinfo CSV to extract run accessions.
    ///
    /// The CSV has a header row where the first column is "Run".
    /// Each subsequent row's first comma-separated field is the SRR/ERR/DRR accession.
    public static func parseRunInfoCSV(_ csv: String) -> [String] {
        let lines = csv.components(separatedBy: .newlines)
        guard lines.count > 1 else { return [] }
        // Skip header (first line)
        return lines.dropFirst().compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            // First comma-separated field is the Run accession
            let run = trimmed.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? ""
            return run.isEmpty ? nil : run
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SRAEFetchParsingTests 2>&1 | tail -5`
Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishCore/Services/NCBI/NCBIService.swift Tests/LungfishCoreTests/SRAEFetchParsingTests.swift
git commit -m "feat: add NCBI SRA ESearch and EFetch runinfo methods"
```

---

## Task 5: Batch ENA Lookup Engine

Add `searchReadsBatch()` to ENAService for parallel multi-accession lookups.

**Files:**
- Modify: `Sources/LungfishCore/Services/ENA/ENAService.swift`
- Create: `Tests/LungfishCoreTests/SRABatchLookupTests.swift`

- [ ] **Step 1: Write failing tests for batch lookup**

Create `Tests/LungfishCoreTests/SRABatchLookupTests.swift`:

```swift
// SRABatchLookupTests.swift - Tests for batch ENA lookup
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

final class SRABatchLookupTests: XCTestCase {

    func testBatchLookupMethodExists() async throws {
        let service = ENAService()
        // Verify the method signature compiles — this test just validates the API surface.
        // We pass empty array so no network calls are made.
        var progressCalls: [(Int, Int)] = []
        let results = try await service.searchReadsBatch(
            accessions: [],
            concurrency: 5,
            progress: { completed, total in
                progressCalls.append((completed, total))
            }
        )
        XCTAssertTrue(results.isEmpty)
        XCTAssertTrue(progressCalls.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SRABatchLookupTests 2>&1 | tail -5`
Expected: Build error — `searchReadsBatch` not defined.

- [ ] **Step 3: Implement searchReadsBatch in ENAService**

In `Sources/LungfishCore/Services/ENA/ENAService.swift`, add after the existing `searchReadsByStudy` method (around line 280):

```swift
    // MARK: - Batch Lookup

    /// Looks up multiple SRA accessions in parallel, returning FASTQ metadata for each.
    ///
    /// Failed individual lookups are logged and skipped — they don't abort the batch.
    /// Results are returned in the same order as the input accessions.
    ///
    /// - Parameters:
    ///   - accessions: Array of SRR/ERR/DRR accessions to look up
    ///   - concurrency: Maximum number of concurrent ENA requests (default: 10)
    ///   - progress: Callback reporting (completedCount, totalCount) after each lookup
    /// - Returns: Array of ENAReadRecord for successfully resolved accessions
    public func searchReadsBatch(
        accessions: [String],
        concurrency: Int = 10,
        progress: @Sendable (Int, Int) -> Void
    ) async throws -> [ENAReadRecord] {
        guard !accessions.isEmpty else { return [] }

        let total = accessions.count
        // Use actor to track completed count safely
        let counter = BatchCounter()

        return try await withThrowingTaskGroup(of: (Int, [ENAReadRecord]).self) { group in
            var results = Array<[ENAReadRecord]?>(repeating: nil, count: total)
            var launched = 0
            var collected = 0

            // Launch initial batch up to concurrency limit
            for i in 0..<min(concurrency, total) {
                let accession = accessions[i]
                let index = i
                group.addTask {
                    do {
                        let records = try await self.searchReads(term: accession, limit: 100)
                        return (index, records)
                    } catch {
                        logger.warning("Batch lookup failed for \(accession): \(error.localizedDescription)")
                        return (index, [])
                    }
                }
                launched += 1
            }

            // Collect results and launch more as slots open
            for try await (index, records) in group {
                results[index] = records
                collected += 1
                let completedCount = await counter.increment()
                progress(completedCount, total)

                // Launch next task if any remain
                if launched < total {
                    let accession = accessions[launched]
                    let nextIndex = launched
                    group.addTask {
                        do {
                            let records = try await self.searchReads(term: accession, limit: 100)
                            return (nextIndex, records)
                        } catch {
                            logger.warning("Batch lookup failed for \(accession): \(error.localizedDescription)")
                            return (nextIndex, [])
                        }
                    }
                    launched += 1
                }
            }

            return results.compactMap { $0 }.flatMap { $0 }
        }
    }
```

Add the `BatchCounter` actor at the bottom of the file (before the final closing brace, or as a private type inside the file):

```swift
/// Thread-safe counter for tracking batch progress.
private actor BatchCounter {
    private var count = 0

    func increment() -> Int {
        count += 1
        return count
    }
}
```

Also add a logger at the top of the file if not already present (after the imports):

```swift
private let logger = Logger(subsystem: "com.lungfish.core", category: "ENAService")
```

And add `import os.log` to the imports if not already present.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SRABatchLookupTests 2>&1 | tail -5`
Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishCore/Services/ENA/ENAService.swift Tests/LungfishCoreTests/SRABatchLookupTests.swift
git commit -m "feat: add batch ENA lookup with parallel concurrency"
```

---

## Task 6: Two-Step Search Routing in performSearch

Wire the NCBI ESearch → EFetch → ENA batch pipeline into the `.ena` case of `performSearch()`.

**Files:**
- Modify: `Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserViewController.swift` (lines 1286-1313, the `.ena` case)

- [ ] **Step 1: Understand the current `.ena` search path**

Read `DatabaseBrowserViewController.swift` lines 1286-1313. The current code does:
```swift
case .ena:
    // ... sets searchPhase ...
    let readRecords = try await ena.searchReads(term: query.term, limit: query.limit, offset: query.offset)
    // ... converts to SearchResultRecord ...
```

This sends any query text directly to ENA filereport's `accession` parameter.

- [ ] **Step 2: Replace the .ena case with smart routing**

Replace the entire `case .ena:` block (lines 1286-1313) with:

```swift
                case .ena:
                    performOnMainRunLoop { [weak self] in
                        guard let self = self else { return }
                        self.objectWillChange.send()
                        self.searchPhase = .searching
                    }

                    let records: [SearchResultRecord]

                    // Detect multi-accession input (paste or CSV import)
                    let parsedAccessions = SRAAccessionParser.parseAccessionList(query.term)
                    if parsedAccessions.count >= 2 {
                        // Batch mode: multiple accessions pasted or imported
                        logger.info("performSearch: Batch mode with \(parsedAccessions.count) accessions")
                        performOnMainRunLoop { [weak self] in
                            guard let self = self else { return }
                            self.objectWillChange.send()
                            self.searchPhase = .loadingDetails
                        }

                        let readRecords = try await ena.searchReadsBatch(
                            accessions: parsedAccessions,
                            concurrency: 10,
                            progress: { [weak self] completed, total in
                                performOnMainRunLoop { [weak self] in
                                    guard let self = self else { return }
                                    self.objectWillChange.send()
                                    self.searchPhase = .loadingAllResults(loaded: completed, total: total)
                                }
                            }
                        )
                        records = readRecords.map { record in
                            SearchResultRecord(
                                id: record.runAccession,
                                accession: record.runAccession,
                                title: record.experimentTitle ?? "\(record.runAccession) - \(record.libraryStrategy ?? "Unknown") \(record.libraryLayout ?? "")",
                                organism: nil,
                                length: record.baseCount,
                                date: record.firstPublic,
                                source: .ena
                            )
                        }

                    } else if SRAAccessionParser.isSRAAccession(query.term.trimmingCharacters(in: .whitespaces)) {
                        // Single accession: direct ENA filereport (fast path)
                        logger.info("performSearch: Direct ENA lookup for single accession")
                        performOnMainRunLoop { [weak self] in
                            guard let self = self else { return }
                            self.objectWillChange.send()
                            self.searchPhase = .loadingDetails
                        }
                        let readRecords = try await ena.searchReads(term: query.term, limit: query.limit, offset: query.offset)
                        records = readRecords.map { record in
                            SearchResultRecord(
                                id: record.runAccession,
                                accession: record.runAccession,
                                title: record.experimentTitle ?? "\(record.runAccession) - \(record.libraryStrategy ?? "Unknown") \(record.libraryLayout ?? "")",
                                organism: nil,
                                length: record.baseCount,
                                date: record.firstPublic,
                                source: .ena
                            )
                        }

                    } else {
                        // Non-accession query (title, organism, bioproject, author, free text)
                        // Two-step: NCBI ESearch → EFetch run accessions → ENA batch lookup
                        logger.info("performSearch: Two-step NCBI ESearch → ENA for non-accession query")

                        // Step 1: ESearch SRA database
                        performOnMainRunLoop { [weak self] in
                            guard let self = self else { return }
                            self.objectWillChange.send()
                            self.searchPhase = .searching
                        }

                        // Build the SRA search term with any active advanced filters
                        var sraClauses: [String] = [query.term]
                        if let platformValue = capturedSRAPlatform?.entrezValue {
                            sraClauses.append("\(platformValue)[Platform]")
                        }
                        if let strategyValue = capturedSRAStrategy?.entrezValue {
                            sraClauses.append("\(strategyValue)[Strategy]")
                        }
                        if let layoutValue = capturedSRALayout?.entrezValue {
                            sraClauses.append("\(layoutValue)[Layout]")
                        }
                        if let minMb = capturedSRAMinMbases, !minMb.isEmpty, let mbVal = Int(minMb) {
                            sraClauses.append("\(mbVal):*[Mbases]")
                        }
                        let sraDateFrom = capturedSRAPubDateFrom ?? ""
                        let sraDateTo = capturedSRAPubDateTo ?? ""
                        if !sraDateFrom.isEmpty || !sraDateTo.isEmpty {
                            let lower = sraDateFrom.isEmpty ? "1900/01/01" : sraDateFrom
                            let upper = sraDateTo.isEmpty ? "3000/12/31" : sraDateTo
                            sraClauses.append("\(lower):\(upper)[Publication Date]")
                        }
                        let sraSearchTerm = sraClauses.joined(separator: " AND ")
                        logger.info("performSearch: SRA ESearch term = '\(sraSearchTerm, privacy: .public)'")

                        let esearchResult = try await ncbi.sraESearch(term: sraSearchTerm, retmax: min(query.limit, 200))
                        logger.info("performSearch: ESearch returned \(esearchResult.ids.count) UIDs out of \(esearchResult.totalCount) total")

                        guard !esearchResult.ids.isEmpty else {
                            records = []
                            break
                        }

                        try Task.checkCancellation()

                        // Step 2: EFetch to get SRR accessions
                        performOnMainRunLoop { [weak self] in
                            guard let self = self else { return }
                            self.objectWillChange.send()
                            self.searchPhase = .loadingDetails
                        }
                        let runAccessions = try await ncbi.sraEFetchRunAccessions(uids: esearchResult.ids)
                        logger.info("performSearch: EFetch resolved \(runAccessions.count) run accessions")

                        guard !runAccessions.isEmpty else {
                            records = []
                            break
                        }

                        try Task.checkCancellation()

                        // Step 3: Batch ENA lookup for FASTQ metadata
                        let readRecords = try await ena.searchReadsBatch(
                            accessions: runAccessions,
                            concurrency: 10,
                            progress: { [weak self] completed, total in
                                performOnMainRunLoop { [weak self] in
                                    guard let self = self else { return }
                                    self.objectWillChange.send()
                                    self.searchPhase = .loadingAllResults(loaded: completed, total: total)
                                }
                            }
                        )
                        records = readRecords.map { record in
                            SearchResultRecord(
                                id: record.runAccession,
                                accession: record.runAccession,
                                title: record.experimentTitle ?? "\(record.runAccession) - \(record.libraryStrategy ?? "Unknown") \(record.libraryLayout ?? "")",
                                organism: nil,
                                length: record.baseCount,
                                date: record.firstPublic,
                                source: .ena
                            )
                        }
                    }

                    searchResults = SearchResults(
                        totalCount: records.count,
                        records: records,
                        hasMore: false,
                        nextCursor: nil
                    )
                    logger.info("performSearch: ENA search returned \(records.count) results")
```

- [ ] **Step 3: Capture SRA filter values before Task.detached**

In `performSearch()`, before the `currentSearchTask = Task.detached` line (around line 1047), add captures for the SRA filter values:

```swift
        // Capture SRA-specific filters
        let capturedSRAPlatform: SRAPlatformFilter? = isSRASearch ? sraPlatformFilter : nil
        let capturedSRAStrategy: SRAStrategyFilter? = isSRASearch ? sraStrategyFilter : nil
        let capturedSRALayout: SRALayoutFilter? = isSRASearch ? sraLayoutFilter : nil
        let capturedSRAMinMbases: String? = isSRASearch ? sraMinMbases.trimmingCharacters(in: .whitespaces) : nil
        let capturedSRAPubDateFrom: String? = isSRASearch ? sraPubDateFrom.trimmingCharacters(in: .whitespaces) : nil
        let capturedSRAPubDateTo: String? = isSRASearch ? sraPubDateTo.trimmingCharacters(in: .whitespaces) : nil
```

- [ ] **Step 4: Add `import LungfishCore` if not already present**

The file needs access to `SRAAccessionParser` from LungfishCore. Check if `import LungfishCore` is already at the top — it should be since the file already uses `NCBIService` and `ENAService`.

- [ ] **Step 5: Build to verify compilation**

Run: `swift build --build-tests 2>&1 | tail -10`
Expected: Build succeeds.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserViewController.swift
git commit -m "feat: wire two-step NCBI→ENA search and batch mode into performSearch"
```

---

## Task 7: SRA Advanced Filters UI

Add the SRA-specific filter panel to the advanced search section.

**Files:**
- Modify: `Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserViewController.swift` (views section)

- [ ] **Step 1: Add the SRA filters grid view**

In `DatabaseBrowserViewController.swift`, add a new computed property after the existing `advancedFiltersGrid` view (around line 3300):

```swift
    // MARK: - SRA Filters Grid

    private var sraFiltersGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Platform and Strategy row
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Platform", systemImage: "cpu")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Picker("", selection: $viewModel.sraPlatformFilter) {
                        ForEach(SRAPlatformFilter.allCases) { platform in
                            Text(platform.rawValue).tag(platform)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 180)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Label("Strategy", systemImage: "list.bullet.rectangle")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Picker("", selection: $viewModel.sraStrategyFilter) {
                        ForEach(SRAStrategyFilter.allCases) { strategy in
                            Text(strategy.rawValue).tag(strategy)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 160)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Label("Layout", systemImage: "arrow.left.and.right")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Picker("", selection: $viewModel.sraLayoutFilter) {
                        ForEach(SRALayoutFilter.allCases) { layout in
                            Text(layout.rawValue).tag(layout)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 120)
                }

                Spacer()
            }

            // Min Mbases and Publication Date row
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Min Size (Mbases)", systemImage: "internaldrive")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("e.g., 10", text: $viewModel.sraMinMbases)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Label("Publication Date", systemImage: "calendar")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack(spacing: 8) {
                        TextField("From (YYYY/MM/DD)", text: $viewModel.sraPubDateFrom)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                        Text("to")
                            .foregroundColor(.secondary)
                        TextField("To (YYYY/MM/DD)", text: $viewModel.sraPubDateTo)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                    }
                }

                Spacer()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
```

- [ ] **Step 2: Wire the SRA filters grid into advancedSearchSection**

In the `advancedSearchSection` view (around line 2967), update the conditional to show SRA filters:

Change:
```swift
            if viewModel.isAdvancedExpanded {
                if viewModel.isPathoplexusSearch {
                    pathoplexusFiltersGrid
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else if viewModel.ncbiSearchType == .virus {
                    virusFiltersGrid
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    advancedFiltersGrid
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
```

To:
```swift
            if viewModel.isAdvancedExpanded {
                if viewModel.isPathoplexusSearch {
                    pathoplexusFiltersGrid
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else if viewModel.isSRASearch {
                    sraFiltersGrid
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else if viewModel.ncbiSearchType == .virus {
                    virusFiltersGrid
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    advancedFiltersGrid
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
```

- [ ] **Step 3: Build to verify compilation**

Run: `swift build --build-tests 2>&1 | tail -10`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserViewController.swift
git commit -m "feat: add SRA-specific advanced filters UI (platform, strategy, layout)"
```

---

## Task 8: CSV Import Button

Add the "Import List" button to the search bar for importing accession list files.

**Files:**
- Modify: `Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserViewController.swift`

- [ ] **Step 1: Add the import list method to the ViewModel**

In `DatabaseBrowserViewModel`, add a method (around line 970, after `clearFilters()`):

```swift
    /// Imports accession list from a CSV or text file.
    /// Opens NSOpenPanel, parses the file, and triggers batch search.
    func importAccessionList() {
        let panel = NSOpenPanel()
        panel.title = "Import Accession List"
        panel.allowedContentTypes = [
            .commaSeparatedText,
            .plainText,
            .init(filenameExtension: "csv")!
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let accessions = try SRAAccessionParser.parseCSVFile(at: url)
            if accessions.isEmpty {
                // Show alert for no valid accessions
                let alert = NSAlert()
                alert.messageText = "No Valid Accessions"
                alert.informativeText = "No valid SRA accessions were found in the selected file."
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return
            }

            logger.info("importAccessionList: Parsed \(accessions.count) accessions from \(url.lastPathComponent)")

            // Set search text to the parsed accessions and trigger search
            searchText = accessions.joined(separator: "\n")
            searchScope = .accession
            performSearch()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Import Failed"
            alert.informativeText = "Could not read the file: \(error.localizedDescription)"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
```

- [ ] **Step 2: Add the Import List button to the search bar**

In the `primarySearchBar` view (around line 2812, after the clear button's closing brace), add:

```swift
                // Import accession list button (SRA only)
                if viewModel.isSRASearch {
                    Button {
                        viewModel.importAccessionList()
                    } label: {
                        Image(systemName: "doc.badge.plus")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Import accession list from CSV or text file")
                }
```

- [ ] **Step 3: Build to verify compilation**

Run: `swift build --build-tests 2>&1 | tail -10`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserViewController.swift
git commit -m "feat: add CSV/text accession list import button for SRA search"
```

---

## Task 9: Test Fixtures and Integration Tests

Record real API responses as fixtures and write integration tests.

**Files:**
- Create: `Tests/Fixtures/sra/drr028938-ena-response.json`
- Create: `Tests/Fixtures/sra/sample-accession-list.csv`
- Create: `Tests/LungfishIntegrationTests/SRASearchIntegrationTests.swift`

- [ ] **Step 1: Create test fixture files**

Create `Tests/Fixtures/sra/sample-accession-list.csv`:

```csv
acc
DRR028938
DRR051810
DRR052292
```

- [ ] **Step 2: Write integration tests**

Create `Tests/LungfishIntegrationTests/SRASearchIntegrationTests.swift`:

```swift
// SRASearchIntegrationTests.swift - Live API integration tests for SRA search
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// These tests hit real NCBI/ENA APIs and may be slow or flaky.
// Skip in CI by filtering: swift test --skip SRASearchIntegrationTests

import XCTest
@testable import LungfishCore

final class SRASearchIntegrationTests: XCTestCase {

    private var enaService: ENAService!
    private var ncbiService: NCBIService!

    override func setUp() async throws {
        try await super.setUp()
        enaService = ENAService()
        ncbiService = NCBIService()
    }

    // MARK: - Single Accession via ENA

    func testSingleAccessionViaENA() async throws {
        // DRR028938: 631 reads, paired-end, Illumina HiSeq 2500
        let records = try await enaService.searchReads(term: "DRR028938", limit: 10)
        XCTAssertFalse(records.isEmpty, "Should find DRR028938 in ENA")

        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.runAccession, "DRR028938")
        XCTAssertEqual(record.libraryLayout, "PAIRED")
        XCTAssertEqual(record.instrumentPlatform, "ILLUMINA")
        XCTAssertNotNil(record.readCount)
        XCTAssertNotNil(record.fastqFTP, "Should have FASTQ download URLs")
    }

    // MARK: - Batch Lookup

    func testBatchThreeAccessions() async throws {
        let accessions = ["DRR028938", "DRR051810", "DRR052292"]
        var progressUpdates: [(Int, Int)] = []

        let records = try await enaService.searchReadsBatch(
            accessions: accessions,
            concurrency: 3,
            progress: { completed, total in
                progressUpdates.append((completed, total))
            }
        )

        XCTAssertGreaterThanOrEqual(records.count, 2, "Should resolve at least 2 of 3 accessions")

        // Progress should have been reported
        XCTAssertFalse(progressUpdates.isEmpty, "Should report progress")
        if let last = progressUpdates.last {
            XCTAssertEqual(last.1, 3, "Total should be 3")
        }
    }

    // MARK: - NCBI SRA ESearch

    func testSRAESearchByOrganism() async throws {
        let result = try await ncbiService.sraESearch(term: "SARS-CoV-2[Organism]", retmax: 5)
        XCTAssertGreaterThan(result.totalCount, 0, "Should find SRA entries for SARS-CoV-2")
        XCTAssertFalse(result.ids.isEmpty)
    }

    func testSRAESearchByBioProject() async throws {
        // PRJNA989177 is CDC Traveler-Based Genomic Surveillance
        let result = try await ncbiService.sraESearch(term: "PRJNA989177[BioProject]", retmax: 5)
        XCTAssertGreaterThan(result.totalCount, 100, "Should find many entries in PRJNA989177")
        XCTAssertFalse(result.ids.isEmpty)
    }

    // MARK: - Two-Step: ESearch → EFetch → Run Accessions

    func testESearchToEFetchRunAccessions() async throws {
        // Search for a specific small BioProject
        let esearchResult = try await ncbiService.sraESearch(term: "PRJDB3502[BioProject]", retmax: 10)
        XCTAssertGreaterThan(esearchResult.ids.count, 0, "Should find entries")

        let runAccessions = try await ncbiService.sraEFetchRunAccessions(uids: Array(esearchResult.ids.prefix(5)))
        XCTAssertGreaterThan(runAccessions.count, 0, "Should resolve to run accessions")

        // Run accessions should match SRA pattern
        for acc in runAccessions {
            XCTAssertTrue(SRAAccessionParser.isSRAAccession(acc),
                         "\(acc) should be a valid SRA accession")
        }
    }

    // MARK: - CSV Fixture Parsing

    func testParseFixtureCSV() throws {
        let fixtureURL = Bundle.module.url(forResource: "sample-accession-list", withExtension: "csv", subdirectory: "sra")
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/sra/sample-accession-list.csv")

        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw XCTSkip("Fixture file not found at \(fixtureURL.path)")
        }

        let accessions = try SRAAccessionParser.parseCSVFile(at: fixtureURL)
        XCTAssertEqual(accessions, ["DRR028938", "DRR051810", "DRR052292"])
    }
}
```

- [ ] **Step 3: Run integration tests**

Run: `swift test --filter SRASearchIntegrationTests 2>&1 | tail -10`
Expected: Tests pass (requires network). If NCBI/ENA is down, tests may fail — that's expected.

- [ ] **Step 4: Commit**

```bash
git add Tests/Fixtures/sra/sample-accession-list.csv Tests/LungfishIntegrationTests/SRASearchIntegrationTests.swift
git commit -m "test: add SRA search integration tests and fixture CSV"
```

---

## Task 10: Full Build and Test Verification

Run the complete test suite to verify nothing is broken.

**Files:** None (verification only)

- [ ] **Step 1: Build all targets**

Run: `swift build --build-tests 2>&1 | tail -10`
Expected: Build succeeds with no errors.

- [ ] **Step 2: Run all existing tests**

Run: `swift test 2>&1 | tail -20`
Expected: All tests pass. The new SRA tests should appear in the output.

- [ ] **Step 3: Run just the new SRA tests**

Run: `swift test --filter SRAAccessionParserTests --filter SRAEFetchParsingTests --filter SRABatchLookupTests 2>&1 | tail -10`
Expected: All new unit tests pass.

- [ ] **Step 4: Final commit if any fixups were needed**

If any compilation or test issues were found and fixed:
```bash
git add -A
git commit -m "fix: address test/build issues from SRA search enhancement"
```
