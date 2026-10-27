# interleaved-sra-names

A hand-made Kraken 2 result of one interleaved paired file whose mates carry
byte-equal SRA names, shaped like the HSV-1 extraction of the 2026-10-26 walk
(SRR12486983). Phase 3.0 lane PAIRING uses it.

- `source.fastq` holds 6 pairs, 12 records. The two mates of a pair are
  adjacent and have the same header, as `fasterq-dump --split-spot` writes
  them, with no `/1` or `/2`.
- `classification.kraken` has one line per pair. Pairs 1 to 4 sit on taxid
  10298 (Human alphaherpesvirus 1) and pairs 5 and 6 on taxid 10325
  (Macacine alphaherpesvirus 1).
- `classification.kreport` counts the 6 pairs, 4 under 10298 and 2 under
  10325, both below Simplexvirus.
- `classification-result.json` records the sample `SRR12486983` with
  `interleavedInput true`.

Extracting `10298,children,HSV-1` gives 8 records, 4 pairs, and no single
read. Extracting `10325,exact,MaHV-1` gives 4 records.
