# Platform header fixtures

Each file holds four reads with a real header form and synthetic bases and qualities. The platform detector (`PlatformInference` in LungfishIO) is tested against every file. The files were written by `make_fixtures.py` in this folder (`python3 make_fixtures.py <this folder> <bgzip> <samtools>`), which seeds its random bases, and the BAM files were made from the FASTQ files with `samtools view`.

| File | Header form | Source of the form |
|---|---|---|
| `illumina-novaseq6000.fastq` | `A00488:61:HMLGNDSXX:4:1101:1000:5678 1:N:0:ATCACG+TTAGGC` | bcl2fastq and BCL Convert output from a NovaSeq 6000 |
| `illumina-miseq-dash-flowcell.fastq` | `M00123:45:000000000-A1B2C:1:1101:15589:1333 1:N:0:1` | MiSeq, whose flow cell IDs carry a dash |
| `illumina-nextseq2000-umi.fastq` | `VH00123:12:AAAW2YHM5:1:1101:12345:1000:ACGTACGT 1:N:0:GATCAG+CTGATC` | NextSeq 2000 with a UMI in the eighth field |
| `illumina-pre18.fastq` | `HWUSI-EAS100R:6:73:941:1973#0/1` | Illumina pipelines before CASAVA 1.8 |
| `ena-renamed-illumina.fastq` | `ERR5069949.2151832 NS500628:121:HK3MMAFX2:2:21208:10793:15304/1` | ENA download that keeps the original name in the second field |
| `sra-renamed-short.fastq` | `SRR12345678.1 1 length=150` | `fasterq-dump` spot names, 150 base reads |
| `sra-renamed-long.fastq` | `SRR12345678.1 1 length=1800` | `fasterq-dump` spot names, 1,800 base reads |
| `element-aviti.fastq` | `AV224501:1:2324216641:1:10102:0181:0028 1:N:0:ACGTACGT` | Element AVITI `bases2fastq` |
| `mgi-dnbseq.fastq` | `V300012345L1C001R001000001/1` | MGI DNBSEQ flow cell, lane, column, row form |
| `iontorrent.fastq` | `ZG3P3:00012:00034` | Ion Torrent Suite run, row and column form |
| `ont-minknow-full.fastq` | UUID with `runid`, `read`, `ch`, `start_time`, `flow_cell_id` and `basecall_model_version_id` | MinKNOW and Guppy key=value comment |
| `ont-guppy-runid-only.fastq` | UUID with `runid`, `read`, `ch` and `start_time`, no flow cell | older Guppy output |
| `ont-dorado-samtags-tab.fastq` | UUID followed by tab-separated `qs:f`, `ch:i`, `st:Z`, `RG:Z` and other tags | `samtools fastq -T '*'` of a dorado BAM, or `dorado --emit-fastq` |
| `ont-dorado-samtags-space.fastq` | the same tags separated by spaces | the same output after a tool rewrote tabs |
| `ont-uuid-only-long.fastq` | bare UUID, long reads | ONT reads after a tool dropped the comment |
| `ont-uuid-only-short.fastq` | bare UUID, short reads | the same, too short to call ONT |
| `pacbio-sequel2-ccs.fastq` | `m64011_190830_220126/101/ccs` | Sequel II CCS |
| `pacbio-sequel2e-ccs.fastq` | `m64012e_210101_120000/12345/ccs` | Sequel IIe on-instrument CCS |
| `pacbio-revio-ccs.fastq` | `m84011_220902_175841_s1/12345/ccs` | Revio HiFi |
| `pacbio-ccs-bystrand.fastq` | `m64011_190830_220126/101/ccs/fwd` and `/rev` | CCS by-strand output |
| `pacbio-subreads.fastq` | `m54006_160504_020705/4194369/0_1958` | Sequel subreads (CLR) |
| `pacbio-hifi-tags.fastq` | `hifi_read_1` with `np:i`, `rq:f` and `zm:i` tags | `samtools fastq -T np,rq,zm` of renamed HiFi reads |
| `zmw-word-not-pacbio.fastq` | `sample_zmwtest_1 library=A` | a name that contains the word zmw by chance |
| `illumina-header-long-reads.fastq` | Illumina names on 5,000 base reads | a conflict that must not be called Illumina |
| `mixed-ont-then-illumina.fastq` | one MinKNOW read, then three Illumina reads | a mixed file that must not be guessed |
| `ont-dorado-samtags.fastq.gz` | gzip of `ont-dorado-samtags-tab.fastq` | single-member gzip |
| `ont-dorado-samtags.bgzf.fastq.gz` | `bgzip` of the same file | BGZF, a multi-member gzip |
| `ont-dorado.bam` | unaligned BAM with `@RG PL:ONT` and `@PG PN:dorado` | dorado basecaller output |
| `pacbio-hifi.bam` | unaligned BAM with `@RG PL:PACBIO`, `READTYPE=CCS` and `@PG PN:ccs` | PacBio `hifi_reads.bam` |
| `unlabelled.bam` | unaligned BAM with no `PL` | `samtools import` of reads with no platform |
