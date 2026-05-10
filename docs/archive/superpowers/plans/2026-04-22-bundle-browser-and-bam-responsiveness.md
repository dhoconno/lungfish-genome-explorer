# Bundle Browser and BAM Responsiveness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the old chromosome drawer with a default list/detail browser for every `.lungfishref` bundle and keep BAM-backed detail views responsive by switching to coverage-only rendering until the viewport is zoomed in enough for read-level detail to matter.

**Design input:** `/Users/dho/Documents/lungfish-genome-explorer/.worktrees/fasta-fastq-bridge/docs/superpowers/specs/2026-04-22-bundle-browser-and-bam-responsiveness-design.md`

**Architecture:** Add a typed `browser_summary` section to `BundleManifest` so Lungfish-written bundles carry an immediate open-time row cache. Layer a project-local SQLite mirror on top for legacy bundles and richer local metrics without mutating shared external manifests during open. Route bundle viewing through an explicit `BundleDisplayMode` so top-level bundle opens land in a new `BundleBrowserViewController`, while embedded mapping viewers still jump directly into sequence detail. Tighten BAM rendering with a dedicated read-visibility policy that treats coverage as the default zoomed-out mode and proactively drops read-level work when it is visually meaningless.

**Tech Stack:** Swift, AppKit, LungfishCore bundle models, LungfishIO alignment metadata databases and project-root helpers, SQLite3, XCTest, XCUI, `swift test`, `xcodebuild`.

---

## File Structure

### Bundle Browser Manifest Contract

- Create: `Sources/LungfishCore/Bundles/BundleBrowserSummary.swift`
- Modify: `Sources/LungfishCore/Bundles/BundleManifest.swift`
- Test: `Tests/LungfishCoreTests/BundleManifestTests.swift`

### Bundle Browser Loading, Variant Synthesis, and SQLite Mirror

- Create: `Sources/LungfishApp/Services/BundleSequenceSummarySynthesizer.swift`
- Create: `Sources/LungfishApp/Services/BundleBrowserMirrorStore.swift`
- Create: `Sources/LungfishApp/Services/BundleBrowserLoader.swift`
- Test: `Tests/LungfishAppTests/BundleBrowserLoaderTests.swift`

### Bundle Browser UI and Viewer Routing

- Create: `Sources/LungfishApp/Views/Viewer/BundleBrowserViewController.swift`
- Create: `Sources/LungfishApp/Views/Viewer/BundleDisplayMode.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+BundleDisplay.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`
- Test: `Tests/LungfishAppTests/BundleBrowserViewControllerTests.swift`
- Test: `Tests/LungfishAppTests/BundleViewerTests.swift`

### Mapping Shell Integration

- Modify: `Sources/LungfishApp/Views/Results/Mapping/MappingResultViewController.swift`
- Modify: `Tests/LungfishAppTests/MappingResultViewControllerTests.swift`
- Modify: `Tests/LungfishAppTests/MappingViewportRoutingTests.swift`

### BAM Read-Visibility Policy

- Create: `Sources/LungfishApp/Views/Viewer/ReadViewportPolicy.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ReadTrackRenderer.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/SequenceViewerView.swift`
- Modify: `Tests/LungfishAppTests/ReadTrackRendererTests.swift`
- Create: `Tests/LungfishAppTests/SequenceViewerReadVisibilityTests.swift`

### XCUI and Deterministic Fixtures

- Create: `Tests/LungfishXCUITests/BundleBrowserXCUITests.swift`
- Create: `Tests/LungfishXCUITests/TestSupport/BundleBrowserRobot.swift`
- Modify: `Tests/LungfishXCUITests/TestSupport/LungfishProjectFixtureBuilder.swift`
- Modify: `Tests/LungfishXCUITests/MappingXCUITests.swift`
- Modify: `Tests/LungfishXCUITests/TestSupport/MappingRobot.swift`
- Modify: `Tests/LungfishAppTests/AppUITestMappingBackendTests.swift`

This split keeps the manifest contract in `LungfishCore`, the open-time loading/cache logic in `LungfishApp`, the routing/UI work in the viewer layer, and the BAM responsiveness rules isolated enough to test without the entire window shell.

---

## Task 1: Add a Typed Bundle Browser Summary to `BundleManifest`

**Files:**

- Create: `Sources/LungfishCore/Bundles/BundleBrowserSummary.swift`
- Modify: `Sources/LungfishCore/Bundles/BundleManifest.swift`
- Test: `Tests/LungfishCoreTests/BundleManifestTests.swift`

- [ ] **Step 1: Write the failing manifest tests**

Add these tests to `Tests/LungfishCoreTests/BundleManifestTests.swift`:

```swift
func testSaveSynthesizesBrowserSummaryFromGenomeChromosomes() throws {
    let bundleURL = tempDirectory.appendingPathComponent("browser-summary.lungfishref", isDirectory: true)
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

    let manifest = BundleManifest(
        name: "Fixture",
        identifier: "org.test.fixture",
        source: SourceInfo(organism: "Test organism", assembly: "fixture"),
        genome: GenomeInfo(
            path: "genome/sequence.fa.gz",
            indexPath: "genome/sequence.fa.gz.fai",
            totalLength: 300,
            chromosomes: [
                ChromosomeInfo(name: "chr1", length: 200, offset: 0, lineBases: 80, lineWidth: 81, aliases: ["1"], isPrimary: true, isMitochondrial: false, fastaDescription: "primary"),
                ChromosomeInfo(name: "chrM", length: 100, offset: 201, lineBases: 80, lineWidth: 81, aliases: ["MT"], isPrimary: false, isMitochondrial: true, fastaDescription: "mitochondrion")
            ]
        )
    )

    try manifest.save(to: bundleURL)
    let loaded = try BundleManifest.load(from: bundleURL)

    XCTAssertEqual(loaded.browserSummary?.schemaVersion, 1)
    XCTAssertEqual(loaded.browserSummary?.sequences.map(\.name), ["chr1", "chrM"])
    XCTAssertEqual(loaded.browserSummary?.sequences.last?.aliases, ["MT"])
    XCTAssertEqual(loaded.browserSummary?.aggregate.alignmentTrackCount, 0)
}

func testBundleManifestDecodesWithoutBrowserSummaryForLegacyBundles() throws {
    let legacyJSON = """
    {
      "format_version": "1.0",
      "name": "Legacy",
      "identifier": "org.test.legacy",
      "created_date": "2026-04-22T00:00:00Z",
      "modified_date": "2026-04-22T00:00:00Z",
      "source": { "organism": "Legacy", "assembly": "legacy" },
      "genome": {
        "path": "genome/sequence.fa.gz",
        "index_path": "genome/sequence.fa.gz.fai",
        "total_length": 10,
        "chromosomes": [
          { "name": "chr1", "length": 10, "offset": 0, "line_bases": 10, "line_width": 11, "aliases": [], "is_primary": true, "is_mitochondrial": false }
        ]
      },
      "annotations": [],
      "variants": [],
      "tracks": [],
      "alignments": []
    }
    """.data(using: .utf8)!

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(BundleManifest.self, from: legacyJSON)
    XCTAssertNil(decoded.browserSummary)
}
```

- [ ] **Step 2: Run the manifest tests and confirm they fail for the new field**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/fasta-fastq-bridge --filter BundleManifestTests
```

Expected: failures because `BundleManifest` does not yet expose `browserSummary` and `save(to:)` does not synthesize one.

- [ ] **Step 3: Add the browser summary types**

Create `Sources/LungfishCore/Bundles/BundleBrowserSummary.swift`:

```swift
import Foundation

public struct BundleBrowserSummary: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let aggregate: Aggregate
    public let sequences: [BundleBrowserSequenceSummary]

    public struct Aggregate: Codable, Sendable, Equatable {
        public let annotationTrackCount: Int
        public let variantTrackCount: Int
        public let alignmentTrackCount: Int
        public let totalMappedReads: Int64?
    }
}

public struct BundleBrowserSequenceSummary: Codable, Sendable, Equatable, Identifiable {
    public let name: String
    public var id: String { name }
    public let displayDescription: String?
    public let length: Int64
    public let aliases: [String]
    public let isPrimary: Bool
    public let isMitochondrial: Bool
    public let metrics: BundleBrowserSequenceMetrics?
}

