// ProvenanceLegacyDisplayRecords.swift - Legacy provenance records written as literal bytes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The MSA, tree and assembly records are the literals of ProvenanceEnvelopeTests,
// which decode them in LungfishWorkflowTests. The mapping record is a schema 3
// `mapping-provenance.json` modeled on the key layout today's writer produces
// (Tests/Fixtures/golden/mapping). Every path in them names a placeholder
// (`/project/...`, `@/...`) and none names a person's folder.

import Foundation

enum ProvenanceLegacyRecords {
    /// An MSA record whose `files` is a keyed map, as `lungfish align mafft` wrote it.
    static let msa = Data("""
    {
      "schemaVersion": 1,
      "createdAt": "2026-05-12T18:41:18Z",
      "workflowName": "multiple-sequence-alignment-mafft",
      "toolName": "lungfish align mafft",
      "toolVersion": "0.1.0",
      "argv": ["lungfish", "align", "mafft", "input.lungfishref", "--output", "aligned.lungfishmsa"],
      "reproducibleCommand": "lungfish align mafft input.lungfishref --output aligned.lungfishmsa",
      "runtimeIdentity": {
        "executablePath": "/Applications/Lungfish.app/Contents/MacOS/lungfish-cli",
        "operatingSystemVersion": "macOS test",
        "processIdentifier": 42
      },
      "input": {
        "checksumSHA256": "\(String(repeating: "a", count: 64))",
        "fileSize": 20,
        "path": "/project/aligned.lungfishmsa/alignment/source.original"
      },
      "inputFiles": [
        {
          "checksumSHA256": "\(String(repeating: "b", count: 64))",
          "fileSize": 10,
          "path": "/project/input.lungfishref"
        }
      ],
      "files": {
        "alignment/primary.aligned.fasta": {
          "checksumSHA256": "\(String(repeating: "c", count: 64))",
          "fileSize": 30,
          "path": "/project/aligned.lungfishmsa/alignment/primary.aligned.fasta"
        }
      },
      "output": {
        "checksumSHA256": "\(String(repeating: "d", count: 64))",
        "fileSize": 40,
        "path": "/project/aligned.lungfishmsa"
      },
      "externalToolInvocations": [
        {
          "name": "mafft",
          "version": "7.526",
          "argv": ["mafft", "--auto", "/project/aligned.lungfishmsa/alignment/input.unaligned.fasta"],
          "reproducibleCommand": "mafft --auto input > output",
          "exitStatus": 0,
          "wallTimeSeconds": 1.5
        }
      ],
      "exitStatus": 0,
      "wallTimeSeconds": 2.0
    }
    """.utf8)

    /// A tree record with no `createdAt`, as `lungfish tree infer iqtree` wrote it.
    static let tree = Data("""
    {
      "schemaVersion": 1,
      "workflowName": "phylogenetic-tree-infer-iqtree",
      "toolName": "lungfish tree infer iqtree",
      "toolVersion": "0.5.0-alpha6",
      "argv": ["lungfish", "tree", "infer", "iqtree", "aligned.lungfishmsa"],
      "command": "lungfish tree infer iqtree aligned.lungfishmsa",
      "runtimeIdentity": {
        "executablePath": "/usr/local/bin/lungfish-cli",
        "operatingSystemVersion": "macOS test"
      },
      "input": {
        "path": "/project/aligned.lungfishmsa",
        "sha256": "\(String(repeating: "e", count: 64))",
        "fileSizeBytes": 100
      },
      "output": {
        "path": "/project/tree.lungfishtree",
        "sha256": "\(String(repeating: "f", count: 64))",
        "fileSizeBytes": 200
      },
      "checksums": {
        "manifest.json": "\(String(repeating: "1", count: 64))",
        "tree/primary.nwk": "\(String(repeating: "2", count: 64))"
      },
      "fileSizes": {
        "manifest.json": 12,
        "tree/primary.nwk": 34
      },
      "externalTool": {
        "toolName": "iqtree2",
        "toolVersion": "2.3.6",
        "argv": ["iqtree2", "-s", "input.aligned.fasta"],
        "reproducibleCommand": "iqtree2 -s input.aligned.fasta",
        "exitStatus": 0,
        "wallTimeSeconds": 3.0
      },
      "exitStatus": 0,
      "wallTimeSeconds": 4.0
    }
    """.utf8)

