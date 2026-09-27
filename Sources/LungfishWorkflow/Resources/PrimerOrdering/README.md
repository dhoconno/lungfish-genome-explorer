# IDT oPools ordering template

`IDT-oPools-template.xlsx` derives from the user-provided Integrated DNA Technologies `opoolsentrysample.xlsx` template, supplied on 2026-09-12.

- Original file SHA-256: `af54ddea06dba272488db20a463d3cb22d48756286d432d4971752e122d8f8ca`
- Bundled sanitized file SHA-256: `06011c8a0c29ef15aefb91fe7d7ce0af00e7dabbd5fab82dc726608b2ae962b4`

Sanitization removes the vendor creator/last-editor properties, the local Windows download path and collaboration revision record in `xl/workbook.xml`, and the tenant/label properties in `docProps/custom.xml`. Archive timestamps are fixed at 1980-01-01. Sheet1, shared strings, cell styles, theme, print settings and template instructions remain unchanged, including the illustrative entry rows in this source template. Vendor attribution remains in the document title and company property.

The native Swift writer verifies the bundled hash and retains the exact template as `template.xlsx` in each derived order. Generated workbooks replace every sample entry in columns A/B below the header with the captured pool names and saved 5′–3′ sequences. Unused sample strings are removed from the generated shared-string table. The writer preserves the vendor instructions, mixed-base table and styles, and widens column A when needed for pool names.

`primer-order.xlsx` adds an Order metadata worksheet with the captured selection, optional user-supplied order fields, and oligo identities. `IDT-oPools.xlsx` contains only the vendor worksheet for upload systems that do not support selecting a sheet. The CSV and metadata do not infer sequence modifications. Untouched `template-parts` and generated `upload-parts`/`workbook-parts` are retained for the recorded extraction and ZIP commands. Native version probes identify ZIP tools, with binary hashes as fallback; no managed analysis runtime is required.