public struct BundleBrowserSequenceMetrics: Codable, Sendable, Equatable {
    public let mappedReads: Int64?
    public let mappedPercent: Double?
    public let meanDepth: Double?
    public let coverageBreadth: Double?
    public let medianMAPQ: Double?
    public let meanIdentity: Double?
}
```

- [ ] **Step 4: Thread the optional field through `BundleManifest` and synthesize it on save**

Update `Sources/LungfishCore/Bundles/BundleManifest.swift`:

```swift
public let browserSummary: BundleBrowserSummary?

public init(
    formatVersion: String = "1.0",
    name: String,
    identifier: String,
    description: String? = nil,
    originBundlePath: String? = nil,
    createdDate: Date = Date(),
    modifiedDate: Date = Date(),
    source: SourceInfo,
    genome: GenomeInfo? = nil,
    annotations: [AnnotationTrackInfo] = [],
    variants: [VariantTrackInfo] = [],
    tracks: [SignalTrackInfo] = [],
    alignments: [AlignmentTrackInfo] = [],
    metadata: [MetadataGroup]? = nil,
    browserSummary: BundleBrowserSummary? = nil
) {
    self.formatVersion = formatVersion
    self.name = name
    self.identifier = identifier
    self.description = description
    self.originBundlePath = originBundlePath
    self.createdDate = createdDate
    self.modifiedDate = modifiedDate
    self.source = source
    self.genome = genome
    self.annotations = annotations
    self.variants = variants
    self.tracks = tracks
    self.alignments = alignments
    self.metadata = metadata
    self.browserSummary = browserSummary
}

public func withSynthesizedBrowserSummaryIfNeeded() -> BundleManifest {
    guard browserSummary == nil, let genome else { return self }
    let synthesized = BundleBrowserSummary(
        schemaVersion: 1,
        aggregate: .init(
            annotationTrackCount: annotations.count,
            variantTrackCount: variants.count,
            alignmentTrackCount: alignments.count,
            totalMappedReads: alignments.compactMap(\.mappedReadCount).reduce(0, +)
        ),
        sequences: genome.chromosomes.map {
            BundleBrowserSequenceSummary(
                name: $0.name,
                displayDescription: $0.fastaDescription,
                length: $0.length,
                aliases: $0.aliases,
                isPrimary: $0.isPrimary,
                isMitochondrial: $0.isMitochondrial,
                metrics: nil
            )
        }
    )
    return BundleManifest(
        formatVersion: formatVersion,
        name: name,
        identifier: identifier,
        description: description,
        originBundlePath: originBundlePath,
        createdDate: createdDate,
        modifiedDate: modifiedDate,
        source: source,
        genome: genome,
        annotations: annotations,
        variants: variants,
        tracks: tracks,
        alignments: alignments,
        metadata: metadata,
        browserSummary: synthesized
    )
}

public func save(to bundleURL: URL) throws {
    let manifestURL = bundleURL.appendingPathComponent(Self.filename)
    let data = try encoder.encode(withSynthesizedBrowserSummaryIfNeeded())
    try data.write(to: manifestURL)
}
```

- [ ] **Step 5: Re-run the manifest tests**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/fasta-fastq-bridge --filter BundleManifestTests
```

Expected: pass.

- [ ] **Step 6: Commit the manifest contract**

```bash
git -C /Users/dho/Documents/lungfish-genome-explorer/.worktrees/fasta-fastq-bridge add \
  Sources/LungfishCore/Bundles/BundleBrowserSummary.swift \
  Sources/LungfishCore/Bundles/BundleManifest.swift \
  Tests/LungfishCoreTests/BundleManifestTests.swift
git -C /Users/dho/Documents/lungfish-genome-explorer/.worktrees/fasta-fastq-bridge commit -m "Add bundle browser summary manifest contract"
```

---

## Task 2: Add the Bundle Browser Loader, Variant Synthesizer, and Project-Local SQLite Mirror

**Files:**

- Create: `Sources/LungfishApp/Services/BundleSequenceSummarySynthesizer.swift`
- Create: `Sources/LungfishApp/Services/BundleBrowserMirrorStore.swift`
- Create: `Sources/LungfishApp/Services/BundleBrowserLoader.swift`
- Test: `Tests/LungfishAppTests/BundleBrowserLoaderTests.swift`

- [ ] **Step 1: Write failing loader tests for manifest precedence, mirror fallback, and variant synthesis**

Create `Tests/LungfishAppTests/BundleBrowserLoaderTests.swift` with:

```swift
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO

final class BundleBrowserLoaderTests: XCTestCase {
    func testLoaderPrefersManifestSummaryOverSQLiteMirror() throws {
        let fixture = try makeBundleFixture()
        let mirrorStore = try BundleBrowserMirrorStore(projectURL: fixture.projectURL)
        try mirrorStore.upsert(
            summary: BundleBrowserSummary(
                schemaVersion: 1,
                aggregate: .init(annotationTrackCount: 0, variantTrackCount: 0, alignmentTrackCount: 0, totalMappedReads: nil),
                sequences: [BundleBrowserSequenceSummary(name: "mirror-only", displayDescription: nil, length: 10, aliases: [], isPrimary: true, isMitochondrial: false, metrics: nil)]
            ),
            bundleKey: BundleBrowserLoader.bundleKey(for: fixture.bundleURL, manifest: fixture.manifest)
        )

        let loader = BundleBrowserLoader(mirrorStoreFactory: { _ in mirrorStore })
        let result = try loader.load(bundleURL: fixture.bundleURL, manifest: fixture.manifest)

        XCTAssertEqual(result.source, .manifest)
        XCTAssertEqual(result.summary.sequences.map(\.name), ["chr1", "chr2"])
    }

func testLoaderFallsBackToMirrorThenSynthesizedSummary() throws {
        let fixture = try makeBundleFixture(withManifestSummary: false)
        let mirrorStore = try BundleBrowserMirrorStore(projectURL: fixture.projectURL)
        let mirrorSummary = BundleBrowserSummary(
            schemaVersion: 1,
            aggregate: .init(annotationTrackCount: 1, variantTrackCount: 0, alignmentTrackCount: 0, totalMappedReads: nil),
            sequences: [BundleBrowserSequenceSummary(name: "cached-chr", displayDescription: "cached", length: 50, aliases: [], isPrimary: true, isMitochondrial: false, metrics: nil)]
        )
        try mirrorStore.upsert(summary: mirrorSummary, bundleKey: BundleBrowserLoader.bundleKey(for: fixture.bundleURL, manifest: fixture.manifest))

        let loader = BundleBrowserLoader(mirrorStoreFactory: { _ in mirrorStore })
        let cached = try loader.load(bundleURL: fixture.bundleURL, manifest: fixture.manifest)
        XCTAssertEqual(cached.source, .mirror)
        XCTAssertEqual(cached.summary.sequences.map(\.name), ["cached-chr"])

        try mirrorStore.delete(bundleKey: BundleBrowserLoader.bundleKey(for: fixture.bundleURL, manifest: fixture.manifest))
        let synthesized = try loader.load(bundleURL: fixture.bundleURL, manifest: fixture.manifest)
        XCTAssertEqual(synthesized.source, .synthesized)
        XCTAssertEqual(synthesized.summary.sequences.map(\.name), ["chr1", "chr2"])
    }

    func testLoaderSynthesizesVariantOnlyRowsWhenGenomeIsMissing() throws {
        let fixture = try makeVariantOnlyBundleFixture()
        let loader = BundleBrowserLoader(
            mirrorStoreFactory: { _ in try BundleBrowserMirrorStore(projectURL: fixture.projectURL) },
            synthesizer: { _, manifest in
                XCTAssertNil(manifest.genome)
                return BundleBrowserSummary(
                    schemaVersion: 1,
                    aggregate: .init(annotationTrackCount: 0, variantTrackCount: 1, alignmentTrackCount: 0, totalMappedReads: nil),
                    sequences: [
                        BundleBrowserSequenceSummary(name: "scaffold_1", displayDescription: "synthesized from variants", length: 500, aliases: [], isPrimary: false, isMitochondrial: false, metrics: nil)
                    ]
                )
            }
        )

        let result = try loader.load(bundleURL: fixture.bundleURL, manifest: fixture.manifest)

        XCTAssertEqual(result.source, .synthesized)
        XCTAssertEqual(result.summary.sequences.map(\.name), ["scaffold_1"])
        XCTAssertEqual(result.summary.aggregate.variantTrackCount, 1)
    }

    private func makeBundleFixture(withManifestSummary: Bool = true) throws -> (projectURL: URL, bundleURL: URL, manifest: BundleManifest) {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bundle-browser-loader-\(UUID().uuidString).lungfish", isDirectory: true)
        let bundleURL = projectURL.appendingPathComponent("Reference Sequences/TestGenome.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let summary = withManifestSummary
            ? BundleBrowserSummary(
                schemaVersion: 1,
                aggregate: .init(annotationTrackCount: 1, variantTrackCount: 0, alignmentTrackCount: 0, totalMappedReads: nil),
                sequences: [
                    BundleBrowserSequenceSummary(name: "chr1", displayDescription: "primary", length: 200, aliases: ["1"], isPrimary: true, isMitochondrial: false, metrics: nil),
                    BundleBrowserSequenceSummary(name: "chr2", displayDescription: "secondary", length: 120, aliases: ["2"], isPrimary: true, isMitochondrial: false, metrics: nil)
                ]
            )
            : nil

        let manifest = BundleManifest(
            name: "TestGenome",
            identifier: "org.test.bundle-browser",
            source: SourceInfo(organism: "Test organism", assembly: "fixture"),
            genome: GenomeInfo(
                path: "genome/sequence.fa.gz",
                indexPath: "genome/sequence.fa.gz.fai",
                totalLength: 320,
                chromosomes: [
                    ChromosomeInfo(name: "chr1", length: 200, offset: 0, lineBases: 80, lineWidth: 81, aliases: ["1"], isPrimary: true, isMitochondrial: false, fastaDescription: "primary"),
                    ChromosomeInfo(name: "chr2", length: 120, offset: 201, lineBases: 80, lineWidth: 81, aliases: ["2"], isPrimary: true, isMitochondrial: false, fastaDescription: "secondary")
                ]
            ),
            browserSummary: summary
        )

        return (projectURL, bundleURL, manifest)
    }

    private func makeVariantOnlyBundleFixture() throws -> (projectURL: URL, bundleURL: URL, manifest: BundleManifest) {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("variant-only-loader-\(UUID().uuidString).lungfish", isDirectory: true)
        let bundleURL = projectURL.appendingPathComponent("Reference Sequences/VariantOnly.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let manifest = BundleManifest(
            name: "VariantOnly",
            identifier: "org.test.variant-only",
            source: SourceInfo(organism: "Variant only", assembly: "fixture"),
            genome: nil,
            variants: [
                VariantTrackInfo(
                    id: "variants",
                    name: "Variants",
                    path: "variants/variants.db",
                    indexPath: "variants/variants.db",
                    databasePath: "variants/variants.db",
                    variantType: .mixed,
                    variantCount: 1,
                    source: "Test"
                )
            ]
        )

        return (projectURL, bundleURL, manifest)
    }
}
```

