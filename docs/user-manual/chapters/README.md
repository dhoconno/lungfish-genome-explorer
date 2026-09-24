# Chapters

This file is a contributor index of the chapters tree, not a reader chapter.

**Ownership.** The Bioinformatics Educator writes chapter bodies. The Brand
Copy Editor may edit for brand fidelity and records changes in `reviews/`. No
other agent writes to chapter files.

## Structure

```
chapters/
├── 01-foundations/               # Part I, format and concept primers
├── 02-sequences/                 # Part II starts here
├── 03-reads/
├── 04-alignments/
├── 05-variants/
├── 06-classification/            # shares the 06 prefix by design
├── 06-human-germline-variants/   # shares the 06 prefix by design
├── 07-assembly/
├── 08-workflows/
├── 09-genotyping/
└── appendices/                   # Part III, reference material
```

Each chapter is one `.md` file with YAML frontmatter. The directory name
encodes the part number, and the file name encodes the chapter's order within
its part. `06-classification` and `06-human-germline-variants` share the `06`
prefix on purpose. Renaming either would break in-app help links and paths
that tests pin.

Every chapter follows the chapter template in `../STYLE.md`. The narrow scope
of each chapter, meaning what it covers and what it leaves to another chapter,
is recorded in the `## Chapter scopes` table of `../ARCHITECTURE.md`, which is
the one place to check before adding text to a chapter.
