# SDD ledger — plan: docs/superpowers/plans/2026-09-15-allele-aware-primal-scheme.md

## Execution roots
- LGE: /Users/dho/Documents/lungfish-genome-explorer/.worktrees/allele-aware-primal-cli; base ae3ab4808deb371a80727a5db20d79f965974b8a
- Native: /Users/dho/Documents/lungfish-genome-explorer/.worktrees/allele-aware-primalscheme; base 2abc3207629aacb101f1c04a4f57348ef5b903b2
- Approved spec includes persistent histories in §5.4.
- User authorizes autonomous CLI implementation and MHC legacy comparison, advanced CLI controls. GUI remains behind CLI acceptance.

## Preflight
| Task | Internal consistency |
|---|---|
| 1 | Snapshot/runner precede real scientific execution; receipts required on failure |
| 2 | Immutable contracts and coverage/history tests precede consumers |
| 3 | Discovery retains failed diagnostics, selectable chemistry independent |
| 4 | Configurations carry selected-site identity and subset lineage |
| 5 | Exact support distinct from seed specificity; pair-local certificates |
| 6 | Search preserves incumbent and explicit work limits |
| 7 | Strict output saved first; cumulative exposure and history preserved |
| 8 | Publication validates selected outputs independently; new capability contract |
| 9 | Historical legacy comparison labeled separately from controlled ablations |
| 10 | LGE CLI only after native evidence; provenance rehydrated |
| 11 | Evidence packet precedes GUI acceptance; no GUI work in scope |

| Producer / consumer | Shared interface/files | Disposition |
|---|---|---|
| 1 / 9 | benchmark runner | Sequential extension |
| 2 / 3 / 4 | catalog/types/support | Contract freeze then sequential ownership |
| 2 / 3–8 | history records | Stable evidence and dependency keys |
| 4 / 5 / 6 | exact selected configurations | Validation before search |
| 5 / 7 / 8 | constraints, stage validation | Same fresh validator contract |
| 6 / 7 | search state | Strict incumbent retained |
| 2–7 / 8 | native CLI publication | Integrate frozen interfaces |
| 8 / 9 / 10 | v2 artifacts/capabilities | Native evidence before wrapper |
| 9 / 10 / 11 | evidence reports | Distinguish scientific policies and workflow |

## Progress
- Setup: isolated worktrees created; native environment installation in progress.

- Native baseline: 143 tests passed, one upstream kaleido deprecation warning (21.28 s). Python 3.12.8 isolated uv environment.
- LGE docs contract commit: 6477f2724.
- Task 1: benchmark_runner (Sol) active; architecture-preflight Astra read-only active.

- User advanced-control emphasis captured in spec §11: versioned balanced preset with explicit override precedence, science vs compute help, no ignored options.

- LGE baseline: build succeeds, selected suite fails 5 publication tests because test lookup omits a Resources subdirectory present in the current Xcode resource bundle. Log /tmp/allele-cli-baseline-tests.log. Diagnose/restore reproducible test fixture payloads before Task10 verification; do not attribute to new algorithm.
- Ruling: permit benchmark-only fixes concurrently with record implementation in disjoint files, as the approved plan permits Tasks1/2 independence — no shared scientific interface mutation — cost if wrong is integration rework; each remains independently reviewed.

- Baseline diagnosis: source fixtures ARE tracked/present; bundle copy is Contents/Resources/Resources/PrimalScheme3CoverageNative, tests resolve Contents/Resources/PrimalScheme3CoverageNative. Correct resource resolver at Task10 with baseline failing test evidence.

- Baseline fixture fix complete: d69995498,18 publication tests pass; Astra validation approved baseline-fixture-review.md.
- Task1 review fix round1: five receipt/control defects, Sol correcting scoped benchmark files. No scientific baselines until receipt fixes pass review.
- Task2: Astra allele_records implementing immutable metrics/history; architecture note supplied.

- Task2 provisional contract frozen; exact allele-coverage tests6 pass. Root flagged metric ID version and immutable mapping/digest caching before finalization.
- Task3 variant_discovery Astra implementing isolated coverage_discovery/core/test_variant_discovery files against frozen Task2 contract; no shared-file writes.

- Task5 numerical-kernel reference: /Users/dho/Desktop/sandbox/mhc-primal-scheme/combined-diagnosis-20260915/score_blocks.py defines both native orientation/offset ranges and verified 43,043 comparisons against boolean do_pool_interact at9 thresholds. Reuse algorithm with boundary regression, not chemistry ΔG substitution.

- Task2 implementation abd291c:13focusedpass. Independent Astra review task-2-review.md identified3 blockers; fixround1 active with original implementer (masks identity/checkpoint hashes/stale dispositions).
- Task1 fix c4179b5:7tests pass. Re-review resolves2–5, identity/default-contract validation still open; fixround2 active. No scientific run yet.
- Task3:22focused discovery tests reported passing; native-score offset corrected using existing verified audit.

- Task 1: complete (fb0fe83,c4179b5,696186b);10focusedtests pass, Astra task-1-review-final.md approved all findings. Snapshotv3 frozen original independent397/combined206 artifacts; upstream/existinglge3 pendingexecutions.
- Task2 fix0850597:26focusedtests pass, reviewpending.
- Ruling: default discovery to first complete chemistry-compatible length per row/anchor/profile, retaining examined failures and explicit longer-length non-enumeration; exhaustive lengths remains advanced CLI opt-in — analytic full MHC exhaustive ceiling19.48million row-length records makes default impractical — cost if wrong is missed longer compatible choices, measurable via opt-in sensitivity runs.

- Task 2: complete (abd291c,0850597),26focusedtests pass; Astra task-2-review-final.md approves all3fixes.
- Task4 subset_configurations Astra active on coverage_variants.py/test only; derives omitted spanbounds from catalog config and will support family-local ledgers to avoid O(global-catalog) copying perproposal.
- Early Task9 upstream-original baseline: benchmark_runner Sol prepares measured probe+matrix and one original3.3.0 combined run; exact default bounds180–220,D0 labeled descriptive notcontrolled. Existing originalenv read-only. Target output upstream-original-baseline-01.
- Hardware memory48GiB; exhaustive discovery analytic19.48Mrow-length records informs preset first-compatible.

- Benchmark interpretation risk: homologous MHC loci may suffer strong cross-target specificity blocks under positiveD2000; existing lge3 report used HLA and showed low coverage under stricter rules. Do not hide this behind aggregate gain or relax specificity implicitly. Report per-cause loss and compare policy-matched arms; user requested capability evaluation, not guaranteed95%.

- Task5 policy clarification needed at implementation: specificity finite observed-row seed windows (including internalN) vs extrapolating arbitrary whollymissing terminal seeds. Do not invent coordinates or imply unobserved genomic sequence assessed; exactsupport cannot use missing. Ask Astra validator to bound uncertainty explicitly so missing terminal padding does not create every imaginable product.

- Upstream baseline complete scientificexit0,13.5725s,66amplicons291primerrows. Harnesspostvalidation flagged only input_bedfile null vs upstreamstr(None). Root performed provenance-bearing exactone-mismatch audit without rewriting originalreceipts: /Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/upstream-original-baseline-01-metadata-audit/audit.json exit0; rehashed36input/outputartifacts. Common allele metric/specificity scoring stillpending.
- Upstream harnesssupport8665303: workingdirectory, hashedprobe artifacts, booleanflag contracts and selectable nativeconfig keys,10tests pass. Include in finalharnessreview.
- Task3fix clarified frequency by independent anchored LENGTH cohorts, perrow ambiguitymass≤1, terminalunavailable footprint excluded, generateddiagnosticvolumecannotinflate; sharedsite frequencies independentfirst/all enumeration. Agentimplementing.
- Task4implementation111f341:29focusedtests pass; independentreview active.
- Task5 subset_configurations Astra now implementing new allele_validation.py and tests, sourcev1unchanged. Scope finite suppliedrowseedwindowsN/IUPAC conservative; observedseed fullfootprintextension uncertainblocked, no inventedterminalpadding seeds. Serializedscopeexplicit.

- Task3 frequency fix48b0d70 approved by Astra task-3-review-final.md,36focusedpassed.
- Task4fix7712d6f complete,93focusedpassed; Astra task-4-review-final.md approves all3findings.
- Task6 allele_records Astra active using additive existing _Search hooks, dynamic exactconfig registry, aggregate exposure checks.
- Task3 discovery performancefixee6e153 replaces repeatedly serialized fullrow with precomputed rowdigest;37focusedpassed, independentreview pending. Root preparing provenance-bearing bounded10anchor discovery probe before fulllocus/MHC.

- Task5 4e9be6a completeimplementation,39focusedpassed, independentreviewqueued; adding smallpublicexposurecounts accessor forsearch objective.
- Probe f81cb05, bounded10anchors eachside KIR2DL04 completed10.498s,314MBparentRSS,36.19MBoutput,5723evidence/14109assessments/15526events; inputs/source/runtimeunchanged. Performanceprobereviewapproved.
- Ruling: add SQLite-backed compressed history before fullMHC; measuredhistoryvolume makes retainingallrecords inRAM/perrecordfsync impractical. Preserveallrecords/contracts/indexedquery and durablecheckpoints; costifwrong backendintegration rework. Astra variant_discovery implementing.
- Task8a parser/capabilities assigned subset_configurations Astra because tool rejected Solfollowup withagentthreadlimit; explicitlower-modelattempt documented. Task8b rootpublication381ad52,10focusedpassed, independentreviewqueued.

- Task5 independent Astra APPROVED task-5-review.md (4e9be6a +13a861b compact exposure counts),50combined focusedpass.
- Task6 implementationb10f80a,38focusedpassed; independentTask6reviewactive. Preliminary defect: safe measured dimer edges become deletionwitnesses; queuedactualviolatingedgefilter.
- Task8a85be6c2,113focusedpassed; independentreview foundprivateConfigpresetoverride notrecorded andlostroundtrip. Queuedrejectprivatechemistrykwargs. Localisolateduvsync now3.3.0+lge.4; managedenv untouched.
- Task8b381ad52 reviewP2BEDnamecrossartifactidentity fixed83f8db3;11focusedpass, Astraapprovedtask-8b-review.md.
- Task7root100f4b2 +810bfae; preserveprofile/goal, failedpublicationcorrectivesnapshot, retainedfailedledger, durablecancelreason.14focusedpass; reviewerremainingtwo: empty salvage masqueradesstrict, lasttiercancelstopreason. FixesqueueduntilfullKIRsourcefreezeends.
- SQLitehistoryb62abd7 independentAPPROVED task-history-scaling-review.md,23focusedstorage+salvagepass; fullcombined128earlier. Memorybounded compressedrows/indexedquery.
- Groupedorigincompactionb3a42eb53focusedpass, exactprimitive reconstruction/scienceprojection unchanged. Independentreviewactive allele_records. Measured same20anchorKIRprobe2.2207s125MBparentRSS17.96MB vsSQLiteuncompacted14.53s127MB96.1MB vsJSONL10.498s314MB36.19MB. Newfile receipt sources/input/runtime unchanged.
- Rootnativepipeline8f3eee7 provides earlyallelemode routebeforelegacycloudfilter, strictpublishbeforetiers, rawinputcopies/freshreload, alltiersledgerincludingfailed, relativeartifacts+finalprovenance. Emptyendtoendtestpasses;21focusedpipeline/salvage/legacypublicationpass. Independentreviewactive variant_discovery.
- FullKIRdiscovery-only probe running session18116/pid14135 at .../allele-coverage-development/discovery-probe-full-kir-01; command scripts/probe_variant_discovery.py --msa snapshotv3/snapshot/inputs/2248690E-880F-4975-B721-F6F422876196.fasta --full --cores4 --history-backend sqlite. Source frozen duringprobe; allagentsreviewread-only, root onlyLGEdocs/reads. Snapshotstarted~2m49 beforelastcheck,913MBdisk1.54GBRSS. Needreadreceipt whenends beforequeuednativefixes.
- RemainingnativeTask8: durableindexedqueryCLI + savedoutputauditorCLI, exactsavedinputre-audit againstrawFASTAcopies atbundlelevel, strongerprovenancefailure tests/full-suite, cache/reuseexperiment strategy. Task9fullMHCmatrix/commonlegacyrescoring outstanding; Task10LGECLI (noGUI) andTask11report outstanding.

