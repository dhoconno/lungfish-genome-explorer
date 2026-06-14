# Reads and Workflows

## What it is

FASTQ workflows change read data. Trimming, filtering, demultiplexing, mapping, assembly, and extraction can all change which reads are kept, how they are grouped, or which bundle stores the result.

Use the help text in each dialog to check the selected inputs, defaults, and output strategy before you click Run.

## Procedure

1. Select the FASTQ or FASTA inputs in the project sidebar.
2. Open the workflow dialog from Tools or the inspector action.
3. Choose the operation that matches your biological question.
4. Check the Inputs, Primary Settings, Output, and Readiness sections.
5. Click Run when the readiness text says the operation can proceed.

## Interpretation

Per Input output keeps one derived result per source. Grouped Result combines compatible inputs into one result. That choice changes bundle topology and output checksums.

Advanced arguments are passed directly to the underlying command. Use them when you need a specific CLI option, and check provenance afterward to confirm the final argv.

## Provenance

Data-changing FASTQ workflows write provenance for the command, tool version, visible options, resolved defaults, inputs, checksums, file sizes, output paths, status, and runtime. Use the Provenance view when you need to repeat the run or explain it in methods.
