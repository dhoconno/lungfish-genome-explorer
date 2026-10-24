# LungfishPortable

Line numbers were checked at commit 3cee435e3. When a line has moved, search for the named symbol.

## Purpose

The portable layer, row 0 of the layering table in the root `AGENTS.md`. It depends on no other Lungfish module and builds for macOS and for static Linux (musl), so the app and `lungfish-executor` on a CHTC node run the same code. It holds the plan the Mac writes for one sample and the executor follows, the run record the executor writes back, the FASTQ readers and storage-step rules that a Mac import and a node run must share byte for byte, and the launcher protocols that let each platform start its own processes. LungfishCore depends on it and re-exports it with `@_exported import LungfishPortable`, so a change to a public or package name here reaches every target that imports LungfishCore.

## Allowed imports

Foundation. Glibc, Musl and Darwin only inside `#if` blocks. CryptoKit on macOS and swift-crypto's `Crypto` on Linux only inside the `#if` blocks of `PortableDigest.swift` and `FileDigest.swift`. Never another Lungfish module. `Package.swift` gives the target one dependency, the `Crypto` product, on Linux only. `scripts/ratchets/portable-imports.sh` counts an import of Darwin, os, os.log, CryptoKit, Compression, Security, MachO, AppKit or SQLite3 outside an `#if` block as `forbidden_imports`, and its baseline is 0.

## Entry points

| Type | Path |
|---|---|
| `ExecutionPlan`, the plan the Mac writes for one sample and `lungfish-executor run --plan` follows | Sources/LungfishPortable/Plan/ExecutionPlan.swift line 13 |
| `PlanStep`, one step of the plan | Sources/LungfishPortable/Plan/ExecutionPlan.swift line 247 |
| `PlanEntry`, one file the plan pins by role, relative path, SHA-256 and size | Sources/LungfishPortable/Plan/PlanEntry.swift line 52 |
| `PlanResourceResolver`, which resolves every plan path under the folder that holds the plan file, reads no environment variable and opens outputs without following links | Sources/LungfishPortable/Plan/PlanResourceResolver.swift line 74 |
| `PlanDecodeError`, why a plan cannot run, naming the field | Sources/LungfishPortable/Plan/PlanDecodeError.swift line 9 |
| `ImageToolManifest`, the one source of each tool's version and path on the node | Sources/LungfishPortable/Plan/ImageToolManifest.swift line 63 |
| `ExecutorRunRecord`, the `run-record.json` of one run and the only channel from the node to the bundle | Sources/LungfishPortable/RunRecord/ExecutorRunRecord.swift line 13 |
| `ExecutorStepRecord`, one step's part of the run record | Sources/LungfishPortable/RunRecord/ExecutorStepRecord.swift line 14 |
| `ExecutorExitCode` and `ExecutorRunOutcome` | Sources/LungfishPortable/RunRecord/ExecutorExitCode.swift lines 8 and 28 |
| `PortableChildLauncher`, how the layer starts a child it reads | Sources/LungfishPortable/Process/PortableChildLauncher.swift line 51 |
| `PortableToolLauncher`, how a tool step starts its tools and records each launch | Sources/LungfishPortable/Process/PortableToolLauncher.swift line 140 |
| `PortableStorageStep` (line 139) and `PortableStorageChecks` (line 32), the storage run of an import over a launcher | Sources/LungfishPortable/FASTQ/PortableStorageStep.swift |
| `PortableStoragePlan`, what the storage step decides before it launches anything | Sources/LungfishPortable/FASTQ/PortableStoragePlan.swift line 9 |
| `PortableMixedLayout`, the mixed file of a merged layout | Sources/LungfishPortable/FASTQ/PortableMixedLayout.swift line 9 |
| `PortableFileJoin`, two files joined into one without a third copy | Sources/LungfishPortable/PortableFileJoin.swift line 9 |
| `FASTQPairInterleaver` | Sources/LungfishPortable/FASTQ/FASTQPairInterleaver.swift line 15 |
| `FASTQRawLineReader`, a pull-based line reader over a plain or gzip FASTQ | Sources/LungfishPortable/FASTQ/FASTQRawLineReader.swift line 13 |
| `FASTQReadLayoutClassifier` | Sources/LungfishPortable/FASTQ/FASTQReadLayoutClassifier.swift line 14 |
| `QualityEncoding` | Sources/LungfishPortable/FASTQ/QualityEncoding.swift line 17 |
| `TrimGaloreReport` | Sources/LungfishPortable/FASTQ/TrimGaloreReport.swift line 51 |
| `PortableDigest`, SHA-256 on both platforms | Sources/LungfishPortable/PortableDigest.swift line 12 |
| `FileDigest`, streaming SHA-256 helpers | Sources/LungfishPortable/FileDigest.swift line 22 |
| `autoreleasepool(invoking:)`, a pass-through where the Objective-C runtime is absent | Sources/LungfishPortable/Autoreleasepool.swift line 11 |

