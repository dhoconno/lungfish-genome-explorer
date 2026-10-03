#!/usr/bin/env python3
"""Builds Tests/Fixtures/platform-headers. Real header forms, synthetic bases."""
import gzip, os, random, subprocess, sys

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
rng = random.Random(20261003)

def seq(n):
    return "".join(rng.choice("ACGT") for _ in range(n))

def qual_binned(n):
    return "".join(rng.choice("F:,F") for _ in range(n))

def qual_long(n):
    return "".join(chr(33 + rng.randint(5, 40)) for _ in range(n))

def write(name, records):
    with open(os.path.join(out, name), "w") as f:
        for header, n, qf in records:
            f.write(f"@{header}\n{seq(n)}\n+\n{qf(n)}\n")

UUIDS = [
    "0a1b2c3d-4e5f-4789-abcd-ef0123456789",
    "1b2c3d4e-5f60-4a12-9bcd-f01234567890",
    "2c3d4e5f-6071-4b23-8cde-012345678901",
    "3d4e5f60-7182-4c34-acdf-123456789012",
]
RUNID = "8a9b0c1d2e3f405162738495a6b7c8d9e0f1a2b3"
LONG = [1820, 2410, 1265, 3050]
SHORT = [150, 150, 150, 150]

write("illumina-novaseq6000.fastq", [
    (f"A00488:61:HMLGNDSXX:4:1101:{1000 + i}:{5678 + i} 1:N:0:ATCACG+TTAGGC", 150, qual_binned) for i in range(4)])
write("illumina-miseq-dash-flowcell.fastq", [
    (f"M00123:45:000000000-A1B2C:1:1101:{15589 + i}:1333 1:N:0:1", 250, qual_long) for i in range(4)])
write("illumina-nextseq2000-umi.fastq", [
    (f"VH00123:12:AAAW2YHM5:1:1101:{12345 + i}:1000:ACGTACGT 1:N:0:GATCAG+CTGATC", 151, qual_binned) for i in range(4)])
write("illumina-pre18.fastq", [
    (f"HWUSI-EAS100R:6:73:{941 + i}:1973#0/1", 36, qual_long) for i in range(4)])
write("ena-renamed-illumina.fastq", [
    (f"ERR5069949.{2151832 + i} NS500628:121:HK3MMAFX2:2:21208:{10793 + i}:15304/1", 75, qual_binned) for i in range(4)])
write("sra-renamed-short.fastq", [
    (f"SRR12345678.{i + 1} {i + 1} length=150", 150, qual_long) for i in range(4)])
write("sra-renamed-long.fastq", [
    (f"SRR12345678.{i + 1} {i + 1} length=1800", 1800, qual_long) for i in range(4)])
write("element-aviti.fastq", [
    (f"AV224501:1:2324216641:1:10102:{181 + i:04d}:0028 1:N:0:ACGTACGT", 150, qual_long) for i in range(4)])
write("mgi-dnbseq.fastq", [
    (f"V300012345L1C001R00{1000001 + i}/1", 100, qual_long) for i in range(4)])
write("iontorrent.fastq", [
    (f"ZG3P3:{12 + i:05d}:{34 + i:05d}", [182, 210, 165, 240][i], qual_long) for i in range(4)])
write("ont-minknow-full.fastq", [
    (f"{UUIDS[i]} runid={RUNID} sampleid=s1 read={12 + i} ch={34 + i} start_time=2023-05-01T10:20:30Z "
     f"flow_cell_id=FAW12345 protocol_group_id=run1 sample_id=s1 barcode=barcode01 "
     f"basecall_model_version_id=dna_r10.4.1_e8.2_400bps_sup@v4.2.0", LONG[i], qual_long) for i in range(4)])
write("ont-guppy-runid-only.fastq", [
    (f"{UUIDS[i]} runid={RUNID} sampleid=s1 read={12 + i} ch={34 + i} start_time=2019-05-01T10:20:30Z",
     LONG[i], qual_long) for i in range(4)])
DORADO_TAGS = ["qs:f:12.5", "du:f:3.2", "ns:i:16000", "ts:i:10", "mx:i:1", "ch:i:123",
               "st:Z:2023-05-01T10:20:30.000+00:00", "rn:i:4567", "fn:Z:FAW12345_pass_0.pod5",
               "sm:f:96.1", "sd:f:21.3", "sv:Z:quantile", "dx:i:0",
               f"RG:Z:{RUNID[:8]}_dna_r10.4.1_e8.2_400bps_sup@v4.3.0"]
write("ont-dorado-samtags-tab.fastq", [
    (UUIDS[i] + "\t" + "\t".join(DORADO_TAGS), LONG[i], qual_long) for i in range(4)])
write("ont-dorado-samtags-space.fastq", [
    (UUIDS[i] + " " + " ".join(DORADO_TAGS), LONG[i], qual_long) for i in range(4)])
