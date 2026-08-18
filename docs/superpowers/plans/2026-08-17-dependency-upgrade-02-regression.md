# Dependency Upgrade Regression Tiers Implementation Plan (Plan B)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Fable orchestrates and reviews every task; see the master index for model routing.

**Goal:** Make a dependency bump unable to go green by accident: tool-executing tests fail (not skip) in conformance mode, every pinned tool has a live conformance test, format-fragile parsers are hardened, frozen goldens can be regenerated and diffed, and a dispatchable CI job runs the whole thing.

**Architecture:** A shared `ToolAvailability` helper turns `XCTSkip` into `XCTFail` under `LUNGFISH_REQUIRE_TOOLS=1`. New `Tests/LungfishWorkflowTests/Conformance/` suites run each manifest tool on `Tests/Fixtures/sarscov2/` (plus the 0.5 GB Kraken2 viral DB and a fixture-built deacon index) with structural assertions through the real parsers. `scripts/deps/goldens.json` records how each golden is produced; `regenerate-goldens.sh` re-runs them into a scratch dir and `diff-goldens.py` compares with per-format rules. `full-suite-gate.sh --require-tools` and a `workflow_dispatch` CI job wire it together.

**Tech Stack:** XCTest, Swift 6.2, bash, Python 3 (stdlib only) for scripts, GitHub Actions `macos-26`.

**Spec:** `docs/superpowers/specs/2026-08-17-dependency-upgrade-mechanism-design.md` (section 4.7 and the parser-hardening paragraph)

## Global Constraints

- Conformance tests must be deterministic and offline once tools/DBs are provisioned; network only in explicit tier 3 scripts.
- Under `LUNGFISH_REQUIRE_TOOLS=1`, missing tools or databases are failures; without it, behavior is unchanged (skip).
- Assertions go through the real parsers (`KreportParser`, `AlignmentMetadataDatabase` flagstat/idxstats parsing, `EsVirituDetectionParser`, `IVarTSVRow`, `SPAdesOutputParser`), never ad hoc string matching, so a format change surfaces where production would break.
- Golden diff rules: header/column changes are hard failures; numeric tolerance only where declared; goldens are regenerated only deliberately with a recorded `dependencySet`.
- Isolation: tests use `CondaManager.shared` (respects `LUNGFISH_CONDA_ROOT`/`LUNGFISH_STORAGE_ROOT` from Plan A Task A8); databases resolve through `MetagenomicsDatabaseRegistry.shared` and `DatabaseRegistry.shared`.
- One swift invocation at a time; `--skip-update` always.

## File structure

Create:
- `Tests/Support/LungfishTestSupport/ToolAvailability.swift` (require/skip helper + `ProcessRunner`)
- `Tests/LungfishWorkflowTests/Conformance/ConformanceFixtures.swift` (paths, temp dirs, DB lookup)
- `Tests/LungfishWorkflowTests/Conformance/ToolVersionConformanceTests.swift`
- `Tests/LungfishWorkflowTests/Conformance/Kraken2BrackenConformanceTests.swift`
- `Tests/LungfishWorkflowTests/Conformance/MappingConformanceTests.swift` (minimap2, samtools, bcftools, htslib)
- `Tests/LungfishWorkflowTests/Conformance/AssemblyConformanceTests.swift` (spades, megahit)
- `Tests/LungfishWorkflowTests/Conformance/PhyloBlastVsearchConformanceTests.swift` (iqtree, blast, vsearch, mafft)
- `Tests/LungfishWorkflowTests/Conformance/DeaconFastpSeqkitConformanceTests.swift` (deacon index build + filter, fastp, seqkit, cutadapt, bbtools)
- `scripts/deps/goldens.json`, `scripts/deps/regenerate-goldens.sh`, `scripts/deps/diff-goldens.py`, `scripts/tests/test_diff_goldens.py`
- `scripts/deps/run-pipelines.sh` (tier 3, manual)
- `Tests/Fixtures/conformance/<dependencySet>/` goldens (generated in Task B8)
- `docs/release/dependency-sweep.md`

Modify:
- `Tests/LungfishWorkflowTests/FASTQToolIntegrationTests.swift`, `NativeToolRunnerTests.swift`, `Recipes/RecipeIntegrationTests.swift`, `Metagenomics/ClassificationPipelineTests.swift`, `MSA/MAFFTAlignmentPipelineTests.swift`, `WorkflowBuilderNativeRunnerTests.swift`, `Tests/LungfishIntegrationTests/ReadsToVariantsEndToEndTests.swift`, `IVarConverterViralReconParityTests.swift`, `Tests/LungfishCLITests/BAMPrimerTrimSubcommandTests.swift` (use `ToolAvailability`)
- `scripts/full-suite-gate.sh` (`--require-tools`, `--filter`)
- `Sources/LungfishIO/Formats/EsViritu/EsVirituDetectionParser.swift`, `Sources/LungfishIO/Formats/Kraken/KreportParser.swift`, `Sources/LungfishIO/Bundles/AlignmentMetadataDatabase.swift`, `Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserViewController.swift:3356-3380`, `Sources/LungfishApp/Views/FASTQDatasetViewController.swift:1660`
- `.github/workflows/ci.yml`

---

### Task B1: `ToolAvailability` helper and `LUNGFISH_REQUIRE_TOOLS`

**Files:**
- Create: `Tests/Support/LungfishTestSupport/ToolAvailability.swift`
- Modify: the nine test files listed above (replace ad hoc skips)
- Modify: `scripts/full-suite-gate.sh`
- Test: `Tests/LungfishWorkflowTests/Conformance/ToolAvailabilityTests.swift`

**Interfaces:**
```swift
public enum ToolAvailability {
    public static var requireTools: Bool   // ProcessInfo env LUNGFISH_REQUIRE_TOOLS == "1"
    /// Returns the executable URL or skips/fails.
    public static func require(_ executable: String, environment: String, file: StaticString = #filePath, line: UInt = #line) async throws -> URL
    public static func requireDatabase(_ resolver: () async throws -> URL?, name: String, file: StaticString = #filePath, line: UInt = #line) async throws -> URL
    public static func skipOrFail(_ reason: String, file: StaticString = #filePath, line: UInt = #line) throws -> Never
}
public struct ProcessResult: Sendable { public let status: Int32; public let stdout: String; public let stderr: String }
public enum ProcessRunner {
    public static func run(_ executable: URL, _ arguments: [String], environment: [String: String] = [:], cwd: URL? = nil, timeout: TimeInterval = 600) throws -> ProcessResult
}
```

- [ ] **Step 1: Write the failing test**

```swift
// Tests/LungfishWorkflowTests/Conformance/ToolAvailabilityTests.swift
import XCTest
import LungfishTestSupport

final class ToolAvailabilityTests: XCTestCase {
    func testSkipOrFailSkipsWithoutRequireFlag() throws {
        guard !ToolAvailability.requireTools else { throw XCTSkip("running in require mode") }
        XCTAssertThrowsError(try ToolAvailability.skipOrFail("nope")) { XCTAssertTrue($0 is XCTSkip) }
    }

    func testProcessRunnerCapturesOutput() throws {
        let r = try ProcessRunner.run(URL(fileURLWithPath: "/bin/echo"), ["hello"])
        XCTAssertEqual(r.status, 0); XCTAssertEqual(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --skip-update --filter ToolAvailabilityTests`
Expected: FAIL (types missing).

- [ ] **Step 3: Implement**