## Contracts this module owns

- The plan format. The Mac writes an `ExecutionPlan` and `lungfish-executor run --plan` follows it. Every plan path resolves under the folder that holds the plan file (`PlanResourceResolver`), and each `PlanEntry` must match its pinned size and SHA-256. The executor and the Mac's plan writer refuse a bad plan with the same words, because both take them from `PlanDecodeError`.
- The run record. `ExecutorRunRecord` is written last, as `run-record.json` by one rename, and it is the only channel from a node to the bundle. `ExecutorExitCode` gives a refused run an exit code of its own, so the orchestration layer can retry by code.
- One result on both platforms. `PortableStoragePlan`, `PortableMixedLayout`, `PortableFileJoin` and `PortableStorageStep` exist so the Mac import and a portable executor build the same run and write the same bytes. Change a storage rule here, never in one platform's copy.
- No process starts here. A storage step takes a `PortableToolLauncher` and a reader takes a `PortableChildLauncher`. On the Mac these are `NativeToolStorageLauncher` in Sources/LungfishWorkflow/Ingestion/FASTQIngestionPipeline+StorageStep.swift, which starts every tool through `NativeToolRunner`, and `ToolProcessChildLauncher` in Sources/LungfishCore/Process/ToolProcessChildLauncher.swift, which starts every child through `ToolProcess`. On a node they are `ExecutorToolLauncher` and `ExecutorChildLauncher` in LungfishExecutor. `scripts/ratchets/process-spawn.sh` exempts only `Sources/LungfishCore/Process/` and `Sources/LungfishExecutor/Process/`, so a process call added to this folder raises a count.
- What the layer may name. The five counts of `scripts/ratchets/portable-imports.sh` cover this folder, LungfishExecutor and CLungfishExecutor. Their baseline is `forbidden_imports` 0, `forbidden_tokens` 0, `executor_dependents` 0, `c_targets` 1 and `c_target_dependents` 0, and a count may only fall.

## Tests

Target LungfishPortableTests in Tests/LungfishPortableTests, nine files. Run only it with `swift test --skip-update --filter LungfishPortableTests`. Four files in Tests/LungfishWorkflowTests/ExecutorPlan/ import this module and cover the Mac side of the plan.

`bash scripts/linux/portable-tier.sh` is the Linux build and test. It cross-builds `lungfish-executor` for aarch64 and x86_64 static musl with the swift.org toolchain and the Static Linux SDK pinned in scripts/linux/toolchain.json, then runs the XCTest targets of this module and of LungfishExecutor on glibc in an arm64 Swift container. The container has its network closed under Docker and keeps the network under Apple container. Its evidence counts only when the last line of its output reads `commit <sha> clean`.

## Known traps

| Trap | Evidence |
|---|---|
| An import of Darwin, os, os.log, CryptoKit, Compression, Security, MachO, AppKit or SQLite3 outside an `#if` block builds on the Mac and breaks the static Linux build, and `forbidden_imports` counts it | scripts/ratchets/portable-imports.sh lines 4 to 6 and 51 |
| A code line with Bundle.main, Bundle.module, #filePath, physicalMemory, activeProcessorCount, host_statistics64, LUNGFISH_, _CONDOR_, condor_, HTCondor, ClassAd, APPTAINER_ or SINGULARITY_ raises `forbidden_tokens`, because the layer reads no bundle and no host probe and knows no scheduler. A comment may name them | scripts/ratchets/portable-imports.sh lines 4 to 13 and 52 to 55 |
| SHA-256 differs by platform, CryptoKit on macOS and swift-crypto's `Crypto` on Linux only, so hash through `PortableDigest` and never import either elsewhere | Package.swift lines 118 to 120 and 157, Sources/LungfishPortable/PortableDigest.swift line 12 |
| The Foundation of the Static Linux SDK has no `autoreleasepool`, so a pass-through stands in where the Objective-C runtime is absent | Sources/LungfishPortable/Autoreleasepool.swift line 11 |
| LungfishCore re-exports this module, so a name added here is visible to every file that imports LungfishCore | Sources/LungfishCore/LungfishCore.swift line 43, Package.swift line 186 |
| A process call added here raises a count, because only two folders are exempt | scripts/ratchets/process-spawn.baseline line 1 |
| The Linux tier cuts its view package from the root manifest between the two MARK comments that name LungfishPortable and LungfishCore, so keep both comments, and a target added between them joins the Linux build | scripts/linux/portable-tier.sh lines 187 to 189 and 200 to 201 |
| No test target is cross-built for musl, because the Static Linux SDK ships neither XCTest nor Swift Testing, so the tier runs the tests on glibc | scripts/linux/toolchain.json line 28, scripts/linux/portable-tier.sh lines 5 to 9 |
| The executor writes the `field` and `reason` of a `PlanDecodeError` into its refused run record and the Mac's plan writer shows the `reason`, so one edit reaches both | Sources/LungfishPortable/Plan/PlanDecodeError.swift line 9 |