- Tasks6/7/8a/8b/8c reviews now APPROVED: task-6-review-final.md, task-7-review-final.md, task-8a-review-final.md, task-8b-review.md, task-8c-review-final.md. Native fullsuite453pass17.55s (/tmp/allele-native-suite-current.log).
- FullKIRprobe completed399.44984s,1.713GBpeakparentRSS,2.074GBoutput,42170sites2498selectable54972families; oldconditions. Latest7ca64e6groupedconditioncompression56focusedpass/Astraapprovedtask-3-performance2-review.md.
- Ruling: immutable discovery reuse with exact raw target/order/discovery biology+kernel fingerprints, copied origin catalog/history and separately labeled prior dispositions. Needed to make matrix practical; cost ifwrong rejected reuse/rework, never silent biology mismatch. Astra variant_discovery implementing, Sol native_cache_wiring reassigned independent legacy metric scorer.
- FullMHC run frozen detached nativeworktree allele-aware-primal-benchmark-01 at7ca64e6 with isolatedvenv. Initial mhc-union-subsets-01 intentionally cancelledexit130 (retainedreceipt) upon discovering normalized snapshot inputs differ from upstream originals; canonical run mhc-union-subsets-02 uses same original primary.aligned.fasta files as upstream, preservesN. 11MSAs union/subsets,200/150–250,2pools,4cores,strict120s+3salvage60stiers. Session recorded in conversation.
- Task8d subset_configurations active inspection query/audit including immutable origin cache lookup; no GUI changes.

- Task8d implementationc364233/f71641220focusedpass; independentinspection_review Astra active, candidate multi-target ordering audit defect under verification. FullMHCsession26388/24757 continues isolated unchanged snapshot.
- Ruling: prepare LGE CLI option/contract scaffolding while expensive native MHC discovery runs, but do not mark integration accepted or make GUI changes before CLI evidence review. Stable nativeAPI permits independentfiles; costifwrong adapterrework.

- Task8d: complete c364233/f716412 +fix13796fc, task-8d-review-final.md APPROVED all3findings;23focusedpass10.55s. Queries include bounded snapshotdispositions; multirawinputauditcanonicalorder fixed.
- Cache implementationf3f079d androotwiring5de80fc ready;65modulecombinedtests and91rootoptions/pipeline passed. subset_configurations Astra independentlyreviewing task-cache-and-wiring-review.diff. Rootwiring adds--reuse-discovery/panel-cache, actualworkers0, copiedorigin pointer anddurablepresearch discovery-catalog.
- Historicalmetricscorer1df971b Sol implemented33tests; rootindependentreview3fixes (allowall-gapcols/emptyBED, changedinput-sourceinvalidates success), Solfixactive. Authoritative reportcopiedfrommistakenmainSDD toworktreeSDD.
- LGE Task10 detailedimplementationbrief prepared task-10-implementation-brief.md, notyetdispatched. Criticaladapterrisk: preserveNinnewmode; keepderivedCSVoutsideimmutable nativeprovenanceinventory; fresh nativeauditmustbindcurrentbytesandruntime, not freestandingvalidblob.

- Cache d1391d9 + wiring5de80fc independently APPROVED task-cache-review-final.md,99focusedcombinedpass. Legacy scorer fc4b129 now supports explicit original/normalized row aliases; all11independent andcombined+upstreamcommonmetrics completed with unchangedinput/source receipts. Draft native-cli-report.md contains actual descriptivehistoricals.
- Correction to earlier test count: 453 was scoped native/LGE suite, not entire repository. True fullsuite at648passed/1failed exposed pre-existing core digestion test offset bug; identical failure reproduced on untouched baseline2abc. Test-onlyfix4adb708 selects exclusiveend25 for gapindex24,27coretests passed. New real nonemptytwo-target discovery/selection/audit integration test7fd2906 passed71.51s. Independentreview and truefullsuite rerun underway.
- Task10 Sol active with task-10-implementation-brief.md; sequential CLI/options, audit/publication, savedinspection work, noGUI. Full11MSAdiscovery frozen7ca continues >30min, durablehistory~6GB. Do not query liveSQLite with longscans.

- Native truefullsuite after gaptestfix and realnonemptyintegration:650passed,1upstreamKaleidodeprecationwarning,155.15s; /tmp/allele-native-suite-final.log. Task9scorer/fixture/integrationreview APPROVED task-9-scorer-and-integration-review.md (13independentfocusedpass).
- Root wrote cli-controls.md guide. Task9cachedmatrixrunner assigned subset_configurations Astra; normal-onlymatched>=19catalog is explicit narrower controlledk17/k19comparison (not union-wideclaim). Variant_discovery read-onlyhistoryperformanceassessment active.

- Existinglge3control completed from untouched2abc baselineworktree with isolatedvenv. existing-lge3-control-01/panel:15amplicons42primers,189.414s,wait4peakRSS3,761,192,960bytes,stableinputs/source/runtime,validnativeaudit. Commonmetric13.1911%mean, A1/B0%. DescriptiveD2000,k19,fullspanobjective with .90target. No controlledgainclaim. Existing-lge3-common-metric-01 complete ownreceipt.
- LGEoptionsrootreview task-10-options-review.md requested3nativeparityfixes; Sol6ef0debcc reportsfixed and23pipeline tests pass. Finalcontract/inspection stillactive.

- Native finalintegrationreview APPROVED native-final-review.md,20independentfocusedpass71.92s. Cachedmatrixrunnerc205981 independentlyapproved task-9-cached-matrix-review.md,9tests5.58s. Newfrozen detached matrixworktree allele-aware-primal-matrix-01 atc205981+ownvenv; do notedit. InitialMHC7ca continues~50min7.8GBhistory.
- Added bounded regionaldiagnostic task tovariant_discovery: exactlegacyanchor/sequence matching, selectedclass support/trimmedcoverage, freshinsertionvalidation withcompleteoutputevidence andprovenance. Rulingdefault16expensivecandidatevalidations (up to1000explicit), rankoverlapfirst, discloseomittedcount; cheap unmatchedclassification all. No incrementalnewscientificvalidator.

- History hot-cache17f5c49 trial:100-anchor baseline11.5927s vs11.7560s, exactsameorderedrecorddigest, no measuredspeedup. Ruling: revertunprovenhot-cachecomplexity; independent8/64MiBSQLitepagecacheexperimentonfrozenc205, preservingFULL/DELETE/batch1000 andfullprovenance. Actual3-secondliveprocesssample showed1235pread/2273samples and287fsync, motivatingpagecachetest. No live/frozenwriterchanges. Costifwrong missedoptimization/rework.
- Task10 contract64662527e rootreview5blockers; Sol70b7659f1 addressescacheworker0,fulloptions,exactcommands+alltiers,incrementalattemptreceipts,strongcapabilityidentity. Rootscopedreview1–3addressed;4/5residualactualexecutable/runtimeidentitybeforeprobe andmandatorynativekernelfiledescriptors queuedminimalfix. Realfreshwrapper11.6s andcachereuse5.1s reportedpassed. Savedinspectionstillpending.
- Regionaldiagnostice5359c7 rootreviewrequestedfamilylookupindexandexplicitomittedselectedfamilyvariants/perclassbindingsupport. Variant_discoveryresumedfixes thenindependentAPFSclonehelper(nohardlinks)+fallback/integrity/independencetests.

- Regionaldiagnostic1539e55 rootreviewAPPROVED task-region-diagnostic-review-final.md;14coveringtestsreportedpassed, target+anchorindexed andomittedvariantclasssupportexplicit. No claimonactualMHCuntilcompletedrun.

- CacheCOW5a652b9 rootreviewAPPROVED task-cache-clone-review-final.md;21coveringtestspassed42.31s includingrealDarwinclone. Independentfilecopies/fallback, finalhashverificationunchanged, nohardlinks. Discoveryfingerprintunchangedagainst7ca. Re-freezematrixafterhistorybackenddecision.

- Ruling: adopt64MiBSQLitepagecache only, retainingFULL/DELETE/batch1000/schema. Provenance-bearing500anchorprobes8=101.469713s,64=83.978790s,256=88.306622s;190203orderedrecords andcatalogsidentical,17.2376%gain64vs8.100anchorABBAmeans11.799156vs11.207040s. No evidence256helps. Costifwrong56MiBadditionalconnectioncache/smallworkloadmemory; no extrapolatedfullMHCgain. Astraimplementerminimalconstant+effectivepragma test, thenfinalfreeze.

- Nativec6aa554 historypagecache rootreviewAPPROVED task-history-page-cache-review-final.md;59targetedpassed. Frozenmatrix02detachedc6aa554+ownPython3.12.8venvsetupcomplete; truefullsuite session30661/log/tmp/allele-native-suite-matrix02.logrunning. OriginalfullMHC7ca unchanged.
- LGETask10dbb3a12c4inspectionimplementationreportedcomplete; independentAstrareviewvariant_discoveryfoundmissingwrapperfailureprovenance(confirmedrealpool0failure), perclassdeficitdisplayomission; Solfixqueued. Rootrealrelocationdeferreduntilbinaryfixfreeze.

- Ruling: add single-original-MamuA1 pilot fromfrozenmatrix02 afterfullsuite completes, sameunion/subsetsciencegeometry/defaultbudgets/salvage asinitial11MSArun. Neededearlyselector/allelesupportinsight whileall11discoveryremainsIOheavy. Explicitlyindependentdiagnostic, notcombinedcompatibility/improvementclaim. Costadditionalcompute/disk/IO; originalinputsunchanged. subset_configurationsAstraownsrun+analysis, no sourceedits.

- Finalfrozennativematrix02fullsuite687passed,1upstreamKaleidodeprecation,178.48s; /tmp/allele-native-suite-matrix02.log. SingleA1pilotreleasedtorun.

- FullMHC7ca at~92min indexedreadonlycheckpoint:12,470,423,552-byteDB,latestassessment1243547 high-gc target-occurrence-fa11efd2cee39d43416a6671359efb3e4154af4486cc31711f3d715a892622f9=MamuB sourceindex6. First6MSAsprimerenumerationcomplete; familyconstructionnotyetbegun. Noerrors; originalsourceunchanged.
- SingleMamuA1pilot frozenmatrix02 session48263 wrapperPID74604; agentownsrun/audit/outerreceipt. Outputmamu-a1-union-subsets-pilot-01, outer-execution/audit siblingdirs.

- LGETask10inspectionfixe7f3ec4d2 underAstrareview. RootrebuiltCLI(noassumptionfromskipbuildtests)8.14s. RealrelocationcheckPASSED5.20s withoriginalfresh/reuse/cache/syntheticinputtemporarilyabsent, latestCLIinspect/history/auditall0 usingmatrix02; alloriginalsrestored/sourcebundleunchanged. Receipt allele-coverage-development/lge-wrapper-relocation-01/provenance.json. Freshnon-skip-buildfocusedSwifttests session32009 /tmp/allele-lge-final-focused.logrunning; priorlastskip-builddidnotcoveradditivetargetsummaryline, implementerreportcorrected.

