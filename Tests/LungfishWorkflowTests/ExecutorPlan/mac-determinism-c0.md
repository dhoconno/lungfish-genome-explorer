Excerpt of the C0 Mac determinism table, phase records `chtc-program/c0/lanes/C0-DET/determinism.md`, SHA-256 ab54dc0e0c7157974cb0716c1344c304ee591fb97765a09fd9f8a3da39683d0a, dated 2026-10-21: its lines 1 to 198 and the notes "What the tables say" (lines 220 to 229), verbatim. QA ruling QA-parity-1 has it committed beside the V15 list; no test parses it.

# C0-DET: the Mac determinism table

Run by lge-worker on sonnet at effort max, 2026-10-21. No checkout was changed and nothing was committed.

The first 1,000,000 pairs of experiment 32748 sample C079876_S1, run through the step chain S1 to S6 of the C0 common brief in two modes, at T = 1 and T = 8, twice each (runs `a` and `b`). Argv are in `argv.md`. The levels JSON files are in `levels/mac-<mode>-t<T>-<run>-<step>.json`. Each step's argv, exit status, wall seconds and stderr are in `reports/mac-<mode>-t<T>-<run>/<step>.meta.json` and `<step>.stderr`.

Levels, from the highest: E4 the decompressed stream in stored order, E3 the order-free multiset of full records (a pair counts as one unit), E2 the order-free multiset of sequences, E1 the record and base counts, none when even the counts differ. A cell names the highest level at which the two runs are equal. Compressed bytes never count.

Host: Apple M4 Pro, 14 logical CPUs (10 performance, 4 efficiency), 48 GiB, macOS 26.7.1 build 25G241. Tools: fastp 1.3.6 (ha1d0559_0); deacon 0.16.0 (h314a369_0); seqkit 2.13.0 (hd5f1084_0); pigz 2.8 (hfab5511_2); bbmap 40.02 (he046917_0); openjdk 25.0.2 (h258754b_0).

## Summary

- At T=1 every output of every step is E4 between run a and run b, in both modes.
- At T=8, run a against run b, S1 itself is below E4 (highest level that holds: keep none, remove none). Every later output of the chain differs too, because its input differs.
- At T=8 on a stored identical input, these steps are below E4: keep S1 dedup and trim (pairs) (different counts); keep S2 human scrub (pairs) (same records, different order); remove S1 dedup and trim (pairs) (different counts); remove S2 human scrub (pairs) (same records, different order); remove S3 rRNA filter (pairs) (same records, different order). Every other step is E4.
- The `clumpify` step rewrites the quality of N bases from `#` to `!` (see the notes), so S6 records are not the S5 records.

## Mode `keep`

| Step (output) | Same at T=1 (a vs b) | Same at T=8 (a vs b) | Same across T (t1-a vs t8-a) | Pairs or reads (t1-a / t1-b / t8-a / t8-b) | Bases | Wall s (t1-a / t1-b / t8-a / t8-b) |
|---|---|---|---|---|---|---|
| S1 dedup and trim (pairs) | E4 | none | none | 834,775 / 834,775 / 834,779 / 834,778 pairs | 228,572,578 / 228,572,578 / 228,573,593 / 228,573,431 | 23.6 / 24.6 / 21.7 / 21.7 |
| S2 human scrub (pairs) | E4 | none | none | 816,119 / 816,119 / 816,123 / 816,122 pairs | 223,302,768 / 223,302,768 / 223,303,783 / 223,303,621 | 5.5 / 5.7 / 4.1 / 4.1 |
| S4 merge, merged reads | E4 | none | none | 704,581 / 704,581 / 704,585 / 704,584 records | 115,830,801 / 115,830,801 / 115,831,231 / 115,831,094 | 3.4 / 3.5 / 1.3 / 1.3 |
| S4 merge, unmerged pairs | E4 | E2 | none | 111,538 pairs | 30,126,288 / 30,126,288 / 30,126,263 / 30,126,263 | 3.4 / 3.5 / 1.3 / 1.3 |
| S5 length filter, merged reads (seqkit) | E4 | none | none | 703,173 / 703,173 / 703,176 / 703,175 records | 115,784,604 / 115,784,604 / 115,785,000 / 115,784,863 | 3.9 / 3.9 / 3.1 / 3.1 |
| S5 length filter, unmerged pairs (fastp) | E4 | E2 | none | 95,892 pairs | 28,251,272 / 28,251,272 / 28,251,247 / 28,251,247 | 0.5 / 0.5 / 0.2 / 0.2 |
| S6 clumpify, pairs (interleaved) | E4 | E2 | none | 191,784 records | 28,251,272 / 28,251,272 / 28,251,247 / 28,251,247 | 0.6 / 0.6 / 0.5 / 0.5 |
| S6 clumpify, merged reads | E4 | none | none | 703,173 / 703,173 / 703,176 / 703,175 records | 115,784,604 / 115,784,604 / 115,785,000 / 115,784,863 | 2.5 / 2.4 / 1.5 / 1.5 |
| S6 stored file (pairs then merged, pigz) | E4 | none | none | 894,957 / 894,957 / 894,960 / 894,959 records | 144,035,876 / 144,035,876 / 144,036,247 / 144,036,110 | 5.4 / 5.3 / 0.9 / 0.8 |

