# BINSEQ support in Lungfish Genome Explorer: assessment and recommendation

Date: 2026-08-25
Status: Recommendation, not a commitment to build
Panel: NGS bioinformatics, Swift/macOS architecture, performance engineering, product, data architecture, plus an adversarial red-team pass

## Recommendation

Do not adopt BINSEQ now, in any role. Ship a one-day extension-recognition message so a stray `.bq` or `.cbq` file produces a helpful explanation instead of a confusing failure, and attach the revisit triggers below to the existing dependency-upgrade sweep so the decision gets re-examined on evidence rather than on memory.

BINSEQ should not become the internal storage format. That option is not merely expensive, it is directionally wrong for this app: it would make the most common user-visible operations slower.

The panel voted four to one for do-nothing. The single dissenting vote (import and export support) rested on a factual claim that verification disproved. See "Correcting the panel" below.

## Why the internal-storage option fails

The decisive fact comes from the codebase, not from the format. Every one of the roughly 13 external tools LGE drives, including Kraken2, minimap2, fastp, SPAdes, seqkit and deacon, consumes a FASTQ file path. Only nine `standardInput` sites exist repo-wide, and those feed argument lists rather than read streams. Nextflow samplesheets embed FASTQ paths as text.

An internal BINSEQ payload therefore adds a mandatory decode-to-FASTQ pass before essentially every pipeline run, writing out the largest artifacts in the project before the analysis tool starts. BINSEQ's headline advantage is fast parallel scanning of data that is encoded once and read many times. Inverting that into a per-run transcode tax converts the format's strength into a permanent regression on exactly the operations users wait for.

Three further objections compound this.

The app does not need what BINSEQ provides. The FASTQ viewer displays a 1,000-read prefix drawn from `preview.fastq`, and statistics sample 10,000 reads. Random access into read sets, the thing BINSEQ's memory-mapped fixed records buy, is not a capability the interface currently exercises. Random access into reference FASTA is needed, and is already solved by `.fai` and the bgzip-indexed reader.

The existing architecture already occupies the design space. Space efficiency today comes from gzip plus the virtual-derivative model, where subset, trim, demux and orient bundles store read-ID lists and trim-position tables rather than duplicated reads. That is a pointer-based deduplication scheme, and it saves far more than 2-bit encoding density would. Structured random access is provided by the SQLite side-indexes. BINSEQ is redundant with this pattern rather than complementary.

Lossy defaults collide with provenance requirements. Default `.bq` encoding discards read names and quality scores, and assigns random nucleotides in place of N bases. For a surveillance-adjacent application, silently substituting a real base where the instrument reported ambiguity is disqualifying: N-masking is evidence of low coverage or uncertainty, and its loss is invisible downstream. It would also break the virtual-derivative system, which keys on read identity. The `.cbq` variant is lossless by default and avoids this, but `.cbq` is also the variant with the least mature specification.

Rough effort for the internal-format option was estimated at 12 to 20-plus person-weeks, touching the roughly 40 `materialize*` functions, 133 files with hardcoded extension logic, and about 45 CLI subcommands that bake in `.fastq` output conventions, against a 12,000-test suite. The panel was unanimous that this option should stay off the table regardless of how the ecosystem evolves.

## Why import support is also premature

Import-only support is architecturally cheap in the sense that matters: two clean chokepoints exist, `SequenceFormat` in `Sources/LungfishIO/Formats/Common/SequenceRecord.swift:30` and `FASTQBundle.resolvePrimaryFASTQURL`, and decoding to the existing gzipped-FASTQ bundle at ingestion would leave the rest of the app untouched. Estimates ranged from 3 to 9 person-weeks depending on implementation route.

The problem is demand and dependency cost, not architecture.

No instrument emits BINSEQ. Sequencers produce FASTQ, BAM or POD5. There is no observed instance of a collaborator sending an LGE user a `.bq` or `.cbq` file, and no requester for the feature.

