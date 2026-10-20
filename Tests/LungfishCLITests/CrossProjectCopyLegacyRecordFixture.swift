// CrossProjectCopyLegacyRecordFixture.swift - One cross-project copy of a released Lungfish, frozen as text
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 (DEL-REST), review N1 item 3 of lane 12.18. The in-app copier recorded a read
// bundle's copy as `lungfish fastq import-ont <source> --output <copy>` with `caller` `app-cross-project-copy`.
// This record was written once by that copier (`.appLegacy`, the default identity of
// `CrossProjectItemCopier.copy`) from the read bundle below, in the layout `ProjectItemCopyRecordTests+SchemaOne.swift`
// freezes for the schema 1 `project-copy.json` that a released app wrote. It holds placeholders only. A path
// outside the copy's project reads as `<external>/<file name>`, the project itself as `@/`, and the schema 1
// record names the source with the paths of an example user. The tests build the replay source from the bytes
// below, so an edit to the workflow or the hasher cannot change what this test calls old.

enum CrossProjectCopyLegacyRecordFixture {
    /// The one file of the source read bundle.
    static let sourceReads = "@r1\nACGT\n+\nIIII\n"

    /// The source bundle's envelope, which the bundle holds three times (`.lungfish-provenance.json` and two under `provenance/`).
    static let sourceProvenance = """
    {
      "argv" : [
        "source-fastq-tool",
        "reads.fastq"
      ],
      "createdAt" : "2026-10-20T14:16:09Z",
      "exitStatus" : 0,
      "files" : [
        {
          "checksumSHA256" : "8add5b3bf0a7df65f939b0f2f0650f97ae63c37796bf0d1e769b384e666986cd",
          "fileSize" : 16,
          "format" : "fastq",
          "path" : "@/Imports/R.lungfishfastq/reads.fastq",
          "role" : "output"
        }
      ],
      "id" : "3B0FE58F-E951-4CBA-9DC2-E2298929E5AA",
      "options" : {
        "defaults" : {

        },
        "explicit" : {

        },
        "resolvedDefaults" : {

        }
      },
      "output" : {
        "checksumSHA256" : "8add5b3bf0a7df65f939b0f2f0650f97ae63c37796bf0d1e769b384e666986cd",
        "fileSize" : 16,
        "format" : "fastq",
        "path" : "@/Imports/R.lungfishfastq/reads.fastq",
        "role" : "output"
      },
      "outputs" : [
        {
          "checksumSHA256" : "8add5b3bf0a7df65f939b0f2f0650f97ae63c37796bf0d1e769b384e666986cd",
          "fileSize" : 16,
          "format" : "fastq",
          "path" : "@/Imports/R.lungfishfastq/reads.fastq",
          "role" : "output"
        }
      ],
      "reproducibleCommand" : "source-fastq-tool reads.fastq",
      "runtimeIdentity" : {
        "appVersion" : "Lungfish 2026.10.10 (dev)",
        "architecture" : "arm64",
        "dependencySet" : "2026.2",
        "executablePath" : "<external>/xctest",
        "managedToolLockSHA256" : "7e812c4966d81884f8c5ce03a6aea1bf195aa1b94adff3edb8c225e1ef104c48",
        "operatingSystemVersion" : "macOS 26.7.1 (arm64)"
      },
      "schemaVersion" : 2,
      "signatures" : [

      ],
      "status" : "completed",
      "steps" : [
        {
          "argv" : [
            "source-fastq-tool",
            "reads.fastq"
          ],
          "dependsOn" : [

          ],
          "exitStatus" : 0,
          "id" : "0DB84238-D5B6-4EAA-8BDA-C3E4107270E0",
          "inputs" : [

          ],
          "outputs" : [
            {
              "checksumSHA256" : "8add5b3bf0a7df65f939b0f2f0650f97ae63c37796bf0d1e769b384e666986cd",
              "fileSize" : 16,
              "format" : "fastq",
              "path" : "@/Imports/R.lungfishfastq/reads.fastq",
              "role" : "output"
            }
          ],
          "reproducibleCommand" : "source-fastq-tool reads.fastq",
          "resolvedOptions" : {

          },
          "toolName" : "source-fastq-tool",
          "toolVersion" : "1.0",
          "wallTimeSeconds" : 0.1
        }
      ],
      "tool" : {
        "name" : "source-fastq-tool",
        "version" : "1.0"
      },
      "toolName" : "source-fastq-tool",
      "toolVersion" : "1.0",
      "wallTimeSeconds" : 0.1,
      "workflowName" : "source FASTQ bundle",
      "workflowVersion" : "1.0"
    }
    """

