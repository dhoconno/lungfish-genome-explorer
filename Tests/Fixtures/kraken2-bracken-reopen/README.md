# kraken2-bracken-reopen

A hand-made single Kraken 2 result that also ran Bracken, shaped like the
real Viral-database result that exposed the reopen bug.

- `classification.kreport` is Kraken 2's own report: 1,000 read pairs, 600
  unclassified, 400 classified. It holds a row below species (taxid 10298,
  rank S1, 370 pairs) and a genus Bracken drops (Pahexavirus, 8 pairs).
- `classification.bracken.kreport` is Bracken's re-estimated report: species
  only, 386 reads, no unclassified line. It sorts before Kraken 2's report.
- `classification.bracken` holds Bracken's species estimates (376 and 10).
- `source.fastq` is interleaved: both mates of four pairs, adjacent.
- `classification.kraken` has one line per pair.
- `classification-result.json` records sample `SRRTEST1`, interleaved input,
  and Bracken 3.0.1.

The viewer must show Kraken 2's tree (8 rows, including 10298), percentages
of all 1,000 pairs, and Bracken's 376 only in the Bracken column.
