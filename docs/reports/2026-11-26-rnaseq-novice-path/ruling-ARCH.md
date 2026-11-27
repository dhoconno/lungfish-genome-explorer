# ARCH seat: the RNA-seq novice path (Opus 5.5, `claude-opus-5-5`; the prompt names no effort)

Read at `d5a95ec57`. This is the ARCH field's position on the brief. It is not an `lge-ruling`. I agree with (a), with the changes below. (b) and (c) are UX's call. My only ARCH constraint on them is in trap 9.

## 1. In now

1. **The install logic lives in LungfishWorkflow, and the CLI leaf stays thin.** Add one new file, `Sources/LungfishWorkflow/RNASeq/ReferenceSetInstall.swift`, with a `package` type. It works in this order: preflight, download, `ReferenceSetOwner(storageRoot:).build(request, argv:)`, then `SalmonIndexCache.ensure(SalmonIndexRequest(setID:, k: 31, decoys: .genome), linuxRoute:, argv:)`.
   - The leaf `lungfish-cli rnaseq install-reference --default <id>` sits in a new `RNASeqInstallReferenceSubcommand.swift` and is registered at `RNASeqCommand.swift:12-14`.
   - Use `package` rather than `public` so `docs/architecture/MODULES.md` does not change. Its public-type counts are generated and checked by `scripts/checks/module-map-current.py`.
   - Why: ARCH 1, and one path. The app never runs this in process (`docs/contracts/RUNNING-A-TOOL.md:18`). `ensure` and the cache `init` are already `package` (`SalmonIndexCache+Build.swift:15`, `SalmonIndexCache.swift:167`).
2. **Download with URLSession inside the CLI process. No `Process()` and no curl.**
   - Reuse the public `URLSessionDemoProjectArchiveLoader` through `DemoProjectArchiveLoading` (`DemoProjectArchiveLoader.swift:12-51`). It already handles progress, cancellation and non-200 responses.
   - Inject the loader so tests serve fixture files.
   - Do not copy `DatabaseRegistry`'s private delegate (`DatabaseRegistry.swift:1349-1376,1519`). A copy adds an `@unchecked Sendable` and fails the concurrency-hatches ratchet (baseline 148).
   - ToolProcess does not apply, because no process is started. Salmon and gffread already run through `NativeToolRunner` inside the owner and the cache.
3. **The command emits CLIEvent lines, not the summary document its siblings print.**
   - With `--format json`, use `CLIEventEmitter(enabled:, emit: printEventLine)` (`CLIEvent.swift:233-273`, `CLIOutput.swift:30`).
   - Emit `start`, then `progress` with a real fraction only for downloaded bytes, then a stage message for the set build and for the index build.
   - End with `complete(outputs: [setURL.path, indexURL.path])`. The transport fails a completion that lists no output (`CLISubprocessTransport.swift:280-284`).
   - On any refusal, emit `failed` and exit nonzero.
   - On SIGTERM, use `ManagedToolLeaf.cancellingOnSIGTERM` (`ManagedToolLeafSupport.swift:26`). Then emit `failed` with the cancel words and exit 125, as `DbCommand+ManagedUpdate.swift:36,89-93` does.
   - Human text goes to stderr while events are on (`CLIOutput.swift:44-50`).
4. **The app builds one invocation and reuses an existing operation type.**
   - Add `static func installReference(defaultID:)` beside `updateDatabase` (`CLIManagedToolsRunner.swift:77-80`), with subcommand `rnaseq install-reference` and arguments `["--default", <id>, "--format", "json"]`. Run it with `CLIManagedToolsRunner.launch`, so the recorded command and the argv come from one `Invocation` (`:42-51`).
   - Like the database update row, pass no `--storage-root`. The root reaches the command through the environment (`:53-54`).
   - Use `operationType: .download`, as `PluginManagerViewModel+OperationBegin.swift:64` does. A new case would grow `OperationCenter.swift`, which already sits at its 1385-line baseline (`file-size.baseline:130`).
5. **Provenance needs no new policy row.**
   - The leaf resolves to the group entry `cli.rnaseq` (`ScientificProvenancePolicy.swift:78-89,183`), as `rnaseq index` already does.
   - Add the pin `"rnaseq install-reference": "cli.rnaseq"` to `ScientificProvenancePolicyLeafTests.swift:473-484`. Without it, `testEveryLeafResolvesToItsPinnedEntry` fails (`:46`).
   - Pass `CommandLine.arguments` as `argv` to both `build` and `ensure`, so the set and the index each record the install command.
6. **Write ownership.**
   - The installer writes only its own download folder.
   - The set is written only by `ReferenceSetOwner`. Nothing else may write under `rnaseq-reference-sets/` (`docs/formats/reference-set.md:27`).
   - The index is written only by `SalmonIndexCache` (`reference-set.md:143`).
   - The app writes nothing after the command exits. It only reads again, as `PluginManagerViewModel+OperationBegin.swift:127` does.
7. **Keep the downloads, so that no record names a deleted file.**
   - The set's record names each input path exactly as it was given (`ReferenceSetOwner+Files.swift:33-34`). Deleting the downloads breaks ARCH 5.
   - Put them in `<storage root>/rnaseq-reference-downloads/<id>/<URL last component>`.
   - Add that folder to `docs/formats/reference-set.md`, next to the cleanup-skip line (`:153`).
   - A re-run finds the files and does not download again.