- LGEinspectionfixe7f3ec4d2 independentlyAPPROVED task-10-inspection-review-final.md;3currentbinaryrealrejectedquerychecks retainedexactwrapperargv/nativeruntime/failedstatus/walltime+allbyteverifiedinputsoutputs, stableexecutablehashes. Oneearlierunconfirmedtransientduringconcurrentbuildnotreproduced, candidlyrecorded. Rootfresh87focusedtests passed(78XCTest+9SwiftTesting), noGUI. CLIguidecommit1cbb5f34c. FinalwholeLGEreviewvariant_discoveryactive package lge-final-review.diff. ActualMHCacceptanceremainspending.

- LGEwholebranchindependentAstraAPPROVED lge-final-review.md baseae3ab4808..1cbb5f34c, no newloadbearingfindings. EngineeringTask10complete; scientificacceptanceexplicitlypendingfullMHCmatrix. Nativefinalwholeintegrationreview+storage/diagnosticfixreviewsapproved, frozen687tests; LGE87freshfocused+realrelocation+3realerrorprovenancetests.

- Ruling: boundedexternalnormalized-historyfeasibilityexperiment, no production/frozenedits. ColdMHC~2handA1~20min stillhistoryIOheavy; investigatedrepeatedlongIDrelationindexesactualsample. Astra variant_discovery comparescurrent64MiBvsintegerrelationprototype onimmutablecompleted500anchorhistory, exactcanonicalstream+snapshot/referential/queryequivalence, FULL/DELETE/batch1000, source/runtime/inputoutputhashes/time/RSS/DBsize. Mustmeasureinsert+reload+query, explicitlyexperimentalformat; no migration orliveDBaccess. Cost30–45minprototypeeffort/temporarydisk; retainoldengineeringapprovalandrequireseparaterulingbeforeanyintegration.

- Ruling: adopt explicit SQLite integer-relation history v2 for future runs after separate review. External reversed production-append replay means92.9904s text vs66.2620s integer (28.7% lower), storage379713536 vs223232000bytes (41.2% lower); canonical/compressed records/indexes/snapshots identical, reload unchanged, bounded queries equivalent. Tradeoffs mean append RSS+9.6%, unbounded query+49.5%. Scope history/inspection/cache schema readers+tests/docs, v1 read/append in place, no migrations. Instance-owned bounded cache clears rollback/close; checked relation insertions. Astra variant_discovery implements; root/Sol review before new freeze. Full7ca/A1c6aa remain untouched.

- SingleA1pilot immutable strict tier published/native audit valid:10 assignments,39.1308% mean distinct-class trimmed coverage; classes32.1160–43.0336%, no dropout. Below saved independent86.7%, not improvement evidence. Wholepilot/salvage/auditpending. Astra analysis will distinguish budget/seed starvation vs measured constraint rejection. Sol native_cache_wiring read-only scheduling review: initial full/normal seed budget and fill queue revisit behavior. No selector edits before evidence/ruling.

- Scheduling read-only review confirms one global deadline serializes full/normal seeds before expanded construction/repair; causal attribution to pilot pending counters. Separately confirmed fill refresh resets queue positions and replays already-consumed valid zero-gain/capped/pool-incompatible candidates, spending attempt budget. Ruling: Sol fixes only within-fill replay in coverage_search.py+tests, TDD multi-batch regression, attempt identities scoped to add-only fill and reset on later fill/repair; verify monotonic constraint assumption. Disjoint from v2 history work. Root Astra review before new freeze; phase scheduling unchanged pending empirical metadata.

- Historyv2 97b1996 rootAstrareviewAPPROVED task-history-integer-v2-review-final.md. Root74focusedpassed56.82s; implementer86focusedpassed55.44s; exactcanonical/compressed compatibility and v1/v2 failure/reload/cache/inspection verified. Expected scientific integration source-drift rejection during Sol edits retained, not regression. Final combined frozen suite pending queue fix. FullMHC at~2h32 latestassessment1778675 still MamuB normal strand/profile pass, DB17.86GB; do not extrapolate completion from profile order.

- Selector replay ddf45ae rootAstraAPPROVED task-selector-replay-review-final.md; local attempted identities, monotone built-in states, fresh repair fills, no phase scheduling change. Sol26final shared-engine tests/132prior related pass. Frozenmatrix03 detachedddf45ae created with ownvenv, includes v2 history97b1996. Full frozen suite next, no cold data rerun.

- Frozenmatrix03 ddf45ae fullsuite718passed,1upstreamwarning,177.73s; /tmp/allele-native-suite-matrix03.log. All11 discoveryfingerprint files byte-identical to initial7ca fullrun. Readyforcached scientific followups after pilotcomplete. Astraread-only phase-schedulingproposal underway conditionalon actualpilotcounters; no phasebehaviorchangeauthorizedyet.

- Pilotnativecompleteexit0: strict120.0038s reached both work-capped seeds(full976/normal2112families), expanded32/143297families(2141states/1355configs), zero starts/repairs. Salvage1 expanded12; salvage2/3 cutoffduringnormalseed, zeroexpanded. All39.1308%. Discovery2090.505s; strictsearch+validation442.210s; publication107.897s; salvage1470.719s. Wholebundleauditagentactive. Rootpanel-cache export matrix03 session36058, newmamu-a1-discovery-cache-01, no duplicate agentexport.
- Ruling: nativeAstraimplements opt-in serial|reserved phase reservations, serialdefaultretained pending samecatalog comparison. Actualpilotexposes curtailedsubsetwork/norepairs and latertierseedstarvation. Preserve globalcutoff/incumbents; truthful phase/subphase service vs exhaustion; firstcycle20/40/40 seed/construction/repair and repair20/20/60 prep/cleanup/exchange; enumonlyadvancedCLI. Dynamicconfigbridge avoidsdiscoveryfingerprintchanges. Sol implementsSwiftbridgeafter matrix03tinyv2smoke, noGUI. Rootpreparingcached03strictserialcontrol; proposed04reservednotyetapprovedforrun.

- Pilotcacheexport matrix03 completeexit0 wall67.25146s, mamu-a1-discovery-cache-01/cache-export-provenance.json. Rootexternal run_cached_mamu_a1_control.py (derived originalpilotwrapper, ownidentity/exactargv/cachehashes/wait4peak/freshaudit receipts) started cached serial03 control session65310, outputmamu-a1-cached-serial03-01; strict120s,starts4repair2,salvageoff, same originalA1/MSA/cache/science. Not a fullcombined comparison.
- Matrix03currentLGEsmokePASSED task-matrix03-lge-smoke.md, /private/tmp/lge-matrix03-history-v2-smoke-01/verification.json: freshdesign/inspect/v2history/audit all0valid; priorv1savedhistory queriedunchanged. Sol nowLGEphasebridge; nativeAstra phaseimplementation active, sharedcontractfrozen in messages.

- Pilotwholefresh auditvalidexit0 (~485s), outerwrapperfailedpostcheckwrongreceiptfilename(provenance.json vsactualpanel-provenance.json), preserved. Separateverify_mamu_a1_pilot_completion.py completionverificationexit0 bindsactualnative/audit/probe/identity. Rootcached03 copiedwrapper sharesknownpostcheckfailure, also separatelyverifiedsuccess; future run_cached_mamu_a1_control_v2.py fixespath withoutmutatingactiveoriginal. Trackednative cachedmatrixharness alreadycorrect; no scientific rerunneeded.
- Cached03serialstrict native323.294s audit126.106s both0valid, mean46.03845394%,10amps,classes40.6485–47.2898%, wait4nativeRSS3266805760bytes. Search120.023s, full2032/normal4528seedfamilies,32expanded,zero repairs. +6.91pp vsoriginalpilot, notisolatedqueuecausalityunderwallbudgets.
- ActualA1specificitydiagnosis:2797/2859unaryspecificityfail;206dimerfail(204overlap);60unaryvalid. Strict49495productwitnesses:48353concretebothdesignatedfootprints,31sameanchorbeyondrowedge,1111alternativefootprint/orientation.2696rejectedconfigsonlysameanchor,100mixed,1alternativeonly. Sameanchor near-templatehits atintendedsite rejectedbecause exactcoverage-derived signatures includeoligosequence; no off-targetPCR inference. ExampleR5primeindex4mismatch predictsidentical178bp span alsoexactcertifiedbyretainedvariant. Astra subset_configurations preparingnarrowoptinconcrete-designated-site policy proposal, exactcoverageunchanged, genuineoffsite/edgeuncertaintyblocked; no kernelcodeauthorizedyet.
- Phase e105af4 rootlogicreviewnoallocationblocker, requestedsmallperphaseobjective/acceptedrepair/cursor-before observability beforeapproval;179focusedpassed. NativeAstrafixactive; SolSwiftbridgeactiveaftertransientmodelcapacityretry; noGUI.

- Phase scheduler e105af4+1217c5c rootAstraAPPROVED task-phase-scheduling-review-final.md.179focused+53observability followuppass, finalfreeze04fullsuite requiredbefore realruns. Serialdefault; optionalreservedprioritymaintainsglobalcutoff/incumbent; progressobjectives+acceptedrepairs/cursors. Root beginsmatrix04 detached1217c5c ownvenv.

- Ruling: approve optional concrete-designated-sites intended_product_policy specification task-intended-site-policy-proposal.md. Astra subset_configurations implements native/profile/options/audit/evidence with legacy exact-supported default; separate allowed_intended_products, zeroextraexactcoverage, same-complete-config concretefullfootprints only, off-anchor/other-target/orientation/uncertaintyblocked; existing exactsecondarycerts unchanged. All discoveryfingerprintfilesimmutable. Astra variant_discovery independentlyreviewsdesign thenimplementation. SolphaseSwiftbridgecontinues; newpolicySwiftcontract laterafterfrozeninterface. Decision groundedactual49,495witnessdiagnosis, no feasibility/safety/coveragegainclaim.

- Frozenmatrix04 1217c5c fullsuite735passed,1warning,180.44s; /tmp/allele-native-suite-matrix04.log. Root starts matched04serialcontrol with corrected immutableexternalwrapper_v2, outputmamu-a1-cached-serial04-01. Reserved04 control follows sequentially forcomparison samebuild/science/cache/budgets.
- Swiftphasebridge509932809 rootreviewfinds P1 reservedlater-start phases validly nullbudget wronglyrejected; P2 validno-assessable-targets emptyphaseprogresswronglyrejected. Solfixesrequestedwithnative-shapedregressions beforeapproval. Defaultlegacyrecordsbackwardcompat otherwise sound.

- Swift phase bridge6ab073839 root Astra APPROVED task-phase-scheduling-bridge-review-final.md; both native-shaped edge cases fixed, seven fresh contract tests reported. Serial04 wrapper/native/fresh audit all exit0:46.03845394% mean/10amps, native326.704s/audit127.414s, native wait4 RSS3955392512bytes. Reserved04 matched frozen1217c5c control started session17019 via immutable corrected wrapper_v2, same source/cache/science/budgets.

- Native intended policy92ea291 scoped implementation complete; independent Astra review active. Frozen matrix05 detached92ea291 plus ownPython3.12.8 environment, fullsuite session52846/log/tmp/allele-native-suite-matrix05.log. No policy MHC runs until review. Reserved04 strict stage valid39.4684% versus serial46.0385%; reached two repair rounds with zero accepted replacements. Whole audit pending. Serial default retained; use serial for upcoming policy comparisons. Root comparator script records complete input hashes/options differences/phase and class deltas; external control_v3 explicitly supports policy without modifying existing run scripts.