```swift
// Tests/Support/LungfishTestSupport/ToolAvailability.swift
import Foundation
import XCTest
import LungfishWorkflow

public enum ToolAvailability {
    public static var requireTools: Bool { ProcessInfo.processInfo.environment["LUNGFISH_REQUIRE_TOOLS"] == "1" }

    public static func skipOrFail(_ reason: String, file: StaticString = #filePath, line: UInt = #line) throws -> Never {
        if requireTools {
            XCTFail("LUNGFISH_REQUIRE_TOOLS=1: \(reason)", file: file, line: line)
            throw ToolAvailabilityError.required(reason)
        }
        throw XCTSkip(reason, file: file, line: line)
    }

    public static func require(_ executable: String, environment: String, file: StaticString = #filePath, line: UInt = #line) async throws -> URL {
        do { return try await CondaManager.shared.toolPath(name: executable, environment: environment) }
        catch { try skipOrFail("\(executable) not installed in env \(environment): \(error)", file: file, line: line) }
    }

    public static func requireDatabase(_ resolver: () async throws -> URL?, name: String, file: StaticString = #filePath, line: UInt = #line) async throws -> URL {
        if let url = try await resolver(), FileManager.default.fileExists(atPath: url.path) { return url }
        try skipOrFail("database \(name) not installed", file: file, line: line)
    }
}

public enum ToolAvailabilityError: Error { case required(String) }

public struct ProcessResult: Sendable { public let status: Int32; public let stdout: String; public let stderr: String }

public enum ProcessRunner {
    public static func run(_ executable: URL, _ arguments: [String], environment: [String: String] = [:], cwd: URL? = nil, timeout: TimeInterval = 600) throws -> ProcessResult {
        let p = Process(); p.executableURL = executable; p.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = executable.deletingLastPathComponent().path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        for (k, v) in environment { env[k] = v }
        p.environment = env
        if let cwd { p.currentDirectoryURL = cwd }
        let out = Pipe(), err = Pipe(); p.standardOutput = out; p.standardError = err
        try p.run()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { p.terminate(); throw ToolAvailabilityError.required("timeout running \(executable.lastPathComponent)") }
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return ProcessResult(status: p.terminationStatus, stdout: stdout, stderr: stderr)
    }
}
```

(Reading pipes after the loop can deadlock on very large output; the conformance tests write tool output to files and keep stdout small. If a test needs large stdout, redirect to a file with `-o`.)

Replace skips in the nine listed test files: every `throw XCTSkip("... not installed/available ...")` for a tool or database becomes `try ToolAvailability.skipOrFail(...)` (or `require(...)`). Remove the `LUNGFISH_LIVE_PIPELINE_TESTS` and `LUNGFISH_VIRALRECON_PARITY` gates: those tests now run whenever their tools are present and fail under require mode when absent. `IVarConverterViralReconParityTests` needs `python3` and the upstream script; keep a `python3` presence check through `skipOrFail` and vendor the pinned `ivar_variants_to_vcf.py` under `Tests/Fixtures/ivar-converter-parity/` if it is not already there (check the README; it says the script is installed per CI run, which is stale). Update that README.

`scripts/full-suite-gate.sh`: add `--require-tools` (exports `LUNGFISH_REQUIRE_TOOLS=1`) and `--filter <regex>` (passes `--filter` to `swift test`). In require mode, also count skips within conformance suites: `grep -cE "Test Case '-\[LungfishWorkflowTests\.(.*Conformance.*|FASTQToolIntegrationTests|RecipeIntegrationTests|NativeToolRunnerTests|MAFFTAlignmentPipelineTests|ClassificationPipelineTests)[^]]*\]' skipped"` and fail if non-zero.

- [ ] **Step 4: Run tests**

Run: `swift test --skip-update --filter 'ToolAvailabilityTests|FASTQToolIntegrationTests|NativeToolRunnerTests|RecipeIntegrationTests'` (without require flag) then `LUNGFISH_REQUIRE_TOOLS=1 swift test --skip-update --filter ToolAvailabilityTests`
Expected: PASS in both.

- [ ] **Step 5: Commit**

```bash
git add Tests scripts/full-suite-gate.sh
git commit -m "test: ToolAvailability helper; LUNGFISH_REQUIRE_TOOLS turns tool skips into failures"
```

---

### Task B2: Conformance fixtures helper and tool-version conformance

**Files:**
- Create: `Tests/LungfishWorkflowTests/Conformance/ConformanceFixtures.swift`, `Tests/LungfishWorkflowTests/Conformance/ToolVersionConformanceTests.swift`

**Interfaces:**
```swift
enum ConformanceFixtures {
    static var sarscov2: URL                       // Tests/Fixtures/sarscov2
    static func tempDir(_ name: String) throws -> URL   // unique scratch, removed in tearDown by caller
    static func manifest() throws -> ManagedToolLock
    static func versionCommand(for toolID: String) -> (executable: String, arguments: [String])   // per-tool table
    static func viralKrakenDB() async throws -> URL // via MetagenomicsDatabaseRegistry.shared, name "Viral"
}
```

- [ ] **Step 1: Write the test**

```swift
// Tests/LungfishWorkflowTests/Conformance/ToolVersionConformanceTests.swift
import XCTest
import LungfishTestSupport
@testable import LungfishWorkflow

final class ToolVersionConformanceTests: XCTestCase {
    /// Every manifest tool env must report the manifest version from its version command.
    func testEveryManifestToolReportsPinnedVersion() async throws {
        let manifest = try ConformanceFixtures.manifest()
        var failures: [String] = []
        for tool in manifest.tools {
            let (exe, args) = ConformanceFixtures.versionCommand(for: tool.id)
            let url: URL
            do { url = try await CondaManager.shared.toolPath(name: exe, environment: tool.environment) }
            catch { if ToolAvailability.requireTools { failures.append("\(tool.id): not installed") }; continue }
            let r = try ProcessRunner.run(url, args, timeout: 60)
            let text = r.stdout + r.stderr
            let expected = tool.version ?? ""
            if !text.contains(expected) { failures.append("\(tool.id): expected \(expected) in: \(text.prefix(200))") }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testEveryInstalledPackToolReportsPinnedVersion() async throws {
        let manifest = try ConformanceFixtures.manifest()
        var failures: [String] = []
        for tool in manifest.packTools {
            let (exe, args) = ConformanceFixtures.versionCommand(for: tool.toolID)
            guard let url = try? await CondaManager.shared.toolPath(name: exe, environment: tool.environment) else { continue }
            let r = try ProcessRunner.run(url, args, timeout: 60)
            if !(r.stdout + r.stderr).contains(tool.version) { failures.append("\(tool.toolID): expected \(tool.version)") }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }
}
```

`versionCommand(for:)` table (extend as needed): nextflow `nextflow -version`; snakemake `snakemake --version`; bbtools `reformat.sh --version` (prints to stderr); fastp `fastp --version`; deacon `deacon --version`; samtools/bcftools `--version`; htslib `bgzip --version`; seqkit `seqkit version`; cutadapt `cutadapt --version`; trim_galore `trim_galore --version`; vsearch `vsearch --version`; pigz `pigz --version`; sra-tools `fasterq-dump --version`; ucsc-bedgraphtobigwig → skip version (prints usage; assert executable runs, status 255 acceptable); pysam `python -c "import pysam;print(pysam.__version__)"`; openpyxl same pattern; minimap2 `--version`; bwa-mem2 `version`; bowtie2 `--version`; savont `--version` (fall back to `--help` containing version); blast `blastn -version`; lofreq `version`; ivar `version`; medaka `--version`; clair3 `run_clair3.sh --version`; spades `spades.py --version`; megahit `--version`; skesa `--version`; flye `--version`; hifiasm `--version`; mafft `--version`; iqtree `iqtree3 --version`; kraken2 `--version`; bracken `bracken -v`; esviritu `EsViritu --version`; ribodetector `-v`; freyja `--version`.

- [ ] **Step 2: Run without tools installed to see the skip path, then with the local install**

Run: `swift test --skip-update --filter ToolVersionConformanceTests` (local machine has envs → should PASS or list real mismatches to fix; a mismatch here means the local env is stale relative to the manifest, run `lungfish-cli tools update --apply --yes` first).

- [ ] **Step 3: Commit**

```bash
git add Tests/LungfishWorkflowTests/Conformance
git commit -m "test(conformance): every manifest tool reports its pinned version"
```

---

### Task B3: Kraken2 + Bracken conformance (viral DB)

**Files:**
- Create: `Tests/LungfishWorkflowTests/Conformance/Kraken2BrackenConformanceTests.swift`

- [ ] **Step 1: Write the test**

