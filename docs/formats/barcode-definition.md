# Custom barcode definition

A custom barcode definition is a text file that `lungfish fastq demultiplex --kit <path>` and the Demultiplex Barcodes dialog read in place of a built-in kit. The loader is `BarcodeKitRegistry.loadCustomKit` in `Sources/LungfishIO/Formats/FASTQ`.

## Rows and columns

Each row is one barcode. The fields are split by commas, by tabs, or by runs of spaces, in that order of preference. Without a header line the columns are positional.

| Column | Holds |
| --- | --- |
| 1 | The barcode ID, which names the output bundle of the barcode |
| 2 | The barcode sequence, the i7 index of an Illumina kit |
| 3 | The secondary sequence, the i5 index of a dual-index kit (optional) |
| 4 | The sample name (optional) |

A header line may name the columns instead. Its first two names are an ID name such as `id` and a sequence name such as `sequence`, and later names such as `sample_name` or `secondary_sequence` place those columns. So `id,sequence,sample_name` puts the sample names in the third column. A sequence column holds nucleotide letters only, and a row whose sequence cell is empty is skipped.

## Quoted fields

A field may be quoted as RFC 4180 quotes a CSV field. A field that starts with `"` runs to the next lone `"`, two quotes inside it read as one quote, and a comma or a tab inside it is part of the field. So the row `NTC_1,TCCGGAGA,"NTC, 1"` names the sample `NTC, 1`. A field cannot hold a line break.

## Comment lines and the kit line

A line that starts with `#` is a comment. One comment is read, the kit line.

```
# kit: truseq-single-a
id,sequence,sample_name
Water_blank,ATTACTCG,Water (blank)
NTC_1,TCCGGAGA,"NTC, 1"
```

The kit line names the built-in kit the definition was made on. The definition then keeps that kit's vendor, platform, kit type, indexing and pairing, and holds only its own rows. A run of the definition searches the reads as a run of the kit does. An Illumina kit's run reads the indexes in the read names when they carry two or more of the kit's barcodes, counted over the whole kit and not only the definition's rows, so a definition of one sample takes the same route as the kit's own run on the same file. The split then makes outputs for the definition's rows only, and the reads of the kit's other barcodes go to Unassigned. A long-read kit's run searches the platform's full adapter and barcode construct.

The load refuses in words when the kit line names a kit this version does not know, when two kit lines name different kits, or when a row has a secondary sequence and the kit's barcodes have none, or the other way round. Without a kit line the definition is a kit of its own, single or dual indexed as its rows are, and its run searches the bare sequences.

## The copy in the result folder

A demultiplexing run on a custom definition reads the file once and keeps those bytes in its result folder under the same file name. The recorded command and the `kit` and `customBarcodeKit` parameters name the copy, and the record lists the copy with its SHA-256 digest. A replay of the recorded command reads the copy, so it searches with the definition the run read even after the project's file changes. A definition whose file name is one the run writes in its result folder, such as a name that starts with a dot or ends in `.lungfishfastq`, refuses before the run starts.
