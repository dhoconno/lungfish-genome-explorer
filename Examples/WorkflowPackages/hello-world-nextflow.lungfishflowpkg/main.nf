nextflow.enable.dsl = 2

params.outdir = params.outdir ?: './results'

workflow {
    CREATE_REFERENCE_BUNDLE()
}

process CREATE_REFERENCE_BUNDLE {
    publishDir params.outdir, mode: 'copy', overwrite: true

    output:
    path 'hello-world-nextflow.lungfishref'

    script:
    '''
mkdir -p hello-world-nextflow.lungfishref/genome
cat > hello-world-nextflow.lungfishref/genome/sequence.fa <<'EOF'
>hello
ACGT
EOF
cat > hello-world-nextflow.lungfishref/genome/sequence.fa.fai <<'EOF'
hello	4	7	4	5
EOF
cat > hello-world-nextflow.lungfishref/manifest.json <<'EOF'
{
  "format_version": "1.0",
  "name": "Hello World Nextflow",
  "identifier": "org.lungfish.templates.hello-world-nextflow.reference",
  "description": "Tiny synthetic reference bundle emitted by the hello-world Nextflow template.",
  "created_date": "2026-01-01T00:00:00Z",
  "modified_date": "2026-01-01T00:00:00Z",
  "source": {
    "organism": "Synthetic construct",
    "assembly": "hello-world-nextflow",
    "database": "Lungfish template"
  },
  "genome": {
    "path": "genome/sequence.fa",
    "index_path": "genome/sequence.fa.fai",
    "total_length": 4,
    "chromosomes": [
      {
        "name": "hello",
        "length": 4,
        "offset": 7,
        "line_bases": 4,
        "line_width": 5,
        "aliases": [],
        "is_primary": true,
        "is_mitochondrial": false
      }
    ]
  },
  "annotations": [],
  "variants": [],
  "tracks": [],
  "alignments": []
}
EOF
'''
}