```swift
import XCTest
import LungfishTestSupport
@testable import LungfishWorkflow
@testable import LungfishIO

final class Kraken2BrackenConformanceTests: XCTestCase {
    func testClassifyFixtureReadsAgainstViralDB() async throws {
        let kraken2 = try await ToolAvailability.require("kraken2", environment: "kraken2")
        let bracken = try await ToolAvailability.require("bracken", environment: "bracken")
        let db = try await ToolAvailability.requireDatabase({ try await ConformanceFixtures.viralKrakenDB() }, name: "Kraken2 Viral")
        let tmp = try ConformanceFixtures.tempDir("kraken2"); defer { try? FileManager.default.removeItem(at: tmp) }
        let r1 = ConformanceFixtures.sarscov2.appendingPathComponent("test_1.fastq.gz")
        let r2 = ConformanceFixtures.sarscov2.appendingPathComponent("test_2.fastq.gz")
        let kreport = tmp.appendingPathComponent("reads.kreport"), kout = tmp.appendingPathComponent("reads.kraken")
        let res = try ProcessRunner.run(kraken2, ["--db", db.path, "--paired", "--gzip-compressed", "--report", kreport.path, "--output", kout.path, r1.path, r2.path], timeout: 900)
        XCTAssertEqual(res.status, 0, res.stderr)

        let report = try KreportParser.parse(contentsOf: kreport)          // use the real parser's entry point
        XCTAssertFalse(report.entries.isEmpty)
        XCTAssertNotNil(report.entries.first { $0.rank == "U" || $0.name.contains("unclassified") })
        XCTAssertNotNil(report.entries.first { $0.rank == "R" })
        XCTAssertNotNil(report.entries.first { $0.name.localizedCaseInsensitiveContains("Severe acute respiratory syndrome") }, "SARS-CoV-2 must be detected")

        let outputs = try Kraken2OutputParser.parse(contentsOf: kout)
        XCTAssertGreaterThan(outputs.count, 0)
        XCTAssertGreaterThan(outputs.filter { $0.isClassified }.count, outputs.count / 2, "most fixture reads should classify")

        let bout = tmp.appendingPathComponent("reads.bracken")
        let bres = try ProcessRunner.run(bracken, ["-d", db.path, "-i", kreport.path, "-o", bout.path, "-r", "150", "-l", "S"], timeout: 300)
        XCTAssertEqual(bres.status, 0, bres.stderr)
        let brackenRows = try BrackenParser.parse(contentsOf: bout)
        XCTAssertNotNil(brackenRows.first { $0.name.localizedCaseInsensitiveContains("Severe acute respiratory syndrome") })
    }
}
```

Adjust the parser entry points to the real static functions in `KreportParser`, `Kraken2OutputParser`, `BrackenParser` (read the files first; wrap `String(contentsOf:)` if they take text). If the fixture reads are too short for `-r 150`, use `-r 100` (check read length in `test_1.fastq.gz`).

- [ ] **Step 2: Run**

Run: `swift test --skip-update --filter Kraken2BrackenConformanceTests`
Expected: PASS locally (Viral DB is installed at `~/.lungfish/databases/kraken2/viral`).

- [ ] **Step 3: Commit**

```bash
git add Tests/LungfishWorkflowTests/Conformance/Kraken2BrackenConformanceTests.swift
git commit -m "test(conformance): kraken2 + bracken end-to-end on the SARS-CoV-2 fixture"
```

---

### Task B4: Mapping conformance (minimap2, samtools, bcftools, htslib)

**Files:**
- Create: `Tests/LungfishWorkflowTests/Conformance/MappingConformanceTests.swift`

- [ ] **Step 1: Write the test**

```swift
import XCTest
import LungfishTestSupport
@testable import LungfishWorkflow
@testable import LungfishIO

final class MappingConformanceTests: XCTestCase {
    func testMinimap2SamtoolsRoundTripAndStatsParse() async throws {
        let minimap2 = try await ToolAvailability.require("minimap2", environment: "minimap2")
        let samtools = try await ToolAvailability.require("samtools", environment: "samtools")
        let tmp = try ConformanceFixtures.tempDir("map"); defer { try? FileManager.default.removeItem(at: tmp) }
        let ref = ConformanceFixtures.sarscov2.appendingPathComponent("genome.fasta")
        let r1 = ConformanceFixtures.sarscov2.appendingPathComponent("test_1.fastq.gz"), r2 = ConformanceFixtures.sarscov2.appendingPathComponent("test_2.fastq.gz")
        let sam = tmp.appendingPathComponent("out.sam"), bam = tmp.appendingPathComponent("out.sorted.bam")
        let m = try ProcessRunner.run(minimap2, ["-ax", "sr", "-o", sam.path, ref.path, r1.path, r2.path], timeout: 300)
        XCTAssertEqual(m.status, 0, m.stderr)
        XCTAssertEqual(try ProcessRunner.run(samtools, ["sort", "-o", bam.path, sam.path]).status, 0)
        XCTAssertEqual(try ProcessRunner.run(samtools, ["index", bam.path]).status, 0)
        try FileManager.default.removeItem(at: sam)   // project rule: never keep SAM

        let flagstat = try ProcessRunner.run(samtools, ["flagstat", bam.path])
        let stats = try AlignmentMetadataDatabase.parseFlagstat(flagstat.stdout)     // real parser
        XCTAssertGreaterThan(stats.mappedReads, 0)
        XCTAssertGreaterThan(stats.mappedFraction, 0.5)
        let idx = try ProcessRunner.run(samtools, ["idxstats", bam.path])
        let idxRows = try AlignmentMetadataDatabase.parseIdxstats(idx.stdout)
        XCTAssertEqual(idxRows.first?.reference, "MT192765.1")
        XCTAssertGreaterThan(idxRows.first?.mapped ?? 0, 0)
    }

    func testBcftoolsCallAndHtslibIndexing() async throws {
        let bcftools = try await ToolAvailability.require("bcftools", environment: "bcftools")
        let bgzip = try await ToolAvailability.require("bgzip", environment: "htslib")
        let tabix = try await ToolAvailability.require("tabix", environment: "htslib")
        let tmp = try ConformanceFixtures.tempDir("vcf"); defer { try? FileManager.default.removeItem(at: tmp) }
        let ref = ConformanceFixtures.sarscov2.appendingPathComponent("genome.fasta")
        let bam = ConformanceFixtures.sarscov2.appendingPathComponent("test.paired_end.sorted.bam")
        let vcf = tmp.appendingPathComponent("calls.vcf")
        let mp = try ProcessRunner.run(bcftools, ["mpileup", "-f", ref.path, "-Ou", bam.path], timeout: 300)
        XCTAssertEqual(mp.status, 0, mp.stderr)
        // Pipe via shell to keep it simple and deterministic.
        let sh = try ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "'\(bcftools.path)' mpileup -f '\(ref.path)' -Ou '\(bam.path)' | '\(bcftools.path)' call -mv -Ov -o '\(vcf.path)'"], timeout: 300)
        XCTAssertEqual(sh.status, 0, sh.stderr)
        XCTAssertEqual(try ProcessRunner.run(bgzip, ["-f", vcf.path]).status, 0)
        XCTAssertEqual(try ProcessRunner.run(tabix, ["-p", "vcf", vcf.path + ".gz"]).status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: vcf.path + ".gz.tbi"))
        let text = try ProcessRunner.run(bcftools, ["view", "-H", vcf.path + ".gz"]).stdout
        XCTAssertFalse(text.isEmpty, "expected at least one variant call on the fixture")
    }
}
```

If `AlignmentMetadataDatabase` does not expose static parse functions, add `static func parseFlagstat(_ text: String) throws -> FlagstatSummary` and `parseIdxstats` wrappers around the existing private parsing (a small refactor, keep behavior).

- [ ] **Step 2: Run**

Run: `swift test --skip-update --filter MappingConformanceTests`
Expected: PASS locally.

- [ ] **Step 3: Commit**

```bash
git add Tests/LungfishWorkflowTests/Conformance/MappingConformanceTests.swift Sources/LungfishIO/Bundles/AlignmentMetadataDatabase.swift
git commit -m "test(conformance): minimap2/samtools/bcftools/htslib on the SARS-CoV-2 fixture"
```

---

### Task B5: Assembly conformance (SPAdes, MEGAHIT)

**Files:**
- Create: `Tests/LungfishWorkflowTests/Conformance/AssemblyConformanceTests.swift`

- [ ] **Step 1: Write the test**

