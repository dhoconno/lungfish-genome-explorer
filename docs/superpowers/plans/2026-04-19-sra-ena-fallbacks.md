# SRA ENA Fallbacks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep recent SRA runs usable when ENA reports placeholder zero metadata or omits FASTQ links by falling back to NCBI runinfo for search metadata and SRA Toolkit for downloads.

**Architecture:** The app's ENA/SRA search path will merge ENA `read_run` records with NCBI `runinfo` metadata on accession, preferring ENA when it has real values and falling back to NCBI when ENA returns zero/empty placeholders. The download path will stop hard-failing on missing ENA FASTQ URLs by delegating raw FASTQ acquisition to `LungfishCore.SRAService`, which will try ENA first and then fall back to `prefetch` plus `fasterq-dump` when ENA has no FASTQ files but the managed `sra-tools` environment is available.

**Tech Stack:** Swift, XCTest, AppKit/SwiftUI app code in `LungfishApp`, service code in `LungfishCore`, managed tools via `LungfishWorkflow`.

---

### Task 1: Add regression tests for SRA metadata fallback

**Files:**
- Modify: `Tests/LungfishAppTests/DatabaseBrowserViewModelTests.swift`
- Modify: `Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserViewController.swift`

- [ ] **Step 1: Write the failing test for ENA zero metadata merged with NCBI runinfo**

```swift
func testSRASearchUsesNCBIBasesWhenENAReportsZeroMetadata() async throws {
    let mockClient = MockHTTPClient()
    let ncbi = NCBIService(httpClient: mockClient)
    let ena = ENAService(httpClient: mockClient)

    await mockClient.register(
        pattern: "esearch.fcgi",
        response: .text(#"{"esearchresult":{"count":"1","idlist":["44036162"]}}"#)
    )
    await mockClient.register(
        pattern: "efetch.fcgi",
        response: .text("""
        Run,ReleaseDate,LoadDate,spots,bases,spots_with_mates,avgLength,size_MB,AssemblyName,download_path,Experiment,LibraryName,LibraryStrategy,LibrarySelection,LibrarySource,LibraryLayout,InsertSize,InsertDev,Platform,Model,SRAStudy,BioProject,Study_Pubmed_id,ProjectID,Sample,BioSample,SampleType,TaxID,ScientificName,SampleName,g1k_pop_code,source,g1k_analysis_group,Subject_ID,Sex,Disease,Tumor,Affection_Status,Analyte_Type,Histological_Type,Body_Site,CenterName,Submission,dbgap_study_accession,Consent,RunHash,ReadHash
        SRR38099052,2026-04-14 14:09:49,2026-04-14 14:07:16,19482145,3896429000,19482145,200,2481,,https://example.invalid/SRR38099052.sra,SRX32946020,COVID-19 WGS,AMPLICON,RT-PCR,VIRAL RNA,PAIRED,0,0,ELEMENT,Element AVITI,SRP446588,PRJNA989177,,989177,SRS28785912,SAMN57267219,simple,2697049,Severe acute respiratory syndrome coronavirus 2,SARS-CoV-2/human/USA/CA-GBW-AVWWAAA13329/2026,,,,,,,no,,,,,GBW,SRA2374150,,public,hash,hash
        """)
    )
    await mockClient.register(
        pattern: "portal/api/filereport",
        response: .json([[
            "run_accession": "SRR38099052",
            "experiment_title": "COVID-19 WGS",
            "library_layout": "PAIRED",
            "library_strategy": "AMPLICON",
            "instrument_platform": "ELEMENT",
            "base_count": "0",
            "read_count": "0",
            "fastq_ftp": "",
            "fastq_bytes": "",
            "first_public": "2026-04-16"
        ]])
    )

    let viewModel = DatabaseBrowserViewModel(source: .ena, ncbiService: ncbi, enaService: ena)
    viewModel.searchText = "PRJNA989177"
    viewModel.performSearch()

    try await Task.sleep(nanoseconds: 500_000_000)

    let record = try XCTUnwrap(viewModel.results.first)
    XCTAssertEqual(record.accession, "SRR38099052")
    XCTAssertEqual(record.length, 3_896_429_000)
}
```