- [ ] **Step 2: Run the new loader tests and confirm the symbols are missing**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/fasta-fastq-bridge --filter BundleBrowserLoaderTests
```

Expected: failures because `BundleBrowserMirrorStore`, `BundleBrowserLoader`, and the load-result types do not exist yet.

- [ ] **Step 3: Create the variant-aware summary synthesizer**

Create `Sources/LungfishApp/Services/BundleSequenceSummarySynthesizer.swift`:

```swift
import Foundation
import LungfishCore
import LungfishIO

enum BundleSequenceSummarySynthesizer {
    static func summarize(bundleURL: URL, manifest: BundleManifest) -> BundleBrowserSummary {
        if let browserSummary = manifest.browserSummary {
            return browserSummary
        }

        if let genome = manifest.genome {
            return BundleBrowserSummary(
                schemaVersion: 1,
                aggregate: .init(
                    annotationTrackCount: manifest.annotations.count,
                    variantTrackCount: manifest.variants.count,
                    alignmentTrackCount: manifest.alignments.count,
                    totalMappedReads: manifest.alignments.compactMap(\.mappedReadCount).reduce(0, +)
                ),
                sequences: genome.chromosomes.map {
                    BundleBrowserSequenceSummary(
                        name: $0.name,
                        displayDescription: $0.fastaDescription,
                        length: $0.length,
                        aliases: $0.aliases,
                        isPrimary: $0.isPrimary,
                        isMitochondrial: $0.isMitochondrial,
                        metrics: nil
                    )
                }
            )
        }

        let bundle = ReferenceBundle(url: bundleURL, manifest: manifest)
        let chromosomes = ViewerViewController.synthesizeChromosomesFromVariants(bundle: bundle)
        return BundleBrowserSummary(
            schemaVersion: 1,
            aggregate: .init(
                annotationTrackCount: manifest.annotations.count,
                variantTrackCount: manifest.variants.count,
                alignmentTrackCount: manifest.alignments.count,
                totalMappedReads: manifest.alignments.compactMap(\.mappedReadCount).reduce(0, +)
            ),
            sequences: chromosomes.map {
                BundleBrowserSequenceSummary(
                    name: $0.name,
                    displayDescription: $0.fastaDescription,
                    length: $0.length,
                    aliases: $0.aliases,
                    isPrimary: $0.isPrimary,
                    isMitochondrial: $0.isMitochondrial,
                    metrics: nil
                )
            }
        )
    }
}
```

- [ ] **Step 4: Create the SQLite mirror store**

Create `Sources/LungfishApp/Services/BundleBrowserMirrorStore.swift`:

```swift
import Foundation
import SQLite3
import LungfishCore