```swift
import XCTest
import LungfishTestSupport
@testable import LungfishWorkflow

final class AssemblyConformanceTests: XCTestCase {
    private let r1 = ConformanceFixtures.sarscov2.appendingPathComponent("test_1.fastq.gz")
    private let r2 = ConformanceFixtures.sarscov2.appendingPathComponent("test_2.fastq.gz")

    func testSPAdesProducesContigsWithParsableHeaders() async throws {
        let spades = try await ToolAvailability.require("spades.py", environment: "spades")
        let tmp = try ConformanceFixtures.tempDir("spades"); defer { try? FileManager.default.removeItem(at: tmp) }
        let res = try ProcessRunner.run(spades, ["--isolate", "-1", r1.path, "-2", r2.path, "-t", "4", "-m", "8", "-o", tmp.path], timeout: 1800)
        XCTAssertEqual(res.status, 0, res.stderr.suffix(2000).description)
        let contigs = tmp.appendingPathComponent("contigs.fasta")
        XCTAssertTrue(FileManager.default.fileExists(atPath: contigs.path))
        let headers = try String(contentsOf: contigs).split(separator: "\n").filter { $0.hasPrefix(">") }
        XCTAssertFalse(headers.isEmpty)
        let regex = try NSRegularExpression(pattern: #"^>NODE_\d+_length_\d+_cov_[\d.]+"#)
        for h in headers { XCTAssertNotNil(regex.firstMatch(in: String(h), range: NSRange(h.startIndex..., in: h)), "unexpected SPAdes header \(h)") }
        // Log parser must recognize completion.
        let log = try String(contentsOf: tmp.appendingPathComponent("spades.log"))
        XCTAssertTrue(SPAdesOutputParser.isComplete(log), "SPAdesOutputParser did not recognize completion")
    }

    func testMegahitProducesFinalContigs() async throws {
        let megahit = try await ToolAvailability.require("megahit", environment: "megahit")
        let tmp = try ConformanceFixtures.tempDir("megahit"); let out = tmp.appendingPathComponent("out")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let res = try ProcessRunner.run(megahit, ["-1", r1.path, "-2", r2.path, "-t", "4", "-o", out.path], timeout: 1800)
        XCTAssertEqual(res.status, 0, res.stderr.suffix(2000).description)
        let contigs = out.appendingPathComponent("final.contigs.fa")
        XCTAssertTrue(FileManager.default.fileExists(atPath: contigs.path))
        XCTAssertEqual(AssemblyOutputNormalizer.primaryContigsURL(tool: .megahit, outputDirectory: out), contigs)
    }
}
```

Use the real `SPAdesOutputParser`/`AssemblyOutputNormalizer` entry points (read them; adapt names).

- [ ] **Step 2: Run**

Run: `swift test --skip-update --filter AssemblyConformanceTests`
Expected: PASS locally (a few minutes).

- [ ] **Step 3: Commit**

```bash
git add Tests/LungfishWorkflowTests/Conformance/AssemblyConformanceTests.swift
git commit -m "test(conformance): SPAdes and MEGAHIT assemble the fixture with parsable outputs"
```

---

### Task B6: IQ-TREE, BLAST, vsearch, MAFFT, deacon, fastp, seqkit, cutadapt, bbtools conformance

**Files:**
- Create: `Tests/LungfishWorkflowTests/Conformance/PhyloBlastVsearchConformanceTests.swift`, `Tests/LungfishWorkflowTests/Conformance/DeaconFastpSeqkitConformanceTests.swift`

- [ ] **Step 1: Write the tests**

```swift
// PhyloBlastVsearchConformanceTests.swift
import XCTest
import LungfishTestSupport
@testable import LungfishWorkflow
@testable import LungfishIO

final class PhyloBlastVsearchConformanceTests: XCTestCase {
    func testIQTreeReproducesExpectedLeafSet() async throws {
        let iqtree = try await ToolAvailability.require("iqtree3", environment: "iqtree")
        let tmp = try ConformanceFixtures.tempDir("iqtree"); defer { try? FileManager.default.removeItem(at: tmp) }
        let aln = ConformanceFixtures.fixture("phylogenetics/known-sarcopterygian/alignment.fasta")
        let res = try ProcessRunner.run(iqtree, ["-s", aln.path, "-m", "GTR+G", "-seed", "1", "-nt", "2", "-pre", tmp.appendingPathComponent("run").path, "-redo"], timeout: 900)
        XCTAssertEqual(res.status, 0, res.stderr)
        let tree = try NewickParser.parse(contentsOf: tmp.appendingPathComponent("run.treefile"))
        let expected = try NewickParser.parse(contentsOf: ConformanceFixtures.fixture("phylogenetics/known-sarcopterygian/expected.nwk"))
        XCTAssertEqual(Set(tree.leafNames), Set(expected.leafNames))
        XCTAssertEqual(tree.unrootedSplits, expected.unrootedSplits, "topology changed vs expected.nwk")
    }

    func testBlastnOutfmt6HasDeclaredFields() async throws {
        let blastn = try await ToolAvailability.require("blastn", environment: "blast")
        let makeblastdb = try await ToolAvailability.require("makeblastdb", environment: "blast")
        let tmp = try ConformanceFixtures.tempDir("blast"); defer { try? FileManager.default.removeItem(at: tmp) }
        let ref = ConformanceFixtures.sarscov2.appendingPathComponent("genome.fasta")
        XCTAssertEqual(try ProcessRunner.run(makeblastdb, ["-in", ref.path, "-dbtype", "nucl", "-out", tmp.appendingPathComponent("db").path]).status, 0)
        let fields = FullLengthONTMHCBlastRescueParser.outfmt6Fields   // the 14 fields the pipeline requests
        let res = try ProcessRunner.run(blastn, ["-query", ref.path, "-db", tmp.appendingPathComponent("db").path, "-outfmt", "6 " + fields.joined(separator: " "), "-max_target_seqs", "1"])
        XCTAssertEqual(res.status, 0, res.stderr)
        let firstLine = res.stdout.split(separator: "\n").first.map(String.init) ?? ""
        XCTAssertEqual(firstLine.split(separator: "\t").count, fields.count)
        XCTAssertNoThrow(try FullLengthONTMHCBlastRescueParser.parseLine(firstLine))
    }

    func testVsearchDereplicatesFixtureReads() async throws {
        let vsearch = try await ToolAvailability.require("vsearch", environment: "vsearch")
        let seqkit = try await ToolAvailability.require("seqkit", environment: "seqkit")
        let tmp = try ConformanceFixtures.tempDir("vsearch"); defer { try? FileManager.default.removeItem(at: tmp) }
        let fasta = tmp.appendingPathComponent("reads.fasta")
        XCTAssertEqual(try ProcessRunner.run(seqkit, ["fq2fa", ConformanceFixtures.sarscov2.appendingPathComponent("test_1.fastq.gz").path, "-o", fasta.path]).status, 0)
        let out = tmp.appendingPathComponent("derep.fasta")
        let res = try ProcessRunner.run(vsearch, ["--derep_fulllength", fasta.path, "--output", out.path, "--sizeout"])
        XCTAssertEqual(res.status, 0, res.stderr)
        let headers = try String(contentsOf: out).split(separator: "\n").filter { $0.hasPrefix(">") }
        XCTAssertFalse(headers.isEmpty)
        XCTAssertTrue(headers.allSatisfy { $0.contains(";size=") })
    }

    func testMafftAlignsAndParserReadsIt() async throws {
        let mafft = try await ToolAvailability.require("mafft", environment: "mafft")
        let tmp = try ConformanceFixtures.tempDir("mafft"); defer { try? FileManager.default.removeItem(at: tmp) }
        let input = ConformanceFixtures.fixture("phylogenetics/known-sarcopterygian/alignment.fasta")
        let out = tmp.appendingPathComponent("aln.fasta")
        let res = try ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "'\(mafft.path)' --auto '\(input.path)' > '\(out.path)'"], timeout: 600)
        XCTAssertEqual(res.status, 0, res.stderr)
        let records = try FASTAReader.readAll(out)
        XCTAssertGreaterThan(records.count, 2)
        XCTAssertEqual(Set(records.map { $0.sequence.count }).count, 1, "aligned sequences must share a length")
    }
}
```