## Mode `remove`

| Step (output) | Same at T=1 (a vs b) | Same at T=8 (a vs b) | Same across T (t1-a vs t8-a) | Pairs or reads (t1-a / t1-b / t8-a / t8-b) | Bases | Wall s (t1-a / t1-b / t8-a / t8-b) |
|---|---|---|---|---|---|---|
| S1 dedup and trim (pairs) | E4 | none | none | 834,775 / 834,775 / 834,778 / 834,779 pairs | 228,572,578 / 228,572,578 / 228,573,247 / 228,573,706 | 23.6 / 23.7 / 21.6 / 21.7 |
| S2 human scrub (pairs) | E4 | none | none | 816,119 / 816,119 / 816,122 / 816,123 pairs | 223,302,768 / 223,302,768 / 223,303,437 / 223,303,896 | 5.5 / 5.5 / 4.1 / 4.0 |
| S3 rRNA filter (pairs) | E4 | none | none | 182,696 pairs | 47,010,037 / 47,010,037 / 47,010,035 / 47,010,010 | 1.8 / 1.8 / 0.5 / 0.5 |
| S4 merge, merged reads | E4 | none | E2 | 164,155 records | 24,504,729 / 24,504,729 / 24,504,729 / 24,504,702 | 0.8 / 0.8 / 0.4 / 0.4 |
| S4 merge, unmerged pairs | E4 | none | none | 18,541 pairs | 3,746,581 / 3,746,581 / 3,746,579 / 3,746,581 | 0.8 / 0.8 / 0.4 / 0.4 |
| S5 length filter, merged reads (seqkit) | E4 | none | E2 | 163,591 records | 24,486,015 / 24,486,015 / 24,486,015 / 24,485,988 | 0.8 / 0.8 / 0.7 / 0.7 |
| S5 length filter, unmerged pairs (fastp) | E4 | none | none | 10,496 pairs | 2,998,316 / 2,998,316 / 2,998,314 / 2,998,316 | 0.2 / 0.2 / 0.1 / 0.1 |
| S6 clumpify, pairs (interleaved) | E4 | none | none | 20,992 records | 2,998,316 / 2,998,316 / 2,998,314 / 2,998,316 | 0.2 / 0.2 / 0.2 / 0.2 |
| S6 clumpify, merged reads | E4 | none | E2 | 163,591 records | 24,486,015 / 24,486,015 / 24,486,015 / 24,485,988 | 0.8 / 0.8 / 0.7 / 0.7 |
| S6 stored file (pairs then merged, pigz) | E4 | none | none | 184,583 records | 27,484,331 / 27,484,331 / 27,484,329 / 27,484,304 | 1.8 / 1.8 / 0.3 / 0.3 |

## Steps that are not repeatable at E4