- User steer: hour+ design acceptable if effective;120-second runs are diagnostics, not finalqualitytarget. Astra subset_configurations preparing read-only coherent long-run/work-budget proposal, no automatic defaultchange. Native05fullsuite756passed1warning181.61s and independent policyreviewAPPROVED57focused+shared-anchor falsification; root starts exact05matched serial120s control viawrapper_v3. Reserved04wholeaudit+wrapperexit0; comparatorphase-comparison04-01 confirms sole resolvedoptiondifferencephase_scheduling;39.4684% vs46.0385%,fourrepairtrials/noaccepted, serialretained.

- Root approves observational progress subset of quality-search proposal: timestamped append-only sidecar at phase/incumbent/throttled30s ticks, stable incumbent references/exact objective/target coverage/work/cursors, explicit provisional status, final provenance hash/partial failure retention. No full checkpoint/resume, no search-order/kernel/default changes. Astra subset_configurations implements+fixed-work invariance/overhead tests; independentreview before nextfreeze. Existing05policy controls continue immutable;600s current-caps calibration follows, then reviewed longer quality arms. Geometry/cadence/seed-cap changes remain conditional on measured starvation.

- Full cold7ca indexed readonly checkpoint: assessment2358034, history23737651200bytes; linked row-enumeration evidence target5290ff4c... verifies Mamu-DQB (index8), high-gc forward. No completion estimate from profile order. Originalwriter/runtime/source untouched. Exact05serial120 control fullysuccessful:46.03845394%,native332.352s,audit127.559s,wait4RSS3897196544bytes. Concrete05matched control active session59074.

- Concrete05paired120 control fullyauditedexit0:15.000546%/3amps, native326.635s,audit127.029s;4,929pairchecks vs576exact, seed-only time cutoff, so not a feasibility ceiling/defaultquality judgment. Root comparison05-01 proves sole resolveddifferenceintendedpolicy. Astra variant diagnosing immutable residual blocks. Root current-caps600sconcrete05 calibration running session58454/outputmamu-a1-cached-concrete05-600-01 (samefrozen scientificsource). Native progress2b18b7b implemented64targetedpassed; rootpreliminaryreviewnoblocker, Solindependentreviewactive. Frozen06detached2b18b7b fullsuite/setup session5556. Solmatrix05realLGEnewpolicy2witnesses+legacyv1 smoke all8commandsvalidexit0, reporttask-matrix05-lge-smoke.md.

- Root + independent Astra design APPROVED task-concrete-secondary-policy-proposal.md/review: optional ordered-disjoint-concrete-designated-sites/v1; complete same-row A+B four selected full footprints, allACGT+actualterminal-supported, ordered/disjoint, unchanged dimer/overlap/D/uncertainty/other-target guards, zeroextraexactcoverage. Actual03diagnosis2740exploredpairs soleblockedbyexactsecondarycertificate; notjointfeasibility. VariantAstra implements isolated allele-aware-primal-secondary branch codex/allele-concrete-secondary at2b18b7b; mainnative progressfix unaffected. Newdefaultnotapproved. Root willreview/integrate thenfreeze.
- Progressreview found unresolvedfailed-incumbent refs/cleanupmasking/stalecompletedphase; fixesauthorized. Root ruling loggingtime charged to wallbudget is expected, fixed-work invarianceonly, no pauseddeadline or globaltimeextension. Full frozen06suite762passed183.19s butprogressfix review stillrequired.

- Progress8d168377 rootAstrafinalAPPROVED task-search-progress-review-final.md; independent16focusedpass3.12s, selecteddefinition/catalog/stagepolicyfailure refs resolve, cleanuporiginalerror preserved, terminalphaseclear. Walldeadline chargeslogging intentionally; fixed-work invariance not wallcutoffequality. Nativecurrentmain8d; secondary isolatedbranch active. Concrete05-600wrapper nowexit0; strict28.3224%/4amps, noacceptedrepair, timecutoffinexchange after363.96s. Fullcompare/report next.

- Concrete secondary95c5d00 rootAstraAPPROVED after independent code/test review; integrated61d6ac8 atop progressfixed8d, root26passed2.04s. Frozenmatrix07 detached61d6ac8 ownvenv/fullsuite session34844. Optionalpolicy only, defaults/coverage/discovery unchanged. Exact05-600 control remains active; no simultaneous heavy selector started.

- Exact05-600 wrapper/native/freshaudit all0valid, identityunchanged;46.79449301%/13amps,4acceptedrepairs,19,213attempts/11,379unary/2,303pairs/1,010,268frontierevals/22trials. Native848.998s,audit137.142s,RSS3237134336B. Matchedintended-policy-comparison05-600-01 successful solepolicyoptiondifference versusconcrete28.3224%. Frozenmatrix07 integrated61d6ac8 fullsuite794passed1warning192.07s. Root starts newsecondary07-600 diagnostic session7633 withbothconcretepolicies, samecurrentworkcaps/cache/science, provenancewrapper_v4; source differs05byreviewedprogress+newpolicy so labeldescriptiveuntilmatched07oldcontrol.
- Boundedgainreplay03 shows3.075xrankcomponent, exactwinners/objectives; Astraindependentdesignapprovesstate-local8192LRUgainonly, clearadd/drop, nofractioncache/clock/work/orderchanges. Rootauthorizes subset_configurations implementation+fixedworktests onmainnative61d. Productiongaincache notyetimplemented/reviewed.

- Gainmemo20fe1368 rootAstraAPPROVED task-gain-memoization-review-final.md; independent60passed1.16s, implementer76pass. Production8192LRUreplay3.04xrankcomponent exactvalues/winners, notwholeoptimizer. Frozenmatrix08 detached20fe1368 ownvenv/fullsuiteactive; mainnativeclean. Bridgeb8cd+8ec7916e8 independentlyAstraAPPROVED aftershared-physical-ownerfix; realmatrix07smokeSolactive.

- Correction exact05-600 optimizer.repairs_accepted is3 (not4); four objective-history improvements duringrepair include another improvementcategory. Publicreportcorrected tothree acceptedrepair exchanges. Matrix08 fullsuite806passed1warning183.17s; log/tmp/allele-native-suite-matrix08.log. Secondary07 at481s provisional83.9993% inrepair, stillawaitfinalaudit. Qualityproposal task-long-quality-effort-proposal.md recommendsserial3600s/8192attempts/32families/8starts3repair after08audit, othercapsfixed, noreservedimplicitdefault.

- Secondary07 strictstagepublishedvalid86.71904714%/18assignments,600.0047ssearch,53expandedfamilies,23,124pairs,2repairtrials,optimizer.repairs_accepted0 (bestincumbentimprovedduringrepairrefill, notacceptedexchange counter). Wholefreshauditcurrentlyrunning. Root starts frozen08sameoptions600control session91011 while07selectionfinished/finalauditonly; perstateLRU issole productionsearchdifference, observationunchanged. Matrix08 already806passed. LGE07smokeSolall7commands0 plusold-v1unchanged; reporttask-matrix07-lge-smoke.md, `/private/tmp/lge-matrix07-secondary-smoke-02/verification.json` a5e4325378052ff80c74acca89f6e43ecf26b4bba5345da6e46885893f8fab51. Syntheticselectedpanelhad2intendednew+2exactsecondary, nonewfour-sitecert; realA1Swiftcontractvalidationplanpending.

- Secondary07 completed wrapper/native/freshauditall0valid, allidentitiesunchanged. Mean86.71904714%/18amps,classes84.59162663–89.45392491. Native830.672789s,audit131.528027s,RSS7333822464B.403allowedintended+1740secondary(1380newfour-site+360exact). `mamu-a1-secondary-descriptive05-07-01` completedcomparison, sourcealsochangedprogresssoexplicitdescriptive. Root08controlactive91011; hourqualityoptionsfileprepared quality-work-option-v1.json (8192attempts32families8starts3repair/newsecondary), notyetexecuted.

- RealA1Swiftintegration bab50ab8a rootstaticreviewAPPROVED, agent1passed251.637s all1380realnewsecondarycertwalked, productionbundlewriteractualXCTestidentity, relocatedCLIhistory/audit valid, source40fileinventoryunchanged. RootintegratedSwiftfocusedtestactive /tmp/allele-lge-integrated-focused-final.log. Efficiencyreviewrejectsduplicatefullcold: measuredpagecache17.2%/integerreplay28.7% reductionnotall11estimates, currentv1origincompatible. Continueoriginal26388; no concurrentcold/restart unlessterminalfailure/resourceceiling.

- Secondary08 root91011completednative/outer/freshauditall0identitiesunchanged: same86.71904714%/18amps;69expandedfamilies/25,701pairs/8413attempts/6repairtrials vs07 53/23124/6991/2. Native830.966848s,audit130.196146s,RSS7824801792B; gain-cache-comparison07-08-01 verifiesallresolvedoptionsequal. Noadditionalcoveragegain. RootSwiftintegratedfocused151total/7envskips/144pass/0fail, logged/tmp/allele-lge-integrated-focused-final.log; realA1envtestseparatelypass.
- Measuredunboundedfull diagnosticgraphcaches materialmemoryrisk:128samplereplaypickle5zlib1 ~1.388MBvs22.82MBcontainers-only, fasterthan deepcopy, exactshapes preserved. Rootauthorizes variantAstra narrowtrusted-ephemeral _candidates/_pairs compressedentrywithsmallreasonsfastpath; no eviction/recompute/historychanges. Mainnativeimplementationunderreview, freeze09/hourfollowafterfullsuite. Noextra09shortcontrolrequired; longrealrun/auditwillmeasure actualmemory, noisolatedspeedclaim.

- Compression01cafef rootAstraAPPROVED, independent43passed2.14s;frozenmatrix09ownvenv/fullsuite12128active. Rootapprovesoptionalversioned search-effort standard-v1|quality-v1 convenience perproposal whilefrozen09hourwillusefullyexplicitcontrols. Standarddefaultunchanged120/4/2/2048/16;quality3600/8/3/8192/32 onlyeffort, no scientificpreset/policy/scheduling/salvagechanges. NativevariantAstra+SwiftSol parallelwithfrozeninterface, all11discoveryfilesimmutable. Preserveexplicitmask/olddefaultequaloverrides/savedresolvedvalues and capvalidation. Noqualitydefaultswitch/GUI.

- Frozen09 01cafef fullsuite830passed1warning188.46s; rootstarts hourA1quality session31220/outputmamu-a1-cached-quality09-3600-01 at~22:50local viawrapper_v4+quality-work-option-v1.json, serialbothconcretepoliciesstrict−26salvageoff,3600/8starts/3rounds/8192attempts32families othersunchanged. Captureprovisionalcurveandactualwork/RSS; finalauditautomatic. Thiscomparechangeswork+memoryrepresentation vs08, noisolatedtime/speedclaim. Originalfull11cold26388continues5h; no duplicatecoldauthorized.

- Nativeeffort158a4a3 rootAstraAPPROVED task-search-effort-native-review.md; independent111passed2.31s, implementer200broader+159focused. Frozenmatrix10detached158aownvenv/fullsuite32144active. SwiftbridgeSolactive/variantAstraread-onlyreviewcoordinating. Hour09~572s stillnormalseed67.6723%, workcapschangegreedypath vs08; noqualitygainclaimuntilfinal.

## Search effort integrated verification

Frozen native matrix10 (`158a4a3`) full suite: 854 passed, one warning, 193.08 seconds, exit 0 (`/tmp/allele-native-suite-matrix10.log`). LGE after effort bridge and decoder tests: 157 focused tests, 7 environment skips, 150 passed, no failures, exit 0 (`/tmp/allele-lge-effort-final-focused.log`). Astra approved bridge267778174; real matrix10 smoke retained successful design/inspect/history/audit and old-native explicit-quality failure receipt. Hour matrix09 run remains provisional. Regional A1 394:644 diagnostic launched read-only against completed secondary07 with 16 bounded alternative insertion tests.