```swift
// DeaconFastpSeqkitConformanceTests.swift
import XCTest
import LungfishTestSupport
@testable import LungfishWorkflow

final class DeaconFastpSeqkitConformanceTests: XCTestCase {
    private var r1: URL { ConformanceFixtures.sarscov2.appendingPathComponent("test_1.fastq.gz") }

    func testDeaconIndexBuildAndFilterDepletesFixtureReads() async throws {
        let deacon = try await ToolAvailability.require("deacon", environment: "deacon")
        let tmp = try ConformanceFixtures.tempDir("deacon"); defer { try? FileManager.default.removeItem(at: tmp) }
        let idx = tmp.appendingPathComponent("ref.idx")
        let b = try ProcessRunner.run(deacon, ["index", "build", ConformanceFixtures.sarscov2.appendingPathComponent("genome.fasta").path, "-o", idx.path])
        XCTAssertEqual(b.status, 0, b.stderr)
        let out = tmp.appendingPathComponent("filt.fq.gz"), summary = tmp.appendingPathComponent("summary.json")
        let f = try ProcessRunner.run(deacon, ["filter", "-d", idx.path, r1.path, "-o", out.path, "--summary", summary.path])
        XCTAssertEqual(f.status, 0, f.stderr)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: summary)) as! [String: Any]
        // Fixture reads are SARS-CoV-2; depleting against SARS-CoV-2 must remove nearly all of them.
        let seqsIn = (json["seqs_in"] as? Int) ?? (json["reads_in"] as? Int) ?? 0
        let seqsOut = (json["seqs_out"] as? Int) ?? (json["reads_out"] as? Int) ?? seqsIn
        XCTAssertGreaterThan(seqsIn, 0, "summary keys: \(json.keys.sorted())")
        XCTAssertLessThan(Double(seqsOut) / Double(seqsIn), 0.05)
    }

    func testFastpTrimsAndSeqkitStatsParse() async throws {
        let fastp = try await ToolAvailability.require("fastp", environment: "fastp")
        let seqkit = try await ToolAvailability.require("seqkit", environment: "seqkit")
        let tmp = try ConformanceFixtures.tempDir("fastp"); defer { try? FileManager.default.removeItem(at: tmp) }
        let out = tmp.appendingPathComponent("trim.fq.gz")
        let res = try ProcessRunner.run(fastp, ["-i", r1.path, "-o", out.path, "-j", tmp.appendingPathComponent("f.json").path, "-h", tmp.appendingPathComponent("f.html").path, "-w", "2"])
        XCTAssertEqual(res.status, 0, res.stderr)
        let stats = try ProcessRunner.run(seqkit, ["stats", "-a", "-T", out.path])
        let table = try SeqkitStatsParser.parse(stats.stdout)      // header-driven parser from Task B7
        XCTAssertGreaterThan(table.numSeqs, 0)
        XCTAssertGreaterThan(table.avgLen, 30)
    }

    func testCutadaptAndBBToolsRun() async throws {
        let cutadapt = try await ToolAvailability.require("cutadapt", environment: "cutadapt")
        let reformat = try await ToolAvailability.require("reformat.sh", environment: "bbtools")
        let tmp = try ConformanceFixtures.tempDir("bb"); defer { try? FileManager.default.removeItem(at: tmp) }
        let c = try ProcessRunner.run(cutadapt, ["-a", "AGATCGGAAGAGC", "-o", tmp.appendingPathComponent("c.fq.gz").path, r1.path])
        XCTAssertEqual(c.status, 0, c.stderr)
        let env = CoreToolLocator.bbToolsEnvironment(homeDirectory: FileManager.default.homeDirectoryForCurrentUser, existingPath: ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
        let r = try ProcessRunner.run(reformat, ["in=\(r1.path)", "out=\(tmp.appendingPathComponent("r.fq").path)", "overwrite=t"], environment: env)
        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertTrue(r.stderr.contains("Input:") && r.stderr.contains("reads"), "reformat.sh summary format changed: \(r.stderr.suffix(300))")
    }
}
```

Adapt entry points (`NewickParser`, `FASTAReader`, `FullLengthONTMHCBlastRescueParser`) to the real names; where a parser has no static field list, add one (`static let outfmt6Fields`) and use it in the pipeline too so the contract is single-sourced. Add `ConformanceFixtures.fixture(_ relative: String) -> URL`.

- [ ] **Step 2: Run**

Run: `swift test --skip-update --filter 'PhyloBlastVsearchConformanceTests|DeaconFastpSeqkitConformanceTests'`
Expected: PASS locally (Task B7 provides `SeqkitStatsParser`; if executing B6 before B7, temporarily assert on `stats.stdout` line count == 2 and switch after B7).

- [ ] **Step 3: Commit**

```bash
git add Tests/LungfishWorkflowTests/Conformance Sources
git commit -m "test(conformance): iqtree, blast, vsearch, mafft, deacon, fastp, seqkit, cutadapt, bbtools"
```

---

### Task B7: Parser hardening

**Files:**
- Modify: `Sources/LungfishIO/Formats/EsViritu/EsVirituDetectionParser.swift:87,227-270`, `Sources/LungfishIO/Formats/Kraken/KreportParser.swift:199-296`, `Sources/LungfishIO/Bundles/AlignmentMetadataDatabase.swift:603-640`
- Create: `Sources/LungfishIO/Formats/Seqkit/SeqkitStatsParser.swift`; use it from `Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserViewController.swift:3356-3380` and `Sources/LungfishApp/Views/FASTQDatasetViewController.swift:1660`
- Tests: `Tests/LungfishIOTests/EsVirituParserTests.swift` (add), `KreportParserTests.swift` (add), `AlignmentMetadataDatabaseTests.swift` (add), `Tests/LungfishIOTests/SeqkitStatsParserTests.swift` (new)

- [ ] **Step 1: Write the failing tests**

```swift
// EsVirituParserTests additions
    func testHeaderDrivenParsingToleratesExtraColumn() throws {
        let header = EsVirituDetectionParser.requiredColumns.joined(separator: "\t") + "\tnew_upstream_col"
        let row = EsVirituDetectionParser.requiredColumns.map { _ in "x" } + ["y"]
        // fill numeric columns sensibly
        var cells = row; cells[EsVirituDetectionParser.requiredColumns.firstIndex(of: "reads_aligned")!] = "12"
        let text = header + "\n" + cells.joined(separator: "\t") + "\n"
        let parsed = try EsVirituDetectionParser.parse(text)
        XCTAssertEqual(parsed.count, 1)
    }
    func testMissingRequiredColumnThrowsInsteadOfDroppingRows() {
        let cols = EsVirituDetectionParser.requiredColumns.filter { $0 != "reads_aligned" }
        let text = cols.joined(separator: "\t") + "\n" + cols.map { _ in "x" }.joined(separator: "\t") + "\n"
        XCTAssertThrowsError(try EsVirituDetectionParser.parse(text)) { error in
            XCTAssertTrue("\(error)".contains("reads_aligned"))
        }
    }

// KreportParserTests additions
    func testRejectsUnexpectedColumnCountExplicitly() {
        let bad = "  1.00\t1\t1\tU\t0\tunclassified\textra1\textra2\textra3\n"
        XCTAssertThrowsError(try KreportParser.parse(bad))
    }
    func testAcceptsSixAndEightColumnForms() throws {
        XCTAssertNoThrow(try KreportParser.parse(" 50.00\t5\t5\tU\t0\tunclassified\n 50.00\t5\t0\tR\t1\troot\n"))
        XCTAssertNoThrow(try KreportParser.parse(" 50.00\t5\t5\t7\t7\tU\t0\tunclassified\n 50.00\t5\t0\t7\t7\tR\t1\troot\n"))
    }

// AlignmentMetadataDatabaseTests additions
    func testFlagstatJSONPreferredOverText() throws {
        let json = #"{"QC-passed reads":{"total":100,"mapped":90,"mapped %":90.0},"QC-failed reads":{"total":0}}"#
        let s = try AlignmentMetadataDatabase.parseFlagstat(json: json)
        XCTAssertEqual(s.totalReads, 100); XCTAssertEqual(s.mappedReads, 90)
    }

// SeqkitStatsParserTests (new file)
import XCTest
@testable import LungfishIO
final class SeqkitStatsParserTests: XCTestCase {
    func testParsesByHeaderName() throws {
        let text = "file\tformat\ttype\tnum_seqs\tsum_len\tmin_len\tavg_len\tmax_len\tQ1\tQ2\tQ3\tsum_gap\tN50\tQ20(%)\tQ30(%)\tAvgQual\tGC(%)\n" +
                   "r.fq\tFASTQ\tDNA\t22\t3300\t150\t150.0\t150\t150\t150\t150\t0\t150\t98.1\t95.2\t35.9\t38.0\n"
        let t = try SeqkitStatsParser.parse(text)
        XCTAssertEqual(t.numSeqs, 22); XCTAssertEqual(t.avgLen, 150.0, accuracy: 0.001); XCTAssertEqual(t.gcPercent, 38.0)
    }
    func testColumnReorderStillParses() throws {
        let text = "num_seqs\tfile\tavg_len\n5\tx\t10.5\n"
        let t = try SeqkitStatsParser.parse(text)
        XCTAssertEqual(t.numSeqs, 5); XCTAssertEqual(t.avgLen, 10.5)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --skip-update --filter 'EsVirituParserTests|KreportParserTests|AlignmentMetadataDatabaseTests|SeqkitStatsParserTests'`