8. **The catalog data lives in one place in Workflow.**
   - Use the `ReferenceSetDefault.all` rows plus one list of the installable ids, read by both the CLI and the app.
   - The pane's empty-picker button calls the existing `PluginManagerWindowController.show(tab: .databases)` (`PluginManagerWindowController.swift:57`).
   - The catalog rows need a separate small `@Observable` model in a new file, because an extension cannot add stored properties. That keeps `PluginManagerViewModel.swift` (1059, at its baseline) untouched.
   - The only edit to `PluginManagerView.swift` (1283, at its baseline) is the call that adds the section. The landing raises that file's baseline row with `file-size.sh --raise` (`SCOPE-AND-DELIVERY.md:117`).
9. **Rollback (ARCH 7).** `rnaseq reference-set` and `rnaseq index` stay unchanged, along with their help goldens. The new leaf only combines them.

## 2. Traps

1. **Downloaded file names.** The set id hashes each input's `lastPathComponent` (`ReferenceSetOwner.swift:100-101,118-120`).
   - A file left under its URLSession temp name makes a new id on every run, so the set is never reused and its record holds a junk name.
   - Name each file by its URL's last component, write it to a unique `.partial-<UUID>` file and then use `PortableRename.exclusive` (SWIFT 4).
2. **Refuse before downloading.**
   - Run `RunFitPreflight.require(need: SalmonIndexNeed.need(diskFolder:), ...)` (`SalmonIndexCache+Build.swift:32-33`) before the first byte is downloaded.
   - Otherwise a Mac with less than about 16.6 GB of memory or 64 GB of free disk downloads about 1 GB, builds the set, and only then gets refused.
3. **A set without an index.** Quant needs a published index and refuses without one (`SalmonQuantRoute.swift:133-135`). The picker lists every set folder (`FASTQOperationRNASeqQuantPane.swift:26-38`).
   - If the index step fails after the set was published, the command must still end `failed`.
   - The catalog shows "installed" only when both the set and a `salmon-*-k31-genome` folder under `rnaseq-index-cache/<set id>/` exist (`SalmonIndexCache.swift:35,179-181`).
4. **Do not hash on the app side.**
   - Status comes from comparing the sha256 strings that `reference-set.json` records with the row's pins. Never re-hash a genome.
   - The set id depends on the gffread version, so the app cannot compute the id without starting a process.
   - Read the manifests off the main actor (SWIFT 2).
5. **Do not copy the sibling leaves' output.** In JSON mode, `rnaseq reference-set` and `rnaseq index` print one summary object (`RNASeqReferenceSetSubcommand.swift:91-94`, `RNASeqIndexSubcommand.swift:62-70`). Through the transport that becomes `missingCompletion`.
6. **Keep RNA-seq rows out of `MetagenomicsDatabaseRegistry`.**
   - That registry owns the Kraken2, EsViritu and TaxTriage rows (`PluginManagerView.swift:897-920`). Putting RNA-seq rows there gives the set two writers.
   - Do not nest the new section inside `databaseList` either. It would be hidden whenever that catalog is empty or loading (`:805-809`).
7. **The mouse row.**
   - `ReferenceSetDefaults.swift:41` is the human GENCODE base URL. Mouse needs `Gencode_mouse/release_M<n>/`.
   - The row needs both sha256 pins (`ReferenceSetOwnerTests.swift:290-298`).
   - Fix the "5.1 downloads nothing" note (`:5`).
8. **Ratchets and goldens the change trips.**
   - cli-parity-gaps (baseline 0): the new begin helper needs an App test that calls `RecordedCLICommand.parse` and names its type (`CLI-EQUIVALENCE.md:111`). Also pin argv equal to the recorded command, as the database update row's tests do.
   - Recapture `Tests/Fixtures/golden/cli-help`: `index.tsv` (rows near 209), `lungfish-cli.rnaseq.txt`, and a new `lungfish-cli.rnaseq.install-reference.txt` (`ScientificProvenancePolicyLeafTests.swift:113-128`).
   - file-size: see item 8 of In now.
   - process-spawn and native-tool-runner-in-app must not rise.
   - Where `--threads` cannot apply, refuse it in words, as `RNASeqIndexSubcommand.swift:44-46` does.
9. **Labels in (b) and (c).** Rewrite only the words people read. Keep `OperationType` raw values, accessibility ids, catalog ids and CLI names, or the panel history, the XCUI smoke and the help goldens move.
10. **Errors from the reused loader.** Its errors say "demo project" (`DemoProjectError.swift:42-67`). Map them to the installer's own words (UX 1).

## 3. Deferred (backlog rows)

- **REFCAT-REPLAY.** A replay test of `rnaseq install-reference` that uses a fixture row and a stub loader, runs in the integration tier and compares as `.bundle`.
- **REFCAT-REMOVE.** Remove a catalog reference from the Databases tab through the owner's uses check (`reference-set.md:155`).
- **REFCAT-PREBUILT-INDEX.** Download a pinned prebuilt salmon index, so a Mac under 16.6 GB can still count.
- **REFCAT-DOWNLOAD-RECORD.** A record that ties each downloaded file to its source URL. The annotation URL is not in the set's manifest. BIO decides whether it is needed.
- **REFCAT-STORAGE-MOVE.** Carry `rnaseq-reference-downloads/` across a storage-root change, as for sets (`reference-set.md:161`).
- **LOADER-NEUTRAL-NAME.** Rename `URLSessionDemoProjectArchiveLoader` and its errors to a neutral file-download loader.