## Regional diagnostic complete

Frozen matrix10 script against completed secondary07, region BED394:644,16alternatives: exit0,1098.4653s; freshinputauditvalid, original/source/runtimeunchanged. Sixclasses each200/250=80%.989historicalrecords matched903uniqueconfigs;16unarypass,32insertions alloverlap/31specificity/15dimer+strict-exposure.887configs untested; nofeasibleceiling claim. Nearbyselectedfamilies allretaineligiblevariants. Publicreportupdated with interpretation andreceiptlinks.

## Matched hour-budget search control launched

`mamu-a1-cached-narrow09-3600-01` started with frozen01cafef/matrix09 via reviewed immutable v5runner; originalA1/cache and bothconcretepolicies unchanged, strict−26/salvageoff/serial,3600seconds with4starts/2repair/2048attempts/16families. Comparator is active quality09hour with8/3/8192/32; same scientific inputs/source/globalbudget, different4workcontrols and wrapperv4/v5. Native selector options and identities will be compared after audits. Shared-machine concurrency prevents isolatedspeedclaims. This is one practical preset-control experiment, not an unrestricted matrix. WrapperPID20736/session18177. Atquality2900s provisional87.28117%; finalauditpending.

## A1 finite-catalog availability complete

Approvedexternal87b9c63c/testse19ccfd0 pinnedunchanged inoptimistic-catalog-coverage-frozen01; rootcompleted07run session36467 exit0 in76.4996s. All143297families/10191eligiblesites/6classes/859782familyclasschecks complete; independentselected86.719047% reconstructed andcontained. Singletonandallsubsetrelaxation97.2349276% (classes96.8633–97.9500), onlyterminalgaps. Nojointfeasibilityclaim. Oneactualsubset2164:2413 selects2/3F4/5Rstillall6classes;85:315supports3classes,217:399supports5. Input/source/runtime unchanged. Publicreportupdated.


## Audited broad hour run complete

Quality09 session31220 completed all statuses0, fresh raw audit valid, all identities unchanged. Mean87.28117183%/18amps, range83.08167467–90.13203614%; +.56212469pp vs08 but fourclasses lose .6826–2.4207pp and two gain4.0837/4.5865pp. Native3981.0563s, audit146.2695s, outer4140.1413s, nativepeak5666750464B. Search3611.4206s, onecompletedstart/twoacceptedrepairs/439searchedfamilies/20503materializedconfigs; lastgain2750.654s. Descriptive08→09 comparison completed with receipts; fivework/timecontrols pluscompression sourcechange so noisolatedspeedclaim. Narrow09 samehour/source/science stillactive; at1671s provisional88.1221%, nofinalclaim.

Full11 indexed bounded inspection identified current cold-discovery target04673… as Mamu-DRB (source9), backed by separately parsed original inventory. External fixed-panel backgroundscreen ready for independent Astra review; no real screening run yet. Native additive label map Solactive; discoveryidentity unchanged requirement retained.


## Fixed-panel background experiment launched

Astra approved external background_screen.py af76991b/testse84f022f after11passingtests and mandatorysourcebindings/existingoutputfailureguards. Root froze byteidentical script/tests in fixed-panel-background-screen-frozen01 and launched original11 vsfixed completed07A1, explicitcooperative1800s, session45958/outputmamu-a1-fixed-panel-original11-background-01. Componentonly specificity experiment, no additionaltargetprimers, discovery, optimizer or combinedcoverageclaim. Original11cold26388 and narrowerhour18177 remainactive.


## Fixed-panel added-background screen complete

Session45958 exit0, complete90contexts (18unary72samepoolpairs), exactsavedA1baselineparity,80newfailedcontexts(40eachpool),6687concrete witnesses: A2 3422,A4 2839,B274,E152. Noother-targetexemptions; unchangedA1evidence/support checked. Allinput/source/runtime identitiesunchanged, sourceparitytrue,5.7263swall/2.3815sscreen,376061952BpeakRSS. Frozenaf76991b, outputmamu-a1-fixed-panel-original11-background-01. Addedbackground aloneinvalidatesthisfixedpanel undercurrentrule; doesNOTprove dominance inoptimizedfull11oractualPCRproducts. Astrareviewinginterpretation/subsetderivingunarycounts/lengthbinswithreceipts; nodefaultrelaxation.


## Native labels approved and frozen

Astra approved115878f+236e74a labelsidecar: originalrawheaders/rowIDs/classaliases, ownversion/publicationref, fresh/reuse/oldabsence/tamper/relocation tests, excludedfromscientificidentity. ReviewP2 wholecataloglabelaudit fixed by fresh authoritative targets+canonicalobservations thincontext. Owner67passed126.37s; independent14passed4.50s. Protected11discoveryfiles+coverage_catalog unchanged. Rootfrozematrix11 at236e74a, own3.12.8venv, fullsuite71113active /tmp/allele-native-suite-matrix11.log. SolauthorizedLGECLIlabelbridge,noGUI.

Backgroundinterpretation independentlyrecountedall90contexts:18/18unaryfail(1609),62/72pairfail(5078); all18have someaddedwitness≤250,17haveatleastoneboth17seedexactwitness. Defaultunchanged. Rootauthorizedboundedexistingwitnessfulloligoexactness annotation (nativekernelreadonly, nopoliciessciencechanges) withprovenance/tests; variantAstraactive. Subsetpreparingprioritizedfull11cachedexecutionplan withoutreadinglivehistory/running. Narrowhourat2478.88s provisional89.502675%, finalauditpending.


Matrix11 fullsuite session71113 completed0:865passed1upstreamKaleidowarning190.21s. Publicengineeringreportupdated236e74a/865. SolSwiftlabelbridgeactive. Originalfull11cold26388 continues; cachednarrow09at2762s provisional89.502675%. Subsetequivalenceaudit for historicalindependent11targetdata active, no scientificreruns.


## Full-oligo annotation and historical equivalence

Boundannotationcompleted0/2.256s,6687witnesses/90contexts, originalrawidentity/terminalfieldsverified. Frozenannotator7410cdc92d92668254d3606f4a25ad68bd8f5691c1226569dc993124118677d6/test9f6c44c6a54d3b9238c25ab511733eba9d4c4cdb6c53e41b817edd4977eb5df9; agent13pass.11s/rootindependent13pass.14s. Rootreadsourceorientation/bindings and independentlyrecounted1250remainingnon-full-exact150–250unarywitnesses acrossall18. Outputmamu-a1-background-full-oligo-exactness-01. 17/18configshavesomeboth-full-exact150–250crossproduct(166witnesses); all-sizefull-exact174unary551pair. Noacceptance/coveragechanges, broaderintendedrolesdesignassessmentpendingAstra.

Historicalequivalence-01 completedsuccess1.067s,121MBRSS, all14commonmetricreceipts112distinctinput/outputfileshashverified. All11independentFASTAsbyteidenticaluniquematchtocanonical11despitedifferentUUIDs; all103rows/classes/order/masks/referenceequal, noduplicateclasses. Combined/upstream/LGE3also11/11sameinputorder/bytes. Norescoreneededforbiologicalequivalence; independentpanelsnotjointcompatible. Publicreportupdated.


## Matched narrow hour audited complete

Narrow09 session18177 CLOSEDexit0; mean89.50267498%19amps, class85.3718–93.2765. Native3934.61246s(directchild3939.43237),audit146.20111s,outer4096.33709s, nativepeak5144625152B/audit4450729984B. Auditvalidrawreparsedtrue, allstatuses0identitiesunchanged,secondaryErrors[]. Search3603.49693s,877searchedfamilies/40235configs/66412expandedstates/166repairtrials/4acceptedexchanges/onecompletedstart/0completedfullrepairrounds; lastgain2478.88075s. Seedfills277.2022s vsbroad993.264; exchangework3196.5175s vs2164.981.

`mamu-a1-hour-effort-comparison09-01` complete0 verifiesonly4resolvedworkdifferences (starts8→4,rounds3→2,attempts8192→2048,families32→16) same09source/inputcatalog/hour/science; narrowermean+2.221503pp,4classesgain2lose,minimum+2.29011pp. Sharedmachine/wrapperv4v5meansnoisolatedspeedclaim. `mamu-a1-narrow-descriptive08-09-01` complete0 narrowvs600source08mean+2.783628pp, compression source/timechanged. Public6classpercenttablecheckedagainstretainedcomparison; no95/combinedclaim. Nextfull11qualityprioritizesnarrowexplicit3600; versionedpresetsunchanged.


LGElabelbridge6a5a2f2e9 AstraAPPROVED independent13pass (5bridge8inspect). Rootintegratedfocused --skip-build37247 completedexit0,164total7envskips157passed0failure, log/tmp/allele-lge-label-final-focused.log. No executable rebuild duringSolrealmatrix11smoke. Source/runtime/toolidentitiesstayfrozen; actualsmoke/relocationpendingseparate.


Matchedhourfigure completed provenance-boundmamu-a1-hour-comparison-figure-01 PNG/SVG/PDF/plot-data,11consumedartifactbindings, canonicalclass→row→headerconfirmed,1.770srenderidentityunchanged. RootvisuallyinspectedPNG:clearaxes/provisionalvsfinalmarkers/4gain2loss/95aim/fourcaps/sharedmachinecaveat/readableunclipped. Addedpublicreportfigure.

Soltinyrealmatrix11labelsmoke complete9commandsall0/stderr empty; relocatedinspect/history/auditwhileoriginalabsentpassed; originalinputrestoredunchanged. `/private/tmp/lge-matrix11-label-smoke-01/verification.json`, result9A8F7037-6468-447C-B7C5-63EB8ED17AE1, labelmapvalid1target2rows1class. Rootauthorizedone60sactualproductionLGECLIcachedA1design fromsnapshotoriginal.lungfishmsa usingfrozen11/existingA1cache, engineeringrealMSAaliases/stableIDs/pipelineonly; failclosednocoldfallback, no qualityclaim. Solactive.


Full11 boundedread-onlyindexedlatest8records (2stimeout,noscan) at~01:07local:history41.980GB/position19033000, row-enumerationtarget3c6c54fb… verifiedMamu-E/source10, normalprofile reverseanchor316. FinalinputMSA/finalprofile inprogress; noETAorcompletionclaim. Parentnative24757/session26388 continues, no livecopies/mutations.


Counterinterpretation correction from _Proposals.metadata/_expand/refresh: in subsets mode `searched_families` counts subset-expanded families only, NOT full/normal seedfamilies. Publicreportclarifiesnarrow877vsbroad439subsetfamilies; seedsnarrow2032full/4064normal vsbroad8352full/17056normal(overlap,notdistinctsum). Broader examinedmoreseeds; narrower spentmoretime onsubsetrepair. No nativecounter/sciencechange.


## Selected-variant replacement and production label integration

Root approved frozen selected-variant diagnostic e3061ed3828dfe37704e5b892e08d46b395692bf060b663cea21a3687ae31369 after complete source review and independent11tests0.85s. Session95939 completed0, all5 independent original-panel replacements, baseline paritytrue, identitiesunchanged,31.1218s. Outputmamu-a1-narrow09-one-variant-replacement-01; Astra interpreting numerical blockers/support without historical-cause inference. Three partialselectedfamilies include2/3RIGHTexample.

Actual production LGE cachedA1matrix11 integration completed: resultF61458CD-4513-4DDF-ADE7-232C853A4773; six originalhumanlabels/stableLGE/nativeIDs verified, reuse true/workers0, inspect/history/rawauditall0, source/cacheunchanged. Deliberate60sengineeringrun68.071215%/22ampsnotqualitybaseline. Initialnegative-argexit64 andcorrected successbothretained. Rootreadverification.json.