| Mode | Output | Comparison | Highest level that holds |
|---|---|---|---|
| keep | S1 dedup and trim (pairs) | T=8 a vs b | none |
| keep | S1 dedup and trim (pairs) | across T t1-a vs t8-a | none |
| keep | S2 human scrub (pairs) | T=8 a vs b | none |
| keep | S2 human scrub (pairs) | across T t1-a vs t8-a | none |
| keep | S4 merge, merged reads | T=8 a vs b | none |
| keep | S4 merge, merged reads | across T t1-a vs t8-a | none |
| keep | S4 merge, unmerged pairs | T=8 a vs b | E2 |
| keep | S4 merge, unmerged pairs | across T t1-a vs t8-a | none |
| keep | S5 length filter, merged reads (seqkit) | T=8 a vs b | none |
| keep | S5 length filter, merged reads (seqkit) | across T t1-a vs t8-a | none |
| keep | S5 length filter, unmerged pairs (fastp) | T=8 a vs b | E2 |
| keep | S5 length filter, unmerged pairs (fastp) | across T t1-a vs t8-a | none |
| keep | S6 clumpify, pairs (interleaved) | T=8 a vs b | E2 |
| keep | S6 clumpify, pairs (interleaved) | across T t1-a vs t8-a | none |
| keep | S6 clumpify, merged reads | T=8 a vs b | none |
| keep | S6 clumpify, merged reads | across T t1-a vs t8-a | none |
| keep | S6 stored file (pairs then merged, pigz) | T=8 a vs b | none |
| keep | S6 stored file (pairs then merged, pigz) | across T t1-a vs t8-a | none |
| remove | S1 dedup and trim (pairs) | T=8 a vs b | none |
| remove | S1 dedup and trim (pairs) | across T t1-a vs t8-a | none |
| remove | S2 human scrub (pairs) | T=8 a vs b | none |
| remove | S2 human scrub (pairs) | across T t1-a vs t8-a | none |
| remove | S3 rRNA filter (pairs) | T=8 a vs b | none |
| remove | S3 rRNA filter (pairs) | across T t1-a vs t8-a | none |
| remove | S4 merge, merged reads | T=8 a vs b | none |
| remove | S4 merge, merged reads | across T t1-a vs t8-a | E2 |
| remove | S4 merge, unmerged pairs | T=8 a vs b | none |
| remove | S4 merge, unmerged pairs | across T t1-a vs t8-a | none |
| remove | S5 length filter, merged reads (seqkit) | T=8 a vs b | none |
| remove | S5 length filter, merged reads (seqkit) | across T t1-a vs t8-a | E2 |
| remove | S5 length filter, unmerged pairs (fastp) | T=8 a vs b | none |
| remove | S5 length filter, unmerged pairs (fastp) | across T t1-a vs t8-a | none |
| remove | S6 clumpify, pairs (interleaved) | T=8 a vs b | none |
| remove | S6 clumpify, pairs (interleaved) | across T t1-a vs t8-a | none |
| remove | S6 clumpify, merged reads | T=8 a vs b | none |
| remove | S6 clumpify, merged reads | across T t1-a vs t8-a | E2 |
| remove | S6 stored file (pairs then merged, pigz) | T=8 a vs b | none |
| remove | S6 stored file (pairs then merged, pigz) | across T t1-a vs t8-a | none |

## Cross-T comparisons beyond t1-a vs t8-a

- `remove` S4 merge, merged reads: t1-a vs t8-a is E2, but t1-a vs t8-b is none, t1-b vs t8-b is none
- `remove` S4 merge, unmerged pairs: t1-a vs t8-a is none, but t1-a vs t8-b is E2, t1-b vs t8-b is E2
- `remove` S5 length filter, merged reads (seqkit): t1-a vs t8-a is E2, but t1-a vs t8-b is none, t1-b vs t8-b is none
- `remove` S5 length filter, unmerged pairs (fastp): t1-a vs t8-a is none, but t1-a vs t8-b is E2, t1-b vs t8-b is E2
- `remove` S6 clumpify, pairs (interleaved): t1-a vs t8-a is none, but t1-a vs t8-b is E2, t1-b vs t8-b is E2
- `remove` S6 clumpify, merged reads: t1-a vs t8-a is E2, but t1-a vs t8-b is none, t1-b vs t8-b is none

## Checks

Input slice: 1,000,000 pairs, 279,439,307 bases, mismatched mate names 0. R1 E4 `4208203c5cecaaabb6fc2d4e88da415d5f10e5c9cd0d5658fe8d08b0393037b7`, R2 E4 `1fb8081089d86a553dbf0082ad52a5b9db9751004bfedd04e0ac73228c24763b` (the common brief gives `4208203c...37b7` and `1fb80810...763b`).

| Chain | Count and base conservation | S6 equals its halves (E3 sum) | S6m has the records of S5m (E3) | Mismatched mate names |
|---|---|---|---|---|
| mac-keep-t1-a | ok | ok | differs | 0 |
| mac-keep-t1-b | ok | ok | differs | 0 |
| mac-keep-t8-a | ok | ok | differs | 0 |
| mac-keep-t8-b | ok | ok | differs | 0 |
| mac-remove-t1-a | ok | ok | differs | 0 |
| mac-remove-t1-b | ok | ok | differs | 0 |
| mac-remove-t8-a | ok | ok | differs | 0 |
| mac-remove-t8-b | ok | ok | differs | 0 |