There is no supported install path. Verified today by direct query: `bqtools`, `binseq` and `mmr` all return 404 on bioconda, and the Anaconda API returns an empty result set for `bqtools`. LGE distributes its 17 third-party tools as pinned bioconda specs through the conda pack. Shipping BINSEQ support therefore means either the app's first vendored native binary, with the Rust toolchain, signing and notarization work that implies, or its first FFI dependency against a C bindings repo with 20 commits and a read-only API, or a from-scratch Swift decoder for an under-documented single-lab specification whose only reference implementation is Rust.

The format is still moving. The `.vbq` variant was deprecated in favour of `.cbq` within roughly a year of publication. That is normal for a research format and disqualifying for anything canonical.

The format's own author states the adoption catch-22 plainly and positions BINSEQ for new tool development rather than ecosystem migration. LGE is not a new tool.

## Correcting the panel

The red-team pass caught that the lone pro-import vote rested on one unverified claim: that deacon 0.17.0, released 18 August 2026, added native CBQ input and output, and that since deacon is already a bundled LGE tool this would eliminate the decode tax on the host-depletion path, typically the first step on the largest files in a run. That claim was load-bearing and single-sourced, so I verified it.

It is false. Deacon 0.17.0 exists and was released on 18 August, but its changelog reads "Bring python bindings up to date, include in CI". No deacon release mentions BINSEQ, CBQ or `.bq`. The pinned version in `third-party-tools-lock.json:12` is `bioconda::deacon=0.16.0=h314a369_0`, and upgrading it would not unlock any BINSEQ path. With that corrected, zero tools in LGE's toolchain accept BINSEQ, and the panel's vote is effectively unanimous.

Two smaller corrections. The claim that a `.cbq` decoder would require vendoring zstd because macOS lacks it deserves checking against the current SDK before it is used to size any future estimate; the app currently uses Apple's Compression framework for gzip only and has no zstd path in `Sources/LungfishIO/Compression/GzipSupport.swift`. And the red team correctly noted that the virtual-derivative system does re-scan root FASTQ files repeatedly, once per pipeline run on a derived bundle, which is closer to BINSEQ's encode-once scan-many pattern than the performance assessment allowed. That observation points at a real optimization, but a bgzip offset index over the existing FASTQ addresses it more cheaply than a format change.

## What to do instead

If read-scanning throughput becomes a measured pain point, the win is available without a new format. The in-app hot paths, dedup, demux of large ONT runs, whole-dataset motif search and full-file QC, are single-pass streaming transforms currently bottlenecked by single-threaded gzip decode and parse in `FASTQReader`. A chunked parallel FASTQ parser with faster decompression was estimated at roughly 3 to 6 person-weeks for a realistic 3 to 6-fold improvement, with no format risk, no new dependency and no lossy-default footguns. A bgzip offset index over root FASTQ files would separately accelerate derivative materialization. Both should be profiled before either is built, since no current profile identifies read-scan latency as a user-visible problem.

## Revisit triggers

Re-examine if any one of these fires. Assign them to the dependency-upgrade sweep so they are actually watched rather than forgotten.

1. A second bundled tool beyond the author's own `mmr` wrapper ships native BINSEQ input, particularly Kraken2, fastp, minimap2, seqkit or deacon.
2. `bqtools` lands on bioconda, which drops import cost to a lock-file entry and a smoke test.
3. A real user presents an actual `.bq` or `.cbq` file they need to open, or two independent requests arrive.
4. SRA or ENA announces BINSEQ submission acceptance.

On trigger, the fallback is import-only support for `.cbq`, the lossless variant, decoding to the existing bundle model at ingestion, with the source format and any lossy encoding parameters recorded in bundle metadata and the OperationCenter log. Never make `.bq` an export default. The internal-storage option stays rejected regardless.

## Sources

- BINSEQ announcement post: https://noamteyssier.github.io/2025-04-20/
- BINSEQ, Arc Institute: https://arcinstitute.org/tools/binseq
- Publication, PLOS Computational Biology: https://journals.plos.org/ploscompbiol/article?id=10.1371%2Fjournal.pcbi.1014181
- bqtools: https://github.com/ArcInstitute/bqtools
- C and C++ bindings: https://github.com/arcinstitute/binseq-bindings
- mmr, minimap2 with BINSEQ input: https://github.com/arcinstitute/mmr
- deacon releases, checked 2026-08-25: https://github.com/bede/deacon/releases