write("ont-uuid-only-long.fastq", [(UUIDS[i], LONG[i], qual_long) for i in range(4)])
write("ont-uuid-only-short.fastq", [(UUIDS[i], [320, 410, 280, 455][i], qual_long) for i in range(4)])
write("pacbio-sequel2-ccs.fastq", [(f"m64011_190830_220126/{101 + i}/ccs", LONG[i], qual_long) for i in range(4)])
write("pacbio-sequel2e-ccs.fastq", [(f"m64012e_210101_120000/{12345 + i}/ccs", LONG[i], qual_long) for i in range(4)])
write("pacbio-revio-ccs.fastq", [(f"m84011_220902_175841_s1/{12345 + i}/ccs", LONG[i], qual_long) for i in range(4)])
write("pacbio-ccs-bystrand.fastq", [
    (f"m64011_190830_220126/{101 + i // 2}/ccs/{'fwd' if i % 2 == 0 else 'rev'}", LONG[i], qual_long) for i in range(4)])
write("pacbio-subreads.fastq", [
    (f"m54006_160504_020705/4194369/{s}_{s + n}", n, qual_long)
    for s, n in [(0, 1958), (2004, 1890), (3941, 2010), (6000, 1750)]])
write("pacbio-hifi-tags.fastq", [
    (f"hifi_read_{i + 1}\tnp:i:{12 + i}\trq:f:0.999{i}\tzm:i:{101 + i}", LONG[i], qual_long) for i in range(4)])
write("zmw-word-not-pacbio.fastq", [(f"sample_zmwtest_{i + 1} library=A", 150, qual_long) for i in range(4)])
write("illumina-header-long-reads.fastq", [
    (f"A00488:61:HMLGNDSXX:4:1101:{1000 + i}:{5678 + i} 1:N:0:ATCACG+TTAGGC", 5000, qual_long) for i in range(4)])
write("mixed-ont-then-illumina.fastq", [
    (f"{UUIDS[0]} runid={RUNID} sampleid=s1 read=12 ch=34 start_time=2023-05-01T10:20:30Z flow_cell_id=FAW12345",
     LONG[0], qual_long)] + [
    (f"A00488:61:HMLGNDSXX:4:1101:{1000 + i}:{5678 + i} 1:N:0:ATCACG+TTAGGC", 150, qual_binned) for i in range(1, 4)])

tab = os.path.join(out, "ont-dorado-samtags-tab.fastq")
data = open(tab, "rb").read()
with gzip.GzipFile(os.path.join(out, "ont-dorado-samtags.fastq.gz"), "wb", mtime=0) as g:
    g.write(data)

bgzip, samtools = sys.argv[2], sys.argv[3]
bgz = os.path.join(out, "ont-dorado-samtags.bgzf.fastq.gz")
with open(bgz, "wb") as f:
    subprocess.run([bgzip, "-c", tab], stdout=f, check=True)

def bam(name, fastq, rg, pg):
    sam = os.path.join(out, name + ".sam")
    with open(sam, "w") as s:
        s.write("@HD\tVN:1.6\tSO:unknown\n")
        s.write(rg + "\n")
        s.write(pg + "\n")
        lines = open(os.path.join(out, fastq)).read().splitlines()
        rgid = rg.split("\tID:")[1].split("\t")[0]
        for k in range(0, len(lines), 4):
            qname = lines[k][1:].split()[0]
            s.write(f"{qname}\t4\t*\t0\t0\t*\t*\t0\t0\t{lines[k + 1]}\t{lines[k + 3]}\tRG:Z:{rgid}\n")
    subprocess.run([samtools, "view", "--no-PG", "-b", "-o", os.path.join(out, name), sam], check=True)
    os.remove(sam)

bam("ont-dorado.bam", "ont-uuid-only-long.fastq",
    f"@RG\tID:{RUNID[:8]}_dna_r10.4.1_e8.2_400bps_sup@v4.3.0\tPU:FAW12345\tPL:ONT\tDS:basecall_model=dna_r10.4.1_e8.2_400bps_sup@v4.3.0 runid={RUNID}\tLB:s1\tSM:s1",
    "@PG\tID:basecaller\tPN:dorado\tVN:0.7.2\tCL:dorado basecaller sup pod5/")
bam("pacbio-hifi.bam", "pacbio-revio-ccs.fastq",
    "@RG\tID:a1b2c3d4\tPL:PACBIO\tDS:READTYPE=CCS;Ipd:CodecV1=ip;PulseWidth:CodecV1=pw;BINDINGKIT=102-739-100;SEQUENCINGKIT=102-118-800;BASECALLERVERSION=5.0;FRAMERATEHZ=100.000000\tLB:lib1\tPU:m84011_220902_175841_s1\tSM:s1\tPM:REVIO",
    "@PG\tID:ccs\tPN:ccs\tVN:7.0.0\tCL:ccs subreads.bam hifi_reads.bam")
bam("unlabelled.bam", "sra-renamed-long.fastq",
    "@RG\tID:rg1\tSM:s1", "@PG\tID:samtools\tPN:samtools\tVN:1.21\tCL:samtools import reads.fastq")