- [ ] **Step 2: Run the single test to verify it fails**

Run: `swift test --filter DatabaseBrowserViewModelTests/testSRASearchUsesNCBIBasesWhenENAReportsZeroMetadata`

Expected: FAIL because `DatabaseBrowserViewModel` cannot yet accept injected services and the result length remains `0`.

- [ ] **Step 3: Add minimal app-side merge support**

```swift
init(
    source: DatabaseSource,
    ncbiService: NCBIService = NCBIService(),
    enaService: ENAService = ENAService()
) {
    self.source = source
    self.ncbiService = ncbiService
    self.enaService = enaService
    loadSearchHistory()
}

private func mergedSRARecord(
    enaRecord: ENAReadRecord,
    ncbiRun: SRARunInfo?
) -> SearchResultRecord {
    let effectiveBaseCount = {
        if let baseCount = enaRecord.baseCount, baseCount > 0 { return baseCount }
        return ncbiRun?.bases
    }()

    return SearchResultRecord(
        id: enaRecord.runAccession,
        accession: enaRecord.runAccession,
        title: enaRecord.experimentTitle ?? "\(enaRecord.runAccession) - \(enaRecord.libraryStrategy ?? "Unknown") \(enaRecord.libraryLayout ?? "")",
        organism: ncbiRun?.organism,
        length: effectiveBaseCount,
        date: enaRecord.firstPublic ?? ncbiRun?.releaseDate,
        source: .ena
    )
}
```

- [ ] **Step 4: Update the non-accession SRA path to fetch NCBI runinfo and use the merge helper**

```swift
let runInfos = try await ncbi.sraEFetchRunInfo(uids: esearchResult.ids)
let runInfoByAccession = Dictionary(uniqueKeysWithValues: runInfos.map { ($0.accession, $0) })

records = readRecords.map { record in
    mergedSRARecord(enaRecord: record, ncbiRun: runInfoByAccession[record.runAccession])
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --filter DatabaseBrowserViewModelTests/testSRASearchUsesNCBIBasesWhenENAReportsZeroMetadata`

Expected: PASS with `record.length == 3896429000`.

- [ ] **Step 6: Commit**

```bash
git add Tests/LungfishAppTests/DatabaseBrowserViewModelTests.swift Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserViewController.swift
git commit -m "fix: fallback to ncbi metadata for zeroed ena sra records"
```

### Task 2: Add regression tests for ENA download fallback to SRA Toolkit

**Files:**
- Modify: `Tests/LungfishCoreTests/Services/Mocks/MockHTTPClient.swift`
- Modify: `Tests/LungfishCoreTests/SRAServicePathTests.swift`
- Modify: `Tests/LungfishCoreTests/Services/ENAServiceTests.swift`
- Modify: `Sources/LungfishCore/Services/NCBI/SRAService.swift`

- [ ] **Step 1: Write the failing test for ENA-missing FASTQ fallback**

```swift
func testDownloadFASTQPrefersToolkitWhenENAHasNoFASTQURLs() async throws {
    let mockClient = MockHTTPClient()
    let home = makeTemporaryHomeDirectory()
    try makeFakeExecutable(
        at: home.appendingPathComponent(".lungfish/conda/envs/sra-tools/bin/prefetch"),
        body: "#!/bin/sh\nmkdir -p \"$2/$1\" && touch \"$2/$1/$1.sra\"\n"
    )
    try makeFakeExecutable(
        at: home.appendingPathComponent(".lungfish/conda/envs/sra-tools/bin/fasterq-dump"),
        body: "#!/bin/sh\noutdir=\"$3\"; touch \"$outdir/SRR000001_1.fastq\"; touch \"$outdir/SRR000001_2.fastq\"\n"
    )

    await mockClient.register(
        pattern: "portal/api/filereport",
        response: .json([[
            "run_accession": "SRR000001",
            "base_count": "0",
            "read_count": "0",
            "fastq_ftp": "",
            "fastq_bytes": ""
        ]])
    )

    let service = SRAService(
        ncbiService: NCBIService(httpClient: mockClient),
        httpClient: mockClient,
        homeDirectoryProvider: { home }
    )

    let outputDir = home.appendingPathComponent("downloads", isDirectory: true)
    let files = try await service.downloadFASTQPreferENA(accession: "SRR000001", outputDir: outputDir)

    XCTAssertEqual(files.map(\\.lastPathComponent).sorted(), ["SRR000001_1.fastq", "SRR000001_2.fastq"])
}
```

