# Wave 1 IO Correctness Plan

**Goal:** Fix foundational compressed/text IO parsing defects in LungfishIO without changing scientific data provenance behavior.

**Scope:**
- Keep changes inside the wave1 worktree and targeted LungfishIO files/tests.
- Use TDD: add failing tests first, confirm red, implement minimal fixes, confirm green.
- Treat gzip-aware readers as shared infrastructure for FASTQ/FASTA/BED/GFF/GTF workflows.

**Tasks:**
1. Add regression tests for `GzipInputStream.lines()` proving chunk-boundary newlines do not yield extra empty lines and consecutive newlines still yield true empty lines.
2. Add a `GZIIndex(url:)` regression test using an intentionally unaligned `.gzi` payload so aligned `UInt64` loads fail until the reader switches to unaligned little-endian decoding.
3. Add `.fa.gz`/`.fasta.gz` tests for `FASTAReader.readAll`, `sequences()`, and `readHeaders()`; implement transparent gzip-aware reading for compressed FASTA.
4. Add gzip fixture tests for `BEDReader`, `GFF3Reader`, and `GTFReader`; route their async line readers through `URL.linesAutoDecompressing()`.
5. If contained, add tests and fixes so FASTA, FAI index building, and FASTQ header parsing split identifiers from descriptions on any Unicode whitespace, not only literal spaces.

**Verification:**
- Red runs: targeted XCTest filters for the newly added tests before production edits.
- Green runs: targeted LungfishIO test filters covering gzip lines, GZI index, FASTA, BED, GFF3, GTF, FASTQ, plus any adjusted comprehensive parser tests.
- Do not commit unless targeted tests are green.