    /// An assembly record in the assembler's own snake_case keys, stored as `assembly/provenance.json`.
    static let assembly = Data("""
    {
      "assembler": "SPAdes",
      "assembler_version": "4.0.0",
      "execution_backend": "micromamba",
      "managed_environment": "spades",
      "host_os": "macOS test",
      "host_architecture": "arm64",
      "lungfish_version": "Lungfish test",
      "assembly_date": "2026-05-12T18:41:18Z",
      "wall_time_seconds": 12.5,
      "command_line": "spades.py -1 reads_1.fastq -2 reads_2.fastq -o assembly",
      "parameters": {
        "mode": "isolate",
        "k_mer_sizes": "auto",
        "memory_gb": 16,
        "threads": 8,
        "skip_error_correction": false,
        "min_contig_length": 500,
        "extraArgs": "",
        "advanced_arguments": []
      },
      "inputs": [
        {
          "filename": "reads_1.fastq",
          "original_path": "/project/reads_1.fastq",
          "sha256": "\(String(repeating: "a", count: 64))",
          "size_bytes": 100
        }
      ]
    }
    """.utf8)

    /// A schema 3 `mapping-provenance.json` for a paired minimap2 run, with project-relative
    /// (`@/`) paths as a mapping inside a project writes them. Step times are seconds since
    /// 2001-01-01, the default of the encoder that wrote them, and `recordedAt` is seconds since 1970.
    static let mappingSchema3 = Data(#"""
    {
      "advancedArguments" : [],
      "exitStatus" : 0,
      "includeSecondary" : false,
      "includeSupplementary" : true,
      "inputFASTQPaths" : [
        "@/Imports/HG002-reads.lungfishfastq/HG002_R1.fastq.gz",
        "@/Imports/HG002-reads.lungfishfastq/HG002_R2.fastq.gz"
      ],
      "inputFiles" : [
        {
          "format" : "fastq",
          "path" : "@/Imports/HG002-reads.lungfishfastq/HG002_R1.fastq.gz",
          "role" : "input",
          "sha256" : "0515ba304cb1bf7abcdd9c156b6affad7e580273f983dfed2e8fe2d918e800ff",
          "sizeBytes" : 9413
        },
        {
          "format" : "fastq",
          "path" : "@/Imports/HG002-reads.lungfishfastq/HG002_R2.fastq.gz",
          "role" : "input",
          "sha256" : "0080f40cab58c7e7b85443e37de22775e3ed6b7afdef9a3271ac3147576f3027",
          "sizeBytes" : 9395
        },
        {
          "format" : "fasta",
          "path" : "@/Reference Sequences/NC_045512.2.lungfishref/genome/sequence.fa.gz",
          "role" : "reference",
          "sha256" : "1c945301b29bae75e5219f08b5189a56a72a5cdf452873e54bf513468ae091f6",
          "sizeBytes" : 8764
        }
      ],
      "inputLayout" : "paired_files",
      "inputLayoutReason" : "Two input files are bound as R1 and R2.",
      "mapper" : "minimap2",
      "mapperDisplayName" : "minimap2",
      "mapperInvocation" : {
        "argv" : [
          "minimap2",
          "-a",
          "-x",
          "sr",
          "-t",
          "4",
          "-R",
          "@RG\\tID:HG002\\tSM:HG002\\tLB:HG002\\tPL:ILLUMINA\\tPU:HG002",
          "--secondary=no",
          "-o",
          "@/Analyses/minimap2-2026-07-14T15-20-00/HG002.raw.sam",
          "@/Reference Sequences/NC_045512.2.lungfishref/genome/sequence.fa.gz",
          "@/Imports/HG002-reads.lungfishfastq/HG002_R1.fastq.gz",
          "@/Imports/HG002-reads.lungfishfastq/HG002_R2.fastq.gz"
        ],
        "label" : "minimap2"
      },
      "mapperVersion" : "2.31",
      "minimumMappingQuality" : 0,
      "modeDisplayName" : "Short-read",
      "modeID" : "short-read-default",
      "normalizationInvocations" : [
        {
          "argv" : [
            "samtools",
            "sort",
            "-@",
            "2",
            "-o",
            "@/Analyses/minimap2-2026-07-14T15-20-00/HG002.sorted.bam",
            "@/Analyses/minimap2-2026-07-14T15-20-00/HG002.raw.sam"
          ],
          "label" : "samtools sort"
        },
        {
          "argv" : [
            "samtools",
            "index",
            "@/Analyses/minimap2-2026-07-14T15-20-00/HG002.sorted.bam"
          ],
          "label" : "samtools index"
        }
      ],
      "outputFiles" : [
        {
          "format" : "bam",
          "path" : "@/Analyses/minimap2-2026-07-14T15-20-00/HG002.sorted.bam",
          "role" : "output",
          "sha256" : "5c2a0f6a7d1d5bd0d8e6a7d0cc7e1a1b0f0a3f6a4a3f2b7a9d4c1e8b6a5f3e21",
          "sizeBytes" : 58213
        },
        {
          "format" : "bai",
          "path" : "@/Analyses/minimap2-2026-07-14T15-20-00/HG002.sorted.bam.bai",
          "role" : "index",
          "sha256" : "9b8f7e6d5c4b3a291807f6e5d4c3b2a1908f7e6d5c4b3a291807f6e5d4c3b2a1",
          "sizeBytes" : 1144
        }
      ],
      "pairedEnd" : true,
      "parameters" : {
        "extraArgs" : "",
        "readGroup" : {
          "id" : "HG002",
          "lb" : "HG002",
          "pl" : "ILLUMINA",
          "pu" : "HG002",
          "sm" : "HG002"
        }
      },
      "readClassHints" : [
        "Illumina short reads"
      ],
      "readGroup" : {
        "id" : "HG002",
        "library" : "HG002",
        "platform" : "ILLUMINA",
        "platformUnit" : "HG002",
        "sampleName" : "HG002"
      },
      "readLayoutHandling" : "as_pairs",
      "recordedAt" : 1784042400,
      "referenceFASTAPath" : "@/Reference Sequences/NC_045512.2.lungfishref/genome/sequence.fa.gz",
      "runtimeIdentity" : {
        "mapper" : "managed conda environment minimap2; executable minimap2",
        "samtools" : "managed conda environment samtools; executable samtools; package bioconda::samtools=1.24=h36b3a25_1"
      },
      "sampleName" : "HG002",
      "samtoolsVersion" : "1.24",
      "schemaVersion" : 3,
      "sourceReferenceBundlePath" : "@/Reference Sequences/NC_045512.2.lungfishref",
      "stderr" : "[M::main] Version: 2.31-r1302\n[M::main] Real time: 95.213 sec; CPU: 301.4 sec; Peak RSS: 0.412 GB\n",
      "steps" : [
        {
          "command" : [
            "minimap2",
            "-a",
            "-x",
            "sr",
            "-t",
            "4",
            "-R",
            "@RG\\tID:HG002\\tSM:HG002\\tLB:HG002\\tPL:ILLUMINA\\tPU:HG002",
            "--secondary=no",
            "-o",
            "@/Analyses/minimap2-2026-07-14T15-20-00/HG002.raw.sam",
            "@/Reference Sequences/NC_045512.2.lungfishref/genome/sequence.fa.gz",
            "@/Imports/HG002-reads.lungfishfastq/HG002_R1.fastq.gz",
            "@/Imports/HG002-reads.lungfishfastq/HG002_R2.fastq.gz"
          ],
          "dependsOn" : [],
          "endTime" : 805735200,
          "exitCode" : 0,
          "id" : "4F0D3C5E-6A1B-4C2D-8E3F-5A6B7C8D9E01",
          "inputs" : [
            {
              "format" : "fastq",
              "path" : "@/Imports/HG002-reads.lungfishfastq/HG002_R1.fastq.gz",
              "role" : "input",
              "sha256" : "0515ba304cb1bf7abcdd9c156b6affad7e580273f983dfed2e8fe2d918e800ff",
              "sizeBytes" : 9413
            },
            {
              "format" : "fastq",
              "path" : "@/Imports/HG002-reads.lungfishfastq/HG002_R2.fastq.gz",
              "role" : "input",
              "sha256" : "0080f40cab58c7e7b85443e37de22775e3ed6b7afdef9a3271ac3147576f3027",
              "sizeBytes" : 9395
            },
            {
              "format" : "fasta",
              "path" : "@/Reference Sequences/NC_045512.2.lungfishref/genome/sequence.fa.gz",
              "role" : "reference",
              "sha256" : "1c945301b29bae75e5219f08b5189a56a72a5cdf452873e54bf513468ae091f6",
              "sizeBytes" : 8764
            }
          ],
          "outputs" : [
            {
              "format" : "sam",
              "path" : "@/Analyses/minimap2-2026-07-14T15-20-00/HG002.raw.sam",
              "role" : "output",
              "sha256" : "7a6b5c4d3e2f1a0b9c8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a2b1c0d9e8f7a6b",
              "sizeBytes" : 412876
            }
          ],
          "startTime" : 805735105,
          "stderr" : "[M::main] Version: 2.31-r1302\n[M::main] Real time: 95.213 sec; CPU: 301.4 sec; Peak RSS: 0.412 GB\n",
          "toolName" : "minimap2",
          "toolVersion" : "2.31 (managed conda environment minimap2; executable minimap2)",
          "wallTime" : 95.213
        },
        {
          "command" : [
            "samtools",
            "sort",
            "-@",
            "2",
            "-o",
            "@/Analyses/minimap2-2026-07-14T15-20-00/HG002.sorted.bam",
            "@/Analyses/minimap2-2026-07-14T15-20-00/HG002.raw.sam"
          ],
          "dependsOn" : [],
          "endTime" : 805735200,
          "exitCode" : 0,
          "id" : "4F0D3C5E-6A1B-4C2D-8E3F-5A6B7C8D9E02",
          "inputs" : [
            {
              "format" : "sam",
              "path" : "@/Analyses/minimap2-2026-07-14T15-20-00/HG002.raw.sam",
              "role" : "input",
              "sha256" : "7a6b5c4d3e2f1a0b9c8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a2b1c0d9e8f7a6b",
              "sizeBytes" : 412876
            }
          ],
          "outputs" : [
            {
              "format" : "bam",
              "path" : "@/Analyses/minimap2-2026-07-14T15-20-00/HG002.sorted.bam",
              "role" : "output",
              "sha256" : "5c2a0f6a7d1d5bd0d8e6a7d0cc7e1a1b0f0a3f6a4a3f2b7a9d4c1e8b6a5f3e21",
              "sizeBytes" : 58213
            }
          ],
          "startTime" : 805735200,
          "toolName" : "samtools",
          "toolVersion" : "1.24 (managed conda environment samtools; executable samtools; package bioconda::samtools=1.24=h36b3a25_1)",
          "wallTime" : 0.184
        },
        {
          "command" : [
            "samtools",
            "index",
            "@/Analyses/minimap2-2026-07-14T15-20-00/HG002.sorted.bam"
          ],
          "dependsOn" : [],
          "endTime" : 805735200,
          "exitCode" : 0,
          "id" : "4F0D3C5E-6A1B-4C2D-8E3F-5A6B7C8D9E03",
          "inputs" : [
            {
              "format" : "bam",
              "path" : "@/Analyses/minimap2-2026-07-14T15-20-00/HG002.sorted.bam",
              "role" : "input",
              "sha256" : "5c2a0f6a7d1d5bd0d8e6a7d0cc7e1a1b0f0a3f6a4a3f2b7a9d4c1e8b6a5f3e21",
              "sizeBytes" : 58213
            }
          ],
          "outputs" : [
            {
              "format" : "bai",
              "path" : "@/Analyses/minimap2-2026-07-14T15-20-00/HG002.sorted.bam.bai",
              "role" : "index",
              "sha256" : "9b8f7e6d5c4b3a291807f6e5d4c3b2a1908f7e6d5c4b3a291807f6e5d4c3b2a1",
              "sizeBytes" : 1144
            }
          ],
          "startTime" : 805735200,
          "toolName" : "samtools",
          "toolVersion" : "1.24 (managed conda environment samtools; executable samtools; package bioconda::samtools=1.24=h36b3a25_1)",
          "wallTime" : 0.021
        }
      ],
      "threads" : 4,
      "viewerBundlePath" : "NC_045512.2.lungfishref",
      "wallClockSeconds" : 95.4,
      "workflowName" : "lungfish map"
    }
    """#.utf8)
}