Expected: FAIL.

- [ ] **Step 3: Implement**

- `EsVirituDetectionParser`: add `public static let requiredColumns: [String]` (the 23 current names, read from the existing positional mapping), parse the header line into `[name: index]`, throw `EsVirituParseError.missingColumns([String])` if any required column is absent, then read cells by name; extra columns ignored. Keep the public parse API.
- `KreportParser`: replace the 8-column sniff with explicit acceptance of 6 or 8 tab-separated columns (kraken2 `--report-minimizer-data` = 8) and throw `KreportParseError.unexpectedColumnCount(Int, line: Int)` otherwise.
- `AlignmentMetadataDatabase`: add `parseFlagstat(json:)`; when running samtools, call `flagstat -O json` first and fall back to text if exit != 0 (samtools < 1.10). Expose `parseFlagstat(_ text:)` and `parseIdxstats(_:)` as static.
- `SeqkitStatsParser`: `struct SeqkitStatsRow { file, numSeqs: Int, sumLen: Int, minLen, avgLen: Double, maxLen, gcPercent: Double? ... }`; parse header by name; throw on missing `num_seqs`. Replace the header-count parsing in the two App call sites.

- [ ] **Step 4: Run tests**

Run: `swift test --skip-update --filter 'EsVirituParserTests|KreportParserTests|AlignmentMetadataDatabaseTests|SeqkitStatsParserTests|EsViritu|Kraken|DatabaseBrowser|FASTQDataset'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "fix(parsers): header-driven EsViritu/seqkit parsing, explicit kreport columns, flagstat JSON"
```

---

### Task B8: Golden recipes, regeneration, and diff tooling

**Files:**
- Create: `scripts/deps/goldens.json`, `scripts/deps/regenerate-goldens.sh`, `scripts/deps/diff-goldens.py`, `scripts/tests/test_diff_goldens.py`, `Tests/Fixtures/conformance/README.md`
- Generate: `Tests/Fixtures/conformance/2026.1/**` (baseline goldens for the CURRENT set)

**Interfaces:**
- `goldens.json` schema:
```json
{ "goldens": [
  { "id": "kraken2-mini-SRR35517702", "tool": "kraken2", "env": "kraken2",
    "inputs": ["Tests/Fixtures/kraken2-mini/SRR35517702/source.fastq"],
    "database": "kraken2-viral",
    "command": "kraken2 --db {db} --report {out}/classification.kreport --output {out}/classification.kraken {in0}",
    "outputs": { "classification.kreport": {"kind": "kreport"}, "classification.kraken": {"kind": "tsv", "keyColumns": [1], "compareColumns": [0,2]} },
    "golden": "Tests/Fixtures/kraken2-mini/SRR35517702" },
  { "id": "sarscov2-flagstat", "tool": "samtools", "env": "samtools", "inputs": ["Tests/Fixtures/sarscov2/test.paired_end.sorted.bam"],
    "command": "samtools flagstat -O json {in0} > {out}/flagstat.json",
    "outputs": { "flagstat.json": {"kind": "json", "numericTolerance": 0} },
    "golden": "Tests/Fixtures/conformance/{set}/sarscov2-flagstat" },
  { "id": "sarscov2-idxstats", "tool": "samtools", "env": "samtools", "inputs": ["Tests/Fixtures/sarscov2/test.paired_end.sorted.bam"], "command": "samtools idxstats {in0} > {out}/idxstats.tsv", "outputs": { "idxstats.tsv": {"kind": "tsv", "keyColumns": [0], "compareColumns": [1,2,3]} }, "golden": "Tests/Fixtures/conformance/{set}/sarscov2-idxstats" },
  { "id": "sarscov2-seqkit-stats", "tool": "seqkit", "env": "seqkit", "inputs": ["Tests/Fixtures/sarscov2/test_1.fastq.gz"], "command": "seqkit stats -a -T {in0} | sed 's#{in0}#IN#' > {out}/stats.tsv", "outputs": { "stats.tsv": {"kind": "tsv-header", "compareColumns": ["num_seqs","sum_len","min_len","avg_len","max_len","GC(%)"], "numericTolerance": 1e-3} }, "golden": "Tests/Fixtures/conformance/{set}/sarscov2-seqkit-stats" },
  { "id": "sarscov2-fastp", "tool": "fastp", "env": "fastp", "inputs": ["Tests/Fixtures/sarscov2/test_1.fastq.gz"], "command": "fastp -i {in0} -o {out}/trim.fq.gz -j {out}/fastp.json -h /dev/null -w 1 && python3 -c \"import json,sys; d=json.load(open('{out}/fastp.json')); json.dump({'before':d['summary']['before_filtering'],'after':d['summary']['after_filtering']}, open('{out}/summary.json','w'), sort_keys=True)\" && rm {out}/trim.fq.gz {out}/fastp.json", "outputs": { "summary.json": {"kind": "json", "numericTolerance": 0.02, "relative": true} }, "golden": "Tests/Fixtures/conformance/{set}/sarscov2-fastp" },
  { "id": "sarscov2-minimap2", "tool": "minimap2", "env": "minimap2", "inputs": ["Tests/Fixtures/sarscov2/genome.fasta","Tests/Fixtures/sarscov2/test_1.fastq.gz","Tests/Fixtures/sarscov2/test_2.fastq.gz"], "command": "minimap2 -ax sr {in0} {in1} {in2} 2>/dev/null | {samtools} sort -o {out}/aln.bam - && {samtools} flagstat -O json {out}/aln.bam > {out}/flagstat.json && rm {out}/aln.bam", "outputs": { "flagstat.json": {"kind": "json", "numericTolerance": 0.01, "relative": true} }, "golden": "Tests/Fixtures/conformance/{set}/sarscov2-minimap2" },
  { "id": "sarscov2-spades", "tool": "spades", "env": "spades", "inputs": ["Tests/Fixtures/sarscov2/test_1.fastq.gz","Tests/Fixtures/sarscov2/test_2.fastq.gz"], "command": "spades.py --isolate -1 {in0} -2 {in1} -t 4 -m 8 -o {out}/spades >/dev/null && {seqkit} stats -a -T {out}/spades/contigs.fasta | sed 's#{out}/spades/##' > {out}/contigs-stats.tsv && rm -rf {out}/spades", "outputs": { "contigs-stats.tsv": {"kind": "tsv-header", "compareColumns": ["num_seqs","sum_len","N50"], "numericTolerance": 0.05, "relative": true} }, "golden": "Tests/Fixtures/conformance/{set}/sarscov2-spades" },
  { "id": "sarscov2-vsearch-derep", "tool": "vsearch", "env": "vsearch", "inputs": ["Tests/Fixtures/sarscov2/test_1.fastq.gz"], "command": "{seqkit} fq2fa {in0} -o {out}/r.fa && vsearch --derep_fulllength {out}/r.fa --output {out}/d.fa --sizeout --quiet && grep -c '^>' {out}/d.fa > {out}/count.txt && rm {out}/r.fa {out}/d.fa", "outputs": { "count.txt": {"kind": "text"} }, "golden": "Tests/Fixtures/conformance/{set}/sarscov2-vsearch-derep" },
  { "id": "sarscov2-deacon", "tool": "deacon", "env": "deacon", "inputs": ["Tests/Fixtures/sarscov2/genome.fasta","Tests/Fixtures/sarscov2/test_1.fastq.gz"], "command": "deacon index build {in0} -o {out}/ref.idx && deacon filter -d {out}/ref.idx {in1} -o /dev/null --summary {out}/summary.json && rm {out}/ref.idx", "outputs": { "summary.json": {"kind": "json", "ignoreKeys": ["time","version","index","input","output","seqs_per_second","bp_per_second"], "numericTolerance": 0.01, "relative": true} }, "golden": "Tests/Fixtures/conformance/{set}/sarscov2-deacon" },
  { "id": "sarscov2-bcftools", "tool": "bcftools", "env": "bcftools", "inputs": ["Tests/Fixtures/sarscov2/genome.fasta","Tests/Fixtures/sarscov2/test.paired_end.sorted.bam"], "command": "bcftools mpileup -f {in0} -Ou {in1} 2>/dev/null | bcftools call -mv -Ov 2>/dev/null | grep -v '^##' > {out}/calls.vcf", "outputs": { "calls.vcf": {"kind": "tsv-header", "keyColumns": ["#CHROM","POS","REF","ALT"], "compareColumns": ["#CHROM","POS","REF","ALT"]} }, "golden": "Tests/Fixtures/conformance/{set}/sarscov2-bcftools" },
  { "id": "iqtree-known-sarcopterygian", "tool": "iqtree", "env": "iqtree", "inputs": ["Tests/Fixtures/phylogenetics/known-sarcopterygian/alignment.fasta"], "command": "iqtree3 -s {in0} -m GTR+G -seed 1 -nt 2 -pre {out}/run -redo >/dev/null && cp {out}/run.treefile {out}/tree.nwk && rm {out}/run.*", "outputs": { "tree.nwk": {"kind": "newick-topology"} }, "golden": "Tests/Fixtures/conformance/{set}/iqtree-known-sarcopterygian" }
]}
```
- `regenerate-goldens.sh --set <id> --out <dir> [--only id,...]`: resolves `{samtools}`, `{seqkit}` etc. via `~/.lungfish/conda/envs/<env>/bin/<tool>` (respecting `LUNGFISH_CONDA_ROOT`), `{db}` via `lungfish-cli db info <name> --json` path or the registry JSON, runs each command with the env's `bin` first on `PATH`, writes `<out>/<id>/...` plus `<out>/<id>/meta.json` (`dependencySet`, tool version from `lungfish-cli version --tools`, timestamp).
- `diff-goldens.py --golden-root <dir|repo> --candidate <dir> --set <id> [--json]`: per-`kind` comparators: `kreport` (parse 6/8 cols; compare set of (rank, taxid, name); compare read counts with tolerance 0 by default), `tsv` (positional keys/compare cols), `tsv-header` (by header name; **any header change = failure**), `json` (recursive with `ignoreKeys`, tolerance abs/relative), `text` (exact), `newick-topology` (leaf set + unrooted splits, ignore branch lengths). Exit 0 clean, 2 differences, 3 missing goldens.

