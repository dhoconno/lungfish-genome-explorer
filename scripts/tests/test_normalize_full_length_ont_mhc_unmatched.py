import importlib.util
import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = PROJECT_ROOT / "scripts" / "analysis" / "normalize_full_length_ont_mhc_unmatched.py"

spec = importlib.util.spec_from_file_location("normalize_full_length_ont_mhc_unmatched", SCRIPT_PATH)
normalizer = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = normalizer
spec.loader.exec_module(normalizer)


def normalized_row(
    sample,
    cluster,
    reads,
    trimmed_sequence_id,
    trimmed_sequence,
    mapping_closest_match_id="AlleleA_1SNP",
):
    original = normalizer.WorkbookRow(
        unmatched_sequence_id="raw-id",
        sample=sample,
        cluster=cluster,
        cluster_reads=reads,
        closest_match_id=mapping_closest_match_id,
        match_class="snp-different",
        sequence=trimmed_sequence,
        source_values={},
    )
    return normalizer.NormalizedRow(
        original=original,
        raw_sequence_id=normalizer.unmatched_sequence_id(trimmed_sequence),
        trimmed_sequence_id=trimmed_sequence_id,
        raw_length=len(trimmed_sequence),
        trimmed_length=len(trimmed_sequence),
        trim_start=1,
        trim_end=len(trimmed_sequence),
        trim_source="minimap2-target-interval",
        minimap_allele="AlleleA",
        mapping_closest_match_id=mapping_closest_match_id,
        mapping_match_class="snp-different",
        mapping_nucleotides_different=1,
        minimap_snps=1,
        minimap_indel_bases=0,
        minimap_matched_bases=len(trimmed_sequence) - 1,
        minimap_score=len(trimmed_sequence) - 101,
        trimmed_sequence=trimmed_sequence,
        blast_hit=None,
    )


def test_cigar_target_span_counts_only_target_consuming_operations():
    assert normalizer.cigar_target_span("5S10=2I3X4D6N7M8S") == 30


def test_parse_minimap_sam_hit_derives_cluster_interval_from_pos_and_cigar():
    line = "AlleleA\t0\tCluster1_ReadCount-7\t11\t60\t5S10=2I3X4D\t*\t0\t0\tACGT\t*"

    hit = normalizer.parse_minimap_sam_hit(line)

    assert hit.cluster == "Cluster1_ReadCount-7"
    assert hit.allele == "AlleleA"
    assert hit.cluster_start == 11
    assert hit.cluster_end == 27
    assert hit.snps == 3
    assert hit.indel_bases == 6
    assert hit.matched_bases == 10
    assert hit.is_reverse is False


def test_parse_minimap_sam_hit_marks_reverse_strand_records():
    line = "AlleleA\t16\tCluster1_ReadCount-7\t2\t60\t4=\t*\t0\t0\tACGT\t*"

    hit = normalizer.parse_minimap_sam_hit(line)

    assert hit.is_reverse is True


def test_parse_minimap_sam_hit_ignores_unmapped_records():
    assert normalizer.parse_minimap_sam_hit("AlleleA\t4\t*\t0\t0\t*\t*\t0\t0\t*\t*") is None


def test_best_hit_for_cluster_matches_swift_closest_match_ordering():
    hits = [
        normalizer.MinimapHit(
            cluster="Cluster1",
            allele="AlleleB",
            cluster_start=20,
            cluster_end=119,
            snps=2,
            matched_bases=100,
            indel_bases=0,
        ),
        normalizer.MinimapHit(
            cluster="Cluster1",
            allele="AlleleA",
            cluster_start=5,
            cluster_end=124,
            snps=1,
            matched_bases=120,
            indel_bases=2,
        ),
        normalizer.MinimapHit(
            cluster="Cluster1",
            allele="AlleleC",
            cluster_start=10,
            cluster_end=109,
            snps=1,
            matched_bases=100,
            indel_bases=0,
        ),
    ]

    best = normalizer.best_minimap_hit(hits)

    assert best.allele == "AlleleC"
    assert best.cluster_start == 10
    assert best.cluster_end == 109


def test_mapping_closest_match_id_matches_workflow_convention():
    snp_hit = normalizer.MinimapHit(
        cluster="Cluster1",
        allele="Mafa-A1*001:01",
        cluster_start=1,
        cluster_end=100,
        snps=2,
        matched_bases=98,
        indel_bases=0,
    )
    extension_hit = normalizer.MinimapHit(
        cluster="Cluster2",
        allele="Mafa-B*001:01",
        cluster_start=10,
        cluster_end=90,
        snps=0,
        matched_bases=81,
        indel_bases=12,
    )

    assert normalizer.mapping_closest_match_id(snp_hit) == "Mafa-A1*001:01_2SNP"
    assert normalizer.mapping_match_class(snp_hit) == "snp-different"
    assert normalizer.mapping_nucleotides_different(snp_hit) == 2
    assert normalizer.mapping_closest_match_id(extension_hit) == "Mafa-B*001:01_extension"
    assert normalizer.mapping_match_class(extension_hit) == "extension"
    assert normalizer.mapping_nucleotides_different(extension_hit) == 0


def test_trim_rows_reverse_complements_reverse_strand_hits_before_id_assignment():
    row = normalizer.WorkbookRow(
        unmatched_sequence_id="raw-id",
        sample="PN384b",
        cluster="Cluster1",
        cluster_reads=998,
        closest_match_id="AlleleA_1SNP",
        match_class="snp-different",
        sequence="AAGCAT",
        source_values={},
    )
    forward_hit = normalizer.MinimapHit(
        cluster="Cluster1",
        allele="AlleleA",
        cluster_start=2,
        cluster_end=5,
        snps=1,
        matched_bases=3,
        indel_bases=0,
    )
    reverse_hit = normalizer.MinimapHit(
        cluster="Cluster1",
        allele="AlleleA",
        cluster_start=2,
        cluster_end=5,
        snps=1,
        matched_bases=3,
        indel_bases=0,
        is_reverse=True,
    )

    forward = normalizer.trim_rows([row], {("PN384b", "Cluster1"): forward_hit})[0]
    reverse = normalizer.trim_rows([row], {("PN384b", "Cluster1"): reverse_hit})[0]

    assert forward.trimmed_sequence == "AGCA"
    assert reverse.trimmed_sequence == "TGCT"
    assert reverse.trimmed_sequence_id == normalizer.unmatched_sequence_id("TGCT")


def test_grouped_trimmed_fasta_header_reports_occurrences_and_samples(tmp_path):
    rows = [
        normalized_row("PN384", "Cluster1", 202, "seq-1", "ACGT"),
        normalized_row("PN384b", "Cluster2", 998, "seq-1", "ACGT"),
        normalized_row("PN385", "Cluster3", 5, "seq-2", "TGCA"),
    ]
    output = tmp_path / "grouped.fasta"

    normalizer.write_grouped_trimmed_fasta(rows, output)

    assert output.read_text(encoding="utf-8").splitlines() == [
        ">seq-1|occurrences=2|sample_count=2|samples=PN384;PN384b|total_cluster_reads=1200",
        "ACGT",
        ">seq-2|occurrences=1|sample_count=1|samples=PN385|total_cluster_reads=5",
        "TGCA",
    ]