final class BundleBrowserMirrorStore {
    private let db: OpaquePointer
    private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(projectURL: URL) throws {
        let cacheDirectory = projectURL.appendingPathComponent(".lungfish-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let dbURL = cacheDirectory.appendingPathComponent("bundle-browser.sqlite")
        var handle: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let handle else {
            throw NSError(domain: "BundleBrowserMirrorStore", code: 1)
        }
        db = handle
        try createSchema()
    }

    deinit {
        sqlite3_close_v2(db)
    }

    func fetch(bundleKey: String) throws -> BundleBrowserSummary? {
        let sql = "SELECT payload_json FROM bundle_browser_cache WHERE bundle_key = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "BundleBrowserMirrorStore", code: 2)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (bundleKey as NSString).utf8String, -1, sqliteTransient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let bytes = sqlite3_column_blob(stmt, 0)
        let count = Int(sqlite3_column_bytes(stmt, 0))
        let data = Data(bytes: bytes!, count: count)
        return try JSONDecoder().decode(BundleBrowserSummary.self, from: data)
    }

    func upsert(summary: BundleBrowserSummary, bundleKey: String) throws {
        let payload = try JSONEncoder().encode(summary)
        let sql = """
        INSERT INTO bundle_browser_cache(bundle_key, payload_json, updated_at)
        VALUES (?, ?, ?)
        ON CONFLICT(bundle_key) DO UPDATE SET
            payload_json = excluded.payload_json,
            updated_at = excluded.updated_at
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "BundleBrowserMirrorStore", code: 3)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (bundleKey as NSString).utf8String, -1, sqliteTransient)
        payload.withUnsafeBytes { rawBuffer in
            sqlite3_bind_blob(stmt, 2, rawBuffer.baseAddress, Int32(rawBuffer.count), sqliteTransient)
        }
        sqlite3_bind_text(stmt, 3, (Date().ISO8601Format() as NSString).utf8String, -1, sqliteTransient)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw NSError(domain: "BundleBrowserMirrorStore", code: 4)
        }
    }

    func delete(bundleKey: String) throws {
        let sql = "DELETE FROM bundle_browser_cache WHERE bundle_key = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "BundleBrowserMirrorStore", code: 5)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (bundleKey as NSString).utf8String, -1, sqliteTransient)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw NSError(domain: "BundleBrowserMirrorStore", code: 6)
        }
    }

    private func createSchema() throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS bundle_browser_cache (
            bundle_key TEXT PRIMARY KEY,
            payload_json BLOB NOT NULL,
            updated_at TEXT NOT NULL
        );
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "BundleBrowserMirrorStore", code: 7)
        }
    }
}
```

- [ ] **Step 5: Create the precedence-aware loader**

Create `Sources/LungfishApp/Services/BundleBrowserLoader.swift`:

```swift
import Foundation
import LungfishCore
import LungfishIO

struct BundleBrowserLoadResult: Equatable {
    enum Source: Equatable {
        case manifest
        case mirror
        case synthesized
    }

    let summary: BundleBrowserSummary
    let source: Source
}

struct BundleBrowserLoader {
    var mirrorStoreFactory: (URL) throws -> BundleBrowserMirrorStore = { try BundleBrowserMirrorStore(projectURL: $0) }
    var synthesizer: (URL, BundleManifest) -> BundleBrowserSummary = { bundleURL, manifest in
        BundleSequenceSummarySynthesizer.summarize(bundleURL: bundleURL, manifest: manifest)
    }

    static func bundleKey(for bundleURL: URL, manifest: BundleManifest) -> String {
        let fingerprint = [
            bundleURL.standardizedFileURL.path,
            manifest.identifier,
            manifest.modifiedDate.ISO8601Format(),
            String(manifest.genome?.totalLength ?? 0),
            String(manifest.alignments.count)
        ].joined(separator: "\n")
        return fingerprint
    }

    func load(bundleURL: URL, manifest: BundleManifest) throws -> BundleBrowserLoadResult {
        if let summary = manifest.browserSummary {
            return BundleBrowserLoadResult(summary: summary, source: .manifest)
        }

        if let projectURL = ProjectTempDirectory.findProjectRoot(bundleURL) {
            let store = try mirrorStoreFactory(projectURL)
            let key = Self.bundleKey(for: bundleURL, manifest: manifest)
            if let cached = try store.fetch(bundleKey: key) {
                return BundleBrowserLoadResult(summary: cached, source: .mirror)
            }

            let synthesized = synthesizer(bundleURL, manifest)
            try store.upsert(summary: synthesized, bundleKey: key)
            return BundleBrowserLoadResult(summary: synthesized, source: .synthesized)
        }

        return BundleBrowserLoadResult(
            summary: synthesizer(bundleURL, manifest),
            source: .synthesized
        )
    }
}
```

- [ ] **Step 6: Run the loader tests**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/fasta-fastq-bridge --filter 'BundleBrowserLoaderTests|BundleManifestTests'
```

Expected: pass.

- [ ] **Step 7: Commit the loader layer**

```bash
git -C /Users/dho/Documents/lungfish-genome-explorer/.worktrees/fasta-fastq-bridge add \
  Sources/LungfishApp/Services/BundleSequenceSummarySynthesizer.swift \
  Sources/LungfishApp/Services/BundleBrowserMirrorStore.swift \
  Sources/LungfishApp/Services/BundleBrowserLoader.swift \
  Tests/LungfishAppTests/BundleBrowserLoaderTests.swift
git -C /Users/dho/Documents/lungfish-genome-explorer/.worktrees/fasta-fastq-bridge commit -m "Add bundle browser loader and project cache"
```

---

## Task 3: Build the Manifest-Backed Bundle Browser UI

**Files:**

- Create: `Sources/LungfishApp/Views/Viewer/BundleBrowserViewController.swift`
- Test: `Tests/LungfishAppTests/BundleBrowserViewControllerTests.swift`

- [ ] **Step 1: Write the failing bundle-browser view tests**

Create `Tests/LungfishAppTests/BundleBrowserViewControllerTests.swift`:

```swift
import XCTest
@testable import LungfishApp
@testable import LungfishCore

@MainActor
final class BundleBrowserViewControllerTests: XCTestCase {
    func testConfigureSelectsFirstRowAndShowsDetail() {
        let vc = BundleBrowserViewController()
        _ = vc.view

        vc.configure(summary: makeSummary())

        XCTAssertEqual(vc.testDisplayedNames, ["chr1", "chr2"])
        XCTAssertEqual(vc.testSelectedName, "chr1")
        XCTAssertEqual(vc.testDetailLengthText, "200 bp")
    }

    func testFilterMatchesAliasAndDescription() {
        let vc = BundleBrowserViewController()
        _ = vc.view

        vc.configure(summary: makeSummary())
        vc.testSetFilterText("mitochondrion")
        XCTAssertEqual(vc.testDisplayedNames, ["chrM"])

        vc.testSetFilterText("MT")
        XCTAssertEqual(vc.testDisplayedNames, ["chrM"])
    }

    func testOpenCallbackUsesSelectedRow() {
        let vc = BundleBrowserViewController()
        _ = vc.view
        var opened: String?
        vc.onOpenSequence = { opened = $0.name }
        vc.configure(summary: makeSummary())

        vc.testSelectRow(named: "chr2")
        vc.testInvokeOpen()

        XCTAssertEqual(opened, "chr2")
    }

    private func makeSummary() -> BundleBrowserSummary {
        BundleBrowserSummary(
            schemaVersion: 1,
            aggregate: .init(annotationTrackCount: 1, variantTrackCount: 0, alignmentTrackCount: 1, totalMappedReads: 300),
            sequences: [
                BundleBrowserSequenceSummary(name: "chr1", displayDescription: "primary contig", length: 200, aliases: ["1"], isPrimary: true, isMitochondrial: false, metrics: .init(mappedReads: 220, mappedPercent: 73.3, meanDepth: 11.2, coverageBreadth: 97.1, medianMAPQ: 60.0, meanIdentity: 99.1)),
                BundleBrowserSequenceSummary(name: "chrM", displayDescription: "mitochondrion", length: 80, aliases: ["MT"], isPrimary: false, isMitochondrial: true, metrics: .init(mappedReads: 80, mappedPercent: 26.7, meanDepth: 42.0, coverageBreadth: 100.0, medianMAPQ: 60.0, meanIdentity: 99.9))
            ]
        )
    }
}
```

- [ ] **Step 2: Run the UI-unit tests and confirm the controller is missing**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/fasta-fastq-bridge --filter BundleBrowserViewControllerTests
```

Expected: failures because `BundleBrowserViewController` and its test hooks do not exist.

- [ ] **Step 3: Create the browser controller with state capture and accessibility IDs**

Create `Sources/LungfishApp/Views/Viewer/BundleBrowserViewController.swift`:

```swift
import AppKit
import LungfishCore

struct BundleBrowserState: Equatable {
    var filterText: String = ""
    var selectedSequenceName: String?
    var scrollOriginY: CGFloat = 0
}

@MainActor
final class BundleBrowserViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onOpenSequence: ((BundleBrowserSequenceSummary) -> Void)?

    private var summary: BundleBrowserSummary?
    private var displayedRows: [BundleBrowserSequenceSummary] = []
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let openButton = NSButton(title: "Open in Browser", target: nil, action: nil)
    private let detailStack = NSStackView()
    private let detailNameLabel = NSTextField(labelWithString: "")
    private let detailLengthLabel = NSTextField(labelWithString: "")
    private let detailMetricsLabel = NSTextField(labelWithString: "")

    override func loadView() {
        let container = NSView()
        let splitView = NSSplitView()
        let listPane = NSView()
        let detailPane = NSView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sequence"))

        [splitView, listPane, detailPane, searchField, scrollView, tableView, detailStack, openButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        container.accessibilityIdentifier = "bundle-browser-view"
        splitView.isVertical = true
        splitView.dividerStyle = .thin

        searchField.placeholderString = "Filter sequences"
        searchField.target = self
        searchField.action = #selector(searchFieldChanged(_:))

        tableView.accessibilityIdentifier = "bundle-browser-table"
        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = self
        column.title = "Sequence"
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true

        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = 8
        detailStack.addArrangedSubview(detailNameLabel)
        detailStack.addArrangedSubview(detailLengthLabel)
        detailStack.addArrangedSubview(detailMetricsLabel)

        openButton.accessibilityIdentifier = "bundle-browser-open-button"
        openButton.target = self
        openButton.action = #selector(openSelectedSequence(_:))

        listPane.addSubview(searchField)
        listPane.addSubview(scrollView)
        detailPane.addSubview(detailStack)
        detailPane.addSubview(openButton)
        splitView.addArrangedSubview(listPane)
        splitView.addArrangedSubview(detailPane)
        container.addSubview(splitView)

        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: container.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            searchField.topAnchor.constraint(equalTo: listPane.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: listPane.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: listPane.trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: listPane.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: listPane.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: listPane.bottomAnchor, constant: -12),

            detailStack.topAnchor.constraint(equalTo: detailPane.topAnchor, constant: 16),
            detailStack.leadingAnchor.constraint(equalTo: detailPane.leadingAnchor, constant: 16),
            detailStack.trailingAnchor.constraint(lessThanOrEqualTo: detailPane.trailingAnchor, constant: -16),

            openButton.topAnchor.constraint(equalTo: detailStack.bottomAnchor, constant: 16),
            openButton.leadingAnchor.constraint(equalTo: detailPane.leadingAnchor, constant: 16),
            openButton.bottomAnchor.constraint(lessThanOrEqualTo: detailPane.bottomAnchor, constant: -16),
        ])
        view = container
    }

    func configure(summary: BundleBrowserSummary, restoredState: BundleBrowserState? = nil) {
        self.summary = summary
        displayedRows = summary.sequences
        tableView.reloadData()
        apply(restoredState ?? BundleBrowserState(
            filterText: "",
            selectedSequenceName: summary.sequences.first?.name,
            scrollOriginY: 0
        ))
    }

    func captureState() -> BundleBrowserState {
        BundleBrowserState(
            filterText: searchField.stringValue,
            selectedSequenceName: selectedRow?.name,
            scrollOriginY: scrollView.contentView.bounds.origin.y
        )
    }

    private func apply(_ state: BundleBrowserState) {
        searchField.stringValue = state.filterText
        if !state.filterText.isEmpty {
            searchFieldChanged(searchField)
        }
        if let selectedSequenceName = state.selectedSequenceName,
           let row = displayedRows.firstIndex(where: { $0.name == selectedSequenceName }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            updateDetailPane(for: displayedRows[row])
        } else {
            updateDetailPane(for: displayedRows.first)
        }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: state.scrollOriginY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func restoreSelectionAfterFilter() {
        if displayedRows.isEmpty {
            updateDetailPane(for: nil)
            return
        }

        if let selectedRow,
           let rowIndex = displayedRows.firstIndex(where: { $0.name == selectedRow.name }) {
            tableView.selectRowIndexes(IndexSet(integer: rowIndex), byExtendingSelection: false)
            updateDetailPane(for: displayedRows[rowIndex])
        } else {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            updateDetailPane(for: displayedRows[0])
        }
    }

    private var selectedRow: BundleBrowserSequenceSummary? {
        let row = tableView.selectedRow
        guard row >= 0, row < displayedRows.count else { return nil }
        return displayedRows[row]
    }

    var testDisplayedNames: [String] { displayedRows.map(\.name) }
    var testSelectedName: String? { selectedRow?.name }
    var testDetailLengthText: String { detailLengthLabel.stringValue }

    func testSetFilterText(_ text: String) {
        searchField.stringValue = text
        searchFieldChanged(searchField)
    }

    func testSelectRow(named name: String) {
        guard let row = displayedRows.firstIndex(where: { $0.name == name }) else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        updateDetailPane(for: displayedRows[row])
    }

    func testInvokeOpen() {
        guard let selectedRow else { return }
        onOpenSequence?(selectedRow)
    }

    @objc private func openSelectedSequence(_ sender: Any?) {
        guard let selectedRow else { return }
        onOpenSequence?(selectedRow)
    }
}
```

- [ ] **Step 4: Wire detail rendering and filter behavior**

Inside `BundleBrowserViewController`, implement the concrete filter and detail update logic:

```swift
func numberOfRows(in tableView: NSTableView) -> Int {
    displayedRows.count
}

func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let identifier = NSUserInterfaceItemIdentifier("BundleBrowserCell")
    let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? NSTableCellView()
    let textField = cell.textField ?? NSTextField(labelWithString: "")
    textField.translatesAutoresizingMaskIntoConstraints = false
    if textField.superview == nil {
        cell.addSubview(textField)
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
    }
    cell.identifier = identifier
    cell.textField = textField
    textField.stringValue = displayedRows[row].name
    return cell
}

func tableViewSelectionDidChange(_ notification: Notification) {
    updateDetailPane(for: selectedRow)
}

@objc private func searchFieldChanged(_ sender: NSSearchField) {
    let query = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard let summary else { return }
    if query.isEmpty {
        displayedRows = summary.sequences
    } else {
        displayedRows = summary.sequences.filter {
            $0.name.lowercased().contains(query)
            || ($0.displayDescription?.lowercased().contains(query) ?? false)
            || $0.aliases.contains(where: { $0.lowercased().contains(query) })
        }
    }
    tableView.reloadData()
    restoreSelectionAfterFilter()
}

private func updateDetailPane(for row: BundleBrowserSequenceSummary?) {
    guard let row else {
        detailNameLabel.stringValue = "No sequence selected"
        detailLengthLabel.stringValue = ""
        detailMetricsLabel.stringValue = ""
        openButton.isEnabled = false
        return
    }

    detailNameLabel.stringValue = row.name
    detailLengthLabel.stringValue = "\(row.length.formatted()) bp"
    if let metrics = row.metrics, let mappedReads = metrics.mappedReads {
        detailMetricsLabel.stringValue = "Mapped reads: \(mappedReads.formatted())"
    } else {
        detailMetricsLabel.stringValue = "Mapped reads: unavailable"
    }
    openButton.isEnabled = true
}
```

- [ ] **Step 5: Re-run the controller tests**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/fasta-fastq-bridge --filter BundleBrowserViewControllerTests
```

Expected: pass.

- [ ] **Step 6: Commit the new browser controller**

```bash
git -C /Users/dho/Documents/lungfish-genome-explorer/.worktrees/fasta-fastq-bridge add \
  Sources/LungfishApp/Views/Viewer/BundleBrowserViewController.swift \
  Tests/LungfishAppTests/BundleBrowserViewControllerTests.swift
git -C /Users/dho/Documents/lungfish-genome-explorer/.worktrees/fasta-fastq-bridge commit -m "Add manifest-backed bundle browser view"
```

---

## Task 4: Route Top-Level Bundle Opens Through Browser Mode and Keep Mapping Embedded Viewers in Direct Sequence Mode

**Files:**

- Create: `Sources/LungfishApp/Views/Viewer/BundleDisplayMode.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+BundleDisplay.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`
- Modify: `Sources/LungfishApp/Views/Results/Mapping/MappingResultViewController.swift`
- Modify: `Tests/LungfishAppTests/BundleViewerTests.swift`
- Modify: `Tests/LungfishAppTests/MappingResultViewControllerTests.swift`
- Modify: `Tests/LungfishAppTests/MappingViewportRoutingTests.swift`

- [ ] **Step 1: Write the failing routing tests**

Add these tests:

```swift
func testDisplayBundleBrowseModeDoesNotInstallChromosomeNavigator() throws {
    let vc = ViewerViewController()
    _ = vc.view
    let bundleURL = try makeReferenceBundle(chromosomes: ["chr1", "chr2"])

    try vc.displayBundle(at: bundleURL, mode: .browse)

    XCTAssertNil(vc.chromosomeNavigatorView)
    XCTAssertNotNil(vc.testBundleBrowserController)
}

func testSingleSequenceBundleStillOpensInBrowserMode() throws {
    let vc = ViewerViewController()
    _ = vc.view
    let bundleURL = try makeReferenceBundle(chromosomes: ["chr1"])

    try vc.displayBundle(at: bundleURL, mode: .browse)

    XCTAssertNil(vc.chromosomeNavigatorView)
    XCTAssertEqual(vc.testBundleBrowserController?.testSelectedName, "chr1")
}

func testMappingEmbeddedViewerLoadsSequenceModeInsteadOfBundleBrowser() throws {
    let vc = MappingResultViewController()
    _ = vc.view
    vc.configureForTesting(result: makeMappingResult(viewerBundleURL: try makeReferenceBundleWithAnnotationDatabase()))

    XCTAssertFalse(vc.testEmbeddedViewerShowsBundleBrowser)
}

private func makeReferenceBundle(chromosomes: [String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("bundle-viewer-routing-\(UUID().uuidString).lungfishref", isDirectory: true)
    let genomeDir = root.appendingPathComponent("genome", isDirectory: true)
    try FileManager.default.createDirectory(at: genomeDir, withIntermediateDirectories: true)
    try Data().write(to: genomeDir.appendingPathComponent("sequence.fa.gz"))
    try Data().write(to: genomeDir.appendingPathComponent("sequence.fa.gz.fai"))

    let manifest = BundleManifest(
        name: "Fixture",
        identifier: "org.test.viewer.fixture",
        source: SourceInfo(organism: "Fixture", assembly: "fixture"),
        genome: GenomeInfo(
            path: "genome/sequence.fa.gz",
            indexPath: "genome/sequence.fa.gz.fai",
            totalLength: Int64(chromosomes.count * 100),
            chromosomes: chromosomes.enumerated().map { index, name in
                ChromosomeInfo(name: name, length: 100, offset: Int64(index * 101), lineBases: 80, lineWidth: 81)
            }
        )
    )
    try manifest.save(to: root)
    return root
}
```

Update `Tests/LungfishAppTests/MappingViewportRoutingTests.swift` to assert the main window and mapping shell call the new API:

```swift
XCTAssertTrue(source.contains("displayBundle(at: url, mode: .browse)"))
XCTAssertTrue(source.contains("displayBundle(at: standardized, mode: .sequence"))
```

- [ ] **Step 2: Run the routing tests and confirm the new mode API is absent**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/fasta-fastq-bridge --filter 'BundleViewerTests|MappingResultViewControllerTests|MappingViewportRoutingTests'
```

Expected: failures because `BundleDisplayMode` and the new `displayBundle(at:mode:)` API do not exist.

- [ ] **Step 3: Add the explicit bundle display mode**

Create `Sources/LungfishApp/Views/Viewer/BundleDisplayMode.swift`:

```swift
import Foundation

public enum BundleDisplayMode: Equatable {
    case browse
    case sequence(name: String, restoreViewState: Bool)
}
```

- [ ] **Step 4: Generalize the back button in `ViewerViewController`**

Replace the sequence-array-specific back-button storage in `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift` with a generic callback:

```swift
private var backNavigationButton: NSButton?
private var backNavigationBar: NSView?
private var backNavigationAction: (() -> Void)?
private var bundleBrowserController: BundleBrowserViewController?

func showBackNavigationButton(title: String, action: @escaping () -> Void) {
    hideCollectionBackButton()
    backNavigationAction = action

    let navBar = NSView()
    navBar.translatesAutoresizingMaskIntoConstraints = false

    let button = NSButton()
    button.translatesAutoresizingMaskIntoConstraints = false
    button.bezelStyle = .accessoryBarAction
    button.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
    button.imagePosition = .imageLeading
    button.title = title
    button.accessibilityIdentifier = "viewer-back-navigation-button"
    button.target = self
    button.action = #selector(backNavigationButtonTapped(_:))

    let separator = NSBox()
    separator.translatesAutoresizingMaskIntoConstraints = false
    separator.boxType = .separator

    navBar.addSubview(button)
    navBar.addSubview(separator)
    view.addSubview(navBar)

    NSLayoutConstraint.activate([
        navBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
        navBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        navBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        navBar.heightAnchor.constraint(equalToConstant: 28),
        button.leadingAnchor.constraint(equalTo: navBar.leadingAnchor, constant: 6),
        button.centerYAnchor.constraint(equalTo: navBar.centerYAnchor),
        separator.leadingAnchor.constraint(equalTo: navBar.leadingAnchor),
        separator.trailingAnchor.constraint(equalTo: navBar.trailingAnchor),
        separator.bottomAnchor.constraint(equalTo: navBar.bottomAnchor),
    ])

    backNavigationBar = navBar
    backNavigationButton = button
}

@objc private func backNavigationButtonTapped(_ sender: Any?) {
    backNavigationAction?()
}

public func hideCollectionBackButton() {
    backNavigationBar?.removeFromSuperview()
    backNavigationBar = nil
    backNavigationButton = nil
    backNavigationAction = nil
}

func hideBundleBrowserView() {
    bundleBrowserController?.view.removeFromSuperview()
    bundleBrowserController?.removeFromParent()
    bundleBrowserController = nil
}

var testBundleBrowserController: BundleBrowserViewController? { bundleBrowserController }
```

- [ ] **Step 5: Split `displayBundle` into browse-mode and sequence-mode paths**

Update `Sources/LungfishApp/Views/Viewer/ViewerViewController+BundleDisplay.swift`:

Keep the existing bundle-viewer setup logic from the current `displayBundle(at:)` implementation intact: load `BundleViewState`, apply annotation/read display settings, update headers/ruler, schedule the delayed redraw, reopen the annotation drawer when appropriate, and sync the inspector. The routing change here is only about whether the viewer lands in bundle-browser mode or direct sequence mode.

```swift
public func displayBundle(at url: URL, mode: BundleDisplayMode = .browse) throws {
    saveCurrentViewState()
    contentMode = .genomics

    let manifest = try BundleManifest.load(from: url)
    let validationErrors = manifest.validate()
    guard validationErrors.isEmpty else {
        let message = validationErrors.map(\.localizedDescription).joined(separator: "; ")
        throw DocumentLoadError.parseError("Bundle validation failed: \(message)")
    }

    currentBundleDataProvider = BundleDataProvider(bundleURL: url, manifest: manifest)
    currentBundleURL = url
    let viewStateURL = url.appendingPathComponent(BundleViewState.filename)
    currentBundleViewState = FileManager.default.fileExists(atPath: viewStateURL.path)
        ? BundleViewState.load(from: url)
        : Self.defaultBundleViewStateFromAppSettings()

    let bundle = ReferenceBundle(url: url, manifest: manifest)
    publishBundleDidLoadNotification(
        userInfo: [
            NotificationUserInfoKey.bundleURL: url,
            NotificationUserInfoKey.chromosomes: manifest.genome?.chromosomes ?? [],
            NotificationUserInfoKey.manifest: manifest,
            NotificationUserInfoKey.referenceBundle: bundle
        ]
    )

    switch mode {
    case .browse:
        removeChromosomeNavigator()
        let loadResult = try BundleBrowserLoader().load(bundleURL: url, manifest: manifest)
        displayBundleBrowser(summary: loadResult.summary, bundleURL: url)

    case .sequence(let name, let restoreViewState):
        removeChromosomeNavigator()
        try displayBundleSequence(named: name, bundle: bundle, manifest: manifest, restoreViewState: restoreViewState)
    }
}
```

Also add these helpers:

```swift
private func displayBundleBrowser(
    summary: BundleBrowserSummary,
    bundleURL: URL,
    restoredState: BundleBrowserState? = nil
) {
    hideQuickLookPreview()
    hideFASTQDatasetView()
    hideVCFDatasetView()
    hideFASTACollectionView()
    hideTaxonomyView()
    hideEsVirituView()
    hideTaxTriageView()
    hideNaoMgsView()
    hideNvdView()
    hideAssemblyView()
    hideMappingView()

    hideCollectionBackButton()
    hideBundleBrowserView()
    let controller = BundleBrowserViewController()
    controller.onOpenSequence = { [weak self, weak controller] row in
        guard let self, let controller else { return }
        let savedState = controller.captureState()
        self.hideBundleBrowserView()
        self.showBackNavigationButton(title: "All Sequences (\(summary.sequences.count))") { [weak self] in
            self?.displayBundleBrowser(summary: summary, bundleURL: bundleURL, restoredState: savedState)
        }
        try? self.displayBundle(at: bundleURL, mode: .sequence(name: row.name, restoreViewState: false))
    }
    addChild(controller)
    let browserView = controller.view
    browserView.translatesAutoresizingMaskIntoConstraints = false
    browserView.accessibilityIdentifier = "bundle-browser-view"
    view.addSubview(browserView)
    NSLayoutConstraint.activate([
        browserView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
        browserView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        browserView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        browserView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    controller.configure(summary: summary, restoredState: restoredState)
    bundleBrowserController = controller
}

private func displayBundleSequence(
    named name: String,
    bundle: ReferenceBundle,
    manifest: BundleManifest,
    restoreViewState: Bool
) throws {
    hideBundleBrowserView()
    let chromosomes = manifest.genome?.chromosomes ?? Self.synthesizeChromosomesFromVariants(bundle: bundle)
    guard let targetChromosome = chromosomes.first(where: { $0.name == name }) ?? chromosomes.first else {
        showNoSequenceSelected()
        return
    }

    viewerView.setReferenceBundle(bundle)
    let effectiveWidth = max(800, Int(viewerView.bounds.width))
    let start: Double
    let end: Double
    if restoreViewState,
       let savedChromosome = currentBundleViewState?.lastChromosome,
       savedChromosome == targetChromosome.name,
       let savedOrigin = currentBundleViewState?.lastOrigin,
       let savedScale = currentBundleViewState?.lastScale {
        start = max(0, savedOrigin)
        end = min(Double(targetChromosome.length), start + savedScale * Double(effectiveWidth))
    } else {
        start = 0
        end = Double(max(1, targetChromosome.length))
    }

    referenceFrame = ReferenceFrame(
        chromosome: targetChromosome.name,
        start: start,
        end: end,
        pixelWidth: effectiveWidth,
        sequenceLength: Int(targetChromosome.length)
    )
    updateStatusBar()
    viewerView.needsDisplay = true
}
```

- [ ] **Step 6: Update the top-level and mapping callers**

In `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`, change:

```swift
try self.viewerController.displayBundle(at: url, mode: .browse)
```

In `Sources/LungfishApp/Views/Results/Mapping/MappingResultViewController.swift`, change bundle loading to:

```swift
try embeddedViewerController.displayBundle(
    at: standardized,
    mode: .sequence(name: selectedContig.contigName, restoreViewState: false)
)
```

and keep the existing `navigateToChromosomeAndPosition` call as the explicit viewport reset after load.

Also add a test hook in `MappingResultViewController`:

```swift
var testEmbeddedViewerShowsBundleBrowser: Bool {
    embeddedViewerController.testBundleBrowserController != nil
}
```

- [ ] **Step 7: Re-run the routing tests**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/fasta-fastq-bridge --filter 'BundleViewerTests|MappingResultViewControllerTests|MappingViewportRoutingTests|BundleBrowserViewControllerTests'
```

Expected: pass.

- [ ] **Step 8: Commit the routing changes**

```bash
git -C /Users/dho/Documents/lungfish-genome-explorer/.worktrees/fasta-fastq-bridge add \
  Sources/LungfishApp/Views/Viewer/BundleDisplayMode.swift \
  Sources/LungfishApp/Views/Viewer/ViewerViewController.swift \
  Sources/LungfishApp/Views/Viewer/ViewerViewController+BundleDisplay.swift \
  Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift \
  Sources/LungfishApp/Views/Results/Mapping/MappingResultViewController.swift \
  Tests/LungfishAppTests/BundleViewerTests.swift \
  Tests/LungfishAppTests/MappingResultViewControllerTests.swift \
  Tests/LungfishAppTests/MappingViewportRoutingTests.swift
git -C /Users/dho/Documents/lungfish-genome-explorer/.worktrees/fasta-fastq-bridge commit -m "Route bundles through browser and direct sequence modes"
```

---

## Task 5: Tighten BAM Read Rendering to Coverage-Only Until `2.0 bp/px`

**Files:**

- Create: `Sources/LungfishApp/Views/Viewer/ReadViewportPolicy.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ReadTrackRenderer.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/SequenceViewerView.swift`
- Modify: `Tests/LungfishAppTests/ReadTrackRendererTests.swift`
- Create: `Tests/LungfishAppTests/SequenceViewerReadVisibilityTests.swift`

- [ ] **Step 1: Write the failing read-visibility tests**

Add and update these tests:

```swift
func testCoverageTierBeginsAboveTwoBpPerPx() {
    XCTAssertEqual(ReadViewportPolicy.coverageThresholdBpPerPx, 2.0)
    XCTAssertEqual(ReadViewportPolicy.zoomTier(scale: 2.01), .coverage)
    XCTAssertEqual(ReadViewportPolicy.zoomTier(scale: 2.0), .packed)
    XCTAssertEqual(ReadViewportPolicy.zoomTier(scale: 0.6), .base)
}

@MainActor
func testEnteringCoverageTierClearsReadCachesAndInvalidatesOutstandingFetches() {
    let view = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
    view.testSetCachedAlignedReads([makeAlignedRead(name: "r1"), makeAlignedRead(name: "r2")])
    view.testSetCachedPackedReads([(0, makeAlignedRead(name: "r1"))])
    let originalGeneration = view.testReadFetchGeneration

    let tier = view.testApplyReadViewportPolicy(scale: 3.0)

    XCTAssertEqual(tier, .coverage)
    XCTAssertTrue(view.testCachedAlignedReads.isEmpty)
    XCTAssertTrue(view.testCachedPackedReads.isEmpty)
    XCTAssertEqual(view.testReadFetchGeneration, originalGeneration + 1)
}

private func makeAlignedRead(name: String) -> AlignedRead {
    AlignedRead(
        name: name,
        flag: 0,
        chromosome: "chr1",
        position: 10,
        mapq: 60,
        cigar: [CIGAROperation(op: .match, length: 20)],
        sequence: "AAAAAAAAAAAAAAAAAAAA",
        qualities: Array(repeating: 30, count: 20)
    )
}
```

- [ ] **Step 2: Run the read-policy tests and confirm the threshold is still `10`**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/fasta-fastq-bridge --filter 'ReadTrackRendererTests|SequenceViewerReadVisibilityTests'
```

Expected: failures because `ReadViewportPolicy` does not exist and `ReadTrackRenderer.coverageThresholdBpPerPx` is still `10`.

- [ ] **Step 3: Add a dedicated read-visibility policy**

Create `Sources/LungfishApp/Views/Viewer/ReadViewportPolicy.swift`:

```swift
import Foundation

enum ReadViewportPolicy {
    static let coverageThresholdBpPerPx: Double = 2.0
    static let baseThresholdBpPerPx: Double = 0.6

    static func zoomTier(scale: Double) -> ReadTrackRenderer.ZoomTier {
        if scale > coverageThresholdBpPerPx {
            return .coverage
        } else if scale > baseThresholdBpPerPx {
            return .packed
        } else {
            return .base
        }
    }

    static func allowsIndividualReads(scale: Double) -> Bool {
        zoomTier(scale: scale) != .coverage
    }
}
```

- [ ] **Step 4: Make `ReadTrackRenderer` delegate tier selection to the policy**

Update `Sources/LungfishApp/Views/Viewer/ReadTrackRenderer.swift`:

```swift
static let coverageThresholdBpPerPx: Double = ReadViewportPolicy.coverageThresholdBpPerPx
static let baseThresholdBpPerPx: Double = ReadViewportPolicy.baseThresholdBpPerPx

public static func zoomTier(scale: Double) -> ZoomTier {
    ReadViewportPolicy.zoomTier(scale: scale)
}
```

- [ ] **Step 5: Centralize cache-dropping when coverage tier becomes active**

Add this helper to `Sources/LungfishApp/Views/Viewer/SequenceViewerView.swift` and call it from `drawBundleContent` before any read fetch/layout work:

```swift
@discardableResult
func applyReadViewportPolicy(scale: Double) -> ReadTrackRenderer.ZoomTier {
    let tier = ReadViewportPolicy.zoomTier(scale: scale)
    lastRenderedReadTier = tier

    guard tier == .coverage else { return tier }

    readFetchGeneration += 1
    cachedAlignedReads = []
    cachedPackedReads = []
    cachedReadRegion = nil
    readContentHeight = 0
    isFetchingReads = false
    return tier
}
```

Add these test hooks beside the helper:

```swift
var testReadFetchGeneration: Int { readFetchGeneration }
var testCachedAlignedReads: [AlignedRead] { cachedAlignedReads }
var testCachedPackedReads: [(Int, AlignedRead)] { cachedPackedReads }

func testSetCachedAlignedReads(_ reads: [AlignedRead]) {
    cachedAlignedReads = reads
}

func testSetCachedPackedReads(_ rows: [(Int, AlignedRead)]) {
    cachedPackedReads = rows
}

func testApplyReadViewportPolicy(scale: Double) -> ReadTrackRenderer.ZoomTier {
    applyReadViewportPolicy(scale: scale)
}
```

Then update `fetchReadsAsync(bundle:region:)`:

```swift
let tier = ReadViewportPolicy.zoomTier(scale: currentScale)
guard tier != .coverage else { return }
```

Keep `readAtPoint(_:)` and any hover-specific methods gated by `tier != .coverage`.

- [ ] **Step 6: Re-run the read-policy tests**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/fasta-fastq-bridge --filter 'ReadTrackRendererTests|SequenceViewerReadVisibilityTests'
```

Expected: pass.

- [ ] **Step 7: Commit the BAM responsiveness changes**

```bash
git -C /Users/dho/Documents/lungfish-genome-explorer/.worktrees/fasta-fastq-bridge add \
  Sources/LungfishApp/Views/Viewer/ReadViewportPolicy.swift \
  Sources/LungfishApp/Views/Viewer/ReadTrackRenderer.swift \
  Sources/LungfishApp/Views/Viewer/SequenceViewerView.swift \
  Tests/LungfishAppTests/ReadTrackRendererTests.swift \
  Tests/LungfishAppTests/SequenceViewerReadVisibilityTests.swift
git -C /Users/dho/Documents/lungfish-genome-explorer/.worktrees/fasta-fastq-bridge commit -m "Tighten BAM coverage-only rendering thresholds"
```

---

## Task 6: Add XCUI Coverage for the Bundle Browser and Final Verification

**Files:**

- Create: `Tests/LungfishXCUITests/BundleBrowserXCUITests.swift`
- Create: `Tests/LungfishXCUITests/TestSupport/BundleBrowserRobot.swift`
- Modify: `Tests/LungfishXCUITests/TestSupport/LungfishProjectFixtureBuilder.swift`
- Modify: `Tests/LungfishXCUITests/MappingXCUITests.swift`
- Modify: `Tests/LungfishXCUITests/TestSupport/MappingRobot.swift`
- Modify: `Tests/LungfishAppTests/AppUITestMappingBackendTests.swift`

- [ ] **Step 1: Add deterministic fixture support for multi-contig reference bundles**

Extend `Tests/LungfishXCUITests/TestSupport/LungfishProjectFixtureBuilder.swift` with:

```swift
static func makeBundleBrowserProject(named name: String = "BundleBrowserFixture") throws -> URL {
    try makeProject(
        named: name,
        sequenceFilename: nil,
        sequenceContents: nil,
        referenceBundleRecords: [
            ("chr1", String(repeating: "A", count: 200)),
            ("chr2", String(repeating: "C", count: 120)),
            ("chrM", String(repeating: "G", count: 60))
        ]
    )
}
```

If the existing helper does not support `referenceBundleRecords`, add the minimal plumbing there instead of creating a second fixture path.

- [ ] **Step 2: Add a dedicated robot for the bundle browser**

Create `Tests/LungfishXCUITests/TestSupport/BundleBrowserRobot.swift`:

```swift
import XCTest

@MainActor
struct BundleBrowserRobot {
    let app: XCUIApplication

    init(app: XCUIApplication = XCUIApplication()) {
        self.app = app
    }

    func launch(opening projectURL: URL) {
        var options = LungfishUITestLaunchOptions(
            projectPath: projectURL,
            fixtureRootPath: LungfishFixtureCatalog.fixturesRoot
        )
        options.apply(to: app)
        app.launchEnvironment["LUNGFISH_DEBUG_BYPASS_REQUIRED_SETUP"] = "1"
        app.launch()
    }

    func openBundle(named name: String) {
        let item = app.outlines["sidebar-outline"].staticTexts[name].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        item.click()
    }

    var browserView: XCUIElement { app.otherElements["bundle-browser-view"] }
    var browserTable: XCUIElement { app.tables["bundle-browser-table"] }
    var openButton: XCUIElement { app.buttons["bundle-browser-open-button"] }
    var backButton: XCUIElement { app.buttons["viewer-back-navigation-button"] }
}
```

- [ ] **Step 3: Add bundle-browser XCUI tests**

Create `Tests/LungfishXCUITests/BundleBrowserXCUITests.swift`:

```swift
import XCTest

final class BundleBrowserXCUITests: XCTestCase {
    @MainActor
    func testOpeningReferenceBundleShowsBrowserAndBackNavigationRestoresSelection() throws {
        let projectURL = try LungfishProjectFixtureBuilder.makeBundleBrowserProject(named: "BundleBrowserFixture")
        let robot = BundleBrowserRobot()
        defer {
            robot.app.terminate()
            try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent())
        }

        robot.launch(opening: projectURL)
        robot.openBundle(named: "TestGenome")

        XCTAssertTrue(robot.browserView.waitForExistence(timeout: 10))
        XCTAssertTrue(robot.browserTable.staticTexts["chr1"].waitForExistence(timeout: 5))

        robot.browserTable.staticTexts["chr2"].click()
        robot.openButton.click()
        XCTAssertTrue(robot.backButton.waitForExistence(timeout: 10))

        robot.backButton.click()
        XCTAssertTrue(robot.browserView.waitForExistence(timeout: 10))
        XCTAssertTrue(robot.browserTable.staticTexts["chr2"].isSelected)
    }
}
```

- [ ] **Step 4: Assert mapping does not nest the bundle browser**

Extend `Tests/LungfishXCUITests/MappingXCUITests.swift` and `Tests/LungfishXCUITests/TestSupport/MappingRobot.swift`:

```swift
func testDeterministicMappingViewportDoesNotShowNestedBundleBrowser() throws {
    let projectURL = try LungfishProjectFixtureBuilder.makeIlluminaMappingProject(named: "MappingBundleModeFixture")
    let robot = MappingRobot()
    defer {
        robot.app.terminate()
        try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent())
    }

    robot.launch(opening: projectURL, backendMode: "deterministic")
    robot.selectSidebarItem(named: "test_1.fastq.gz", extendingSelection: true)
    robot.openMappingDialog()
    robot.chooseMapper("minimap2")
    robot.clickPrimaryAction()
    robot.waitForAnalysisRow(prefix: "minimap2-", timeout: 30)

    XCTAssertFalse(robot.bundleBrowserView.exists)
}
```

with the robot addition:

```swift
var bundleBrowserView: XCUIElement {
    app.otherElements["bundle-browser-view"]
}
```

- [ ] **Step 5: Run the focused UI and regression suite**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/fasta-fastq-bridge --filter 'BundleManifestTests|BundleBrowserLoaderTests|BundleBrowserViewControllerTests|BundleViewerTests|MappingResultViewControllerTests|MappingViewportRoutingTests|ReadTrackRendererTests|SequenceViewerReadVisibilityTests'
xcodebuild test -project /Users/dho/Documents/lungfish-genome-explorer/.worktrees/fasta-fastq-bridge/Lungfish.xcodeproj -scheme Lungfish -destination 'platform=macOS' -only-testing:LungfishXCUITests/BundleBrowserXCUITests -only-testing:LungfishXCUITests/MappingXCUITests
```

Expected: pass.

- [ ] **Step 6: Commit the UI coverage and final integration changes**

```bash
git -C /Users/dho/Documents/lungfish-genome-explorer/.worktrees/fasta-fastq-bridge add \
  Tests/LungfishXCUITests/BundleBrowserXCUITests.swift \
  Tests/LungfishXCUITests/TestSupport/BundleBrowserRobot.swift \
  Tests/LungfishXCUITests/TestSupport/LungfishProjectFixtureBuilder.swift \
  Tests/LungfishXCUITests/MappingXCUITests.swift \
  Tests/LungfishXCUITests/TestSupport/MappingRobot.swift \
  Tests/LungfishAppTests/AppUITestMappingBackendTests.swift
git -C /Users/dho/Documents/lungfish-genome-explorer/.worktrees/fasta-fastq-bridge commit -m "Add bundle browser and BAM responsiveness test coverage"
```

---

## Final Verification Checklist

- [ ] `swift test --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/fasta-fastq-bridge --filter 'BundleManifestTests|BundleBrowserLoaderTests|BundleBrowserViewControllerTests|BundleViewerTests|MappingResultViewControllerTests|MappingViewportRoutingTests|ReadTrackRendererTests|SequenceViewerReadVisibilityTests'`
- [ ] `xcodebuild test -project /Users/dho/Documents/lungfish-genome-explorer/.worktrees/fasta-fastq-bridge/Lungfish.xcodeproj -scheme Lungfish -destination 'platform=macOS' -only-testing:LungfishXCUITests/BundleBrowserXCUITests -only-testing:LungfishXCUITests/MappingXCUITests`
- [ ] Manual spot-check in the debug app from `/Users/dho/Documents/lungfish-genome-explorer/.worktrees/fasta-fastq-bridge/.build/arm64-apple-macosx/debug/Lungfish`:
  - open a single-sequence `.lungfishref` and verify it lands in the browser, not the old drawer
  - open a multi-sequence `.lungfishref` and verify the back button restores the last selected row
  - open a large BAM-backed mapping result and verify the initial view shows coverage without read-level lag