- [ ] **Step 2: Run the single test to verify it fails**

Run: `swift test --filter SRAServicePathTests/testDownloadFASTQPrefersToolkitWhenENAHasNoFASTQURLs`

Expected: FAIL because `downloadFASTQPreferENA` does not exist yet.

- [ ] **Step 3: Add the minimal fallback API in `SRAService`**

```swift
public func downloadFASTQPreferENA(
    accession: String,
    outputDir: URL? = nil,
    progress: (@Sendable (Double) -> Void)? = nil
) async throws -> [URL] {
    do {
        let files = try await downloadFASTQFromENA(
            accession: accession,
            outputDir: outputDir,
            progress: progress
        )
        if !files.isEmpty { return files }
    } catch {
        guard isSRAToolkitAvailable else { throw error }
        logger.warning("ENA download unavailable for \(accession, privacy: .public); falling back to SRA Toolkit")
    }

    return try await downloadFASTQ(
        accession: accession,
        outputDir: outputDir,
        progress: progress
    )
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter SRAServicePathTests/testDownloadFASTQPrefersToolkitWhenENAHasNoFASTQURLs`

Expected: PASS with two local FASTQ files created by the fake toolkit executables.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishCore/Services/NCBI/SRAService.swift Tests/LungfishCoreTests/SRAServicePathTests.swift
git commit -m "fix: fallback to sra toolkit when ena lacks fastq files"
```

### Task 3: Switch the app download path to use the consolidated SRA fallback

**Files:**
- Modify: `Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserViewController.swift`
- Test: `Tests/LungfishAppTests/DatabaseBrowserViewModelTests.swift`

- [ ] **Step 1: Replace the ENA-only raw download block with `SRAService.downloadFASTQPreferENA`**

```swift
let sraService = SRAService(ncbiService: ncbiService)
let downloadedFASTQFiles = try await sraService.downloadFASTQPreferENA(
    accession: record.accession,
    outputDir: batchDir,
    progress: { progress in
        performOnMainRunLoop {
            DownloadCenter.shared.update(
                id: downloadCenterTaskID,
                progress: progressFraction + (progress / Double(totalCount)),
                detail: "Downloading \(record.accession)..."
            )
        }
    }
)
```

- [ ] **Step 2: Preserve provenance metadata based on the actual source**

```swift
metadata.enaReadRecord = readRecord
metadata.downloadDate = Date()
metadata.downloadSource = readRecord.fastqHTTPURLs.isEmpty ? "SRA Toolkit" : "ENA"
metadata.sequencingPlatform = confirmedPlatform
```

- [ ] **Step 3: Run focused tests for the app and core paths**

Run: `swift test --filter DatabaseBrowserViewModelTests`
Run: `swift test --filter SRAServicePathTests`
Run: `swift test --filter ENAServiceTests`

Expected: PASS for the new regression tests and no failures in the touched suites.

- [ ] **Step 4: Commit**

```bash
git add Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserViewController.swift Sources/LungfishCore/Services/NCBI/SRAService.swift Tests/LungfishAppTests/DatabaseBrowserViewModelTests.swift Tests/LungfishCoreTests/SRAServicePathTests.swift
git commit -m "fix: keep sra results downloadable when ena metadata is incomplete"
```