Productlengthexternal7b6b0d3 reviewed source and independent2tests0.40s; approvedcompleted-audited-panels only. Narrow09 exactlyreconstructed89.502675%;123classproducts118inrange5above251–252; exclusiveoutofrange4.330041pp. No validity/PCRinference. Freeze and briefacceptancechecklist delegated; no newsciencearm.

Full11 cold now generated-family events (last indexedposition19959000,history43.714GB), past final-MSA oligo row stage. Stilllive; no cacheexport/historyextraction. Sol preparing immutable matrix11/v5actualcapability/input/optionexecutionfreeze before gates.


Fivevariantinterpretation02 complete0/.7537s/16consumedfilesbound/identitiesunchanged. Rootreadfullreport: trials1/2 LEFT at2569:2815Pool1 conflict−35.74489925/−34.44627562 withRIGHTs in732:977; wouldrecover same67A1*011bases butinvalid, below−32floor. Trials3–5 validredundant;2/3RIGHT863:1067 becomes863:1069 withouttrimmedgain. Allspecificitypass, noclaimhistoricalcause/multipleadditionfeasibility. Publicreportupdated; immutable01interpretationretainedsuperseded02prosegeometrycorrection.


## Full11 execution freeze approved conditionally

Rootread exact ordered3argv and26options, capabilities/kernel/source identities; verifiedcommandSHA5ac577c3f13b1462a2b0ebf095455c0c34527e41c741eb9cb920bc5a6eeebc61. Immutablefull11-execution-freeze11-01 identitymanifest67a07a53692dc4c65496bd9f14e6c722cb83dd79d9cacc538bdfac7fc0036862, preparationsuccess/sourceRuntimeStable/inputordertrue/protected11equal. Approved gateauditcold→cacheexport→narrowstrict3600 onlyaftereachpriorgatepasses andidentityunchanged. Freshnativeauditor supportsoldabsenceofnewlabelmap; currentselectionpolicy remainsrecordedoldpolicy incolddesign. No sciencecommand launched, livecoldstillwriteractive.


Final native integrationdelta7fd2906→236e74a approved in native-final-delta-review.md, no newloadbearingfinding. Crossmodulecertificate→rawaudit/cacheidentity/workoptions/progress/labels/historychecked; reviewerexplicitlyreliesonindependentscopedreviews forowncomponents. No newscience/testorliveDBread. Rootreadreport and confirmedupcomingLGEcombinedinputorder isrequest.inputURLs.enumerated→inputs→[inputs], notsorted; original11nativecacheorderpreservablethroughproductionCLI.


## Cold checkpoint cost assessment

Bounded readonlyindexedmonitoring verifiedfamilyassembly DQB→DRB→E byjoininglatestfamilygeometry siteID toitsfirstrow-enumeration evidence usingentity_records_lookup+recordsIDindex (LIMIT8,2sdeadline; nolargescan). At02:18lastcommitted24561000/~47.181GiBhistory; later8h40nativealiveCPU11.4%RSS8.78GBsnapshotnotpeak. 1sOSsample/tmp/mhc-cold-checkpoint-sample-01.txt showsSQLiteBtreepread dominance; cannotattributeentireruntime or specificSQLbyOSstackalone.

Astraread-onlyassessment task-full-prefix-checkpoint-assessment.md: currentprefix closure joins logicallyredundantonlyundertrustedvalidatedsinglewriterinvariants; naivecountsequality skips realcorruption rejection, reproducedintinyv1+v2temporaryDBs. RootRuling: defer guardedwriterfastpath (unownedmutation/data_version/total_changes/transaction/failuretrust handling) until separatelyimplemented/reviewedifneeded; no current/frozen codechange. Cost: keepcheckpoint overheadinthiscoldsource; correctnesscontractpreserved. Existingv2integerstorage+64MiBimprovementsalreadyinmatrix11, notanunmeasuredpromiseaboutwholeMHCspeed.

Rootverified selected03bade7c full2569:2815 has5distinctsupportedclasses inretainedselected-configurations.json.gz. Addedpublicexactfive-of-sixexample; otheromittedvarianttesttrialsunchanged.


## Reviewed v2 physical checkpoint joins and next freeze

Native74102b8 replaces only v2 compatibility-view/ID round trips with physical integer joins; all three closure predicates remain, v1 unchanged. Sol60history+53cache/inspection tests pass; independent Astra review task-v2-prefix-joins-review.md APPROVED with60tests1.02s. Rootread actualdiff/tests/review; full native suite15108 completedexit0,876passed1upstreamKaleidowarning181.11s, /tmp/allele-native-suite-74102b8.log; mutableclean. No full-MHC speedclaim or activev1benefit.

Root authorized preparing NEW matrix12/freeze12 identities/commands with same science/options/order, preserving unusedfreeze11 unchanged; Solpreparationactive. No scientificcommands yet; closedcold→freshrawaudit→cacheexport gates unchanged. Root will verifynewfreeze beforeexecution.

Static Astra task-full11-history-scaling-assessment.md reviewed: downstreamaudit/export/reuse avoid semantic replay of24.56Mrecords, but stream originhashes6timesforinitialaudit/export and9perwrappedarm, plus wholecatalog/ledger/dispositions allocations and duplicateauditcatalogs. Logicalreadcountsnotphysicaltraffic/timeestimates. Rootdecision: noadditionaloptimization now; measureone serialunionbaseline beforeoptionalcontrols. Keepallvalidation/no livecopy/migration.


Matrix12/freeze12 READY and rootconditionallyAPPROVED. Rootreadreadiness, verifiedidentitymanifest4d3855c95f24bc6568c3459a73530f23c74d098d456a1f0b115de2e69a12d4d0 andcommands4e9964a50d7b2dd942d02142fc1fe4a718e78cf2408b2bd00e47886a0667b78f. Independentnormalized3argv+expandednativeargvexactparitytrue; optionbytesidentical. WholecommandJSONdiff onlyaddsrootfullsuitepassedprecondition beyondpathnames. Suitewasrunmutable74102b8, samecommit/runtimeversionsasfreeze12; notreruninfrozenworktree. Rootchoosesmatrix12 fornextaudit/cache/hour; prepared11retainedunexecuted. Coldstillactive~9h11, no completedreceipt/cache. Publicengineeringcountupdated876 andCLIpath12; actualLGEproductionverificationremains11.


Oldcoldtailassessment reviewed: clean7ca strict+3salvage needsfivefurtherfullsnapshotchecks afterdiscovery(15closurequeryinvocations+10DISTINCTentityqueries), notboundedbysearch120/60seconds; no normalhistoryexport/reload/copy, finalDBhashsequential. Firststandalonefullcatalogonlystrictpendingpublication; validatedstrictstage surviveslaterfailurebutdoesnotconstitutesuccessfulrootreceipt. Rootkeepsrunintact; norecoveryshortcut/livebackup/mutation/cancellation. Latestboundedmode=ro snapshotmetadataquery stillNone, history50659807232bytes. Cannotforecastremainingtimeorassumeeachquerysamecost.


## Automatic continuation while user away

At~03:12local coldnative24757/session26388 remainsrunning9h22m, SQLitewaits/no successfuloutputyet. Allindependentimplementation/review/preparationworkcomplete; avoidminute-by-minuteunchangedpolling. Created ACTIVE threadheartbeat `continue-mhc-primalscheme-evaluation` every10minutes, verifiedtoolview, tocontinueexistingauthorizedwork: detectcoldcompletion→verifyactualnativereceipt→preparedmatrix12rawaudit→cacheexport→serialnarrowhour→full11comparison/diagnostics/LGECLIgate. Automationpromptrequiresreadingthisledger, identity/closedwriter/freshoutput/diskchecks, no duplicatedcold/livecopy/sourcechanges, notifymeaningfulchangesonly, andpauseafterCLIwork/finalreportdone. NoGUI/managedruntime/merge/push/release. Initialcreatewithoutdestinationreturnedargumenterror; corrected destination=thread succeeded. This is continuation scheduling, notclaimtaskcomplete.


## Discovery checkpoint completed (04:05–04:06 local)

Heartbeat09:04:30Z verifiedsamecoldPID24757/argv. Historygrewfrom50659807232to50960502784bytes; initialboundedreadonlymetadataquerydeferredwithdatabase-locked duringwrite, connectionclosed; no write/mutation. After55swaitsession26388stillrunning, indexedmode=ro query confirmedcommitted snapshot(stage_id=discovery,ordinal0,position24561230). Latestcommittedrecordassessment stage=strict position24592230. Nativeelapsed10h16m59s, RSS12966640KiBsnapshotnotpeak;504GiBdiskfree. Thusdiscoverycheckpointfinished andstrictselectionhasstarted; no panelcompletion/audit/cachegateclaim. Continueexistingcoldthroughremainingcheckpoints; matrix12follow-oncommandsstillunexecuted.


## Full11 cold stage-only milestone (Luna, 2026-09-16)

The original frozen-source full11 cold job `mhc-union-subsets-02` (source `7ca64e68690f6e4db5b91f54bfe8a4847c402a62`, old short-120s/default intended + secondary policies) remains active under the original native process; no root completion receipt exists and matrix12 gates have not started. Its finalized strict-stage files at `/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/mhc-union-subsets-02/stages/strict/stage.json` and `validation.json` were observed at `2026-09-16 06:03:35 -0500`. `validation.json` reports `valid: true`, mean coverage `11.89410429%`, worst target `0`, and no target at the 95% goal. This is stage-only evidence from the old run, not the matrix12 narrow-hour arm, which has not run; the overall native writer remains active.

## Full11 cancellation and runtime diagnosis (Luna, 2026-09-16)

User-authorized cancellation sent SIGINT to native PID 24757 at 11:10:03 -0500; it remained present for 50 seconds, then SIGTERM at 11:10:53 -0500 terminated it within approximately 5 seconds. The hot SQLite journal and all output remain preserved; no native completion receipt exists. Strict and salvage-1 stages were valid but both remained at 11.89410429% mean coverage. Diagnosis and ranked measurement/fix proposals are in `task-cancelled-mhc-runtime-diagnosis.md`; this interrupted v1 run is ineligible for matrix12 audit/cache gates.

## User cost and stopping policy update (2026-09-16 morning)

User explicitly requests GPT-5.6 Luna for simple job running/benchmarking and simple implementation; reserve Astra sparingly for oversight and consequential algorithm-plan changes. User is away another hour and authorizes autonomous continuation. User accepts stopping below95% when performance plateaus; do not endlessly chase the aspiration. New bounded agent luna_benchmark_runner (GPT-5.6 Luna, low effort) owns routine statecheck→completedcoldverification→preparedmatrix12gates and writes task-luna-benchmark-status.md. Root must not duplicate routine monitoring/benchmark work.

Updated existing heartbeat to30minutes (from10) and explicit Luna delegation policy to reduce Astra usage; same thread/gates preserved. Afterfirstcombinedcachedbaseline, require a concrete hypothesis/plausible useful gain for any extraarm; no exhaustiveoptional14armmatrix. A1narrowhour89.5027% remains bestcompleted, notwholepanelclaim. Stoppingforplateau stillrequires truthfulper-target/per-allele comparison, limitations and appropriateCLIverification; 95% isnotacceptancegate.


## Scalability hold after user regression question

User correctly challenged roughly15h earlyNEW7ca run with11.8941%strictcoverage. Root acknowledged severe runtime regression and no demonstrated combinedcoverageimprovement; closestlegacycontrol189.414s/13.1911% differsnormal/k19vsnewunion/k17, savedcombined67.3%also differentsettings. Do notdescribe theseasfullycontrolledalgorithmcomparison or confuse earlyNEWwithlegacy. Full11strictartifactvalid isstage-only, overallstillactive15h23m/no rootreceipt atlatestLunacheck.