    /// The copy's `.lungfish-provenance.json`, as the copier wrote it.
    static let copyProvenance = """
    {
      "argv" : [
        "lungfish-cli",
        "fastq",
        "import-ont",
        "<external>/R.lungfishfastq",
        "--output",
        "@/Imports/R.lungfishfastq"
      ],
      "createdAt" : "2026-10-20T14:16:09Z",
      "durableReplayArgv" : [
        "lungfish-cli",
        "fastq",
        "import-ont",
        "<external>/R.lungfishfastq",
        "--output",
        "@/Imports/R.lungfishfastq"
      ],
      "exitStatus" : 0,
      "files" : [
        {
          "checksumSHA256" : "8add5b3bf0a7df65f939b0f2f0650f97ae63c37796bf0d1e769b384e666986cd",
          "fileSize" : 16,
          "format" : "fastq",
          "originPath" : "<external>/reads.fastq",
          "path" : "@/Imports/R.lungfishfastq/reads.fastq",
          "role" : "output",
          "sourceProvenancePath" : "<external>/reads.fastq.lungfish-provenance.json"
        },
        {
          "checksumSHA256" : "8add5b3bf0a7df65f939b0f2f0650f97ae63c37796bf0d1e769b384e666986cd",
          "fileSize" : 16,
          "format" : "fastq",
          "path" : "<external>/reads.fastq",
          "role" : "input",
          "sourceProvenancePath" : "<external>/.lungfish-provenance.json"
        },
        {
          "format" : "unknown",
          "originPath" : "<external>/R.lungfishfastq",
          "path" : "@/Imports/R.lungfishfastq",
          "role" : "output",
          "sourceProvenancePath" : "<external>/.lungfish-provenance.json"
        }
      ],
      "id" : "A8F28F2A-8F2D-49FE-BA08-D86D8E2E9A2E",
      "options" : {
        "defaults" : {
          "copyMode" : {
            "type" : "string",
            "value" : "none"
          },
          "sourceKind" : {
            "type" : "string",
            "value" : "raw-ont-directory"
          }
        },
        "explicit" : {
          "input" : {
            "type" : "file",
            "value" : "<external>/R.lungfishfastq"
          },
          "output" : {
            "type" : "file",
            "value" : "@/Imports/R.lungfishfastq"
          }
        },
        "resolvedDefaults" : {
          "caller" : {
            "type" : "string",
            "value" : "app-cross-project-copy"
          },
          "copyMode" : {
            "type" : "string",
            "value" : "atomic-bundle-copy"
          },
          "destinationBundle" : {
            "type" : "file",
            "value" : "@/Imports/R.lungfishfastq"
          },
          "input" : {
            "type" : "file",
            "value" : "<external>/R.lungfishfastq"
          },
          "output" : {
            "type" : "file",
            "value" : "@/Imports/R.lungfishfastq"
          },
          "sourceKind" : {
            "type" : "string",
            "value" : "existing-fastq-bundle"
          },
          "sourceProject" : {
            "type" : "file",
            "value" : "<external>/S.lungfish"
          }
        }
      },
      "output" : {
        "format" : "unknown",
        "originPath" : "<external>/R.lungfishfastq",
        "path" : "@/Imports/R.lungfishfastq",
        "role" : "output",
        "sourceProvenancePath" : "<external>/.lungfish-provenance.json"
      },
      "outputs" : [
        {
          "format" : "unknown",
          "originPath" : "<external>/R.lungfishfastq",
          "path" : "@/Imports/R.lungfishfastq",
          "role" : "output",
          "sourceProvenancePath" : "<external>/.lungfish-provenance.json"
        },
        {
          "checksumSHA256" : "8add5b3bf0a7df65f939b0f2f0650f97ae63c37796bf0d1e769b384e666986cd",
          "fileSize" : 16,
          "format" : "fastq",
          "originPath" : "<external>/reads.fastq",
          "path" : "@/Imports/R.lungfishfastq/reads.fastq",
          "role" : "output",
          "sourceProvenancePath" : "<external>/.lungfish-provenance.json"
        }
      ],
      "reproducibleCommand" : "lungfish-cli fastq import-ont <external>/R.lungfishfastq --output @/Imports/R.lungfishfastq",
      "runtimeIdentity" : {
        "appVersion" : "Lungfish 2026.10.10 (dev)",
        "architecture" : "arm64",
        "dependencySet" : "2026.2",
        "executablePath" : "<external>/xctest",
        "managedToolLockSHA256" : "7e812c4966d81884f8c5ce03a6aea1bf195aa1b94adff3edb8c225e1ef104c48",
        "operatingSystemVersion" : "macOS 26.7.1 (arm64)"
      },
      "schemaVersion" : 2,
      "signatures" : [

      ],
      "status" : "completed",
      "steps" : [
        {
          "argv" : [
            "source-fastq-tool",
            "reads.fastq"
          ],
          "dependsOn" : [

          ],
          "durableReplayArgv" : [
            "source-fastq-tool",
            "reads.fastq"
          ],
          "exitStatus" : 0,
          "id" : "0DB84238-D5B6-4EAA-8BDA-C3E4107270E0",
          "inputs" : [

          ],
          "outputs" : [
            {
              "checksumSHA256" : "8add5b3bf0a7df65f939b0f2f0650f97ae63c37796bf0d1e769b384e666986cd",
              "fileSize" : 16,
              "format" : "fastq",
              "originPath" : "<external>/reads.fastq",
              "path" : "@/Imports/R.lungfishfastq/reads.fastq",
              "role" : "output",
              "sourceProvenancePath" : "<external>/reads.fastq.lungfish-provenance.json"
            }
          ],
          "reproducibleCommand" : "source-fastq-tool reads.fastq",
          "resolvedOptions" : {

          },
          "toolName" : "source-fastq-tool",
          "toolVersion" : "1.0",
          "wallTimeSeconds" : 0.1
        },
        {
          "argv" : [
            "lungfish-cli",
            "fastq",
            "import-ont",
            "<external>/R.lungfishfastq",
            "--output",
            "@/Imports/R.lungfishfastq"
          ],
          "completedAt" : "2026-10-20T14:16:09Z",
          "dependsOn" : [

          ],
          "durableReplayArgv" : [
            "lungfish-cli",
            "fastq",
            "import-ont",
            "<external>/R.lungfishfastq",
            "--output",
            "@/Imports/R.lungfishfastq"
          ],
          "exitStatus" : 0,
          "id" : "770D32A4-55AC-49A0-997E-104B28A64910",
          "inputs" : [
            {
              "checksumSHA256" : "8add5b3bf0a7df65f939b0f2f0650f97ae63c37796bf0d1e769b384e666986cd",
              "fileSize" : 16,
              "format" : "fastq",
              "path" : "<external>/reads.fastq",
              "role" : "input",
              "sourceProvenancePath" : "<external>/.lungfish-provenance.json"
            }
          ],
          "outputs" : [
            {
              "format" : "unknown",
              "originPath" : "<external>/R.lungfishfastq",
              "path" : "@/Imports/R.lungfishfastq",
              "role" : "output",
              "sourceProvenancePath" : "<external>/.lungfish-provenance.json"
            },
            {
              "checksumSHA256" : "8add5b3bf0a7df65f939b0f2f0650f97ae63c37796bf0d1e769b384e666986cd",
              "fileSize" : 16,
              "format" : "fastq",
              "originPath" : "<external>/reads.fastq",
              "path" : "@/Imports/R.lungfishfastq/reads.fastq",
              "role" : "output",
              "sourceProvenancePath" : "<external>/.lungfish-provenance.json"
            }
          ],
          "reproducibleCommand" : "lungfish-cli fastq import-ont <external>/R.lungfishfastq --output @/Imports/R.lungfishfastq",
          "resolvedOptions" : {

          },
          "startedAt" : "2026-10-20T14:16:09Z",
          "toolName" : "lungfish fastq import-ont",
          "toolVersion" : "Lungfish 2026.10.10 (dev)",
          "wallTimeSeconds" : 0.006427288055419922
        }
      ],
      "tool" : {
        "kind" : "cli",
        "name" : "lungfish fastq import-ont",
        "version" : "Lungfish 2026.10.10 (dev)"
      },
      "toolName" : "lungfish fastq import-ont",
      "toolVersion" : "Lungfish 2026.10.10 (dev)",
      "wallTimeSeconds" : 0.006427288055419922,
      "workflowName" : "lungfish fastq import-ont",
      "workflowVersion" : "Lungfish 2026.10.10 (dev)"
    }
    """

    /// The copy's `project-copy.json`, a schema 1 record, which has no `sourceItemFiles`.
    static let copyRecord = """
    {
      "copiedAt" : "2026-09-24T10:00:00Z",
      "links" : [

      ],
      "schemaVersion" : 1,
      "sourceItemPath" : "/Users/example/Source.lungfish/Imports/R.lungfishfastq",
      "sourceProjectPath" : "/Users/example/Source.lungfish",
      "targetProjectPath" : "/Users/example/Target.lungfish"
    }
    """
}
