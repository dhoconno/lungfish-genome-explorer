# Format Handling Plan — Expert Report

## Completed
1. **Streaming FASTA** — 256KB buffered chunks, O(n) accumulation, CRLF support (9d76445)
2. **GTF Support** — Full GTFReader with 42 tests (639908f)
3. **Bgzip VCF** — Uses url.linesAutoDecompressing() for transparent .vcf.gz support (48a8161, c957262)

## Future: Tabix Index Support
- Phase 2 of bgzip VCF: add TabixReader for region queries
- Parse .tbi binary index format
- Seek to compressed offset, decompress only needed blocks
- Share bgzip block reader with BgzipIndexedFASTAReader
- Not needed for current use cases (full-file import works)

## Key Design Decisions
- FASTA streaming: FileHandle + 256KB chunks (sync), url.lines (async)
- VCF bgzip: url.linesAutoDecompressing() (2-line change leveraging existing GzipInputStream)
- GTF: Separate reader class (not auto-detect in GFF3Reader) — different attribute syntax