## Runs

Chains ran one after another. Wall seconds are for the tool steps only (S6 is clumpify pairs, clumpify merged reads and pigz). The laptop was shared with other work while these ran, so the wall seconds are indicative. The load column is the 1-minute load average read at the start of each step, lowest to highest. The machine has 14 logical CPUs.

| Chain | Started (UTC) | Sum of all step walls s | Load at step start (min to max) | Exit statuses |
|---|---|---|---|---|
| mac-keep-t1-a | 2026-10-21T22:15:35.734150Z | 46.3 | 14.8 to 16.8 | 0 |
| mac-keep-t1-b | 2026-10-21T22:16:28.087388Z | 47.4 | 28.7 to 46.7 | 0 |
| mac-keep-t8-a | 2026-10-21T22:12:53.420939Z | 34.1 | 19.8 to 25.1 | 0 |
| mac-keep-t8-b | 2026-10-21T22:13:33.515341Z | 33.9 | 22.7 to 24.6 | 0 |
| mac-remove-t1-a | 2026-10-21T22:14:13.446471Z | 35.7 | 19.2 to 22.0 | 0 |
| mac-remove-t1-b | 2026-10-21T22:14:54.530393Z | 35.7 | 17.3 to 19.0 | 0 |
| mac-remove-t8-a | 2026-10-21T22:11:44.957342Z | 28.8 | 23.4 to 29.9 | 0 |
| mac-remove-t8-b | 2026-10-21T22:12:19.256775Z | 28.8 | 20.1 to 22.6 | 0 |

## Same input, T=8

S1 was made once at T=1 and stored. S2 to S6 then ran at T=8 twice per mode on that same input (`iso-<mode>-t8-<run>`, `run_chain_fixed_s1.sh`). A difference between the two runs comes from the step itself, not from its input. The last two columns compare with the T=1 chains, whose S1 output is the same stream.

Input check: the stored S1 output compared with the S1 stream inside every iso chain and every T=1 chain gives E4.

### Mode `keep`

| Step (output) | T=8 run a vs b | T=8 run a vs T=1 run a | T=8 run b vs T=1 run a |
|---|---|---|---|
| S2 human scrub (pairs) | E3 | E3 | E3 |
| S4 merge, merged reads | E3 | E3 | E3 |
| S4 merge, unmerged pairs | E3 | E3 | E3 |
| S5 length filter, merged reads (seqkit) | E3 | E3 | E3 |
| S5 length filter, unmerged pairs (fastp) | E3 | E3 | E3 |
| S6 clumpify, pairs (interleaved) | E4 | E4 | E4 |
| S6 clumpify, merged reads | E4 | E4 | E4 |
| S6 stored file (pairs then merged, pigz) | E4 | E4 | E4 |

### Mode `remove`

| Step (output) | T=8 run a vs b | T=8 run a vs T=1 run a | T=8 run b vs T=1 run a |
|---|---|---|---|
| S2 human scrub (pairs) | E3 | E3 | E3 |
| S3 rRNA filter (pairs) | E3 | E3 | E3 |
| S4 merge, merged reads | E3 | E3 | E3 |
| S4 merge, unmerged pairs | E3 | E3 | E3 |
| S5 length filter, merged reads (seqkit) | E3 | E3 | E3 |
| S5 length filter, unmerged pairs (fastp) | E3 | E3 | E3 |
| S6 clumpify, pairs (interleaved) | E4 | E4 | E4 |
| S6 clumpify, merged reads | E4 | E4 | E4 |
| S6 stored file (pairs then merged, pigz) | E4 | E4 | E4 |

S2 reads the stored S1 stream, so its row is a clean test of S2. S3 to S5 read the T=8 output of the step before, and that output changes in order from run to run, so a difference there may be inherited. The S6 rows are E4 although the S5 files fed to them differ in order between runs. The next section tests every step on an input that does not change.

## Each step at T=8 on its own stored input