- [ ] **Step 1: Write the failing python tests**

```python
# scripts/tests/test_diff_goldens.py
import json, pathlib, subprocess, sys, tempfile, unittest
ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/deps"))
import diff_goldens  # noqa: E402

class DiffGoldensTests(unittest.TestCase):
    def test_tsv_header_change_is_failure(self):
        g = "a\tb\n1\t2\n"; c = "a\tb\tc\n1\t2\t3\n"
        diffs = diff_goldens.compare_tsv_header(g, c, {"compareColumns": ["a", "b"]})
        self.assertTrue(any("header" in d for d in diffs))

    def test_json_relative_tolerance(self):
        g = {"x": 100, "y": {"z": 1.0}}; c = {"x": 101, "y": {"z": 1.0}}
        self.assertEqual(diff_goldens.compare_json(g, c, {"numericTolerance": 0.02, "relative": True}), [])
        self.assertNotEqual(diff_goldens.compare_json(g, c, {"numericTolerance": 0.001, "relative": True}), [])

    def test_kreport_rank_set_and_counts(self):
        g = " 50.00\t5\t5\tU\t0\tunclassified\n 50.00\t5\t0\tR\t1\troot\n"
        c = " 50.00\t5\t5\tU\t0\tunclassified\n 50.00\t5\t0\tR\t1\troot\n  10.00\t1\t1\tD\t2\t  Viruses\n"
        diffs = diff_goldens.compare_kreport(g, c, {})
        self.assertTrue(any("Viruses" in d for d in diffs))

    def test_newick_topology_ignores_branch_lengths(self):
        self.assertEqual(diff_goldens.compare_newick("((A:0.1,B:0.2):0.3,C:0.4);", "((A:1,B:1):1,C:1);", {}), [])
        self.assertNotEqual(diff_goldens.compare_newick("((A,B),C);", "((A,C),B);", {}), [])

    def test_cli_exit_codes(self):
        with tempfile.TemporaryDirectory() as td:
            golden = pathlib.Path(td, "g", "x"); cand = pathlib.Path(td, "c", "x")
            golden.mkdir(parents=True); cand.mkdir(parents=True)
            (golden / "count.txt").write_text("5\n"); (cand / "count.txt").write_text("6\n")
            recipes = {"goldens": [{"id": "x", "outputs": {"count.txt": {"kind": "text"}}, "golden": str(golden.parent) + "/{set}/../x"}]}
            (pathlib.Path(td) / "goldens.json").write_text(json.dumps(recipes))
            r = subprocess.run([sys.executable, str(ROOT / "scripts/deps/diff-goldens.py"), "--recipes", str(pathlib.Path(td, "goldens.json")), "--golden-root", str(golden.parent), "--candidate", str(cand.parent), "--set", "s"], capture_output=True, text=True)
            self.assertEqual(r.returncode, 2, r.stdout + r.stderr)

if __name__ == "__main__":
    unittest.main()
```

(Keep the CLI test's path handling simple: `--golden-root` overrides the `golden` field's directory when given; implement accordingly.)

- [ ] **Step 2: Run to verify it fails**

Run: `python3 -B -m unittest scripts/tests/test_diff_goldens.py`
Expected: FAIL (module missing).

- [ ] **Step 3: Implement `diff-goldens.py`** (module name `diff_goldens.py` with a thin `diff-goldens.py` shim, or make the file importable via `importlib`; simplest: name the module `diff_goldens.py` and have `regenerate-goldens.sh`/docs call `python3 scripts/deps/diff_goldens.py`; update the test invocation accordingly), stdlib only, functions `compare_text/compare_tsv/compare_tsv_header/compare_json/compare_kreport/compare_newick`, `main()` with argparse and the exit codes above; print a Markdown summary table (id, output, status, first difference).

- [ ] **Step 4: Implement `regenerate-goldens.sh`** as described (bash + jq + python for placeholder substitution), and generate the baseline: `bash scripts/deps/regenerate-goldens.sh --set 2026.1 --out /tmp/goldens-2026.1` then copy `/tmp/goldens-2026.1/<id>` into each recipe's `golden` path with `{set}=2026.1`. Register `Tests/Fixtures/conformance/2026.1/*` in `scripts/testing/fixture_provenance.py` `RETAINED_FIXTURES` (`fixtureToolName` = the tool, `dependencySet` field added to the record) and run `bash scripts/testing/audit-fixture-provenance.sh` to write provenance.

- [ ] **Step 5: Verify round trip**

Run: `python3 scripts/deps/diff_goldens.py --recipes scripts/deps/goldens.json --candidate /tmp/goldens-2026.1 --set 2026.1`
Expected: exit 0, all rows "same". Then run `python3 -B -m unittest discover -s scripts/tests` → PASS.

- [ ] **Step 6: Commit**

```bash
git add scripts/deps scripts/tests scripts/testing Tests/Fixtures/conformance Tests/Fixtures/kraken2-mini
git commit -m "test(goldens): golden recipes, regeneration and diff tooling with 2026.1 baseline"
```

---

### Task B9: Tier 3 pipeline runner (manual)

**Files:**
- Create: `scripts/deps/run-pipelines.sh`, `scripts/deps/pipeline-goldens.json`
- Modify: `scripts/deps/diff_goldens.py` (add `kind: "tsv-header"` reuse for pipeline outputs, nothing new)

- [ ] **Step 1: Write the script**