HOLD automaticmatrix12audit/cache/hour launch pending revisedscalabilityoversight; heartbeatupdatedtomatch, frozencommandsuntouched. Luna owns bounded synthetic history-checkpoint-scaling-01 benchmark: actualcurrentAPI v1vsv2 deterministic1000/10000/50000chains, separateappend/firstandsecondcomplete checkpoints,size/queryplans, canonicalequivalence, ~10min/2GiB bounds. No liveDBreads/sourceedits/unsafevalidation-skips; write task-history-scaling-benchmark.md. Purposequantifyalreadyimplementedv2benefit/residualbottleneck beforefurtherexpensiveMHCwork. Parentoversightonly, preserveuserLunacostpolicy.


## Bounded synthetic scaling evidence and revised next gate

Luna benchmark1aad40844 completed6cases1k/10k/50kchains (3records/chain) currentmatrix12v1vsv2; canonicalrecords/snapshotIDs equal atallsizes. At50k: v1append27.526s,checkpoints.550/.519s,197586944B; v2append20.362s,checkpoints.246/.323s,103268352B. Total56.665s, receipts/helper retained includingfailedattempts. Rootread task-history-scaling-benchmark.md; syntheticfitsmemory/no7ca8MiBcomparison/not24.6Mrecords/noend-to-endclaim. No unreviewedproductionfix warrantedfromthistestalone.

Refinedhold: aftercoldsuccessfulclosedcompletion, existingreviewedmatrix12freshrawaudit andcacheexport MAYproceed; staticassessmentprovesnoglobalhistorysemanticreplayinthesepaths (streamhashingstilllarge). ONE-HOURSEARCH remainsheld. Beforethat, propose bounded real-data cachedscalingcheck with explicitwall/memoryobservations/failureprovenance andfrozenoptions; rootapproveworklimits onlywhencompletedcacheavailable. Do notduplicatecold, patchliveSQL, skipintegritychecks orspeculativelyaddtrustfastpath. Usercost/stoppingpolicyunchanged. Heartbeatupdatedexplicitlywiththisclarification.


## User-authorized selective discovery implementation (active)

User asks skip initial bookkeeping and materialize detailed information asneeded forhardprimers, withLuna implementation/CLItests andAstraalgorithmoversight. This supersedesearlierallattempt-detailretentionrequirement; provenance+scientificvalidationremainmandatory. Rootspec+plan1f43943c4 at docs/superpowers/{specs,plans}/2026-09-16-selective-discovery-history.md. DefaultalleleCLI --discovery-history compact; advancedfull. Lowlevelbuild history_detail=full default; pipelineexplicitmode. Compactskiporigin-groupcanonicalization/evidence/assessment/events/dispositionmaps forindividualsites/families; retainallscientificsites/profilememberships/families andboundedtarget/profilecounts+scope. Selectorrecordsactuallyevaluatedconfigs/conflicts unchanged. New panel-discovery-diagnose replaysrequestedfamily/siteanchors/allrows/fulloriginalprofiles withfullhistory; separatelyprovenanced reconstruction, neveroriginalchronology. IDs/scienceprojectionparity required; crossmodecatalog/ledgerdigestsintentionallydiffer. Compactcacheprojectionusestoredprofilemembership, no missingevidencelookups; explicitdetailbinding/incompatiblepromotionrejection. Oldfullreadssupported; sourcefingerprintsnotweakened.

Active Luna-high agents: luna_compact_discovery ownsdiscovery/options/pipeline/cache/inspection/capabilities/CLI+tests; luna_discovery_diagnostics ownsnewdiscovery_diagnostics.py/testmoduleonly. Bothinmutablenativebase74102b8, sharedfilesystem/disjointownership. RootAstrareviewpending. Existingluna_benchmark_runner (Luna-low) prepares/runsboundedCLIchecks onlyafterfrozencodeapproval. Itsfirsttestplan307e5dd9a wasREJECTED forwrongdetailmode/default,digestequality,inventedhistoryflags,andaccidentalall11run; corrected27f6b1d5c mustreviewbeforeexecution. No tests/scientificrunsyetauthorizedfromchangingmutablesourceexceptagentsfocusedunitwork. Gate: tinyCLI+cache/audit/replay, boundedanchorsoriginalA1compact/fullcomparison, thenonefullA1COMPACT30soptimizer/salvageOFF engineeringrun; NOFULL11retry. AutomatedfollowupsremainPAUSED; cancelled17houtput/hotjournaluntouched.


## Selective discovery review checkpoint (2026-09-16)

Native commits `5d30e38`, `f9c5917`, and `77e03b5` implement compact discovery and anchored diagnostic replay. Root reviewed the scientific acceptance/mapping distinction, cache detail binding, diagnostic source reconstruction, and provenance. Focused Luna tests pass; final fixed-work selector parity and a failure-provenance inventory correction remain before source freeze. No integrated benchmark has run yet.

The low-effort Luna runner’s harness drafts were rejected for incorrect API arguments, absent real-A1 comparison, and resource-monitoring defects. They must not be executed as committed. Luna-high `luna_discovery_diagnostics` now owns correcting those scripts and subsequent CLI evaluation; the former runner has stopped. This changes execution ownership, not the approved bounded plan. All native changes must settle before source-bound runs. Cancelled full11 data remains untouched, automation paused, GUI and managed runtime unchanged.


## Native candidate freeze and execution authorization

Native `cfafd488fa064438f005417a85d85904ec81da4d` is clean and includes corrected diagnostic failure inventories plus fixed-work compact/full selector parity. Luna compact agent owns one full native suite. Luna diagnostics agent owns tiny actual CLI/cache/audit/history/replay verification and bounded original-A1 anchored compact/full measurement. No source mutations during either run. The committed low-effort harness drafts remain unaccepted until replaced or corrected. Full-A1 compact engineering run remains gated on the tiny and anchored results; no full11 work is authorized.


## Selective discovery implementation verified

Native `cfafd48` passed 900 tests in 173.38 seconds; source stayed clean throughout CLI evaluation. Independent Luna diagnostics agent completed tiny compact/full/default/reuse runs (999 sites, 176 families; zero selected assignments), audit/history/cache and valid site/family reconstruction. A1 six-anchor compact/full parity: 370 sites, one family; compact 0.2686 seconds / 73,728 history bytes versus full 0.6472 seconds / 3,117,056 bytes. This single small probe cannot establish full-MHC speedup or memory reduction.

Full original A1 compact engineering run succeeded and freshly audited: 246.639 seconds, sampled process-group peak RSS 4,162,469,888 bytes; discovery 80.705 seconds, search plus validation 57.400 seconds, publication plus audit 95.013 seconds. One pool / 30-second search / one start / zero repairs / salvage off yielded five amplicons and 24.1317% mean trimmed coverage. The earlier 89.50% longer two-pool A1 result remains the quality reference; no comparable quality run was attempted here. Source/runtime/input stable.

Additional core-agent tiny-fixture work was interrupted by automatic content-access safety screening. That step was not retried. The independently completed CLI checks above, the fixed-work parity unit test and the successful real-A1 engineering run provide the accepted verification; no claim is made for the interrupted supplementary step.

Bounded measurement scripts corrected and committed as `1bd5ea118`; Luna is preserving the completed evaluation outputs with copy provenance and writing the final SDD report. No additional experimental runs authorized or needed for this change. Cancelled full11 output remains untouched and heartbeat paused.


## User-authorized two-pool shared-MSA pilot (active)

User asks Luna to evaluate two pools for the intended multi-MSA panel. Root approved a bounded A1+A2 shared-pool pilot on clean native `cfafd48`: original raw source-inputs A1 C64AA855 and A2 2E748544 in that order, union profiles, compact discovery, strict dimer -26, 150–250 bp/200 target, minimum frequency zero, distinct-allele trimmed coverage, 4 requested workers, 4 starts/2 repair rounds/120-second optimizer, salvage off. Existing A1-only cache cannot be concatenated or reused for a different target set; fresh combined discovery is required.

Luna-high `luna_two_pool_evaluation` owns execution and reporting, no native edits. Caps: 15 minutes whole-process-group wall time, 12 GiB group RSS, 2 GiB output, bounded signal escalation and interruption receipt. On success, fresh audit and per-target/allele coverage plus pool burden, phase/runtime/memory/history metrics. No all11 launch or broad sweep authorized in this turn. Cancelled full11 artifacts and paused heartbeat remain untouched. This tests two shared targets and cannot establish all11 performance.


## Two-pool A1+A2 pilot completed; no automatic rerun

The fresh compact run `mhc-a1-a2-compact-two-pool-01/compact` completed successfully on `cfafd48` in approximately 551 seconds external wall time (native provenance 548.854 seconds), peak group RSS about 5.35 billion bytes, approximately 318 MB output. Fresh audit exited zero, validation valid, in 198.52 seconds. Source/runtime/input identities remained stable.

Harness review revealed it retained one core, one start, and zero repairs instead of the approved four/four/two. Actual two pools, 120-second search budget, union profiles, strict -26, and salvage off were correct. Root stopped the agent from automatically rerunning: this is a valid bounded scientific result with a disclosed search-effort deviation, not the planned stronger comparison.

A1 trimmed coverage 2.25349% across six classes (four zero), one amplicon. A2 26.86025% across nine classes, seven amplicons. User pool 1 contains five A2 amplicons; pool 2 contains two A2 and one A1. Mean target coverage 14.55687%; no class reaches 95%; no accepted dimer violations.

Search ended at 107.513 seconds with misleadingly broad stop label `completed`, but work_truncated=true and all three phases ended at work-cap (three construction limit hits). Main construction search explored 80 of 277,668 families, with seed cursors separately 2,016 full and 4,672 normal. This is not an optimum or a simple wall-time timeout. Discovery 183.460 seconds, search plus validation 164.234 seconds, publication plus audit 178.426 seconds. Luna is finishing only a bounded read-only rejection summary and report. No all11 run or second panel-create authorized.


## User-authorized stronger shared-pool search (active)

User requests Luna try stronger settings and explore more families. Luna-high `luna_stronger_two_pool` owns one supported cache export from the completed A1+A2 compact panel and one cached stronger two-pool run on unchanged native `cfafd48`. Approved manifest: seed 0; four requested starts, two repair rounds, 600-second optimizer, four requested cores; reserved phase scheduling; frontier 128; construction attempts 8192; families per refresh 64; repair probes/neighborhoods/trials 512 each; pool lookahead 8; cleanup moves 128; subset beam 16 and expansion 256 unchanged. Reserved first-cycle shares 20% seeds/40% construction/40% repair; actual completion of all requested starts/rounds is not guaranteed.

Scientific policies, original raw A1/A2 inputs, two pools, strict -26 dimer threshold and salvage off remain unchanged. Cache identity cannot be bypassed. Agent must assert exact argv/resolved options against the manifest before expensive launch and verify saved options promptly after launch, preventing the previous harness mismatch. Main run caps: 1800 seconds total, 12 GiB process-group RSS, 2 GiB output; preserve interrupted provenance and bounded signal escalation. Fresh audit after successful close. No automatic sweep, full11 run, GUI or source changes.


## Stronger search and authentic legacy reference baseline (2026-09-16)

User added requirement to save an authentic legacy two-pool baseline on the same MSAs and use percent MSA reference covered as primary even without perfect support for all alleles. Primary comparison is now per-MSA geometric reference coverage (provisionally primer-trimmed, preserving earlier trimming preference; full spans also reported). This changes evaluation, not the already-running allele objective.