The section above fixes only S1, so S3 onward still received an input whose order changed from run to run. This section removes that. Per mode the chain ran once at T=1 and its outputs were stored (`ref`). Then every step ran at T=8, twice, reading the stored output of the step before (`run_perstep.sh`, labels `perstep-<mode>-t8-<run>-<step>`). A difference between the two runs, or between a run and the T=1 output, comes from that step alone. S1 has no earlier step, so its row is a second and third run of S1 against the stored T=1 output.

Reference check: every stored T=1 output compared with the same output of `mac-<mode>-t1-a` gives E4.

### Mode `keep`

| Step (output) | T=8 run a vs b | T=8 run a vs T=1 | T=8 run b vs T=1 | Lowest level means |
|---|---|---|---|---|
| S1 dedup and trim (pairs) | none | none | none | different counts |
| S2 human scrub (pairs) | E3 | E3 | E3 | same records, different order |
| S4 merge, merged reads | E4 | E4 | E4 | identical |
| S4 merge, unmerged pairs | E4 | E4 | E4 | identical |
| S5 length filter, merged reads (seqkit) | E4 | E4 | E4 | identical |
| S5 length filter, unmerged pairs (fastp) | E4 | E4 | E4 | identical |
| S6 clumpify, pairs (interleaved) | E4 | E4 | E4 | identical |
| S6 clumpify, merged reads | E4 | E4 | E4 | identical |
| S6 stored file (pairs then merged, pigz) | E4 | E4 | E4 | identical |

### Mode `remove`

| Step (output) | T=8 run a vs b | T=8 run a vs T=1 | T=8 run b vs T=1 | Lowest level means |
|---|---|---|---|---|
| S1 dedup and trim (pairs) | none | none | none | different counts |
| S2 human scrub (pairs) | E3 | E3 | E3 | same records, different order |
| S3 rRNA filter (pairs) | E3 | E3 | E3 | same records, different order |
| S4 merge, merged reads | E4 | E4 | E4 | identical |
| S4 merge, unmerged pairs | E4 | E4 | E4 | identical |
| S5 length filter, merged reads (seqkit) | E4 | E4 | E4 | identical |
| S5 length filter, unmerged pairs (fastp) | E4 | E4 | E4 | identical |
| S6 clumpify, pairs (interleaved) | E4 | E4 | E4 | identical |
| S6 clumpify, merged reads | E4 | E4 | E4 | identical |
| S6 stored file (pairs then merged, pigz) | E4 | E4 | E4 | identical |

## Notes

### What the tables say

1. T=1 repeats at E4 in every step and in both modes. Run a and run b give the same decompressed stream for every output file.
2. T=8 does not repeat, and three tools are the cause. The section "Each step at T=8 on its own stored input" ran each step twice at T=8 on an identical stored input.
   - S1, fastp `--dedup` with `-w 8`. The number of pairs kept changes: 834,775 at T=1 in all four T=1 runs, 834,778 to 834,780 at T=8 in five runs (the four chains and the smoke chain). So even E1 fails. The 3 to 5 extra pairs fit duplicates that two workers saw at the same moment. Some downstream outputs of `keep` are E2 (same sequences, different names or qualities), which fits a different member of a duplicate group being kept.
   - S2 and S3, deacon `filter` with `-t 8`. The records are the same (E3) and the order differs from run to run and from the T=1 order.
   - Not at fault: fastp merge (S4), seqkit and fastp length filter (S5), clumpify and pigz (S6). Each is E4 at T=8 on an identical input, and equal to its T=1 output.
3. Differences travel downstream. In the eight chains every output after S1 differs at T=8 because the S1 output differs. With S1 fixed (section "Same input, T=8") S2 to S5 still differ in order and S6 is E4 anyway. That fits clumpify's k-mer sort, which returns one stream for one set of records. A different record count is not repaired that way.
4. clumpify rewrites quality. `clumpify_probe.py` ran the S6c argv on the first 10,000 reads of R1. All 887 N bases with quality `#` (Q2) came out with quality `!` (Q0), and nothing else in any record changed (header, sequence, plus line, other qualities). So an S6 record is not its S5 record. That is why the check column "S6m has the records of S5m (E3)" reads `differs` in all eight chains, while "S6 equals its halves" passes. The probe covered the unpaired path (`interleaved=f`). Q20 and Q30 base counts do not move, since both qualities sit below them, but a mean quality or a quality histogram taken after the storage step differs slightly from one taken before it. A Mac against CHTC comparison at E3 is unaffected, since both run clumpify.