`run-pipelines.sh --which taxtriage|esviritu|all --out <dir> [--accession SRR35517702]`:
- Fetch reads with the managed `fasterq-dump` (`sra-tools` env) for the accession(s) into `<out>/reads/`; subsample to 50k pairs with `seqkit sample -n 50000 -s 11` (record in meta).
- TaxTriage: `lungfish-cli taxtriage run --reads ... --output <out>/taxtriage` (use the existing CLI subcommand; read `TaxTriageCommand.swift` for flags), then copy `report/multiqc_data/multiqc_confidences.txt` and `combine/*.combined.gcfmap.tsv`.
- EsViritu: `lungfish-cli esviritu run --reads ... --db <installed> --output <out>/esviritu`; copy `*.detected_virus.info.tsv`, `*.virus_coverage_windows.tsv`, `*.tax_profile.tsv`.
- Diff structurally against `Tests/Fixtures/taxtriage-mini` and `Tests/Fixtures/esviritu-mini` with `pipeline-goldens.json` recipes of `kind: "tsv-header"` and `compareColumns: []` (headers only) so only schema drift fails; print value-level differences as informational.
- Emits `<out>/tier3-report.md`.

- [ ] **Step 2: Dry-run the script's argument parsing**

Run: `bash scripts/deps/run-pipelines.sh --help`
Expected: usage text, exit 0. Full execution is part of the sweep (Plan C) and documented in `docs/release/dependency-sweep.md`.

- [ ] **Step 3: Commit**

```bash
git add scripts/deps/run-pipelines.sh scripts/deps/pipeline-goldens.json
git commit -m "test(tier3): manual pipeline runner with structural diff against mini fixtures"
```

---

### Task B10: CI `toolset-conformance` job

**Files:**
- Modify: `.github/workflows/ci.yml`
- Test: `scripts/tests/test_ci_workflow.py` (existing CI lint tests; add assertions)

- [ ] **Step 1: Add assertions to the existing CI workflow test**

```python
    def test_toolset_conformance_job_exists_and_is_dispatch_only(self):
        wf = yaml_load(ROOT / ".github/workflows/ci.yml")
        job = wf["jobs"]["toolset-conformance"]
        self.assertIn("workflow_dispatch", job["if"])
        steps = " ".join(step.get("run", "") for step in job["steps"])
        self.assertIn("tools update --apply --yes --required-only", steps)
        self.assertIn("LUNGFISH_REQUIRE_TOOLS", steps)
        self.assertIn("full-suite-gate.sh --require-tools", steps)
```

- [ ] **Step 2: Run to verify it fails**

Run: `python3 -B -m unittest scripts/tests/test_ci_workflow.py`
Expected: FAIL.

- [ ] **Step 3: Add the job**

```yaml
  toolset-conformance:
    name: Toolset conformance
    runs-on: macos-26
    timeout-minutes: 120
    if: ${{ github.event_name == 'workflow_dispatch' }}
    steps:
      - uses: actions/checkout@v6
        with: { fetch-depth: 0 }
      - name: Select Xcode 26.4.1
        run: sudo xcode-select -s /Applications/Xcode_26.4.1.app/Contents/Developer
      - name: Resolve dependencies
        run: swift package resolve
      - name: Build CLI
        run: swift build --product lungfish-cli
      - name: Compute manifest hash
        id: manifest
        run: echo "hash=$(shasum -a 256 Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json | cut -d' ' -f1)" >> "$GITHUB_OUTPUT"
      - name: Cache managed tools and viral DB
        uses: actions/cache@v4
        with:
          path: |
            ~/.lungfish/conda
            ~/.lungfish/databases/kraken2/viral
            ~/.lungfish/databases/metagenomics-db-registry.json
            ~/.lungfish/dependency-receipt.json
          key: lungfish-tools-${{ runner.os }}-${{ steps.manifest.outputs.hash }}
      - name: Provision required tools
        run: .build/debug/lungfish-cli tools update --apply --yes --required-only
      - name: Provision conformance packs
        run: |
          .build/debug/lungfish-cli conda install --pack read-mapping --yes
          .build/debug/lungfish-cli conda install --pack assembly --yes
          .build/debug/lungfish-cli conda install --pack phylogenetics --yes
          .build/debug/lungfish-cli conda install --pack multiple-sequence-alignment --yes
          .build/debug/lungfish-cli conda install --pack metagenomics --yes
          .build/debug/lungfish-cli conda install --pack full-length-mhc-genotyping --yes
      - name: Provision Kraken2 viral DB
        run: .build/debug/lungfish-cli db download Viral --yes
      - name: Run conformance suites
        env: { LUNGFISH_REQUIRE_TOOLS: "1" }
        run: bash scripts/full-suite-gate.sh --require-tools --filter 'Conformance|FASTQToolIntegrationTests|RecipeIntegrationTests|NativeToolRunnerTests|MAFFTAlignmentPipelineTests|ClassificationPipelineTests|ReadsToVariantsEndToEndTests|BAMPrimerTrimSubcommandTests|IVarConverterViralReconParityTests'
      - name: Golden diff
        run: |
          bash scripts/deps/regenerate-goldens.sh --set "$(python3 -c 'import json;print(json.load(open("Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json"))["dependencySet"])')" --out .build/goldens
          python3 scripts/deps/diff_goldens.py --recipes scripts/deps/goldens.json --candidate .build/goldens --set "$(python3 -c 'import json;print(json.load(open("Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json"))["dependencySet"])')"
      - uses: actions/upload-artifact@v4
        if: always()
        with: { name: toolset-conformance-logs, path: .build/gate-logs }
```

Confirm the `conda install --pack` and `db download --yes` flags exist in `CondaCommand`/`DbCommand`; if names differ, use the real ones.

- [ ] **Step 4: Run tests**

Run: `python3 -B -m unittest discover -s scripts/tests`
Expected: PASS. Then trigger the job once from GitHub (`gh workflow run ci.yml`) and confirm it passes at the current manifest.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/ci.yml scripts/tests
git commit -m "ci: dispatchable toolset-conformance job provisions tools and runs conformance + golden diff"
```

---

### Task B11: Sweep checklist doc and release-skill pointer

**Files:**
- Create: `docs/release/dependency-sweep.md`
- Modify: `docs/superpowers/plans/2026-08-05-reproducible-lungfish-release-skill.md` (add gate: "dependencySet in manifest equals the receipt from `scripts/deps/verify.sh`; a green `toolset-conformance` run exists for the manifest hash"), `.codex/skills/releasing-lungfish/SKILL.md` if present in this checkout (add the same gate line), `SKILLS.md`

- [ ] **Step 1: Write the doc**

Sections: When (twice a year, plus security fixes), Roles (Fable orchestrates), Steps: 1 `python3 scripts/deps/check-upstream.py --markdown > /tmp/candidates.md`; 2 decide bumps/holds (record in `docs/release-notes/deps-<set>.md` draft); 3 `python3 scripts/deps/bump.py --set <YYYY.N> --from /tmp/candidates.json [--hold ...]`; 4 `bash scripts/deps/verify.sh --tier 1` (fails on skips), `--tier 2` (golden diff; regenerate deliberately with justification), `--tier 3` (pipelines, manual); 5 GUI walkthroughs (fresh, upgrade); 6 dispatch `toolset-conformance`; 7 release notes section "Updated tools and databases"; 8 bump app version and release via the release skill. Include expected runtimes and the known-risk checklist from spec section 5.

- [ ] **Step 2: Commit**

```bash
git add docs SKILLS.md .codex 2>/dev/null
git commit -m "docs: semiannual dependency sweep checklist and release-skill gate"
```

---

### Task B12: Gate and Fable review for Plan B

- [ ] **Step 1: Run** `bash scripts/full-suite-gate.sh` (normal mode) → green bar; then `LUNGFISH_REQUIRE_TOOLS=1 bash scripts/full-suite-gate.sh --require-tools --filter 'Conformance|FASTQToolIntegrationTests|RecipeIntegrationTests|NativeToolRunnerTests|MAFFTAlignmentPipelineTests|ClassificationPipelineTests|ReadsToVariantsEndToEndTests|BAMPrimerTrimSubcommandTests|IVarConverterViralReconParityTests'` on the local machine → PASS with zero skips.
- [ ] **Step 2: Fable review** of assertions: every conformance test asserts through a production parser; no test passes on `emptyReport`; golden rules never loosened silently.
- [ ] **Step 3: Tag** `git tag deps-plan-b-complete`.

## Self-review notes

- Spec 4.7 tier 1: B1 to B6; tier 2: B7 (hardening) + B8; tier 3: B9; tier 4 GUI: covered in Plan A15 and Plan C sweep; CI: B10; checklist: B11.
- Fragile parsers named in the spec (EsViritu, kreport, flagstat, seqkit, SPAdes header, iVar) each have a conformance test or hardening task; iVar retains its golden VCF + parity test now unconditionally enabled when tools exist (B1).