Luna baseline agent used authentic `--selection-algorithm legacy` in preserved `allele-primal-baseline-check` 3.3.0+lge.3 / `2abc3207629aacb101f1c04a4f57348ef5b903b2`, not the intermediate coverage optimizer. Same original A1/A2 input order, two shared pools, normal profile, 150–250/200, dimer -26, legacy gap backend, match database k19; authentic legacy cannot apply the new 2000-base product restriction and resolves bound zero. Legacy .90/full-span config fields are non-operative. Output `BASE/mhc-a1-a2-legacy-two-pool-01/panel` completed in 6.912 seconds with 26 amplicons (12 A1, 14 A2), peak RSS 1.51 GB. Wrapper provenance and separately preserved, verified raw inputs accompany the outputs; native legacy duplicate-basename working copy was not modified.

Stronger new output `BASE/mhc-a1-a2-compact-two-pool-stronger-01/panel` closed successfully on unchanged `cfafd48` in 943.945 seconds, peak RSS 4,989,698,048 bytes, output high-water 911,046,346 bytes. Saved settings independently verified: four requested starts/two repairs/600 seconds, reserved scheduling, attempts8192/families64/frontier128 and remaining approved work settings. Cached discovery reused, actual discovery workers zero. Search ran600.007 seconds, expanded535 families versus80 previously, produced14 amplicons (6 A1/8 A2). Only construction start0 entered; both repair rounds entered, four starts were requested but not all executed. Stage validation valid; final fresh audit pending at this ledger update.

Shared saved-geometry evaluator validates reference FASTA against original first-row ungapped references (A1 2923/A2 3082), enforces BED bounds and merges zero-based half-open intervals independently per MSA, without allele perfect-match gating. Overlap/touching/transitive union sanity cases pass. Comparison saved at `BASE/mhc-a1-a2-legacy-two-pool-01/reference-coverage/comparison-report.md` plus JSON and provenance.

Reference trimmed/full percentages: legacy A1 69.688676/75.025659, A2 70.668397/75.665152; first new pilot A1 6.739651/8.176531, A2 35.820896/42.699546; stronger A1 29.832364/36.982552, A2 41.434134/48.507463. Length-weighted pooled summary (not primary) is70.1915% legacy vs21.6653% firstpilot vs35.7868% stronger trimmed. New stronger improves over its first pilot but remains below legacy in both coverage measures and is much slower. These compare end-to-end configurations with different profiles/specificity/gap policies, not isolated selector causality. No full11, source changes, GUI edits or further run is authorized automatically.


## Stronger evaluation closed and audited

Fresh stronger audit `BASE/mhc-a1-a2-compact-two-pool-stronger-01-audit` completed exit0 in207.951 seconds, valid=true, raw_inputs_reparsed=true, zero violations; source/runtime stable. Root independently read audit validation/provenance. One accidental duplicate audit was stopped with no output and documented in the external audit-runner receipt; no duplicate panel search occurred. Search requested4starts/2rounds, entered one construction start and both repair rounds, but completed_starts=1/completed_repair_rounds=0; repair acceptance count0. Do not claim four completed starts or two completed rounds.

User-authorized stronger search and saved authentic legacy baseline comparison are complete. Primary per-MSA reference-trimmed geometry improves over firstpilot but remains belowlegacy. Fullspan comparisons, provenance and preservedinputs saved in the baseline comparison directory. No additional experiments or codechanges required for this request; next algorithm decision should use the new baseline and distinguish objective/constraint/search effects.


## User-authorized legacy sequential dimer salvage (active)

User explicitly pivots to original legacy candidate pool plus progressively permissive dimer passes for uncovered regions. Spec/plan `docs/superpowers/{specs,plans}/2026-09-16-legacy-dimer-salvage.md`, commit7e8386aed. Luna-high `luna_legacy_salvage` owns native implementation on clean cfafd48; root Astra reviews contract. No GUI or installed-runtime change.

Original strict generation and selection unchanged; retained post-generation legacy PrimerPair pool only. Internal generation rejects remain outside this feature (no regeneration, high-GC union or per-origin history). Sequential cross-pool-admission dimer cutoffs -28/-30/-32, default hardfloor-32, cumulative per-pool eight relaxed distinctsequenceedges/four incident sequences includingincumbents, configurableminimumreferencegain1base. Only add candidates with positive new primer-trimmed reference union coverage; protect strict assignments and all nondimer rules. Stable compact candidate/pass records, per-MSA trimmed/full reports, unique preservedrawinputs and full success/failure provenance required.

Root rejected proposed Boolean-binary-search score reconstruction: reuse exact tested `numerical_dimer_score`; native conflict is score<=cutoff, including equality. No new intrinsic-discovery callback or exhaustive status enumeration. Feature opt-in legacy-only; unsupported circular/region/imported cases may reject explicitly in first version. Implementation/test-first work authorized; real-MHC runs wait for reviewed clean freeze.

## Legacy salvage implemented and evaluated (2026-09-16)

Luna implemented CLI controls, retained-candidate additive salvage, exact numerical dimer records, strict BED snapshots, stable candidate IDs, independent admission replay, raw-input preservation and success/failure provenance. Native commits 336d670 (core), 677dfd1 (audit hardening), final clean benchmark freeze1597a6c (harness). Full suite919passed/onewarning at336d670; subsequent core audit changes passed9focusedtests and harness changes3focusedtests. No installed runtime or GUI changes.

Saved benchmark `BASE/mhc-a1-a2-legacy-salvage-benchmark-pending-v1`: both runs exit0, bounded fresh validation valid. Current legacy-off5.93seconds, sampledpeakRSS170049536bytes; bounded16.77seconds, sampledpeakRSS250904576bytes. Current off and bounded strict fingerprints match exactly. Both retain26amplicons and original reference geometry: A1 trimmed69.688676%/full75.025659%; A2 trimmed70.668397%/full75.665152%. Historical3.3.0+lge.3 differs by one A2 forward oligo row (747–771 vs746–769); coverage geometry identical. Do not claim exact historical primer equivalence or established cause of that difference.

No rescue under default budgets. All1412positive-trimmed-gain candidates inspected at every cutoff. At-32,1355blocked by overlap in both pools; remaining57blocked in pool2 by overlap and in pool1 by18dimer/30incident-species-budget/9edge-budget. All19044unexplored candidates after10000/pass cap have zerogain; cap did not hide positive-gain options. Results support fast implementation and strict preservation, not coverage improvement. Scores/budgets remain computational screening settings, not experimental guarantees. Human report `benchmark-diagnosis.md`, machine summary and per-run receipts alongside panels. Stop here; no broader threshold/budget sweep, full11 run, GUI rollout or candidate regeneration launched.

## Independent gap-completion scheme implemented and evaluated (2026-09-17)

User approved a separate follow-up scheme for primary-uncovered reference regions, with arbitrary configurable pool count. Luna implemented the new opt-in `panel-create --gap-completion-parent PATH` route using existing `--n-pools`; root Astra reviewed algorithm and evidence. Contract is `docs/superpowers/specs/2026-09-17-gap-completion-scheme.md` (7c8eb3a47). Core commits654af40/0c34e27. Original legacy route unchanged. Full originals and normal legacy generation retained; positive trimmed reference gains selected into fresh pools, strict-26 dimer and original overlap/MatchDB checks, no parent incumbents in follow-up conflicts and no salvage budgets. Standard BED files describe follow-up only; parent snapshots, combined coverage, candidate ceiling/status, unique scheme IDs and reproducibility records are separate. Full regression938passed at pre-audit source; post-audit focused32passed; one existing Kaleido warning. Real integration includes3pools, parent immutability, badreference failure receipt. No GUI/install/full11 change.

One authorized A1+A2 two-pool follow-up completed exit0 at frozen0c34e27: `BASE/mhc-a1-a2-gap-completion-benchmark-pending-v1/gap-completed`. Runtime42.189seconds, sampled process-tree peakRSS189906944bytes, no guardkill; parent scientific payload unchanged. Native fresh published-BED audit passed. Evaluated29070candidates; selected9amplicons across2pools(5/4). Combined trimmed A12171/2923=74.273007% (+134bases from2037); A22291/3082=74.334848% (+113from2178). Combined full A12283/2923=78.104687%, A22389/3082=77.514601%. Available-candidate trimmed ceilings2172/2291; follow-up reaches within1base forA1 and exactlyforA2. Remaining substantial gaps are absent from retained candidate interiors, not fixable simply by adding more pools with this candidate set.

Benchmark harness initially compared follow-up-only coverage as final rather than unioning parent; fixed AFTER native run in656392d,8focusedtests passed. Native output remains untouched; independent post-run analysis/receipt documents correction. Root independently read native combined coverage and freshvalidation to confirm gains. Human report `BASE/mhc-a1-a2-gap-completion-benchmark-pending-v1/benchmark-report.md`. No additional native run needed.

## Gap-focused candidate expansion implemented and evaluated (2026-09-17)

User approved expanding viable candidates around all primary-uncovered regions, retaining full MSAs/flanks and rebuilding independent follow-up pools. Luna implemented core142f46a and review fixesabc3e85; CLIc308ba6, harness3fdee49, integrationc1f00db. Root design contract is `docs/superpowers/specs/2026-09-17-gap-focused-candidate-expansion.md` (2973cd82f). New opt-in `--gap-expansion bounded` uses confirmed single-oligo alternatives at additional acceptable lengths, common observed-row support, exactly representable footprints, native profile/effective Tm tolerance and strict self/pair/pool dimer checks. No chemistry or amplicon-bound relaxation. Anchor sampling is spatial and interleaved; lazy pair-family enumeration is bounded and reports truncation. Union preserves legacy candidates and origins; fresh audits use selected objects to avoid duplicate-origin identity errors. Full suite948passed/150.98seconds at142f46a; post-review11focusedpassed atabc3e85; existing Kaleido warning. Source remains cleanabc3e85.

Default expansion experiment `BASE/mhc-a1-a2-gap-expansion-benchmark-pending-v1/expanded`: same rawA1A2/parent, strict-26, reference-span150–250,2pools,2000anchors/1000geometry-eligiblepairchecks perMSA. Exit0, freshvalidationpassed, parent unchanged;41.657seconds, sampledprocess-treeRSS336150528bytes. Generated1040expandedcandidates (574A1/466A2);30110uniquecandidates; selected10pairs,6expanded. Combined trimmed A12376/2923=81.286349% (+205vspriorgapcompletion); A22338/3082=75.859831% (+47). Combined full2496/2923 and2433/3082. Candidate trimmed ceilings2378/2338. Anchor work2000/4516 and2000/4802. Actualpairchecks581/466 belowglobalnumericcap, but everygap markedfamilysearchtruncated; do not claim exhaustivepairsearch. Corrected humanreport and analysisprovenance preserve originalrawreceipts.

One root-authorized stronger comparison on unchangedabc3e85: `BASE/mhc-a1-a2-gap-expansion-stronger-01/expanded`,5000anchors/4000pairchecks perMSA. Bothanchor spacesfullyexamined4516/4802;pairchecks1347/1745, everygap stillfamilysearchtruncated.32156uniquecandidates;12selected,8expanded withobserved-row evidence. Exit0/freshvalidationpassed/parent unchanged;78.730seconds, sampledRSS368312320bytes. Combined trimmed A12354/2923=80.533698%, A22350/3082=76.249189%; full2464/2923 and2446/3082. Stronger improvesA2by12basesbutloses22A1bases vsdefault; boundedcandidate-set and greedyselection changes prevent monotonic improvement. Keep smaller default preset; do not claim largerbudget alwaysbetter or remaininggaps globallyunsolvable. Root independently read both nativeprovenance/coverage/freshvalidation files. Reports+separateanalysisreceipts saved alongside bothruns. Stop here; no sweep, GUI/install or full11 work.
