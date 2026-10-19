// ReferenceBundleMergePinExpected.swift - The text ReferenceBundleMergePinConformanceTests pins
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

enum ReferenceBundleMergePinExpected {
    static let twoBundles = #"""
== files ==
.lungfish-provenance.json
annotations/alpha_genes.db
annotations/beta_genes.db
genome/sequence.fa.gz
genome/sequence.fa.gz.fai
genome/sequence.fa.gz.gzi
manifest.json
provenance/annotations/alpha_genes.db.lungfish-provenance.json
provenance/annotations/beta_genes.db.lungfish-provenance.json
provenance/bundle.lungfish-provenance.json
provenance/genome/sequence.fa.gz.fai.lungfish-provenance.json
provenance/genome/sequence.fa.gz.gzi.lungfish-provenance.json
provenance/genome/sequence.fa.gz.lungfish-provenance.json
provenance/manifest.json.lungfish-provenance.json
== genome ==
>chrA
ACGTACGTACGTACGTACGT
>chrB
TTGGCCAATTGGCCAATTGG
== manifest ==
{
  "alignments" : [

  ],
  "annotations" : [
    {
      "annotation_type" : "gene",
      "database_path" : "annotations/alpha_genes.db",
      "description" : "Merged from Alpha",
      "feature_count" : 1,
      "id" : "alpha_genes",
      "name" : "Genes Alpha (Alpha)",
      "path" : "annotations/alpha_genes.db"
    },
    {
      "annotation_type" : "gene",
      "database_path" : "annotations/beta_genes.db",
      "description" : "Merged from Beta",
      "feature_count" : 1,
      "id" : "beta_genes",
      "name" : "Genes Beta (Beta)",
      "path" : "annotations/beta_genes.db"
    }
  ],
  "browser_summary" : {
    "aggregate" : {
      "alignmentTrackCount" : 0,
      "annotationTrackCount" : 2,
      "variantTrackCount" : 0
    },
    "schemaVersion" : 1,
    "sequences" : [
      {
        "aliases" : [

        ],
        "isMitochondrial" : false,
        "isPrimary" : true,
        "length" : 20,
        "name" : "chrA"
      },
      {
        "aliases" : [

        ],
        "isMitochondrial" : false,
        "isPrimary" : true,
        "length" : 20,
        "name" : "chrB"
      }
    ]
  },
  "format_version" : "1.0",
  "genome" : {
    "chromosomes" : [
      {
        "aliases" : [

        ],
        "is_mitochondrial" : false,
        "is_primary" : true,
        "length" : 20,
        "line_bases" : 20,
        "line_width" : 21,
        "name" : "chrA",
        "offset" : 6
      },
      {
        "aliases" : [

        ],
        "is_mitochondrial" : false,
        "is_primary" : true,
        "length" : 20,
        "line_bases" : 20,
        "line_width" : 21,
        "name" : "chrB",
        "offset" : 33
      }
    ],
    "gzip_index_path" : "genome/sequence.fa.gz.gzi",
    "index_path" : "genome/sequence.fa.gz.fai",
    "path" : "genome/sequence.fa.gz",
    "total_length" : 40
  },
  "identifier" : "org.lungfish.merge.<UUID>",
  "name" : "Merged Pin",
  "source" : {
    "assembly" : "Merged Pin",
    "notes" : "Merged from Alpha, Beta.",
    "organism" : "Test organism Alpha; Test organism Beta"
  },
  "tracks" : [

  ],
  "variants" : [

  ],
  "warnings" : [

  ]
}
== record ==
{
  "argv" : [
    "lungfish-cli",
    "bundle",
    "merge",
    "@/Alpha.lungfishref",
    "@/Beta.lungfishref",
    "--name=Merged Pin",
    "--output-dir",
    "@/"
  ],
  "durableReplayArgv" : [
    "lungfish-cli",
    "bundle",
    "merge",
    "@/Alpha.lungfishref",
    "@/Beta.lungfishref",
    "--name=Merged Pin",
    "--output-dir",
    "@/"
  ],
  "exitStatus" : 0,
  "files" : [
    {
      "format" : "fasta",
      "path" : "@/Alpha.lungfishref/genome/sequence.fa",
      "role" : "input"
    },
    {
      "format" : "fasta",
      "path" : "@/Beta.lungfishref/genome/sequence.fa",
      "role" : "input"
    },
    {
      "format" : "unknown",
      "path" : "@/Merged_Pin.lungfishref/annotations/alpha_genes.db",
      "role" : "output"
    },
    {
      "format" : "unknown",
      "path" : "@/Merged_Pin.lungfishref/annotations/beta_genes.db",
      "role" : "output"
    },
    {
      "format" : "fasta",
      "path" : "@/Merged_Pin.lungfishref/genome/sequence.fa.gz",
      "role" : "output"
    },
    {
      "format" : "text",
      "path" : "@/Merged_Pin.lungfishref/genome/sequence.fa.gz.fai",
      "role" : "output"
    },
    {
      "format" : "text",
      "path" : "@/Merged_Pin.lungfishref/genome/sequence.fa.gz.gzi",
      "role" : "output"
    },
    {
      "format" : "json",
      "path" : "@/Merged_Pin.lungfishref/manifest.json",
      "role" : "output"
    }
  ],
  "id" : "<UUID>",
  "options" : {
    "defaults" : {
      "annotationMerge" : {
        "type" : "string",
        "value" : "preserved"
      },
      "compressFASTA" : {
        "type" : "boolean",
        "value" : true
      },
      "trackMerge" : {
        "type" : "string",
        "value" : "unsupported"
      },
      "variantMerge" : {
        "type" : "string",
        "value" : "unsupported"
      }
    },
    "explicit" : {
      "bundleName" : {
        "type" : "string",
        "value" : "Merged Pin"
      },
      "inputPayloads" : {
        "type" : "array",
        "value" : [
          {
            "type" : "file",
            "value" : "@/Alpha.lungfishref/genome/sequence.fa"
          },
          {
            "type" : "file",
            "value" : "@/Beta.lungfishref/genome/sequence.fa"
          }
        ]
      },
      "mergeMode" : {
        "type" : "string",
        "value" : "sequence-and-annotations"
      },
      "outputBundle" : {
        "type" : "file",
        "value" : "@/Merged_Pin.lungfishref"
      },
      "outputPayloads" : {
        "type" : "array",
        "value" : [
          {
            "type" : "file",
            "value" : "@/Merged_Pin.lungfishref/annotations/alpha_genes.db"
          },
          {
            "type" : "file",
            "value" : "@/Merged_Pin.lungfishref/annotations/beta_genes.db"
          },
          {
            "type" : "file",
            "value" : "@/Merged_Pin.lungfishref/genome/sequence.fa.gz"
          },
          {
            "type" : "file",
            "value" : "@/Merged_Pin.lungfishref/genome/sequence.fa.gz.fai"
          },
          {
            "type" : "file",
            "value" : "@/Merged_Pin.lungfishref/genome/sequence.fa.gz.gzi"
          },
          {
            "type" : "file",
            "value" : "@/Merged_Pin.lungfishref/manifest.json"
          }
        ]
      },
      "requestedBundleName" : {
        "type" : "string",
        "value" : "Merged Pin"
      },
      "resolvedBundleName" : {
        "type" : "string",
        "value" : "Merged Pin"
      },
      "sourceBundles" : {
        "type" : "array",
        "value" : [
          {
            "type" : "file",
            "value" : "@/Alpha.lungfishref"
          },
          {
            "type" : "file",
            "value" : "@/Beta.lungfishref"
          }
        ]
      }
    },
    "resolvedDefaults" : {
      "annotationMerge" : {
        "type" : "string",
        "value" : "preserved"
      },
      "compressFASTA" : {
        "type" : "boolean",
        "value" : true
      },
      "trackMerge" : {
        "type" : "string",
        "value" : "unsupported"
      },
      "variantMerge" : {
        "type" : "string",
        "value" : "unsupported"
      }
    }
  },
  "output" : {
    "format" : "unknown",
    "path" : "@/Merged_Pin.lungfishref/annotations/alpha_genes.db",
    "role" : "output"
  },
  "outputs" : [
    {
      "format" : "unknown",
      "path" : "@/Merged_Pin.lungfishref/annotations/alpha_genes.db",
      "role" : "output"
    },
    {
      "format" : "unknown",
      "path" : "@/Merged_Pin.lungfishref/annotations/beta_genes.db",
      "role" : "output"
    },
    {
      "format" : "fasta",
      "path" : "@/Merged_Pin.lungfishref/genome/sequence.fa.gz",
      "role" : "output"
    },
    {
      "format" : "text",
      "path" : "@/Merged_Pin.lungfishref/genome/sequence.fa.gz.fai",
      "role" : "output"
    },
    {
      "format" : "text",
      "path" : "@/Merged_Pin.lungfishref/genome/sequence.fa.gz.gzi",
      "role" : "output"
    },
    {
      "format" : "json",
      "path" : "@/Merged_Pin.lungfishref/manifest.json",
      "role" : "output"
    }
  ],
  "reproducibleCommand" : "lungfish-cli bundle merge @/Alpha.lungfishref @/Beta.lungfishref '--name=Merged Pin' --output-dir @/",
  "schemaVersion" : 2,
  "signatures" : [

  ],
  "status" : "completed",
  "steps" : [
    {
      "argv" : [
        "NativeBundleBuilder.build",
        "--name",
        "Merged Pin",
        "--identifier",
        "org.lungfish.merge.<UUID>",
        "--fasta",
        "@/.tmp/reference-merge-<UUID>/merged.fa",
        "--output-directory",
        "@/",
        "--bundle",
        "@/Merged_Pin.lungfishref",
        "--compress-fasta",
        "true",
        "--annotation",
        "@/.tmp/reference-merge-<UUID>/annotations/alpha_genes.gff3",
        "--annotation",
        "@/.tmp/reference-merge-<UUID>/annotations/beta_genes.gff3"
      ],
      "dependsOn" : [

      ],
      "durableReplayArgv" : [
        "NativeBundleBuilder.build",
        "--name",
        "Merged Pin",
        "--identifier",
        "org.lungfish.merge.<UUID>",
        "--fasta",
        "@/Merged_Pin.lungfishref/genome/sequence.fa.gz",
        "--output-directory",
        "@/",
        "--bundle",
        "@/Merged_Pin.lungfishref",
        "--compress-fasta",
        "true",
        "--annotation",
        "@/Merged_Pin.lungfishref/genome/sequence.fa.gz",
        "--annotation",
        "@/Merged_Pin.lungfishref/genome/sequence.fa.gz"
      ],
      "exitStatus" : 0,
      "id" : "<UUID>",
      "inputs" : [
        {
          "format" : "fasta",
          "path" : "@/Alpha.lungfishref/genome/sequence.fa",
          "role" : "input"
        },
        {
          "format" : "fasta",
          "path" : "@/Beta.lungfishref/genome/sequence.fa",
          "role" : "input"
        },
        {
          "format" : "fasta",
          "path" : "@/Merged_Pin.lungfishref/genome/sequence.fa.gz",
          "role" : "input"
        }
      ],
      "outputs" : [
        {
          "format" : "unknown",
          "path" : "@/Merged_Pin.lungfishref/annotations/alpha_genes.db",
          "role" : "output"
        },
        {
          "format" : "unknown",
          "path" : "@/Merged_Pin.lungfishref/annotations/beta_genes.db",
          "role" : "output"
        },
        {
          "format" : "fasta",
          "path" : "@/Merged_Pin.lungfishref/genome/sequence.fa.gz",
          "role" : "output"
        },
        {
          "format" : "text",
          "path" : "@/Merged_Pin.lungfishref/genome/sequence.fa.gz.fai",
          "role" : "output"
        },
        {
          "format" : "text",
          "path" : "@/Merged_Pin.lungfishref/genome/sequence.fa.gz.gzi",
          "role" : "output"
        },
        {
          "format" : "json",
          "path" : "@/Merged_Pin.lungfishref/manifest.json",
          "role" : "output"
        }
      ],
      "reproducibleCommand" : "NativeBundleBuilder.build --name 'Merged Pin' --identifier org.lungfish.merge.<UUID> --fasta @/Merged_Pin.lungfishref/genome/sequence.fa.gz --output-directory @/ --bundle @/Merged_Pin.lungfishref --compress-fasta true --annotation @/Merged_Pin.lungfishref/genome/sequence.fa.gz --annotation @/Merged_Pin.lungfishref/genome/sequence.fa.gz",
      "resolvedOptions" : {

      },
      "toolName" : "NativeBundleBuilder.build"
    },
    {
      "argv" : [
        "lungfish-cli",
        "bundle",
        "merge",
        "@/Alpha.lungfishref",
        "@/Beta.lungfishref",
        "--name=Merged Pin",
        "--output-dir",
        "@/"
      ],
      "dependsOn" : [

      ],
      "durableReplayArgv" : [
        "lungfish-cli",
        "bundle",
        "merge",
        "@/Alpha.lungfishref",
        "@/Beta.lungfishref",
        "--name=Merged Pin",
        "--output-dir",
        "@/"
      ],
      "exitStatus" : 0,
      "id" : "<UUID>",
      "inputs" : [
        {
          "format" : "fasta",
          "path" : "@/Alpha.lungfishref/genome/sequence.fa",
          "role" : "input"
        },
        {
          "format" : "fasta",
          "path" : "@/Beta.lungfishref/genome/sequence.fa",
          "role" : "input"
        }
      ],
      "outputs" : [
        {
          "format" : "unknown",
          "path" : "@/Merged_Pin.lungfishref/annotations/alpha_genes.db",
          "role" : "output"
        },
        {
          "format" : "unknown",
          "path" : "@/Merged_Pin.lungfishref/annotations/beta_genes.db",
          "role" : "output"
        },
        {
          "format" : "fasta",
          "path" : "@/Merged_Pin.lungfishref/genome/sequence.fa.gz",
          "role" : "output"
        },
        {
          "format" : "text",
          "path" : "@/Merged_Pin.lungfishref/genome/sequence.fa.gz.fai",
          "role" : "output"
        },
        {
          "format" : "text",
          "path" : "@/Merged_Pin.lungfishref/genome/sequence.fa.gz.gzi",
          "role" : "output"
        },
        {
          "format" : "json",
          "path" : "@/Merged_Pin.lungfishref/manifest.json",
          "role" : "output"
        }
      ],
      "reproducibleCommand" : "lungfish-cli bundle merge @/Alpha.lungfishref @/Beta.lungfishref '--name=Merged Pin' --output-dir @/",
      "resolvedOptions" : {

      },
      "toolName" : "lungfish bundle merge"
    }
  ],
  "tool" : {
    "kind" : "cli",
    "name" : "lungfish bundle merge",
    "version" : "Lungfish 2026.10.10 (dev)"
  },
  "toolName" : "lungfish bundle merge",
  "workflowName" : "lungfish bundle merge"
}
"""#
}
